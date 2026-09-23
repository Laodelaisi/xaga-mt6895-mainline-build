#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""xaga-mt6895-mainline-build / bot.py —— 自动化助手

功能:
  * 构建完成通知 (喵提醒 / Server酱)
  * 上游内核 + initramfs 更新检测 (对比 build-state.json)
  * 检测到更新后可自动触发 build.yml
  * --commit-patch: 把本次上游 commit 记录提交回仓库
  * --verify-bootimg: 校验 boot.img 头部 (header_version=4 / header_size=1584)

只依赖 Python 标准库, Actions 里直接 `python3 .github/bot.py ...` 即可。

用法:
  python3 .github/bot.py --notify --status success --artifact-url <URL>
  python3 .github/bot.py --check-update
  python3 .github/bot.py --check-update --auto-build
  python3 .github/bot.py --check-update --auto-build --commit-patch
  python3 .github/bot.py --verify-bootimg out/boot-20260921-120000.img

环境变量:
  MEOW_WEBHOOK       喵提醒自定义机器人 Webhook 完整地址 (可选)
  MEOW_SECRET        喵提醒加签密钥 (可选)
  SERVERCHAN_KEY     Server酱 SendKey, sct 开头 (可选)
  GITHUB_TOKEN       Actions 自动注入, 用于检测上游 / 触发构建 / 提交记录
  GITHUB_REPOSITORY  owner/repo
  GITHUB_REF_NAME    当前分支 (默认 main)
  KERNEL_REPO        上游内核仓库, 默认 MT6895-Mainline/linux
  KERNEL_BRANCH      上游内核分支, 默认 7.2-mt6895-xiaomi-xaga
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

# --------------------------------------------------------------------------- 常量

UPSTREAM_KERNEL_REPO = os.environ.get("KERNEL_REPO", "MT6895-Mainline/linux")
UPSTREAM_KERNEL_BRANCH = os.environ.get("KERNEL_BRANCH", "7.2-mt6895-xiaomi-xaga")
UPSTREAM_INITRAMFS_REPO = os.environ.get("INITRAMFS_REPO", "MT6895-Mainline/initramfs")
UPSTREAM_INITRAMFS_BRANCH = os.environ.get("INITRAMFS_BRANCH", "main")

# bot.py 位于 .github/ 下, 仓库根是它的上一级
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE_FILE = os.path.join(REPO_ROOT, ".github", "build-state.json")
WORKFLOW_FILE = "build.yml"

API_ROOT = "https://api.github.com"
SERVERCHAN_API = "https://sctapi.ftqq.com/{key}.send"
HTTP_TIMEOUT = 30

# boot header v4: v3 的 1580 字节 + signature_size(4) = 1584
BOOT_MAGIC = b"ANDROID!"
EXPECTED_HEADER_VERSION = 4
EXPECTED_HEADER_SIZE = 1584
EXPECTED_OS_VERSION = (16, 0, 0)
EXPECTED_OS_PATCH = (2026, 8)


# --------------------------------------------------------------------------- 基础工具


def log(msg: str) -> None:
    print("[bot] %s" % msg, flush=True)


def warn(msg: str) -> None:
    print("[bot][warn] %s" % msg, flush=True)


def die(msg: str, code: int = 1) -> None:
    print("[bot][error] %s" % msg, file=sys.stderr, flush=True)
    sys.exit(code)


def env(name: str, default: str = "") -> str:
    return (os.environ.get(name) or default).strip()


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def http_request(method: str, url: str, data=None, headers=None, timeout=HTTP_TIMEOUT):
    """返回 (status_code, body_text)。网络异常返回 (0, 错误信息)。"""
    body = None
    hdrs = {"User-Agent": "xaga-bot/1.0"}
    if headers:
        hdrs.update(headers)
    if data is not None:
        if isinstance(data, (dict, list)):
            body = json.dumps(data).encode("utf-8")
            hdrs.setdefault("Content-Type", "application/json")
        elif isinstance(data, str):
            body = data.encode("utf-8")
        else:
            body = data
    req = urllib.request.Request(url, data=body, headers=hdrs, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.getcode(), resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        try:
            text = e.read().decode("utf-8", "replace")
        except Exception:
            text = str(e)
        return e.code, text
    except Exception as e:  # 超时 / DNS / 连接失败
        return 0, "%s: %s" % (type(e).__name__, e)


def github_headers() -> dict:
    token = env("GITHUB_TOKEN") or env("GH_TOKEN")
    hdrs = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    if token:
        hdrs["Authorization"] = "Bearer %s" % token
    return hdrs


def repo_slug() -> str:
    slug = env("GITHUB_REPOSITORY")
    if not slug or "/" not in slug:
        try:
            out = subprocess.run(
                ["git", "remote", "get-url", "origin"],
                cwd=REPO_ROOT, capture_output=True, text=True, timeout=15,
            ).stdout.strip()
            if "github.com" in out:
                slug = out.split("github.com")[-1].lstrip(":/")
                if slug.endswith(".git"):
                    slug = slug[:-4]
        except Exception:
            slug = ""
    return slug


# --------------------------------------------------------------------------- 通知


def build_message(status: str, title: str, artifact_url: str, extra_lines=None) -> str:
    status = (status or "unknown").lower()
    icon = {"success": "✅", "failure": "❌", "cancelled": "⚠️", "started": "🚀"}.get(status, "ℹ️")
    slug = repo_slug() or "xaga-mt6895-mainline-build"
    lines = [
        "%s %s" % (icon, title),
        "状态: %s" % status,
        "仓库: %s" % slug,
    ]
    run_id = env("GITHUB_RUN_ID")
    if run_id:
        lines.append("Run ID: %s" % run_id)
    if artifact_url:
        lines.append("构建记录: %s" % artifact_url)
    if extra_lines:
        lines.extend([l for l in extra_lines if l])
    lines.append("时间: %s" % now_utc())
    return "\n".join(lines)


def notify_meow(title: str, content: str) -> bool:
    """喵提醒自定义机器人 (加签)。Webhook / 密钥分别来自 MEOW_WEBHOOK / MEOW_SECRET。"""
    webhook = env("MEOW_WEBHOOK")
    if not webhook:
        return False
    secret = env("MEOW_SECRET")
    url = webhook
    if secret:
        ts = str(int(time.time() * 1000))
        string_to_sign = "%s\n%s" % (ts, secret)
        digest = hmac.new(secret.encode("utf-8"),
                          string_to_sign.encode("utf-8"),
                          hashlib.sha256).digest()
        sign = urllib.parse.quote_plus(base64.b64encode(digest).decode("utf-8"))
        sep = "&" if "?" in url else "?"
        url = "%s%stimestamp=%s&sign=%s" % (url, sep, ts, sign)

    # 兼容两种常见自定义机器人载荷, 逐个尝试
    payloads = [
        {"msgtype": "text", "text": {"content": "%s\n%s" % (title, content)}},
        {"title": title, "text": content, "content": content, "desp": content},
    ]
    for payload in payloads:
        code, body = http_request("POST", url, data=payload)
        if code == 200 or (code == 0 and "timed out" not in body):
            log("喵提醒通知已发送 (HTTP %s)" % code)
            return True
        warn("喵提醒载荷失败 (HTTP %s): %s" % (code, body[:200]))
    return False


def notify_serverchan(title: str, content: str) -> bool:
    """Server酱 (sct 开头 SendKey), 可推微信/QQ。"""
    key = env("SERVERCHAN_KEY")
    if not key:
        return False
    url = SERVERCHAN_API.format(key=key)
    data = urllib.parse.urlencode({"title": title, "desp": content}).encode("utf-8")
    code, body = http_request("POST", url, data=data,
                             headers={"Content-Type": "application/x-www-form-urlencoded"})
    ok = False
    try:
        ok = json.loads(body).get("code") == 0
    except Exception:
        ok = code == 200
    if ok:
        log("Server酱通知已发送")
    else:
        warn("Server酱通知失败 (HTTP %s): %s" % (code, body[:200]))
    return ok


def cmd_notify(args) -> int:
    title = args.title or "xaga-mt6895-mainline-build 构建通知"
    content = build_message(args.status, title, args.artifact_url)
    if args.message:
        content = "%s\n%s" % (content, args.message)
    log("---- 通知内容 ----\n%s\n------------------" % content)

    sent = []
    if notify_meow(title, content):
        sent.append("喵提醒")
    if notify_serverchan(title, content):
        sent.append("Server酱")
    if not sent:
        warn("未配置 MEOW_WEBHOOK / SERVERCHAN_KEY, 跳过通知 (构建结果不受影响)")
        return 0
    log("通知渠道: %s" % ", ".join(sent))
    return 0


# --------------------------------------------------------------------------- boot.img 头部校验


def _u32(buf: bytes, off: int) -> int:
    return struct.unpack_from("<I", buf, off)[0]


def verify_bootimg(path: str) -> int:
    """校验 boot.img 是合法 v4 头 (header_version=4 / header_size=1584)。"""
    if not os.path.isfile(path):
        die("找不到 boot 镜像: %s" % path)
    with open(path, "rb") as f:
        head = f.read(2048)
    if len(head) < 1584:
        die("boot 镜像太小, 不是合法镜像: %s" % path)

    magic = head[0:8]
    kernel_size = _u32(head, 8)
    ramdisk_size = _u32(head, 12)
    os_version = _u32(head, 16)
    header_size = _u32(head, 20)
    header_version = _u32(head, 40)
    cmdline = head[44:44 + 1536].split(b"\x00")[0].decode("utf-8", "replace")
    signature_size = _u32(head, 44 + 1536)

    a = (os_version >> 25) & 0x7F
    b = (os_version >> 18) & 0x7F
    c = (os_version >> 11) & 0x7F
    patch_year = ((os_version >> 4) & 0x7F) + 2000
    patch_month = os_version & 0xF

    log("镜像:            %s (%d 字节)" % (path, os.path.getsize(path)))
    log("magic:           %s" % magic.decode("latin-1"))
    log("kernel_size:     %d" % kernel_size)
    log("ramdisk_size:    %d" % ramdisk_size)
    log("header_version:  %d" % header_version)
    log("header_size:     %d" % header_size)
    log("signature_size:  %d" % signature_size)
    log("os_version:      %d.%d.%d" % (a, b, c))
    log("os_patch_level:  %04d-%02d" % (patch_year, patch_month))
    log("cmdline:         %s" % cmdline)

    fatal = []
    if magic != BOOT_MAGIC:
        fatal.append("magic 不是 ANDROID!")
    if header_version != EXPECTED_HEADER_VERSION:
        fatal.append("header_version=%d, 期望 %d" % (header_version, EXPECTED_HEADER_VERSION))
    if header_size != EXPECTED_HEADER_SIZE:
        fatal.append(
            "header_size=%d, 期望 %d (osm0sis C 版只会给 1580, 它是 v3 结构, MTK LK 可能拒载)"
            % (header_size, EXPECTED_HEADER_SIZE))
    if (a, b, c) != EXPECTED_OS_VERSION:
        warn("os_version 与 postmarketOS wiki 不一致: %d.%d.%d" % (a, b, c))
    if (patch_year, patch_month) != EXPECTED_OS_PATCH:
        warn("os_patch_level 与 postmarketOS wiki 不一致: %04d-%02d" % (patch_year, patch_month))

    if fatal:
        for msg in fatal:
            print("[bot][error] %s" % msg, file=sys.stderr)
        die("boot.img 头部校验失败, 别刷它。")
    log("boot.img 头部校验通过 ✅")
    return 0


# --------------------------------------------------------------------------- 状态 / 输出


def set_output(name: str, value: str) -> None:
    """写 GitHub Actions step output (本地跑时静默跳过)。"""
    out = env("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as f:
            f.write("%s=%s\n" % (name, value))
    log("output %s=%s" % (name, value))


def load_state() -> dict:
    if not os.path.isfile(STATE_FILE):
        return {}
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        warn("build-state.json 解析失败, 按空状态处理: %s" % e)
        return {}


def save_state(state: dict) -> None:
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    state["updated_at"] = now_utc()
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    log("状态已写入 %s" % os.path.relpath(STATE_FILE, REPO_ROOT))


def resolve_upstream_branch(repo: str, hint: str) -> str:
    """拿上游仓库实际的默认分支, 或确认 hint 分支存在。"""
    url = "%s/repos/%s" % (API_ROOT, repo)
    code, body = http_request("GET", url, headers=github_headers())
    if code == 200:
        data = json.loads(body)
        default = data.get("default_branch", hint)
        if hint and hint != default:
            h_url = "%s/repos/%s/branches/%s" % (API_ROOT, repo, urllib.parse.quote(hint))
            h_code, _ = http_request("GET", h_url, headers=github_headers())
            if h_code == 200:
                return hint
            warn("上游 %s 分支 '%s' 不存在, 回退到默认分支 '%s'" % (repo, hint, default))
        return default
    if code == 404:
        die("上游仓库不存在: %s (HTTP 404)" % repo)
    warn("拿不到上游 %s 的默认分支 (HTTP %s), 直接用 '%s'" % (repo, code, hint))
    return hint


def fetch_upstream_head(repo: str, branch: str) -> dict:
    """取上游分支 HEAD: {sha, subject, date, url}"""
    actual_branch = resolve_upstream_branch(repo, branch)
    url = "%s/repos/%s/commits/%s" % (API_ROOT, repo, urllib.parse.quote(actual_branch))
    code, body = http_request("GET", url, headers=github_headers())
    if code == 422 and "No commit found" in body:
        for fb in ("main", "master"):
            if fb != actual_branch:
                fb_url = "%s/repos/%s/commits/%s" % (API_ROOT, repo, urllib.parse.quote(fb))
                fb_code, fb_body = http_request("GET", fb_url, headers=github_headers())
                if fb_code == 200:
                    warn("分支 '%s' 不存在, 回退到 '%s'" % (actual_branch, fb))
                    actual_branch = fb
                    url = fb_url
                    body = fb_body
                    code = 200
                    break
    if code != 200:
        die("读取上游 %s@%s 失败 (HTTP %s): %s" % (repo, actual_branch, code, body[:300]))
    data = json.loads(body)
    commit = data.get("commit", {})
    return {
        "repo": repo,
        "branch": actual_branch,
        "sha": data.get("sha", ""),
        "subject": (commit.get("message") or "").splitlines()[0][:120],
        "date": commit.get("committer", {}).get("date", ""),
        "url": data.get("html_url", ""),
    }


# --------------------------------------------------------------------------- 上游更新检测


def cmd_check_update(args) -> int:
    state = load_state()
    log("上游检测: %s@%s + %s@%s" % (UPSTREAM_KERNEL_REPO, UPSTREAM_KERNEL_BRANCH,
                                    UPSTREAM_INITRAMFS_REPO, UPSTREAM_INITRAMFS_BRANCH))

    changes = []
    for key, repo, branch in (
        ("kernel", UPSTREAM_KERNEL_REPO, UPSTREAM_KERNEL_BRANCH),
        ("initramfs", UPSTREAM_INITRAMFS_REPO, UPSTREAM_INITRAMFS_BRANCH),
    ):
        head = fetch_upstream_head(repo, branch)
        old = (state.get(key) or {}).get("sha", "")
        log("%-9s 本地: %s" % (key, old[:12] or "(空)"))
        log("%-9s 上游: %s  %s" % (key, head["sha"][:12], head["subject"]))
        if head["sha"] and head["sha"] != old:
            changes.append(key)
            state[key] = head

    updated = bool(changes)
    set_output("updated", "true" if updated else "false")
    set_output("changed", ",".join(changes))

    if not updated:
        log("上游没有新 commit, 无需构建。")
        return 0

    log("检测到上游更新: %s" % ", ".join(changes))
    if args.commit_patch:
        commit_patch(state, changes)

    if args.auto_build:
        trigger_build({"build_target": "boot", "reuse_run_id": ""})
    else:
        log("未开启 --auto-build, 仅记录。加 --auto-build 可以自动触发构建。")
    return 0


def trigger_build(inputs: dict) -> bool:
    slug = repo_slug()
    if not slug:
        die("拿不到仓库名 (GITHUB_REPOSITORY 未设置), 无法触发构建")
    ref = env("GITHUB_REF_NAME", "main") or "main"
    url = "%s/repos/%s/actions/workflows/%s/dispatches" % (API_ROOT, slug, WORKFLOW_FILE)
    payload = {"ref": ref, "inputs": {k: str(v) for k, v in inputs.items()}}
    code, body = http_request("POST", url, data=payload, headers=github_headers())
    if code in (204, 201, 200):
        log("已触发 %s (ref=%s) inputs=%s" % (WORKFLOW_FILE, ref, payload["inputs"]))
        return True
    warn("触发构建失败 (HTTP %s): %s" % (code, body[:300]))
    return False


def _git(*git_args, check=True):
    result = subprocess.run(["git"] + list(git_args), cwd=REPO_ROOT,
                            capture_output=True, text=True, timeout=120)
    if check and result.returncode != 0:
        warn("git %s 失败: %s" % (" ".join(git_args), (result.stderr or "").strip()[:300]))
    return result.returncode == 0


def commit_patch(state: dict, changes) -> None:
    """把上游 commit 记录提交回仓库 (Actions 里用 token 推送)。"""
    lines = []
    for key in changes:
        info = state.get(key, {})
        lines.append("- %s %s@%s -> %s (%s) %s" % (
            datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M"),
            info.get("repo", key), info.get("branch", ""),
            info.get("sha", "")[:12], info.get("date", ""), info.get("subject", "")))
    log_file = os.path.join(REPO_ROOT, ".github", "upstream-log.md")
    if not os.path.isfile(log_file):
        with open(log_file, "w", encoding="utf-8") as f:
            f.write("# 上游更新记录\n\nbot.py 每次检测到上游新 commit 时追加。\n\n")
    with open(log_file, "a", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    save_state(state)

    if not env("GITHUB_ACTIONS"):
        log("本地环境, 不自动提交 (文件已更新)。")
        return
    token = env("GITHUB_TOKEN") or env("GH_TOKEN")
    ref = env("GITHUB_REF_NAME", "main") or "main"
    _git("config", "user.name", "github-actions[bot]")
    _git("config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")
    _git("add", ".github/build-state.json", ".github/upstream-log.md")
    if not _git("diff", "--cached", "--quiet", check=False):
        _git("commit", "-m", "chore: 记录上游更新 (%s)" % ", ".join(changes))
        if token:
            slug = repo_slug()
            remote = "https://x-access-token:%s@github.com/%s.git" % (token, slug)
            _git("push", remote, "HEAD:%s" % ref, check=False)
        else:
            warn("没有 token, 跳过 push")


# --------------------------------------------------------------------------- CLI


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="bot.py",
        description="xaga-mt6895-mainline-build 自动化助手 (通知 / 上游检测 / 构建校验)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n"
               "  bot.py --notify --status success --artifact-url https://github.com/.../runs/123\n"
               "  bot.py --check-update --auto-build\n"
               "  bot.py --verify-bootimg out/boot-20260921-120000.img\n",
    )
    p.add_argument("--notify", action="store_true", help="发送构建通知 (喵提醒 / Server酱)")
    p.add_argument("--status", default="success",
                   choices=["success", "failure", "cancelled", "started"],
                   help="构建状态, 默认 success")
    p.add_argument("--title", default="", help="通知标题, 默认自动生成")
    p.add_argument("--artifact-url", default="", help="构建记录 / 产物地址")
    p.add_argument("--message", default="", help="附加到通知正文的额外信息")
    p.add_argument("--check-update", action="store_true", help="检测上游内核/initramfs 更新")
    p.add_argument("--auto-build", action="store_true", help="检测到更新后自动触发 build.yml")
    p.add_argument("--commit-patch", action="store_true",
                   help="把上游 commit 记录写回仓库 (build-state.json + upstream-log.md)")
    p.add_argument("--trigger-build", action="store_true", help="直接触发一次 build.yml")
    p.add_argument("--build-target", default="boot",
                   choices=["boot", "rootfs", "all"], help="配合 --trigger-build, 默认 boot")
    p.add_argument("--verify-bootimg", metavar="PATH", default="",
                   help="校验 boot.img 头部 (header_version=4 / header_size=1584)")
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    if args.verify_bootimg:
        return verify_bootimg(args.verify_bootimg)
    if args.check_update:
        return cmd_check_update(args)
    if args.trigger_build:
        return 0 if trigger_build({"build_target": args.build_target}) else 1
    if args.notify:
        return cmd_notify(args)

    build_parser().print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
