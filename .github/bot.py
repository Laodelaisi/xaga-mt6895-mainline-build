#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
xaga-mt6895-mainline-build 自动化助手 bot.py

功能:
  1. 编译完成通知: 钉钉 Webhook / Server酱(微信/QQ推送)
  2. 上游内核更新检测: 监控 MT6895-Mainline/linux 7.2 分支
  3. 自动触发构建: 检测到上游更新后自动调用 GitHub API 触发 Build.yml
  4. 补丁记录: 将上游最新 commit 写入 .last_upstream_commit 并提交到本仓库

用法:
  python3 bot.py --notify --status success --artifact-url <url>
  python3 bot.py --check-update --auto-build
  python3 bot.py --check-update --auto-build --commit-patch

环境变量(在 GitHub Secrets 中配置):
  DINGTALK_WEBHOOK   钉钉机器人 Webhook 完整地址(含access_token)
  DINGTALK_SECRET    钉钉机器人加签密钥(可选, 未设置则不加签)
  SERVERCHAN_KEY     Server酱 SendKey (sct开头, 可选)
  GITHUB_TOKEN       GitHub Token (Actions 中自动注入 GITHUB_TOKEN)
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request


# ============================================================
# 配置常量
# ============================================================
UPSTREAM_REPO = "MT6895-Mainline/linux"
UPSTREAM_BRANCH = "7.2-mt6895-xiaomi-xaga"
LOCAL_REPO = os.environ.get("GITHUB_REPOSITORY", "")
WORKFLOW_FILE = "Build.yml"
DEFAULT_BRANCH = "main"
COMMIT_RECORD_FILE = ".last_upstream_commit"


# ============================================================
# 工具函数
# ============================================================
def _http_post(url, data, headers=None):
    """通用 HTTP POST, 返回 (status_code, response_text)"""
    if headers is None:
        headers = {"Content-Type": "application/json"}
    body = json.dumps(data).encode("utf-8") if isinstance(data, dict) else data
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")
    except Exception as e:
        return -1, str(e)


def _http_get_json(url, token=None):
    """通用 HTTP GET JSON"""
    headers = {"Accept": "application/vnd.github.v3+json"}
    if token:
        headers["Authorization"] = f"token {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())


# ============================================================
# 通知模块: 钉钉
# ============================================================
def send_dingtalk(webhook, secret, title, markdown_text):
    """发送钉钉 Markdown 消息, 支持加签"""
    if not webhook:
        print("[钉钉] 未配置 DINGTALK_WEBHOOK, 跳过")
        return False

    url = webhook
    if secret:
        timestamp = str(round(time.time() * 1000))
        string_to_sign = f"{timestamp}\n{secret}"
        hmac_code = hmac.new(
            secret.encode("utf-8"),
            string_to_sign.encode("utf-8"),
            digestmod=hashlib.sha256,
        ).digest()
        sign = urllib.parse.quote_plus(base64.b64encode(hmac_code))
        sep = "&" if "?" in url else "?"
        url = f"{url}{sep}timestamp={timestamp}&sign={sign}"

    payload = {
        "msgtype": "markdown",
        "markdown": {"title": title, "text": markdown_text},
    }
    code, body = _http_post(url, payload)
    print(f"[钉钉] HTTP {code}: {body[:200]}")
    return code == 200 and '"errcode":0' in body


# ============================================================
# 通知模块: Server酱 (可推送到微信/QQ)
# ============================================================
def send_serverchan(sckey, title, content):
    """Server酱推送, sckey 格式 sctxxxxxxxx"""
    if not sckey:
        print("[Server酱] 未配置 SERVERCHAN_KEY, 跳过")
        return False

    url = f"https://sctapi.ftqq.com/{sckey}.send"
    data = urllib.parse.urlencode({"title": title, "desp": content}).encode("utf-8")
    code, body = _http_post(url, data, headers={"Content-Type": "application/x-www-form-urlencoded"})
    print(f"[Server酱] HTTP {code}: {body[:200]}")
    return code == 200


# ============================================================
# 通知入口
# ============================================================
def do_notify(status, artifact_url):
    """编译完成通知"""
    is_success = status == "success"
    emoji = "✅" if is_success else "❌"
    status_text = "构建成功" if is_success else "构建失败"
    now = time.strftime("%Y-%m-%d %H:%M:%S")

    title = f"{emoji} xaga主线内核 - {status_text}"

    md = f"""### {emoji} xaga MT6895 主线内核构建通知

| 项目 | 内容 |
|------|------|
| **状态** | {status_text} |
| **时间** | {now} |
| **内核分支** | {UPSTREAM_BRANCH} |
| **上游仓库** | {UPSTREAM_REPO} |
"""
    if artifact_url:
        md += f"| **构建记录** | [点击查看产物]({artifact_url}) |\n"

    webhook = os.environ.get("DINGTALK_WEBHOOK", "")
    secret = os.environ.get("DINGTALK_SECRET", "")
    sckey = os.environ.get("SERVERCHAN_KEY", "")

    send_dingtalk(webhook, secret, title, md)
    send_serverchan(sckey, title, md)


# ============================================================
# 上游更新检测
# ============================================================
def get_upstream_latest_commit(token):
    """获取上游仓库指定分支最新 commit, 返回 (sha, message)"""
    url = f"https://api.github.com/repos/{UPSTREAM_REPO}/commits/{UPSTREAM_BRANCH}"
    data = _http_get_json(url, token)
    sha = data["sha"]
    message = data["commit"]["message"].split("\n")[0]
    author = data["commit"]["author"]["name"]
    return sha, message, author


def get_local_recorded_commit():
    """读取本地记录的上次上游 commit"""
    if os.path.exists(COMMIT_RECORD_FILE):
        with open(COMMIT_RECORD_FILE, "r") as f:
            return f.read().strip()
    return ""


def save_recorded_commit(sha):
    """保存上游 commit 记录"""
    with open(COMMIT_RECORD_FILE, "w") as f:
        f.write(sha + "\n")


# ============================================================
# 自动触发构建
# ============================================================
def trigger_workflow(token, inputs=None):
    """通过 GitHub API 触发 Build.yml 工作流"""
    if not LOCAL_REPO:
        print("[触发构建] 未设置 GITHUB_REPOSITORY, 跳过")
        return False

    url = f"https://api.github.com/repos/{LOCAL_REPO}/actions/workflows/{WORKFLOW_FILE}/dispatches"
    payload = {"ref": DEFAULT_BRANCH}
    if inputs:
        payload["inputs"] = inputs
    else:
        payload["inputs"] = {
            "TASK": "全部(内核+RootFS)",
            "ROOTFS_TYPE": "postmarketOS",
            "PMOS_UI": "phosh",
            "CLANG_VERSION": "18",
        }

    code, body = _http_post(
        url,
        payload,
        headers={
            "Authorization": f"token {token}",
            "Accept": "application/vnd.github.v3+json",
            "Content-Type": "application/json",
        },
    )
    print(f"[触发构建] HTTP {code}: {body[:200]}")
    return code == 204


# ============================================================
# 自动提交补丁记录到本仓库
# ============================================================
def commit_patch_record(sha, message, author):
    """将上游最新 commit 记录提交到本仓库, 便于追踪"""
    try:
        subprocess.run(["git", "config", "user.name", "xaga-bot"], check=True)
        subprocess.run(["git", "config", "user.email", "xaga-bot@users.noreply.github.com"], check=True)
        save_recorded_commit(sha)
        subprocess.run(["git", "add", COMMIT_RECORD_FILE], check=True)
        commit_msg = (
            f"chore: track upstream commit {sha[:8]}\n\n"
            f"Upstream: {UPSTREAM_REPO}@{UPSTREAM_BRANCH}\n"
            f"Commit: {sha}\n"
            f"Author: {author}\n"
            f"Message: {message}\n"
        )
        subprocess.run(["git", "commit", "-m", commit_msg], check=True)
        subprocess.run(["git", "push"], check=True)
        print(f"[补丁记录] 已提交 {sha[:8]} 到本仓库")
        return True
    except subprocess.CalledProcessError as e:
        print(f"[补丁记录] 提交失败: {e}")
        return False


# ============================================================
# 更新检测入口
# ============================================================
def do_check_update(auto_build=False, commit_patch=False):
    """检测上游内核更新"""
    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        print("[错误] 需要 GITHUB_TOKEN 才能调用 GitHub API")
        sys.exit(1)

    print(f"[检测] 上游仓库: {UPSTREAM_REPO}@{UPSTREAM_BRANCH}")
    sha, message, author = get_upstream_latest_commit(token)
    print(f"[上游最新] {sha[:8]} - {message} (by {author})")

    last_sha = get_local_recorded_commit()
    print(f"[本地记录] {last_sha[:8] if last_sha else '(无记录)'}")

    if sha == last_sha:
        print("[结果] 上游无新提交, 无需构建")
        return

    print(f"[发现更新] {last_sha[:8] if last_sha else '首次'} -> {sha[:8]}")

    if commit_patch:
        # 先提交记录, 再触发构建
        commit_patch_record(sha, message, author)
    else:
        save_recorded_commit(sha)

    if auto_build:
        print("[动作] 自动触发 Build.yml 构建...")
        trigger_workflow(token)
    else:
        print("[提示] 未启用 --auto-build, 仅记录不触发构建")


# ============================================================
# 主入口
# ============================================================
def main():
    parser = argparse.ArgumentParser(
        description="xaga-mt6895-mainline-build 自动化助手",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 发送构建成功通知
  python3 bot.py --notify --status success --artifact-url https://github.com/xxx/actions/runs/123

  # 检测上游更新并自动触发构建
  python3 bot.py --check-update --auto-build

  # 检测更新, 提交补丁记录并触发构建 (需在有写权限的环境运行)
  python3 bot.py --check-update --auto-build --commit-patch
        """,
    )
    parser.add_argument("--notify", action="store_true", help="发送构建完成通知")
    parser.add_argument("--status", default="success", choices=["success", "failure"], help="构建状态")
    parser.add_argument("--artifact-url", default="", help="产物/构建记录URL")
    parser.add_argument("--check-update", action="store_true", help="检测上游内核更新")
    parser.add_argument("--auto-build", action="store_true", help="检测到更新时自动触发构建")
    parser.add_argument("--commit-patch", action="store_true", help="将上游commit记录提交到本仓库")

    args = parser.parse_args()

    if not args.notify and not args.check_update:
        parser.print_help()
        sys.exit(0)

    if args.notify:
        do_notify(args.status, args.artifact_url)

    if args.check_update:
        do_check_update(auto_build=args.auto_build, commit_patch=args.commit_patch)


if __name__ == "__main__":
    main()
