#!/usr/bin/env python3
"""
upstream-builder engine.

只做四件事，且都不依赖第三方库：
  1. validate  校验 upstream.json（严格：未知字段直接报错）
  2. plan      解析上游 ref -> SHA，判断哪些项目需要构建（增量 + 节流）
  3. fetch     按 SHA 下载源码快照到临时目录（不落库）
  4. env/record/report  给 shell 构建脚本喂配置、写状态、汇总报告

设计要点见 upstream-builder-可行性评审.md：
  - 源码不进管理仓库（layout=none），所以不存在 .gitignore 互相污染；
  - 上游是「不可信输入」，解压做路径穿越防护；
  - 构建需要的所有信息通过 `env` 以 KEY=VALUE 交给 shell，shell 不解析 JSON。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 2

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
REPO_RE = re.compile(r"^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+?)(?:\.git)?$")
IMAGE_RE = re.compile(r"^ghcr\.io/[a-z0-9._-]+/[a-z0-9._/-]+$")

LANGUAGES = {"go", "python", "node", "rust", "none"}
METHODS = {"native", "dockerfile", "custom", "none"}  # "none" = 纯镜像项目，不做编译
STRATEGIES = {"upstream", "generated", "custom"}
TAG_STRATEGIES = {"upstream-tag", "sha", "rolling-prerelease"}
REF_TYPES = {"branch", "tag", "commit", "release-latest"}
OSES = {"linux", "darwin", "windows"}
ARCHES = {"amd64", "arm64", "arm"}
# 冻结/打包型语言不能交叉编译出目标平台的独立二进制
NO_CROSS_COMPILE = {"python", "node"}


class UbError(Exception):
    pass


class ConfigError(UbError):
    def __init__(self, problems):
        self.problems = problems
        super().__init__("\n".join(problems))


# --------------------------------------------------------------------------
# 小工具
# --------------------------------------------------------------------------

def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def die(msg: str, code: int = 1):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def parse_target(t: str):
    if not isinstance(t, str) or "/" not in t:
        raise UbError(f"target 格式必须是 <os>/<arch>，收到: {t!r}")
    os_, _, arch = t.partition("/")
    if os_ not in OSES:
        raise UbError(f"不支持的 os: {os_!r}（支持 {sorted(OSES)}）")
    if arch not in ARCHES:
        raise UbError(f"不支持的 arch: {arch!r}（支持 {sorted(ARCHES)}）")
    return os_, arch


def target_to_platform(os_: str, arch: str) -> str:
    return f"linux/{arch}" if os_ == "linux" else f"{os_}/{arch}"


def release_asset_name(name: str, version: str, os_: str, arch: str) -> str:
    return f"{name}-{version}-{os_}-{arch}.tar.gz"


# --------------------------------------------------------------------------
# 配置：严格校验
# --------------------------------------------------------------------------

def _check_keys(where, obj, allowed, required=()):
    problems = []
    if not isinstance(obj, dict):
        return [f"{where}: 必须是对象，收到 {type(obj).__name__}"]
    for k in obj:
        if k not in allowed:
            hint = ""
            close = [a for a in allowed if a.lower().startswith(str(k).lower()[:3])]
            if close:
                hint = f"（是否想写 {'/'.join(sorted(close))}？）"
            problems.append(f"{where}.{k}: 未知字段{hint}")
    for k in required:
        if k not in obj:
            problems.append(f"{where}.{k}: 必填字段缺失")
    return problems


DEFAULTS_KEYS = {"targets", "continue_on_error", "runners"}
SYNC_KEYS = {"layout", "state_file", "workdir", "vendor_dir"}
REF_KEYS = {"type", "value"}
BUILD_KEYS = {
    "enabled", "language", "method", "go_version", "python_version", "node_version",
    "workdir", "package", "binary", "ldflags", "trimpath", "env", "script",
    "targets", "assets", "test", "cross_compile", "build_args", "dist_suffix",
}
TEST_KEYS = {"enabled", "required", "command"}
DOCKER_KEYS = {
    "enabled", "strategy", "image", "dockerfile", "context", "targets",
    "provenance", "build_args", "smoke", "platforms", "tags", "native_per_arch", "entrypoint", "env",
    "exposed_ports", "volumes", "user", "base_image",
}
SMOKE_KEYS = {"container_port", "path", "expect", "timeout", "command"}
RELEASE_KEYS = {"enabled", "binary", "tag_strategy", "assets"}
PROJECT_KEYS = {"name", "repo", "ref", "version_source", "build", "docker", "release", "sync", "throttle"}
THROTTLE_KEYS = {"min_interval_hours"}


def validate_config(cfg) -> list:
    p = []
    if not isinstance(cfg, dict):
        return ["配置根节点必须是 JSON 对象"]
    p += _check_keys("root", cfg, {"version", "defaults", "sync", "projects"}, ("version", "projects"))

    if cfg.get("version") != SCHEMA_VERSION:
        p.append(f"version: 必须是 {SCHEMA_VERSION}，收到 {cfg.get('version')!r}")

    defaults = cfg.get("defaults", {})
    p += _check_keys("defaults", defaults, DEFAULTS_KEYS)
    p += _check_keys("defaults.runners", defaults.get("runners", {}), {"amd64", "arm64", "arm"})
    for a, lbl in (defaults.get("runners") or {}).items():
        if not isinstance(lbl, str) or not lbl:
            p.append(f"defaults.runners.{a}: 必须是 runner label 字符串")
    for t in defaults.get("targets", []):
        try:
            parse_target(t)
        except UbError as e:
            p.append(f"defaults.targets: {e}")

    sync = cfg.get("sync", {})
    p += _check_keys("sync", sync, SYNC_KEYS)
    layout = sync.get("layout", "vendor")
    if layout not in {"none", "vendor"}:
        p.append(f"sync.layout: 只支持 'vendor'（源码落库到 vendor/<name>/）或 'none'，收到 {layout!r}")
    if layout == "vendor" and not is_safe_relpath(sync.get("vendor_dir", "vendor")):
        p.append(f"sync.vendor_dir: 非法相对路径 {sync.get('vendor_dir')!r}")

    projects = cfg.get("projects")
    if not isinstance(projects, list) or not projects:
        p.append("projects: 必须是非空数组")
        return p

    seen = set()
    for i, proj in enumerate(projects):
        where = f"projects[{i}]"
        if isinstance(proj, dict) and proj.get("name"):
            where = f"projects[{i}]({proj['name']})"
        errs = validate_project(where, proj, defaults)
        p += errs
        if isinstance(proj, dict):
            n = proj.get("name")
            if n in seen:
                p.append(f"{where}.name: 项目名重复：{n!r}")
            seen.add(n)
    return p


def validate_project(where, proj, defaults) -> list:
    p = _check_keys(where, proj, PROJECT_KEYS, ("name", "repo", "ref"))
    if not isinstance(proj, dict):
        return p

    name = proj.get("name")
    if not isinstance(name, str) or not NAME_RE.match(name) or name in {".", ".."}:
        p.append(f"{where}.name: 非法项目名（只允许字母数字开头，含 . _ -，禁止 / 与 ..）：{name!r}")

    repo = proj.get("repo")
    if not isinstance(repo, str) or not REPO_RE.match(repo):
        p.append(f"{where}.repo: 必须是 https://github.com/<owner>/<repo>：{repo!r}")
    else:
        rname = REPO_RE.match(repo).group(2)
        if rname.lower() in {"upstream-builder", "."}:
            p.append(f"{where}.repo: 不能把管理仓库自身登记为上游")

    ref = proj.get("ref", {})
    p += _check_keys(f"{where}.ref", ref, REF_KEYS, ("type",))
    if isinstance(ref, dict):
        rt = ref.get("type")
        if rt not in REF_TYPES:
            p.append(f"{where}.ref.type: 不支持的 ref 类型 {rt!r}（支持 {sorted(REF_TYPES)}）")
        if rt in {"branch", "tag", "commit"} and not ref.get("value"):
            p.append(f"{where}.ref.value: ref.type={rt} 时必须提供 value")
        if rt == "release-latest" and ref.get("value"):
            p.append(f"{where}.ref.value: ref.type=release-latest 不接受 value")

    vs = proj.get("version_source", "sha")
    if vs not in {"tag", "sha"}:
        p.append(f"{where}.version_source: 必须是 tag 或 sha，收到 {vs!r}")
    if vs == "tag" and isinstance(ref, dict) and ref.get("type") == "branch":
        p.append(f"{where}.version_source: ref 是 branch 时不可能有 tag 版本，请用 sha")

    p += _check_keys(f"{where}.throttle", proj.get("throttle", {}), THROTTLE_KEYS)
    th = proj.get("throttle", {})
    if isinstance(th, dict) and "min_interval_hours" in th:
        v = th["min_interval_hours"]
        if not isinstance(v, (int, float)) or v <= 0:
            p.append(f"{where}.throttle.min_interval_hours: 必须是正数，收到 {v!r}")

    # ---- build ----
    build = proj.get("build", {})
    p += _check_keys(f"{where}.build", build, BUILD_KEYS)
    # 省略 build 段（或显式 enabled=false）表示纯镜像项目，不要求 language/method
    build_enabled = bool(build.get("enabled", bool(build))) if isinstance(build, dict) else False
    if isinstance(build, dict):
        lang = build.get("language", "none")
        method = build.get("method", "none")
        if lang not in LANGUAGES:
            p.append(f"{where}.build.language: 不支持 {lang!r}（支持 {sorted(LANGUAGES)}）")
        if method not in METHODS:
            p.append(f"{where}.build.method: 不支持 {method!r}（支持 {sorted(METHODS)}）")
        if build_enabled:
            if method == "none":
                p.append(f"{where}.build.method: build.enabled=true 时必须指定 method（native/dockerfile/custom）")
            if method == "native" and lang in {"none", None}:
                p.append(f"{where}.build: method=native 需要具体 language")
            if method == "custom" and not build.get("script"):
                p.append(f"{where}.build.script: method=custom 时必须提供适配器脚本路径")
            if method == "dockerfile" and not is_safe_relpath(build.get("workdir", ".")):
                p.append(f"{where}.build.workdir: 非法相对路径 {build.get('workdir')!r}")
            if lang == "go" and method == "native":
                if not build.get("package"):
                    p.append(f"{where}.build.package: Go 原生构建必须显式指定入口包"
                             "（例：./cmd/xxx；写 \".\" 只在 main 包位于根目录时成立）")
                if not build.get("binary"):
                    p.append(f"{where}.build.binary: Go 原生构建必须指定输出二进制名")
                if not build.get("go_version"):
                    p.append(f"{where}.build.go_version: Go 构建必须指定 go_version")
        for t in build.get("targets", []):
            try:
                parse_target(t)
            except UbError as e:
                p.append(f"{where}.build.targets: {e}")
        p += _check_keys(f"{where}.build.test", build.get("test", {}), TEST_KEYS)
        assets = build.get("assets", [])
        if not isinstance(assets, list):
            p.append(f"{where}.build.assets: 必须是数组")
        else:
            for j, a in enumerate(assets):
                p += _check_keys(f"{where}.build.assets[{j}]", a, {"run", "workdir", "shell"})
                if isinstance(a, dict) and not a.get("run"):
                    p.append(f"{where}.build.assets[{j}].run: 必填")

        # 能力一致性：这是多语言扩展的关键约束
        cross = build.get("cross_compile", True)
        targets = build.get("targets") or defaults.get("targets", [])
        arches = {parse_target(t)[1] for t in targets if "/" in str(t)}
        if lang in NO_CROSS_COMPILE and cross and len(arches) > 1:
            p.append(f"{where}.build.cross_compile: {lang} 无法交叉编译出多架构产物，"
                     f"声明 cross_compile=true 但 targets 含 {sorted(arches)}；"
                     "必须改为 false 并使用原生 runner（例如 ubuntu-24.04-arm）")
        if lang in NO_CROSS_COMPILE and proj.get("release", {}).get("binary") and cross:
            p.append(f"{where}.build.cross_compile: {lang} 的独立二进制（冻结打包）不能交叉编译，"
                     "release.binary=true 时必须 cross_compile=false")

    # ---- docker ----
    docker = proj.get("docker", {})
    p += _check_keys(f"{where}.docker", docker, DOCKER_KEYS)
    if isinstance(docker, dict) and docker.get("enabled"):
        strat = docker.get("strategy")
        if strat not in STRATEGIES:
            p.append(f"{where}.docker.strategy: 启用镜像时必填且必须是 {sorted(STRATEGIES)} 之一")
        img = docker.get("image")
        if not img:
            p.append(f"{where}.docker.image: 启用镜像时必须提供 GHCR 镜像名")
        else:
            probe = str(img).replace("{owner}", "owner")
            if not IMAGE_RE.match(probe):
                p.append(f"{where}.docker.image: 必须是 ghcr.io/<owner>/<name> 形式（可用 {{owner}} 占位）：{img!r}")
        if strat in {"upstream", "custom"} and not docker.get("dockerfile"):
            p.append(f"{where}.docker.dockerfile: strategy={strat} 时必须指定 Dockerfile 路径")
        for key in ("dockerfile", "context"):
            if docker.get(key) and not is_safe_relpath(docker[key]):
                p.append(f"{where}.docker.{key}: 非法相对路径 {docker[key]!r}（禁止绝对路径与 ..）")
        dt = docker.get("targets") or docker.get("platforms") or []
        for t in dt:
            try:
                os_, _ = parse_target(t)
                if os_ != "linux":
                    p.append(f"{where}.docker.targets: 镜像只能是 linux 平台，收到 {t!r}")
            except UbError as e:
                p.append(f"{where}.docker.targets: {e}")
        for k in ("native_per_arch", "provenance"):
            if k in docker and not isinstance(docker[k], bool):
                p.append(f"{where}.docker.{k}: 必须是布尔值")
        tags = docker.get("tags")
        if tags is not None and (not isinstance(tags, list) or not all(isinstance(x, str) and x for x in tags)):
            p.append(f"{where}.docker.tags: 必须是非空字符串数组")
        p += _check_keys(f"{where}.docker.smoke", docker.get("smoke", {}), SMOKE_KEYS)
        sm = docker.get("smoke", {})
        if isinstance(sm, dict):
            if "expect" in sm and not isinstance(sm["expect"], list):
                p.append(f"{where}.docker.smoke.expect: 必须是状态码数组，例 [200] 或 [200,403]")
            if sm.get("container_port") is not None and not isinstance(sm["container_port"], int):
                p.append(f"{where}.docker.smoke.container_port: 必须是整数")
            if not sm.get("command"):
                if sm.get("container_port") is None:
                    p.append(f"{where}.docker.smoke: 必须给出 container_port 或 command")
                if not sm.get("path"):
                    p.append(f"{where}.docker.smoke.path: 必须显式指定健康检查路径"
                             "（不能假设 / 返回 200）")

    # ---- release ----
    release = proj.get("release", {})
    p += _check_keys(f"{where}.release", release, RELEASE_KEYS | {"_note"})
    if isinstance(release, dict) and release.get("enabled"):
        ts = release.get("tag_strategy")
        if ts not in TAG_STRATEGIES:
            p.append(f"{where}.release.tag_strategy: 启用发布时必填且必须是 {sorted(TAG_STRATEGIES)} 之一")
        if ts == "upstream-tag" and proj.get("version_source") != "tag":
            p.append(f"{where}.release.tag_strategy: upstream-tag 需要 version_source=tag")
        if release.get("binary") and not build_enabled:
            p.append(f"{where}.release.binary: 二进制发布要求 build.enabled=true 且有可编译的产物")
    return p


def is_safe_relpath(path) -> bool:
    if not isinstance(path, str) or not path:
        return False
    if os.path.isabs(path) or Path(path).is_absolute():
        return False
    parts = Path(path).parts
    return ".." not in parts


# --------------------------------------------------------------------------
# 配置加载
# --------------------------------------------------------------------------

def load_config(path) -> dict:
    try:
        cfg = json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        die(f"配置文件不存在: {path}")
    except json.JSONDecodeError as e:
        die(f"upstream.json 语法错误: 第 {e.lineno} 行第 {e.colno} 列: {e.msg}")
    problems = validate_config(cfg)
    if problems:
        print("配置校验失败：", file=sys.stderr)
        for x in problems:
            print(f"  - {x}", file=sys.stderr)
        sys.exit(2)
    return cfg


def select_projects(cfg, which):
    if which in (None, "all"):
        return cfg["projects"]
    names = [n.strip() for n in str(which).split(",") if n.strip()]
    out = [p for p in cfg["projects"] if p["name"] in names]
    missing = set(names) - {p["name"] for p in out}
    if missing:
        die(f"配置里没有这些项目: {sorted(missing)}")
    return out


def get_project(cfg, name):
    for p in cfg["projects"]:
        if p["name"] == name:
            return p
    die(f"配置里没有项目: {name}")


def state_path(cfg, override=None) -> Path:
    return Path(override or cfg.get("sync", {}).get("state_file", "reports/upstream-state.json"))


def load_state(path: Path) -> dict:
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"version": 1, "updated_at": None, "projects": {}}


def save_state(path: Path, st: dict):
    st["updated_at"] = now_iso()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(st, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")


# --------------------------------------------------------------------------
# GitHub API
# --------------------------------------------------------------------------

def github_get(url: str, token: str | None):
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "upstream-builder",
    })
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:300]
        raise UbError(f"GitHub API {e.code} for {url}: {body}")
    except urllib.error.URLError as e:
        raise UbError(f"GitHub API 无法访问 {url}: {e.reason}")


def resolve_ref(proj: dict, token: str | None):
    """返回 (sha, version_label)。"""
    repo = proj["repo"].removesuffix(".git")
    ref = proj.get("ref", {})
    rt = ref.get("type")
    if rt == "release-latest":
        rel = github_get(f"https://api.github.com/repos/{repo.split('github.com/')[1]}/releases/latest", token)
        if "tag_name" not in rel:
            raise UbError(f"{repo}: 取 latest release 失败: {rel}")
        tag = rel["tag_name"]
        sha = _commit_sha(repo, tag, token)
        return sha, tag
    if rt in {"branch", "tag", "commit"}:
        value = ref["value"]
        sha = _commit_sha(repo, value, token)
        return sha, (value if rt == "tag" else sha[:7])
    raise UbError(f"{repo}: 未知 ref 类型 {rt!r}")


def _commit_sha(repo_url: str, ref: str, token: str | None) -> str:
    slug = repo_url.split("github.com/")[-1]
    data = github_get(f"https://api.github.com/repos/{slug}/commits/{ref}", token)
    if isinstance(data, dict) and data.get("sha"):
        return data["sha"]
    raise UbError(f"{repo_url}: 无法解析 {ref} 的 commit SHA")


# --------------------------------------------------------------------------
# 源码快照：按 SHA 下载，不落库
# --------------------------------------------------------------------------

def _safe_extract(tar: tarfile.TarFile, dest: Path):
    dest = dest.resolve()
    for m in tar.getmembers():
        name = m.name
        if name.startswith("/") or ".." in Path(name).parts:
            raise UbError(f"归档里有不安全路径: {name!r}")
        if m.issym() or m.islnk():
            link = m.linkname
            if os.path.isabs(link) or ".." in Path(link).parts:
                raise UbError(f"归档里有指向外部的链接: {name!r} -> {link!r}")
    tar.extractall(dest)


def tree_digest(root: Path) -> tuple[str, int]:
    h = hashlib.sha256()
    files = sorted(p for p in root.rglob("*") if p.is_file())
    for p in files:
        rel = p.relative_to(root).as_posix()
        h.update(rel.encode())
        h.update(b"\0")
        h.update(str(p.stat().st_size).encode())
        h.update(b"\0")
        fh = hashlib.sha256()
        with p.open("rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                fh.update(chunk)
        h.update(fh.hexdigest().encode())
        h.update(b"\n")
    return h.hexdigest(), len(files)


def fetch_snapshot(proj: dict, sha: str, dest: Path, token: str | None) -> dict:
    slug = proj["repo"].split("github.com/")[-1].removesuffix(".git")
    url = f"https://codeload.github.com/{slug}/tar.gz/{sha}"
    tmp = dest.parent / f"{dest.name}.tar.gz"
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        shutil.rmtree(dest)
    if tmp.exists():
        tmp.unlink()

    req = urllib.request.Request(url, headers={"User-Agent": "upstream-builder"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=180) as r, tmp.open("wb") as f:
            shutil.copyfileobj(r, f)
    except urllib.error.HTTPError as e:
        raise UbError(f"下载源码失败 {url}: HTTP {e.code}")
    except urllib.error.URLError as e:
        raise UbError(f"下载源码失败 {url}: {e.reason}")

    size = tmp.stat().st_size
    if size < 512:
        raise UbError(f"归档异常（{size} 字节），拒绝使用: {url}")

    staging = dest.parent / f"{dest.name}.staging"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    with tarfile.open(tmp, "r:gz") as tar:
        _safe_extract(tar, staging)
    tmp.unlink()

    tops = [d for d in staging.iterdir()]
    if len(tops) != 1 or not tops[0].is_dir():
        raise UbError(f"归档结构异常：顶层应有且仅有一个目录，实际 {[t.name for t in tops]}")
    root = tops[0]

    # 上游是外部输入：剔除 .git（tarball 一般没有，防御性处理）
    gitdir = root / ".git"
    if gitdir.exists():
        shutil.rmtree(gitdir)

    digest, nfiles = tree_digest(root)
    if nfiles == 0:
        raise UbError("源码快照为空，拒绝使用")

    shutil.move(str(root), str(dest))
    shutil.rmtree(staging, ignore_errors=True)

    return {
        "project": proj["name"],
        "repo": proj["repo"],
        "sha": sha,
        "archive_bytes": size,
        "tree_sha256": digest,
        "file_count": nfiles,
        "fetched_at": now_iso(),
    }


# --------------------------------------------------------------------------
# 命令实现
# --------------------------------------------------------------------------

def vendor_one(proj, sha, version, dest: Path, token, dry_run=False, strip=(".github",)):
    """把某个 SHA 的源码快照落到 dest（vendor/<name>/），并在里面写 UPSTREAM.json。

    为什么用命名空间目录而不是仓库根目录：上游自带的 .gitignore 作用域是它所在的
    目录及其子目录。两个上游都放在根目录时只能有一份 .gitignore，后同步的会覆盖
    先同步的，规则还会全局生效（实测：cline2api 的 *_test.go 规则会让另一个项目的
    测试文件静默消失）。放进 vendor/<name>/ 后每个上游的规则只作用于自己的子树。
    """
    up = dest / "UPSTREAM.json"
    old = {}
    if up.exists():
        try:
            old = json.loads(up.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            old = {}
    if old.get("sha") == sha and dest.is_dir():
        return {"project": proj["name"], "dest": str(dest), "sha": sha, "changed": False,
                "reason": "sha-unchanged", "tree_sha256": old.get("tree_sha256"),
                "file_count": old.get("file_count"), "version": old.get("version")}

    work = Path(tempfile.mkdtemp(prefix="ub-vendor-"))
    try:
        snap = work / "snap"
        info = fetch_snapshot(proj, sha, snap, token)

        stripped = []
        for rel in strip:
            target = snap / rel
            if target.is_dir():
                shutil.rmtree(target)
                stripped.append(rel)
            elif target.exists():
                target.unlink()
                stripped.append(rel)

        info.update({
            "project": proj["name"],
            "version": version,
            "ref": proj.get("ref"),
            "stripped": stripped,
            "note": "上游源码归档的快照（等于上游 tar.gz 的内容，不是上游 git 跟踪文件的子集）。"
                    "上游 .github/ 已剔除，避免其 workflow 在本仓库被执行。",
        })
        if dry_run:
            return {"project": proj["name"], "dest": str(dest), "sha": sha, "changed": True,
                    "reason": "would-update", "tree_sha256": info.get("tree_sha256"),
                    "file_count": info.get("file_count"), "version": version}

        (snap / "UPSTREAM.json").write_text(
            json.dumps(info, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")

        # 原子替换：先备份旧快照，移动成功后才删；失败则回滚，保证不会只剩半个目录
        dest.parent.mkdir(parents=True, exist_ok=True)
        backup = None
        if dest.exists():
            backup = dest.with_name(dest.name + ".ub-old")
            if backup.exists():
                shutil.rmtree(backup)
            shutil.move(str(dest), str(backup))
        try:
            shutil.move(str(snap), str(dest))
        except Exception:
            if backup and backup.exists():
                shutil.move(str(backup), str(dest))
            raise
        if backup and backup.exists():
            shutil.rmtree(backup)
        return {"project": proj["name"], "dest": str(dest), "sha": sha, "changed": True,
                "reason": "updated", "tree_sha256": info.get("tree_sha256"),
                "file_count": info.get("file_count"), "version": version,
                "stripped": stripped}
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _vendor_dir(cfg) -> Path:
    return Path(cfg.get("sync", {}).get("vendor_dir", "vendor"))


def _pin_sha(pins, name):
    v = pins.get(name)
    if isinstance(v, dict):
        return v.get("sha"), v.get("version")
    return v, None


def _emit_vendor_summary(results, github_output):
    changed = [r for r in results if r["changed"]]
    payload = {"changed": [r["project"] for r in changed], "results": results}
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    if github_output:
        out = os.environ.get("GITHUB_OUTPUT")
        if out:
            with open(out, "a", encoding="utf-8") as f:
                f.write("changed=" + ",".join(r["project"] for r in changed) + "\n")
                f.write(f"any_changed={'true' if changed else 'false'}\n")
    return 0


def cmd_vendor(args):
    cfg = load_config(args.config)
    proj = get_project(cfg, args.project)
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    dest = Path(args.dest) if args.dest else _vendor_dir(cfg) / proj["name"]
    sha = args.sha
    if not sha:
        st = load_state(state_path(cfg, args.state))
        sha = st["projects"].get(proj["name"], {}).get("resolved_sha")
    if not sha:
        die(f"{proj['name']}: 没有目标 SHA，请用 --sha 指定或先跑 plan")
    version = args.version or (sha[:7])
    info = vendor_one(proj, sha, version, dest, token, dry_run=args.dry_run)
    print(json.dumps(info, indent=2, ensure_ascii=False))
    return 0


def cmd_vendor_all(args):
    """把 pins 里所有项目的快照同步到 vendor/<name>/（sync.yml 用）。"""
    cfg = load_config(args.config)
    pins = json.loads(args.pins) if args.pins else {}
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    st = load_state(state_path(cfg, args.state))
    results = []
    for proj in select_projects(cfg, args.project):
        name = proj["name"]
        sha, version = _pin_sha(pins, name)
        if not sha:
            rec = st["projects"].get(name, {})
            sha = rec.get("resolved_sha")
            version = version or rec.get("resolved_version")
        if not sha:
            print(f"skip {name}: 没有 SHA", file=sys.stderr)
            continue
        dest = _vendor_dir(cfg) / name
        info = vendor_one(proj, sha, version or sha[:7], dest, token, dry_run=args.dry_run)
        flag = "SYNC " if info["changed"] else "keep "
        print(f"{flag}{name:<26} {sha[:12]}  {info['reason']}", file=sys.stderr)
        results.append(info)
    return _emit_vendor_summary(results, args.github_output)


def cmd_validate(args):
    cfg = load_config(args.config)
    print(f"OK: {args.config} 校验通过，{len(cfg['projects'])} 个项目："
          + ", ".join(p["name"] for p in cfg["projects"]))
    return 0


def _project_targets(proj, defaults, key="build"):
    if key == "docker":
        d = proj.get("docker", {})
        return d.get("targets") or d.get("platforms") or defaults.get("targets", [])
    return proj.get("build", {}).get("targets") or defaults.get("targets", [])


def _needs_build(proj, rec, sha, force):
    if force:
        return True, "force"
    if rec.get("last_successful_build_sha") == sha:
        return False, "up-to-date"
    hours = (proj.get("throttle") or {}).get("min_interval_hours")
    last = rec.get("last_build_attempt_at")
    if hours and last:
        try:
            prev = datetime.strptime(last, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            elapsed = (datetime.now(timezone.utc) - prev).total_seconds() / 3600.0
            if elapsed < float(hours):
                return False, f"throttled({elapsed:.1f}h<{hours}h)"
        except ValueError:
            pass
    return True, "sha-changed"


DEFAULT_RUNNERS = {"amd64": "ubuntu-latest", "arm64": "ubuntu-24.04-arm", "arm": "ubuntu-24.04-arm"}


def runner_for(arch, defaults):
    return (defaults.get("runners") or DEFAULT_RUNNERS).get(arch) or DEFAULT_RUNNERS.get(arch, "ubuntu-latest")


def expand_entries(proj, defaults, entry):
    """把一个项目展开成构建矩阵条目。

    两个独立关注点，不能混为一谈：
      * 二进制：cross_compile=true（Go/Rust）可以在一个 amd64 runner 上出所有架构；
                false（Python/Node 冻结产物）必须每个架构一个原生 runner。
      * 镜像：docker.native_per_arch=false（默认）用一个 amd64 runner + QEMU 构多架构；
                true 则每个架构一个原生 runner，发布时用 imagetools 合成 manifest list。
                带前端构建的 Dockerfile 走 QEMU 会非常慢，且 node 在模拟下容易 OOM。

    额外目标（例如 windows/amd64 这种只出二进制、不出镜像的）挂到 amd64 entry 上，
    避免为了它单开一个 runner（那会让架构无关的 assets 步骤重复执行）。
    """
    build = proj.get("build") or {}
    docker_cfg = proj.get("docker") or {}
    cross = build.get("cross_compile", True)
    build_targets = list(_project_targets(proj, defaults, "build"))
    docker_targets = list(_project_targets(proj, defaults, "docker")) if entry["docker"] else []
    docker_native = bool(docker_cfg.get("native_per_arch")) and entry["docker"]

    def mk(suffix, runner, targets, dtargets, per_arch, qemu):
        return dict(entry=f"{entry['name']}{suffix}", name=entry["name"], sha=entry["sha"],
                    version=entry["version"], language=entry["language"], method=entry["method"],
                    docker=entry["docker"], release=entry["release"], runner=runner,
                    native_per_arch=per_arch, needs_qemu=qemu,
                    targets=" ".join(targets), docker_targets=" ".join(dtargets))

    # ---- 情况 1：单一 entry（amd64 runner 通吃） ----
    if not docker_native and (cross or len(set(build_targets + docker_targets)) <= 1):
        qemu = bool(docker_targets) and len(docker_targets) > 1
        return [mk("", runner_for("amd64", defaults), build_targets, docker_targets, False, qemu)]

    # ---- 情况 2：按架构拆分到原生 runner ----
    out = []
    if docker_native:
        # 能交叉编译时，不出镜像的额外目标挂到 amd64 entry；否则它们各占一个 entry
        extra = [t for t in build_targets if t not in docker_targets]

        def extra_for(arch):
            return list(extra) if (cross and arch == "amd64") else []

        for t in docker_targets:
            arch = parse_target(t)[1]
            out.append(mk(f"-{arch}", runner_for(arch, defaults),
                          [t] + extra_for(arch), [t], True, False))
        if not cross:
            for t in extra:
                arch = parse_target(t)[1]
                out.append(mk(f"-{arch}-bin", runner_for(arch, defaults), [t], [], True, False))
        # 交叉编译但不走镜像的额外目标已经挂在 amd64 entry 上了
        if cross and not docker_targets:
            out.append(mk("", runner_for("amd64", defaults), build_targets, [], False, False))
        return out

    # ---- 情况 3：不能交叉编译、镜像走 QEMU（或没有镜像） ----
    seen = []
    for t in build_targets + docker_targets:
        if t not in seen:
            seen.append(t)
    for t in seen:
        arch = parse_target(t)[1]
        out.append(mk(f"-{arch}", runner_for(arch, defaults),
                      [t] if t in build_targets else [],
                      [t] if t in docker_targets else [], True, False))
    return out


def cmd_plan(args):
    cfg = load_config(args.config)
    sp = state_path(cfg, args.state)
    st = load_state(sp)
    pins = json.loads(args.pins) if args.pins else {}
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    defaults = cfg.get("defaults", {})

    include, summary = [], []
    for proj in select_projects(cfg, args.project):
        name = proj["name"]
        rec = st["projects"].setdefault(name, {})
        if name in pins and pins[name]:
            sha = pins[name]
            version = rec.get("resolved_version") or (sha[:7])
            if isinstance(pins[name], dict):
                sha = pins[name]["sha"]
                version = pins[name].get("version") or sha[:7]
        else:
            sha, version = resolve_ref(proj, token)

        # pins 是 sync 已经做出的决策（它可能用了 --force）。build 阶段必须照做，
        # 不能重新按节流规则判一遍，否则会出现「sync 决定构建、build 却把它节流掉」
        # 这种静默丢任务的情况。
        pinned = name in pins and bool(pins[name])
        prev = rec.get("last_synced_sha")
        rec.update({
            "repo": proj["repo"],
            "ref": proj.get("ref"),
            "resolved_sha": sha,
            "resolved_version": version,
            "last_synced_sha": sha,
            "last_synced_at": now_iso(),
        })
        need, reason = _needs_build(proj, rec, sha, args.force or pinned)
        if pinned and reason == "force":
            reason = "pinned"
        rec["last_decision"] = reason
        summary.append({"name": name, "sha": sha[:12], "version": version,
                        "changed": prev != sha, "build": need, "reason": reason})
        if need:
            base = {
                "name": name,
                "sha": sha,
                "version": version,
                "language": proj.get("build", {}).get("language", "none"),
                "method": proj.get("build", {}).get("method", "none"),
                "docker": bool(proj.get("docker", {}).get("enabled")),
                "release": bool(proj.get("release", {}).get("enabled")),
            }
            include.extend(expand_entries(proj, defaults, base))

    save_state(sp, st)
    matrix = {"include": include}
    # 是否有任何项目要发 Release：没有就让 publish-release Job 直接跳过，别浪费 runner
    has_release = any(e["release"] for e in include)
    payload = {"has_work": bool(include), "has_release": has_release,
               "matrix": matrix, "summary": summary}

    for row in summary:
        flag = "BUILD" if row["build"] else "skip "
        print(f"{flag} {row['name']:<26} {row['sha']:<13} v={row['version']:<12} {row['reason']}")

    if args.github_output:
        out = os.environ.get("GITHUB_OUTPUT")
        if out:
            with open(out, "a", encoding="utf-8") as f:
                f.write(f"has_work={'true' if include else 'false'}\n")
                f.write(f"has_release={'true' if has_release else 'false'}\n")
                f.write("matrix=" + json.dumps(matrix) + "\n")
                f.write("projects=" + ",".join(e["name"] for e in include) + "\n")
                pins = {e["name"]: {"sha": e["sha"], "version": e["version"]} for e in include}
                f.write("pins=" + json.dumps(pins, separators=(",", ":")) + "\n")
    else:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0


def shell_quote(v) -> str:
    s = "" if v is None else str(v)
    return "'" + s.replace("'", "'\"'\"'") + "'"


def cmd_env(args):
    cfg = load_config(args.config)
    proj = get_project(cfg, args.project)
    defaults = cfg.get("defaults", {})
    st = load_state(state_path(cfg, args.state))
    rec = st["projects"].get(proj["name"], {})
    sha = args.sha or rec.get("resolved_sha") or ""
    if not sha:
        die(f"{proj['name']}: 拿不到上游 SHA。请先用 `ub.py plan` 解析并写入状态，"
            f"或显式传 --sha（否则会去打一个 404 的 codeload 地址）")
    version = args.version or rec.get("resolved_version") or sha[:7]
    owner = args.owner or os.environ.get("UB_OWNER") or os.environ.get("GITHUB_REPOSITORY_OWNER") or "owner"

    build = proj.get("build", {})
    docker = proj.get("docker", {})
    release = proj.get("release", {})
    smoke = docker.get("smoke", {})
    # Docker 仓库名必须全小写，而 GitHub owner 可能是 MbAIGC 这种大小写混合，
    # 否则 buildx 直接报 "repository name must be lowercase"。
    image = (docker.get("image") or "").replace("{owner}", owner).lower()

    bt = _project_targets(proj, defaults, "build")
    dt = _project_targets(proj, defaults, "docker")
    smoke_arch = "amd64"
    for t in dt:
        if t == "linux/amd64":
            smoke_arch = "amd64"
            break

    kv = {
        "UB_NAME": proj["name"],
        "UB_SYNC_LAYOUT": (cfg.get("sync") or {}).get("layout", "vendor"),
        "UB_VENDOR_DIR": (cfg.get("sync") or {}).get("vendor_dir", "vendor"),
        "UB_REPO": proj["repo"],
        "UB_SHA": sha,
        "UB_SHORT_SHA": sha[:7],
        "UB_VERSION": version,
        "UB_OWNER": owner,
        "UB_LANGUAGE": build.get("language", "none"),
        "UB_METHOD": build.get("method", "none"),
        "UB_BUILD_ENABLED": "true" if build.get("enabled", bool(build)) else "false",
        "UB_WORKDIR": build.get("workdir", "."),
        "UB_PACKAGE": build.get("package", "."),
        "UB_BINARY": build.get("binary", proj["name"]),
        "UB_LDFLAGS": build.get("ldflags", ""),
        "UB_TRIMPATH": "true" if build.get("trimpath", True) else "false",
        "UB_BUILD_TARGETS": " ".join(bt),
        "UB_GO_VERSION": build.get("go_version", ""),
        "UB_PYTHON_VERSION": build.get("python_version") or "3.12",
        "UB_NODE_VERSION": build.get("node_version") or "24",
        "UB_TEST_ENABLED": "true" if (build.get("test") or {}).get("enabled") else "false",
        "UB_TEST_REQUIRED": "true" if (build.get("test") or {}).get("required") else "false",
        "UB_TEST_COMMAND": (build.get("test") or {}).get("command", ""),
        "UB_ASSETS_JSON": json.dumps(build.get("assets", []), separators=(",", ":")),
        "UB_ENV_JSON": json.dumps(build.get("env", {}), separators=(",", ":")),
        "UB_BUILD_ARGS_JSON": json.dumps(build.get("build_args", {}), separators=(",", ":")),
        "UB_DOCKER_ENABLED": "true" if docker.get("enabled") else "false",
        "UB_DOCKER_STRATEGY": docker.get("strategy", ""),
        "UB_DOCKERFILE": docker.get("dockerfile", ""),
        "UB_DOCKER_CONTEXT": docker.get("context", "."),
        "UB_DOCKER_TARGETS": " ".join(dt),
        "UB_DOCKER_PROVENANCE": "true" if docker.get("provenance") else "false",
        "UB_DOCKER_NATIVE_PER_ARCH": "true" if docker.get("native_per_arch") else "false",
        # 配置级的完整目标列表：矩阵 entry 会把它收窄成单架构，但发布阶段校验架构清单
        # 必须用「项目声明的全部架构」，否则原生 arm runner 路径下会误判为架构不符。
        "UB_DOCKER_TARGETS_ALL": " ".join(dt),
        "UB_IMAGE": image,
        "UB_SMOKE_PORT": smoke.get("container_port", ""),
        "UB_SMOKE_PATH": smoke.get("path", ""),
        "UB_SMOKE_EXPECT": ",".join(str(x) for x in smoke.get("expect", [])),
        "UB_SMOKE_TIMEOUT": smoke.get("timeout", 60),
        "UB_SMOKE_COMMAND": smoke.get("command", ""),
        "UB_SMOKE_ARCH": smoke_arch,
        "UB_RELEASE_ENABLED": "true" if release.get("enabled") else "false",
        "UB_RELEASE_BINARY": "true" if (release.get("enabled") and release.get("binary")) else "false",
        "UB_RELEASE_TAG_STRATEGY": release.get("tag_strategy", ""),
        "UB_RELEASE_ASSETS": " ".join(release.get("assets", []) or []),
        "UB_RELEASE_TAG": release_tag(proj, version),
    }
    # 依赖探测：构建脚本里出现 npm/pip 时也要把对应工具链装上（例如 Go 项目的前端 assets）
    import json as _json
    _assets = _json.dumps(build.get("assets", []))
    kv["UB_NEEDS_NODE"] = "true" if (build.get("language") == "node" or "npm" in _assets or "node " in _assets) else "false"
    kv["UB_NEEDS_PYTHON"] = "true" if (build.get("language") == "python" or "pip " in _assets or "python" in _assets) else "false"

    _tags = resolve_tags(proj, version, sha)
    kv["UB_PUSH_TAG"] = _tags[0]
    kv["UB_PROMOTE_TAGS"] = " ".join(_tags[1])

    if args.format == "json":
        print(json.dumps(kv, indent=2, ensure_ascii=False))
    elif args.format == "github-env":
        # 写 $GITHUB_ENV 用：KEY=value，值必须是原样（不做引号处理）
        for k, v in kv.items():
            print(f"{k}={v}")
    else:
        for k, v in kv.items():
            print(f"export {k}={shell_quote(v)}")
    return 0


TAG_VARS = ("name", "version", "sha", "short_sha")


def resolve_tags(proj, version, sha) -> tuple[str, list]:
    """返回 (不可变 push 标签, 需要晋升的标签列表)。

    push 标签永远是不可变的 sha 标签；latest/版本标签只在验证通过后由发布 Job 晋升，
    这样 latest 只会指向已经验证过的 digest（对应方案 7.2 第 3 条）。
    """
    docker = proj.get("docker") or {}
    tpls = docker.get("tags") or ["sha-{short_sha}", "latest"]
    subs = {"name": proj["name"], "version": str(version), "sha": sha, "short_sha": sha[:7]}
    resolved = []
    for t in tpls:
        out = t
        for v in TAG_VARS:
            out = out.replace("{" + v + "}", subs[v])
        if out not in resolved:
            resolved.append(out)
    immutable = next((t for t in resolved if t.startswith("sha-")), f"sha-{sha[:7]}")
    if immutable not in resolved:
        resolved.insert(0, immutable)
    return immutable, [t for t in resolved if t != immutable]


def release_tag(proj, version) -> str:
    """Release 是仓库级命名空间，一个管理仓库管 N 个项目，tag 必须带项目前缀，否则互相覆盖。"""
    ts = (proj.get("release") or {}).get("tag_strategy", "sha")
    base = version
    if ts == "rolling-prerelease":
        return f"{proj['name']}/rolling"
    return f"{proj['name']}/{base}"


def cmd_fetch(args):
    cfg = load_config(args.config)
    proj = get_project(cfg, args.project)
    token = args.token or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    dest = Path(args.dest)
    info = fetch_snapshot(proj, args.sha, dest, token)
    sidecar = dest.parent / f"{dest.name}.source.json"
    sidecar.write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(info, indent=2))
    return 0


def cmd_record(args):
    cfg = load_config(args.config)
    sp = state_path(cfg, args.state)
    st = load_state(sp)
    rec = st["projects"].setdefault(args.project, {})
    rec["build_status"] = args.status
    rec["last_build_attempt_at"] = now_iso()
    if args.sha:
        rec["last_build_attempt_sha"] = args.sha
        # 无论本次是 sync 还是手动触发的 build 解析出的 SHA，都让状态文件保持自洽
        rec["last_synced_sha"] = args.sha
    if args.status == "success":
        if args.sha:
            rec["last_successful_build_sha"] = args.sha
        rec["last_successful_build_at"] = now_iso()
        rec.pop("last_error", None)
    else:
        rec["last_error"] = args.error or "unknown"
    if args.image_digest:
        rec["image_digest"] = args.image_digest
    if args.image:
        rec["image"] = args.image
    if args.release_tag:
        rec["release_tag"] = args.release_tag
    if args.platforms:
        rec["platforms"] = [x for x in args.platforms.split(",") if x]
    save_state(sp, st)

    result = {
        "run_id": args.run_id,
        "name": args.project,
        "sha": args.sha,
        "status": args.status,
        "method": args.method,
        "version": args.version,
        "platforms": [x for x in (args.platforms or "").split(",") if x],
        "image": args.image,
        "image_digest": args.image_digest,
        "release_tag": args.release_tag,
        "error": args.error,
        "recorded_at": now_iso(),
    }
    if args.results_dir:
        d = Path(args.results_dir)
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{args.project}.json").write_text(
            json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


def cmd_report(args):
    cfg = load_config(args.config)
    results = []
    if args.results_dir and Path(args.results_dir).exists():
        for f in sorted(Path(args.results_dir).glob("*.json")):
            results.append(json.loads(f.read_text(encoding="utf-8")))
    failed = [r for r in results if r.get("status") != "success"]
    report = {
        "run_id": args.run_id,
        "started_at": args.started_at,
        "finished_at": now_iso(),
        "project_count": len(results),
        "failed_count": len(failed),
        "projects": results,
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, ensure_ascii=False))
    if failed and args.fail_on_error:
        print(f"ERROR: {len(failed)} 个项目失败", file=sys.stderr)
        return 1
    return 0


META_TO_ENV = {
    "name": "UB_NAME", "image": "UB_IMAGE", "push_tag": "UB_PUSH_TAG",
    "promote_tags": "UB_PROMOTE_TAGS", "docker_targets": "UB_DOCKER_TARGETS",
    "sha": "UB_SHA", "version": "UB_VERSION", "short_sha": "UB_SHORT_SHA",
    "release_tag": "UB_RELEASE_TAG", "docker_strategy": "UB_DOCKER_STRATEGY",
    "entry": "UB_ENTRY", "language": "UB_LANGUAGE", "method": "UB_METHOD",
    "docker_targets_all": "UB_DOCKER_TARGETS_ALL",
    "repo": "UB_REPO",
    "release_binary": "UB_RELEASE_BINARY",
    "release_tag_strategy": "UB_RELEASE_TAG_STRATEGY",
    "release_assets": "UB_RELEASE_ASSETS",
}


def cmd_meta_env(args):
    """把构建 Job 产出的 image-meta.json 转成可 source 的 KEY='value' 行。

    发布 Job 只依赖这个元数据文件，不解析上游源码，也不需要重新读取上游配置。
    """
    d = json.loads(Path(args.meta).read_text(encoding="utf-8"))
    for k, env in META_TO_ENV.items():
        v = d.get(k, "")
        if isinstance(v, list):
            v = " ".join(str(x) for x in v)
        print(f"export {env}={shell_quote(v)}")
    print("export UB_DOCKER_ENABLED='true'")
    return 0


LOCKFILE_PATTERNS = {
    "go": ["go.sum"],
    "node": ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml"],
    "python": ["requirements.txt", "requirements-*.txt", "uv.lock", "poetry.lock",
               "Pipfile.lock", "pyproject.toml", "setup.py"],
    "rust": ["Cargo.lock"],
}


def cmd_lockhash(args):
    """算依赖锁文件的哈希，供 actions/cache 的 key 使用。

    为什么需要它：本设计源码不落库，checkout 时仓库里没有 go.sum / package-lock.json，
    所以 actions/setup-go 的 cache: true 找不到锁文件（会直接失败）。
    正确顺序是先取源码 -> 算这个哈希 -> actions/cache restore -> 构建。
    """
    cfg = load_config(args.config)
    proj = get_project(cfg, args.project)
    src = Path(args.src)
    # 必须校验：--src 为空时 Path("") 会退化成当前目录，于是"哈希整个仓库"也算成功，
    # 缓存键就完全错了（而且不报错）。宁可直接失败。
    if not str(args.src).strip() or not src.is_dir():
        die(f"lockhash: --src 必须是一个存在的目录，收到 {args.src!r}")
    lang = (proj.get("build") or {}).get("language", "none")
    patterns = LOCKFILE_PATTERNS.get(lang, [])
    h = hashlib.sha256()
    matched = []
    for pat in patterns:
        for f in sorted(src.rglob(pat)):
            if ".git" in f.parts or "node_modules" in f.parts:
                continue
            matched.append(f.relative_to(src).as_posix())
            h.update(f.relative_to(src).as_posix().encode())
            h.update(b"\0")
            h.update(f.read_bytes())
            h.update(b"\n")
    # 工具链版本也进 key：换 Go/Python 版本必须换缓存
    build = proj.get("build") or {}
    for k in ("go_version", "python_version", "node_version", "package"):
        h.update(str(build.get(k, "")).encode())
    digest = h.hexdigest()[:16]
    print(digest)
    if not matched:
        print(f"WARN: {proj['name']} ({lang}) 在 {src} 下没有匹配到任何依赖锁文件，"
              f"缓存键将只反映工具链版本", file=sys.stderr)
    print(f"matched={','.join(matched) or '<none>'} hash={digest}", file=sys.stderr)
    return 0


def cmd_targets(args):
    cfg = load_config(args.config)
    proj = get_project(cfg, args.project)
    defaults = cfg.get("defaults", {})
    print(" ".join(_project_targets(proj, defaults, args.kind)))
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def build_parser():
    # --config 允许放在子命令之前或之后：
    # 子命令里的同名参数默认用 SUPPRESS，避免「子命令未提供时用 None 覆盖全局值」这个 argparse 陷阱。
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--config", default=argparse.SUPPRESS, help="配置文件路径（默认 upstream.json）")

    ap = argparse.ArgumentParser(prog="ub.py", description="upstream-builder engine", parents=[common])
    ap.set_defaults(config="upstream.json")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def cmd_parser(name, **kw):
        return sub.add_parser(name, parents=[common], **kw)

    s = cmd_parser("validate", help="校验 upstream.json")
    s.set_defaults(func=cmd_validate)

    s = cmd_parser("plan", help="解析 ref 并决定构建哪些项目")
    s.add_argument("--project", default="all")
    s.add_argument("--state")
    s.add_argument("--force", action="store_true")
    s.add_argument("--pins", help="JSON: {name: sha} 或 {name: {sha,version}}，由 sync 传入以固定本次构建的 SHA")
    s.add_argument("--github-output", action="store_true")
    s.set_defaults(func=cmd_plan)

    s = cmd_parser("env", help="输出项目的构建环境变量（shell/json）")
    s.add_argument("--project", required=True)
    s.add_argument("--state")
    s.add_argument("--sha")
    s.add_argument("--version")
    s.add_argument("--owner")
    s.add_argument("--format", choices=["shell", "json", "github-env"], default="shell")
    s.set_defaults(func=cmd_env)

    s = cmd_parser("vendor", help="把某个 SHA 的源码快照落到 vendor/<name>/（落库布局）")
    s.add_argument("--project", required=True)
    s.add_argument("--sha")
    s.add_argument("--version")
    s.add_argument("--dest")
    s.add_argument("--state")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(func=cmd_vendor)

    s = cmd_parser("vendor-all", help="按 pins 同步所有项目的快照到 vendor/<name>/")
    s.add_argument("--project", default="all")
    s.add_argument("--pins")
    s.add_argument("--state")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--github-output", action="store_true")
    s.set_defaults(func=cmd_vendor_all)

    s = cmd_parser("fetch", help="按 SHA 下载源码快照到临时目录（不落库）")
    s.add_argument("--project", required=True)
    s.add_argument("--sha", required=True)
    s.add_argument("--dest", required=True)
    s.add_argument("--token")
    s.set_defaults(func=cmd_fetch)

    s = cmd_parser("record", help="记录构建结果到 state")
    s.add_argument("--project", required=True)
    s.add_argument("--state")
    s.add_argument("--status", required=True, choices=["success", "failure", "skipped"])
    s.add_argument("--sha")
    s.add_argument("--version")
    s.add_argument("--method")
    s.add_argument("--platforms")
    s.add_argument("--image")
    s.add_argument("--image-digest")
    s.add_argument("--release-tag")
    s.add_argument("--error")
    s.add_argument("--run-id")
    s.add_argument("--results-dir")
    s.set_defaults(func=cmd_record)

    s = cmd_parser("report", help="汇总本次运行报告")
    s.add_argument("--run-id")
    s.add_argument("--started-at")
    s.add_argument("--results-dir", default="reports/run-results")
    s.add_argument("--out", default="reports/build-report.json")
    s.add_argument("--fail-on-error", action="store_true")
    s.set_defaults(func=cmd_report)

    s = cmd_parser("lockhash", help="算依赖锁文件哈希（actions/cache 的 key 用）")
    s.add_argument("--project", required=True)
    s.add_argument("--src", required=True)
    s.set_defaults(func=cmd_lockhash)

    s = cmd_parser("meta-env", help="把 image-meta.json 转成可 source 的环境变量")
    s.add_argument("--meta", required=True)
    s.set_defaults(func=cmd_meta_env)

    s = cmd_parser("targets", help="输出项目的目标列表")
    s.add_argument("--project", required=True)
    s.add_argument("--kind", choices=["build", "docker"], default="build")
    s.set_defaults(func=cmd_targets)
    return ap


def main(argv=None):
    args = build_parser().parse_args(argv)
    # 全局 --config 需要能放在子命令之后也能生效
    if not Path(args.config).exists() and Path("upstream.json").exists():
        args.config = "upstream.json"
    try:
        return args.func(args)
    except ConfigError as e:
        die("配置错误:\n" + "\n".join(e.problems), 2)
    except UbError as e:
        die(str(e))
    except KeyboardInterrupt:
        die("中断", 130)


if __name__ == "__main__":
    sys.exit(main())
