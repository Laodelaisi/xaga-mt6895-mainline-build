#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bot-offline.py —— 本地 (离线) 编译用的通知助手

和仓库里那份 .github/bot.py 的区别:
  * 这是给**本机编译**用的, 不查上游更新、不碰 GitHub API
  * 通知配置写成本文件顶部的「宏定义」, 改完这个文件就直接生效
  * 主打场景: SSH 连接不稳、窗口一断编译就死。把编译丢进 tmux 会话,
    跑完由 build-mainline.sh / build-rootfs.sh 调用本脚本推送结果到手机
    (喵提醒 / Server酱)。也可以单独 --watch-tmux 盯一个会话。

用法:
  python3 .github/bot-offline.py --notify --status success --message "boot 镜像好了"
  python3 .github/bot-offline.py --notify --status failure --log /path/build.log
  python3 .github/bot-offline.py --watch-tmux xaga-build --log /path/build.log
  python3 .github/bot-offline.py --verify-bootimg out/boot-20260921-120000.img
  python3 .github/bot-offline.py --test          # 验证通知配置是否配好
"""

# ===========================================================================
#  通知配置 (宏定义) —— 直接改这里, 改完立即生效
# ===========================================================================

# ---- 喵提醒 (自定义机器人, 安全设置选「加签」的把密钥也填上) ----
MEOW_ENABLED = True
MEOW_WEBHOOK = ""      # 例: "https://miaotixing.com/trigger?id=xxxxxxxx"
MEOW_SECRET = ""       # 加签密钥; 没开加签就留空

# ---- Server酱 (SendKey, sct 开头, 可推微信/QQ) ----
SERVERCHAN_ENABLED = True
SERVERCHAN_KEY = ""    # 例: "SCT123456xxxxxxxxxxxxxxxxxxxx"

# ---- 通用 ----
TITLE_PREFIX = "[xaga 本地编译]"   # 通知标题前缀
LOG_TAIL_LINES = 40                # 通知里附带的日志末尾行数
TMUX_SESSION = "xaga-build"        # --watch-tmux 默认盯的会话名
TMUX_POLL_INTERVAL = 10            # --watch-tmux 轮询间隔 (秒)
TMUX_MAX_WAIT = 0                  # 0 = 一直等; 否则为最长等待秒数

# ===========================================================================
#  以下是实现, 一般不用改
# ===========================================================================

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
from datetime import datetime

HTTP_TIMEOUT = 30
SERVERCHAN_API = "https://sctapi.ftqq.com/{key}.send"

# boot header v4: v3 的 1580 + signature_size(4) = 1584
BOOT_MAGIC = b"ANDROID!"
EXPECTED_HEADER_VERSION = 4
EXPECTED_HEADER_SIZE = 1584
EXPECTED_OS_VERSION = (16, 0, 0)
EXPECTED_OS_PATCH = (2026, 8)

STATUS_ICON = {
    "success": "✅", "failure": "❌", "cancelled": "⚠️",
    "started": "🚀", "unknown": "ℹ️",
}


def log(msg: str) -> None:
    print("[bot-offline] %s" % msg, flush=True)


def warn(msg: str) -> None:
    print("[bot-offline][warn] %s" % msg, flush=True)


def cfg(name: str, default: str = "") -> str:
    """宏定义优先, 环境变量可临时覆盖 (CI/临时测试用)。"""
    return (os.environ.get(name) or globals().get(name) or default).strip()


def enabled(name: str, default: bool = True) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return bool(globals().get(name, default))
    return raw.strip().lower() not in ("0", "false", "no", "")


def host_name() -> str:
    try:
        return os.uname().nodename
    except Exception:
        return os.environ.get("HOSTNAME", "unknown")


def now_str() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def http_request(method: str, url: str, data=None, headers=None, timeout=HTTP_TIMEOUT):
    """返回 (status_code, body_text)。网络异常返回 (0, 错误信息)。"""
    body = None
    hdrs = {"User-Agent": "xaga-offline-bot/1.0"}
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
    except Exception as e:
        return 0, "%s: %s" % (type(e).__name__, e)


# --------------------------------------------------------------------------- 通知渠道


def notify_meow(title: str, content: str) -> bool:
    if not enabled("MEOW_ENABLED"):
        return False
    webhook = cfg("MEOW_WEBHOOK")
    if not webhook:
        warn("MEOW_WEBHOOK 是空的, 跳过喵提醒 (改 bot-offline.py 顶部的宏定义)")
        return False

    secret = cfg("MEOW_SECRET")
    url = webhook
    if secret:
        ts = str(int(time.time() * 1000))
        digest = hmac.new(secret.encode("utf-8"),
                          ("%s\n%s" % (ts, secret)).encode("utf-8"),
                          hashlib.sha256).digest()
        sign = urllib.parse.quote_plus(base64.b64encode(digest).decode("utf-8"))
        url = "%s%stimestamp=%s&sign=%s" % (url, "&" if "?" in url else "?", ts, sign)

    payloads = [
        {"msgtype": "text", "text": {"content": "%s\n%s" % (title, content)}},
        {"title": title, "text": content, "content": content, "desp": content},
    ]
    for payload in payloads:
        code, body = http_request("POST", url, data=payload)
        if code == 200:
            log("喵提醒已发送")
            return True
        warn("喵提醒失败 (HTTP %s): %s" % (code, body[:200]))
    return False


def notify_serverchan(title: str, content: str) -> bool:
    if not enabled("SERVERCHAN_ENABLED"):
        return False
    key = cfg("SERVERCHAN_KEY")
    if not key:
        warn("SERVERCHAN_KEY 是空的, 跳过 Server酱 (改 bot-offline.py 顶部的宏定义)")
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
        log("Server酱已发送")
    else:
        warn("Server酱失败 (HTTP %s): %s" % (code, body[:200]))
    return ok


def send_notify(status: str, title: str, message: str, log_file: str = "",
                tail_lines: int = 0) -> int:
    status = (status or "unknown").lower()
    icon = STATUS_ICON.get(status, "ℹ️")
    title = title or ("%s %s 编译%s" % (TITLE_PREFIX, host_name(),
                                        {True: "完成", False: "失败"}[status == "success"]))
    lines = ["%s %s" % (icon, title),
             "状态: %s" % status,
             "主机: %s" % host_name(),
             "时间: %s" % now_str()]
    if message:
        lines.append("")
        lines.append(message)
    if log_file:
        lines.append("")
        lines.append("日志: %s" % log_file)
        tail = tail_log(log_file, tail_lines or LOG_TAIL_LINES)
        if tail:
            lines.append("")
            lines.append("---- 末尾日志 ----")
            lines.append(tail)
    content = "\n".join(lines)

    log("---- 通知内容 ----\n%s\n------------------" % content)
    sent = []
    if notify_meow(title, content):
        sent.append("喵提醒")
    if notify_serverchan(title, content):
        sent.append("Server酱")
    if not sent:
        warn("没有可用的通知渠道 (宏定义没填 / 未开启), 只在终端打印了结果")
        return 0
    log("已推送: %s" % ", ".join(sent))
    return 0


def tail_log(path: str, lines: int = 40) -> str:
    if not path or not os.path.isfile(path):
        return ""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            data = f.read().splitlines()
    except Exception as e:
        return "(读日志失败: %s)" % e
    return "\n".join(data[-lines:])


# --------------------------------------------------------------------------- boot.img 头部校验


def _u32(buf: bytes, off: int) -> int:
    return struct.unpack_from("<I", buf, off)[0]


def verify_bootimg(path: str) -> int:
    """本地打包完先跑一遍: 确认是合法 v4 头 (header_version=4 / header_size=1584)。"""
    if not os.path.isfile(path):
        print("[bot-offline][error] 找不到 boot 镜像: %s" % path, file=sys.stderr)
        return 1
    with open(path, "rb") as f:
        head = f.read(2048)
    if len(head) < 1584:
        print("[bot-offline][error] 镜像太小, 不是合法镜像: %s" % path, file=sys.stderr)
        return 1

    magic = head[0:8]
    kernel_size = _u32(head, 8)
    ramdisk_size = _u32(head, 12)
    os_version = _u32(head, 16)
    header_size = _u32(head, 20)
    header_version = _u32(head, 40)
    cmdline = head[44:44 + 1536].split(b"\x00")[0].decode("utf-8", "replace")
    signature_size = _u32(head, 44 + 1536)

    a, b, c = (os_version >> 25) & 0x7F, (os_version >> 18) & 0x7F, (os_version >> 11) & 0x7F
    patch_year, patch_month = ((os_version >> 4) & 0x7F) + 2000, os_version & 0xF

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
            "header_size=%d, 期望 %d —— 你用的打包器只实现到 boot_img_hdr_v3 (恒 1580), "
            "MTK LK 可能拒载。换 AOSP 官方 mkbootimg: "
            "git clone https://android.googlesource.com/platform/system/tools/mkbootimg"
            % (header_size, EXPECTED_HEADER_SIZE))
    if (a, b, c) != EXPECTED_OS_VERSION:
        warn("os_version 与 postmarketOS wiki 不一致: %d.%d.%d" % (a, b, c))
    if (patch_year, patch_month) != EXPECTED_OS_PATCH:
        warn("os_patch_level 与 postmarketOS wiki 不一致: %04d-%02d" % (patch_year, patch_month))

    if fatal:
        for msg in fatal:
            print("[bot-offline][error] %s" % msg, file=sys.stderr)
        print("[bot-offline][error] boot.img 头部校验失败, 别刷它。", file=sys.stderr)
        return 1
    log("boot.img 头部校验通过 ✅")
    return 0


# --------------------------------------------------------------------------- tmux 会话盯梢


def tmux_alive(session: str) -> bool:
    try:
        return subprocess.run(["tmux", "has-session", "-t", session],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                              ).returncode == 0
    except FileNotFoundError:
        return False


def watch_tmux(session: str, log_file: str = "", status_file: str = "", timeout: int = 0) -> int:
    """盯一个 tmux 会话: 会话结束 (窗口里的构建跑完) 就推送通知。

    典型用法: 在 SSH 窗口里跑
      python3 .github/bot-offline.py --watch-tmux xaga-build --log build.log
    会话没了说明构建结束, 立刻把结果推到手机。
    """
    try:
        subprocess.run(["tmux", "-V"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       check=True)
    except Exception:
        warn("本机没有 tmux, 无法盯会话")
        return 1

    if not tmux_alive(session):
        warn("tmux 会话 '%s' 不存在 (可能已经跑完了)" % session)
    else:
        log("盯住 tmux 会话 '%s', 每 %s 秒检查一次 ..." % (session, TMUX_POLL_INTERVAL))

    waited, interval = 0, max(1, int(TMUX_POLL_INTERVAL))
    max_wait = int(timeout if timeout else TMUX_MAX_WAIT)
    try:
        while tmux_alive(session):
            time.sleep(interval)
            waited += interval
            if max_wait and waited >= max_wait:
                warn("等待超时 (%ss), 会话 '%s' 仍在运行" % (max_wait, session))
                return 0
    except KeyboardInterrupt:
        log("手动中断盯梢 (会话仍在后台跑)")
        return 0

    status = "success"
    if status_file and os.path.isfile(status_file):
        try:
            status = open(status_file, encoding="utf-8").read().strip().splitlines()[-1].strip()
        except Exception:
            status = "unknown"
    log("tmux 会话 '%s' 已结束 (状态: %s)" % (session, status))
    return send_notify(status, "", "tmux 会话 '%s' 已结束" % session, log_file)


# --------------------------------------------------------------------------- CLI


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="bot-offline.py",
        description="本地编译通知助手 (喵提醒 / Server酱), 配置写在本文件顶部",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n"
               "  bot-offline.py --notify --status success --message 'boot 镜像好了'\n"
               "  bot-offline.py --watch-tmux xaga-build --log build.log\n"
               "  bot-offline.py --verify-bootimg out/boot-20260921-120000.img\n"
               "  bot-offline.py --test\n",
    )
    p.add_argument("--notify", action="store_true", help="推送一条通知")
    p.add_argument("--status", default="success",
                   choices=["success", "failure", "cancelled", "started", "unknown"])
    p.add_argument("--title", default="", help="通知标题, 留空自动生成")
    p.add_argument("--message", default="", help="通知正文补充信息")
    p.add_argument("--log", default="", help="日志文件, 末尾若干行会附到通知里")
    p.add_argument("--tail-lines", type=int, default=0, help="附带日志行数, 默认用宏定义")
    p.add_argument("--watch-tmux", metavar="SESSION", default="",
                   help="盯住 tmux 会话, 会话结束就推送通知")
    p.add_argument("--status-file", default="",
                   help="配合 --watch-tmux: 构建脚本写成功/失败状态的文件")
    p.add_argument("--timeout", type=int, default=0, help="配合 --watch-tmux: 最长等待秒数")
    p.add_argument("--verify-bootimg", metavar="PATH", default="", help="校验 boot.img 头部")
    p.add_argument("--test", action="store_true", help="发一条测试通知, 验证配置")
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    if args.verify_bootimg:
        return verify_bootimg(args.verify_bootimg)
    if args.watch_tmux:
        return watch_tmux(args.watch_tmux, args.log, args.status_file, args.timeout)
    if args.test:
        return send_notify("success", "%s 测试消息" % TITLE_PREFIX,
                           "如果你在手机上看到这条, 说明通知配置没问题。\n主机: %s" % host_name())
    if args.notify:
        return send_notify(args.status, args.title, args.message, args.log, args.tail_lines)

    build_parser().print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())

