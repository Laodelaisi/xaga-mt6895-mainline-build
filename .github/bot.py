#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bot.py —— xaga (Redmi Note 11T Pro / MT6895) 构建机器人

三件事，可以单独用也可以串起来用：

  1) --check-upstream   检查上游内核 / initramfs 有没有新 commit（用于「有新提交才构建」）
  2) --save-state       把本次构建实际用的 commit 记下来（写 .github/build-state.json 并推回仓库）
  3) --trigger          主动触发 GitHub Actions 构建（workflow_dispatch）
  4) --notify           构建结果推送到 喵提醒 / Server酱（可选钉钉）

--------------------------------------------------------------------------------
环境变量（GitHub Secrets / 本地都读，缺的会跳过对应渠道，不会报错）

  喵提醒    MIAO_ID              （喵提醒 https://miaotixing.com 里的「提醒ID」）
  Server酱  SERVERCHAN_KEY      （SendKey，sctapi.ftqq.com 或 sc.ftqq.com 都吃）
  钉钉      DINGTALK_WEBHOOK / DINGTALK_SECRET   （可选，保留兼容）
  GitHub    GITHUB_TOKEN | GH_TOKEN  （提高 API 限额；--save-state / --trigger 必需）
  上游覆盖  UPSTREAM_REPO=MT6895-Mainline/linux  UPSTREAM_BRANCH=7.2-mt6895-xiaomi-xaga
            INITRAMFS_REPO=MT6895-Mainline/initramfs  INITRAMFS_BRANCH=xaga-mt6895

--------------------------------------------------------------------------------
用法

  # 1. 构建完成的通知（工作流里就是这条）
  python3 bot.py --notify --status success --artifact-url "https://github.com/.../runs/123"

  # 2. 检查上游有没有新提交；结果写进 $GITHUB_OUTPUT，本机跑就打印出来
  python3 bot.py --check-upstream
  python3 bot.py --check-upstream --force          # 强制认为有更新

  # 3. 有更新就自动触发构建（本机 cron / 其它 CI 都能用）
  python3 bot.py --check-upstream --trigger-build

  # 4. 构建成功后记状态（工作流最后一步）
  python3 bot.py --save-state --kernel-commit <sha> --initramfs-commit <sha>

不需要任何第三方库（纯标准库），Python 3.8+ 都能跑。
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

DEFAULT_STATE = os.path.join(".github", "build-state.json")

UPSTREAM_REPO = os.environ.get("UPSTREAM_REPO", "MT6895-Mainline/linux")
UPSTREAM_BRANCH = os.environ.get("UPSTREAM_BRANCH", "7.2-mt6895-xiaomi-xaga")
INITRAMFS_REPO = os.environ.get("INITRAMFS_REPO", "MT6895-Mainline/initramfs")
INITRAMFS_BRANCH = os.environ.get("INITRAMFS_BRANCH", "xaga-mt6895")
DEFAULT_WORKFLOW = os.environ.get("BUILD_WORKFLOW", "build-mainline.yml")

TIMEOUT = 25


# --------------------------------------------------------------------------- #
# 小工具
# --------------------------------------------------------------------------- #
def log(msg):
    print(msg, flush=True)


def gh_token():
    return (os.environ.get("GITHUB_TOKEN")
            or os.environ.get("GH_TOKEN")
            or "").strip()


def set_output(**kwargs):
    """写 $GITHUB_OUTPUT（在 Actions 里）；本机跑则打印。"""
    path = os.environ.get("GITHUB_OUTPUT")
    lines = []
    for k, v in kwargs.items():
        v = str(v)
        # 多行值要用 heredoc 语法
        if "\n" in v:
            lines.append("%s<<__EOF__\n%s\n__EOF__" % (k, v))
        else:
            lines.append("%s=%s" % (k, v))
    text = "\n".join(lines)
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text + "\n")
    else:
        log("[output]")
        for line in lines:
            log("  " + line.replace("\n", "\n  "))


def set_env(**kwargs):
    path = os.environ.get("GITHUB_ENV")
    text = "\n".join("%s=%s" % (k, v) for k, v in kwargs.items())
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text + "\n")
    else:
        log("[env]")
        for k, v in kwargs.items():
            log("  %s=%s" % (k, v))


def step_summary(text):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text.rstrip() + "\n")
    except OSError:
        pass


def http(url, method="GET", data=None, headers=None, timeout=TIMEOUT):
    """极简 HTTP：返回 (status, body_text)。不抛异常，错误也返回。"""
    hdrs = {
        "User-Agent": "xaga-build-bot/2.0",
        "Accept": "application/vnd.github+json",
    }
    if headers:
        hdrs.update(headers)

    body = None
    if data is not None:
        if isinstance(data, (dict, list)):
            body = json.dumps(data).encode("utf-8")
            hdrs.setdefault("Content-Type", "application/json")
        elif isinstance(data, str):
            body = data.encode("utf-8")
        else:
            body = data

    req = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        try:
            return e.code, e.read().decode("utf-8", "replace")
        except Exception:
            return e.code, str(e)
    except Exception as e:                                    # 网络/超时
        return 0, "NETWORK-ERROR: %s" % e


def gh_api(path_or_url, method="GET", data=None):
    """调 GitHub API。path_or_url 可以是 api.github.com 之后的路径。"""
    if path_or_url.startswith("http"):
        url = path_or_url
    else:
        url = "https://api.github.com" + path_or_url
    headers = {}
    tok = gh_token()
    if tok:
        headers["Authorization"] = "Bearer " + tok
    return http(url, method=method, data=data, headers=headers)


# --------------------------------------------------------------------------- #
# 1. 上游检测
# --------------------------------------------------------------------------- #
def remote_head(repo, branch):
    """拿上游分支 HEAD：先试 commits/{branch}，失败退回 git/refs/heads/{branch}。"""
    st, body = gh_api("/repos/%s/commits/%s" % (repo, urllib.parse.quote(branch)))
    if st == 200:
        try:
            j = json.loads(body)
            commit = j.get("sha", "")
            msg = (j.get("commit", {}).get("message", "") or "").splitlines()
            return {
                "sha": commit,
                "short": commit[:12],
                "message": msg[0] if msg else "",
                "date": (j.get("commit", {}).get("committer", {}) or {}).get("date", ""),
            }
        except (ValueError, AttributeError):
            pass

    st2, body2 = gh_api("/repos/%s/git/ref/heads/%s" % (repo, urllib.parse.quote(branch)))
    if st2 == 200:
        try:
            j = json.loads(body2)
            sha = j["object"]["sha"]
            return {"sha": sha, "short": sha[:12], "message": "", "date": ""}
        except (ValueError, KeyError):
            pass

    return {"error": "无法读取 %s@%s（HTTP %s/%s）" % (repo, branch, st, st2)}


def load_state(path):
    if not path or not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (ValueError, OSError):
        return {}


def cmd_check_upstream(args):
    state = load_state(args.state)

    kern = remote_head(args.upstream_repo, args.upstream_branch)
    if "error" in kern:
        # 网络问题不应该让整条流水线挂掉：报错但按「不构建」处理，
        # 除非显式 --build-on-error
        log("[!] %s" % kern["error"])
        set_output(changed="false", reason="api-error")
        set_env(SHOULD_BUILD="false")
        step_summary("### 上游检测失败\n\n%s\n" % kern["error"])
        return 1 if args.build_on_error else 0

    init = remote_head(args.initramfs_repo, args.initramfs_branch)
    init_sha = init.get("sha", "") if "error" not in init else ""

    last_kernel = (state.get("kernel_commit") or "").strip()
    last_initramfs = (state.get("initramfs_commit") or "").strip()

    kernel_changed = kern["sha"] != last_kernel
    initramfs_changed = bool(init_sha) and init_sha != last_initramfs
    changed = kernel_changed or initramfs_changed

    if args.force:
        changed = True

    # 没有 state 文件 = 第一次跑，视为「有更新」构建一次
    first_run = not state

    reason = []
    if first_run:
        reason.append("首次运行（无 build-state.json）")
    if kernel_changed:
        reason.append("内核 %s -> %s" % (last_kernel[:12] or "(空)", kern["short"]))
    if initramfs_changed:
        reason.append("initramfs %s -> %s" % (last_initramfs[:12] or "(空)", init_sha[:12]))
    if not reason:
        reason.append("上游无变化")

    log("上游内核     : %s %s  %s" % (args.upstream_branch, kern["short"], kern["message"]))
    log("镜像内内核   : %s" % (last_kernel[:12] or "(未知)"))
    log("上游 initramfs: %s" % (init_sha[:12] or "(读取失败)"))
    log("镜像内 initramfs: %s" % (last_initramfs[:12] or "(未知)"))
    log("是否需要构建 : %s  (%s)" % ("是" if changed else "否", " / ".join(reason)))

    set_output(
        changed="true" if changed else "false",
        kernel_changed="true" if kernel_changed else "false",
        initramfs_changed="true" if initramfs_changed else "false",
        upstream_commit=kern["sha"],
        upstream_short=kern["short"],
        upstream_message=kern["message"],
        initramfs_commit=init_sha,
        last_kernel_commit=last_kernel,
        reason=" / ".join(reason),
    )
    set_env(SHOULD_BUILD="true" if changed else "false",
            UPSTREAM_COMMIT=kern["sha"])

    # 顺手落一份 JSON：工作流里同一个 step 内没法读 $GITHUB_OUTPUT（要等下一个 step），
    # 有这么个文件就能在同一 step 里立刻取值。
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump({
                "changed": changed,
                "kernel_changed": kernel_changed,
                "initramfs_changed": initramfs_changed,
                "upstream_commit": kern["sha"],
                "upstream_short": kern["short"],
                "upstream_message": kern["message"],
                "initramfs_commit": init_sha,
                "last_kernel_commit": last_kernel,
                "last_initramfs_commit": last_initramfs,
                "reason": " / ".join(reason),
            }, f, indent=2, ensure_ascii=False)
        log("已写 %s" % args.json)

    step_summary(
        "### 上游检测\n\n"
        "| 项目 | 值 |\n|---|---|\n"
        "| 上游内核 HEAD | `%s` %s |\n"
        "| 已构建内核 | `%s` |\n"
        "| 上游 initramfs | `%s` |\n"
        "| 已构建 initramfs | `%s` |\n"
        "| 是否构建 | **%s** |\n"
        "| 原因 | %s |\n"
        % (kern["short"], kern["message"], last_kernel[:12] or "—",
           init_sha[:12] or "—", last_initramfs[:12] or "—",
           "是" if changed else "否", " / ".join(reason))
    )

    if args.trigger_build and changed:
        rc = do_trigger(args)
        set_output(triggered="true" if rc == 0 else "false")
    return 0


# --------------------------------------------------------------------------- #
# 2. 状态保存（写回仓库）
# --------------------------------------------------------------------------- #
def cmd_save_state(args):
    state = load_state(args.state)
    state.update({
        "kernel_commit": args.kernel_commit or state.get("kernel_commit", ""),
        "kernel_branch": args.kernel_branch or UPSTREAM_BRANCH,
        "kernel_repo": args.kernel_repo or UPSTREAM_REPO,
        "initramfs_commit": args.initramfs_commit or state.get("initramfs_commit", ""),
        "initramfs_branch": INITRAMFS_BRANCH,
        "initramfs_repo": INITRAMFS_REPO,
        "boot_img_sha256": args.boot_img_sha256 or state.get("boot_img_sha256", ""),
        "rootfs_sha256": args.rootfs_sha256 or state.get("rootfs_sha256", ""),
        "built_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "run_url": args.run_url or "",
    })

    os.makedirs(os.path.dirname(args.state) or ".", exist_ok=True)
    with open(args.state, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
        f.write("\n")
    log("已写 %s" % args.state)
    log(json.dumps(state, indent=2, ensure_ascii=False))

    if args.no_push:
        return 0

    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not repo or not gh_token():
        log("[!] 没有 GITHUB_REPOSITORY / TOKEN，只写本地文件不推送")
        return 0

    # 用 Contents API 提交（比 git push 稳，不用处理 credentials / rebase）
    remote = args.state.replace(os.sep, "/")
    st, body = gh_api("/repos/%s/contents/%s?ref=%s"
                      % (repo, urllib.parse.quote(remote),
                         urllib.parse.quote(args.ref)))
    sha = ""
    if st == 200:
        try:
            sha = json.loads(body).get("sha", "")
        except ValueError:
            pass

    payload = {
        "message": "chore(bot): 记录已构建内核 commit %s [skip ci]"
                   % (state.get("kernel_commit", "")[:12] or "unknown"),
        "content": base64.b64encode(
            json.dumps(state, indent=2, ensure_ascii=False).encode("utf-8")
            + b"\n").decode("ascii"),
        "branch": args.ref,
    }
    if sha:
        payload["sha"] = sha

    st, body = gh_api("/repos/%s/contents/%s" % (repo, urllib.parse.quote(remote)),
                      method="PUT", data=payload)
    if st in (200, 201):
        log("状态已提交回仓库 (%s)" % repo)
        return 0
    log("[!] 提交状态失败 HTTP %s: %s" % (st, body[:400]))
    return 0        # 状态回写失败不该让流水线挂掉


# --------------------------------------------------------------------------- #
# 3. 触发构建
# --------------------------------------------------------------------------- #
def do_trigger(args):
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    tok = gh_token()
    if not repo or not tok:
        log("[!] --trigger 需要 GITHUB_REPOSITORY 与 GITHUB_TOKEN/GH_TOKEN")
        return 1

    inputs = {}
    for k, v in (("TASK", args.task), ("ROOTFS_TYPE", args.rootfs_type),
                 ("KERNEL_COMMIT", args.kernel_commit),
                 ("USB_GADGET", args.usb_gadget)):
        if v:
            inputs[k] = v

    payload = {"ref": args.ref, "inputs": inputs}
    url = "/repos/%s/actions/workflows/%s/dispatches" % (repo, args.workflow)
    st, body = gh_api(url, method="POST", data=payload)
    if st in (204, 200):
        log("已触发构建: %s (ref=%s) inputs=%s" % (args.workflow, args.ref, inputs))
        return 0
    log("[!] 触发失败 HTTP %s: %s" % (st, body[:400]))
    return 1


def cmd_trigger(args):
    return do_trigger(args)


# --------------------------------------------------------------------------- #
# 4. 通知（喵提醒 / Server酱 / 钉钉）
# --------------------------------------------------------------------------- #
def send_miao(text):
    mid = os.environ.get("MIAO_ID", "").strip()
    if not mid:
        return None
    url = "https://miaotixing.com/trigger"
    data = urllib.parse.urlencode({"id": mid, "text": text}).encode("ascii")
    st, body = http(url, method="POST", data=data,
                    headers={"Content-Type": "application/x-www-form-urlencoded"})
    ok = st == 200 and "<code>0</code>" in body
    if not ok:
        # 有些部署返回 JSON
        ok = st == 200 and '"code":0' in body.replace(" ", "")
    return ("喵提醒", ok, "HTTP %s %s" % (st, body[:160]))


def send_serverchan(title, desp):
    key = os.environ.get("SERVERCHAN_KEY", "").strip()
    if not key:
        return None
    for base in ("https://sctapi.ftqq.com", "https://sc.ftqq.com"):
        url = "%s/%s.send" % (base, key)
        st, body = http(url, method="POST",
                        data=urllib.parse.urlencode({"title": title, "desp": desp}).encode("utf-8"),
                        headers={"Content-Type": "application/x-www-form-urlencoded"})
        if st == 200:
            try:
                j = json.loads(body)
                code = j.get("code")
                if code in (0, "0"):
                    return ("Server酱", True, "%s %s" % (base, j.get("message", "ok")))
                if code is None:
                    return ("Server酱", True, "%s ok" % base)
                last = "%s code=%s %s" % (base, code, j.get("message", ""))
            except ValueError:
                last = "%s HTTP %s" % (base, body[:160])
        else:
            last = "%s HTTP %s %s" % (base, st, body[:160])
    return ("Server酱", False, last)


def send_dingtalk(title, desp):
    webhook = os.environ.get("DINGTALK_WEBHOOK", "").strip()
    if not webhook:
        return None
    secret = os.environ.get("DINGTALK_SECRET", "").strip()
    url = webhook
    if secret:
        ts = str(int(round(time.time() * 1000)))
        sign_str = "%s\n%s" % (ts, secret)
        sign = urllib.parse.quote_plus(
            base64.b64encode(hmac.new(secret.encode("utf-8"),
                                      sign_str.encode("utf-8"),
                                      digestmod=hashlib.sha256).digest()).decode())
        url = "%s&timestamp=%s&sign=%s" % (webhook, ts, sign)
    payload = {"msgtype": "markdown",
               "markdown": {"title": title, "text": "%s\n\n%s" % (title, desp)}}
    st, body = http(url, method="POST", data=payload)
    ok = st == 200 and '"errcode":0' in body.replace(" ", "")
    return ("钉钉", ok, "HTTP %s %s" % (st, body[:160]))


def cmd_notify(args):
    status_map = {
        "success": ("✅", "构建成功"),
        "failure": ("❌", "构建失败"),
        "cancelled": ("⚪", "构建已取消"),
    }
    icon, label = status_map.get(args.status, ("ℹ️", "构建" + args.status))

    lines = [
        "%s xaga 主线内核 %s" % (icon, label),
        "",
        "任务: %s" % (args.task or "(默认全部)"),
        "内核: %s" % (args.kernel_branch or UPSTREAM_BRANCH),
    ]
    if args.kernel_commit:
        lines.append("commit: %s" % args.kernel_commit)
    if args.rootfs_type:
        lines.append("rootfs: %s" % args.rootfs_type)
    lines.append("时间: %s" % datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    if args.details:
        lines.append("")
        lines.append(args.details)
    if args.artifact_url:
        lines.append("")
        lines.append("详情: %s" % args.artifact_url)

    if args.markdown:
        title = "%s xaga %s" % (icon, label)
        desp = "\n".join(lines)
    else:
        title = "%s xaga %s" % (icon, label)
        desp = "\n".join(lines)

    results = [send_miao(desp), send_serverchan(title, desp),
               send_dingtalk(title, desp)]
    results = [r for r in results if r]

    if not results:
        log("[!] 没有配置任何通知渠道（MIAO_ID / SERVERCHAN_KEY / DINGTALK_WEBHOOK 都为空）")
        return 0

    any_ok = False
    for name, ok, detail in results:
        log("%s %-10s %s" % ("[ok]  " if ok else "[fail]", name, detail))
        any_ok = any_ok or ok

    # 通知失败不改变构建结果，但要让日志里看得见
    return 0 if any_ok or not args.strict else 1


# --------------------------------------------------------------------------- #
# 5. 产物校验（把 python 逻辑放在这个文件里，工作流就不用在 YAML 里写 heredoc）
# --------------------------------------------------------------------------- #
BOOT_HDR_SIZE_V3 = 1580        # sizeof(boot_img_hdr_v3)
BOOT_HDR_SIZE_V4 = 1584        # sizeof(boot_img_hdr_v4) = v3 + uint32 signature_size
BOOT_HDR_OFF_SIZE = 0x14       # header_size 字段
BOOT_HDR_OFF_VERSION = 0x28    # header_version 字段
# 注：这里不做「补正畸形 v4 头」那种后处理 —— header_size 写不对就说明打包器
# 选错了（osm0sis C 版只实现到 boot_img_hdr_v3，恒写 1580），该换 AOSP 官方
# python 版重打，见工作流「准备 AOSP 版 mkbootimg」一步。


def cmd_verify_bootimg(args):
    """校验 boot.img 头部：magic / header_version / header_size 等。"""
    try:
        with open(args.image, "rb") as f:
            d = f.read(4096)
    except OSError as e:
        log("!! 打不开 %s: %s" % (args.image, e))
        return 1
    if len(d) < 0x2c:
        log("!! %s 太小，不是 boot.img" % args.image)
        return 1

    import struct as _s
    magic = d[0x00:0x08]
    ksize = _s.unpack_from("<I", d, 0x08)[0]
    rsize = _s.unpack_from("<I", d, 0x0c)[0]
    osver = _s.unpack_from("<I", d, 0x10)[0]
    hsize = _s.unpack_from("<I", d, BOOT_HDR_OFF_SIZE)[0]
    hver = _s.unpack_from("<I", d, BOOT_HDR_OFF_VERSION)[0]

    log("    magic          : %s" % magic.decode("latin-1"))
    log("    kernel_size    : %d (%.2f MB)" % (ksize, ksize / 1048576))
    log("    ramdisk_size   : %d (%.1f KB)" % (rsize, rsize / 1024))
    log("    os_version     : 0x%08x" % osver)
    log("    header_size    : %d  (v4 应为 %d)" % (hsize, BOOT_HDR_SIZE_V4))
    log("    header_version : %d" % hver)

    bad = []
    if magic != b"ANDROID!":
        bad.append("magic 不是 ANDROID!")
    if hver != 4:
        bad.append("header_version 应为 4，实际 %d" % hver)
    if hsize != BOOT_HDR_SIZE_V4:
        if hver == 4 and hsize == BOOT_HDR_SIZE_V3:
            bad.append(
                "header_size 应为 %d，实际 %d —— 这是「只实现到 boot_img_hdr_v3」的打包器"
                "写出来的畸形 v4 头（osm0sis C 版 mkbootimg 的 header_size 恒为 1580，"
                "它没有 v4 结构）。改用 AOSP 官方 python 版重新打包："
                "见工作流「准备 AOSP 版 mkbootimg」一步（apt install mkbootimg + gki stub）。"
                % (BOOT_HDR_SIZE_V4, hsize))
        else:
            bad.append("header_size 应为 %d，实际 %d" % (BOOT_HDR_SIZE_V4, hsize))
    if ksize == 0:
        bad.append("kernel 段为空")
    if rsize == 0:
        bad.append("ramdisk 段为空")
    if bad:
        for b in bad:
            log("!! %s" % b)
        return 1
    log("    OK: boot.img 校验通过")
    return 0


def cmd_inspect_image(args):
    """从裸 Image 里读内核版本串 + 内嵌 .config（IKCFG_ST/IKCFG_ED）。

    arm64 defconfig 带 CONFIG_IKCONFIG=y + CONFIG_IKCONFIG_PROC=y，
    所以内核镜像里内嵌了完整 .config（设备上等价于 zcat /proc/config.gz）。
    """
    import gzip
    import re
    try:
        raw = open(args.image, "rb").read()
    except OSError as e:
        log("!! 打不开 %s: %s" % (args.image, e))
        return 1

    m = re.search(rb"Linux version [^\x00\n]{0,140}", raw)
    if m:
        log("    %s" % m.group(0).decode("utf-8", "replace"))
    else:
        log("    (未找到 'Linux version' 版本串)")

    s, e = raw.find(b"IKCFG_ST"), raw.find(b"IKCFG_ED")
    if s < 0 or e < 0:
        log("    IKCFG 标记不存在（CONFIG_IKCONFIG 没开？）")
        # 要断言却读不到 .config —— 必须失败。静默跳过等于把「卡第一 logo」那类
        # 配置事故的最后一关直接放空（arm64 defconfig 带 IKCONFIG=y，读不到就是异常）。
        if args.assert_y or args.assert_n:
            log("!! 要求断言却拿不到内嵌 .config，无法校验（不要在这种情况下放过镜像）")
            return 1
        return 0

    blob = raw[s + 8:e]
    cfg = None
    for off in range(0, 16):
        try:
            cfg = gzip.decompress(blob[off:]).decode("utf-8", "replace")
            break
        except Exception:
            continue
    if cfg is None:
        log("    IKCFG 段 gzip 解压失败")
        if args.assert_y or args.assert_n:
            log("!! 要求断言却解不开内嵌 .config，无法校验")
            return 1
        return 0

    keys = args.keys or [
        "CONFIG_USB_GADGET", "CONFIG_USB_LIBCOMPOSITE", "CONFIG_USB_CONFIGFS",
        "CONFIG_USB_F_ACM", "CONFIG_USB_U_SERIAL", "CONFIG_USB_CONFIGFS_ACM",
        "CONFIG_CONFIGFS_FS", "CONFIG_MODULES", "CONFIG_CRYPTO_USER",
        # 外部 ramdisk / DTB bootargs 形态（2026-09-20 卡第一 logo 就栽在这两个上）
        "CONFIG_INITRAMFS_SOURCE", "CONFIG_INITRAMFS_FORCE",
        "CONFIG_CMDLINE_FORCE", "CONFIG_CMDLINE_FROM_BOOTLOADER",
    ]
    for k in keys:
        hit = re.search(r"^%s=.*$" % re.escape(k), cfg, re.M)
        if hit is None and re.search(r"^# %s is not set$" % re.escape(k), cfg, re.M):
            hit = re.search(r"^# %s is not set$" % re.escape(k), cfg, re.M)
        log("    %-28s %s" % (k, hit.group(0) if hit else "(unset)"))

    if args.dump:
        with open(args.dump, "w", encoding="utf-8") as f:
            f.write(cfg)
        log("    完整 .config 已写到 %s（%d 行）" % (args.dump, cfg.count("\n")))

    if args.assert_y:
        missing = [k for k in args.assert_y
                   if not re.search(r"^%s=y$" % re.escape(k), cfg, re.M)]
        if missing:
            log("!! 断言失败，以下项不是 =y: %s" % " ".join(missing))
            return 1
        log("    OK: %s 全部 =y" % " ".join(args.assert_y))

    # 「必须没开」的断言。缺项（压根没这一行）算通过 —— 正是我们要的那种状态；
    # 只有显式 =y 才算失败。用在本工程最致命的两个开关上：
    #   CONFIG_INITRAMFS_FORCE=y  → 内核无视 bootloader 传入的 ramdisk（外部 initramfs 方案直接废）
    #   CONFIG_CMDLINE_FORCE=y    → 丢弃内嵌 DTB 的 /chosen/bootargs
    if args.assert_n:
        bad = [k for k in args.assert_n
               if re.search(r"^%s=y$" % re.escape(k), cfg, re.M)]
        if bad:
            log("!! 断言失败，以下项不该 =y: %s" % " ".join(bad))
            return 1
        log("    OK: %s 均未开启" % " ".join(args.assert_n))
    return 0


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def build_parser():
    p = argparse.ArgumentParser(
        description="xaga 构建机器人：上游 commit 检测 / 触发构建 / 结果通知",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("用法")[-1] if "用法" in __doc__ else None,
    )
    sub = p.add_subparsers(dest="cmd")

    common_up = argparse.ArgumentParser(add_help=False)
    common_up.add_argument("--upstream-repo", default=UPSTREAM_REPO)
    common_up.add_argument("--upstream-branch", default=UPSTREAM_BRANCH)
    common_up.add_argument("--initramfs-repo", default=INITRAMFS_REPO)
    common_up.add_argument("--initramfs-branch", default=INITRAMFS_BRANCH)
    common_up.add_argument("--state", default=DEFAULT_STATE,
                           help="状态文件路径（默认 .github/build-state.json）")

    a = sub.add_parser("check-upstream", parents=[common_up], help="检查上游有没有新 commit")
    a.add_argument("--force", action="store_true", help="无条件认为有更新")
    a.add_argument("--build-on-error", action="store_true",
                   help="API 出错时也认为需要构建（默认不构建）")
    a.add_argument("--trigger-build", action="store_true", help="检测到更新就直接触发构建")
    a.add_argument("--json", default="", help="把检测结果另存一份 JSON（给工作流同一 step 里读）")
    a.set_defaults(func=cmd_check_upstream)

    b = sub.add_parser("save-state", parents=[common_up], help="记录本次构建的 commit")
    b.add_argument("--kernel-commit", default="")
    b.add_argument("--kernel-branch", default="")
    b.add_argument("--kernel-repo", default="")
    b.add_argument("--initramfs-commit", default="")
    b.add_argument("--boot-img-sha256", default="")
    b.add_argument("--rootfs-sha256", default="")
    b.add_argument("--run-url", default="")
    b.add_argument("--ref", default=os.environ.get("GITHUB_REF_NAME", "main"))
    b.add_argument("--no-push", action="store_true", help="只写本地文件，不推回仓库")
    b.set_defaults(func=cmd_save_state)

    c = sub.add_parser("trigger", help="触发 GitHub Actions 构建")
    c.add_argument("--workflow", default=DEFAULT_WORKFLOW)
    c.add_argument("--ref", default=os.environ.get("GITHUB_REF_NAME", "main"))
    c.add_argument("--task", default="")
    c.add_argument("--rootfs-type", default="")
    c.add_argument("--kernel-commit", default="")
    c.add_argument("--usb-gadget", default="")
    c.set_defaults(func=cmd_trigger)

    d = sub.add_parser("notify", help="推送构建结果通知")
    d.add_argument("--status", default="success",
                   choices=["success", "failure", "cancelled"])
    d.add_argument("--task", default="")
    d.add_argument("--kernel-branch", default="")
    d.add_argument("--kernel-commit", default="")
    d.add_argument("--rootfs-type", default="")
    d.add_argument("--artifact-url", default="")
    d.add_argument("--details", default="")
    d.add_argument("--markdown", action="store_true", help="Server酱用 markdown")
    d.add_argument("--strict", action="store_true", help="所有渠道都失败时返回非零")
    d.set_defaults(func=cmd_notify)

    e = sub.add_parser("verify-bootimg", help="校验 boot.img 头部（v4 / pagesize / 段大小）")
    e.add_argument("image", help="boot.img 路径")
    e.set_defaults(func=cmd_verify_bootimg)

    g = sub.add_parser("inspect-image", help="读裸 Image 的版本串 + 内嵌 .config")
    g.add_argument("image", help="Image 路径")
    g.add_argument("--keys", nargs="*", default=None, help="要打印的 CONFIG_* 列表")
    g.add_argument("--assert-y", nargs="*", default=None, help="这些项必须 =y，否则返回非零")
    g.add_argument("--assert-n", nargs="*", default=None,
                   help="这些项必须**没有** =y（未开 / 未设），否则返回非零")
    g.add_argument("--dump", default="", help="把完整 .config 写到指定文件")
    g.set_defaults(func=cmd_inspect_image)

    return p


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)

    # 同时兼容 `bot.py --notify ...`（老的连字符风格）和子命令风格
    legacy = {"--notify": "notify", "--check-upstream": "check-upstream",
              "--save-state": "save-state", "--trigger": "trigger"}
    if argv and argv[0] in legacy:
        argv = [legacy[argv[0]]] + argv[1:]

    p = build_parser()
    args = p.parse_args(argv)
    if not getattr(args, "func", None):
        p.print_help()
        return 2
    return args.func(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
