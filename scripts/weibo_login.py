#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
扫码登录微博 -> 把登录态下发给越狱 iOS 5/6/7 设备上的「热门」app。

背景：iOS 6 的 WebKit 跑不动 m.weibo.cn 的登录页（Sina Visitor System 用 ES6，
登录还有网易易盾滑块），所以登录在 Mac 侧完成：走 passport.weibo.com 的二维码
登录（手机微博 App 扫一下即可，不需要账号密码），拿到 SUB/SUBP 等 Cookie，
用 /api/config 的 data.login 校验，再写进 app bundle 的 Login.txt，通过 SSH
下发到设备并重启 app。之后设备自己带 Cookie 直连微博接口，Mac 不用常开。

输出是有状态行的，方便上层读取：
    QR_READY=<二维码 PNG 路径>      二维码已生成，可以给用户扫
    STATUS=<文字>                  轮询状态变化
    LOGIN_OK uid=<uid> name=<昵称>
    COOKIE_SAVED=<Login.txt 路径>
    DEVICE_INJECTED / APP_RESTARTED / DONE
    ERROR=<原因>

用法：
    python3 scripts/weibo_login.py --ip 192.168.8.171
    python3 scripts/weibo_login.py --qr-only          # 只生成二维码，不轮询/不注入
    python3 scripts/weibo_login.py --no-device        # 只写本地 Login.txt
    python3 scripts/weibo_login.py --uid 1234567890   # 自动提取 uid 失败时兜底
"""

import argparse
import base64
import http.cookiejar
import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, "Resources")
BUILD = os.path.join(ROOT, "build")
QR_PATH = os.path.join(BUILD, "weibo_login_qr.png")
LOGIN_TXT = os.path.join(RESOURCES, "Login.txt")
APP_REMOTE = "/Applications/LegacyApp.app/Login.txt"

PC_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
         "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
M_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 10_3 like Mac OS X) "
        "AppleWebKit/603.1.30 (KHTML, like Gecko) Version/10.0 Mobile/14E277 Safari/602.1")

# Cookie 里真正决定登录态的是 SUB / SUBP，其余是移动端会话辅助字段。
COOKIE_ORDER = ["SUB", "SUBP", "SSOLoginState", "ALF", "SCF", "_T_WM",
                "WEIBOCN_FROM", "MLOGIN", "XSRF-TOKEN", "mweibo_short_token",
                "M_WEIBOCN_PARAMS", "WBPSESS", "SUHB"]


def emit(key, value=""):
    print(("%s=%s" % (key, value)) if value != "" else key, flush=True)


class Session:
    """一个共享 CookieJar 的会话，按目标域名切换 UA，Cookie 全程自动携带。"""

    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        handlers = [urllib.request.HTTPCookieProcessor(self.jar)]
        try:
            ctx = ssl.create_default_context()
            handlers.append(urllib.request.HTTPSHandler(context=ctx))
        except Exception:
            pass
        self.opener = urllib.request.build_opener(*handlers)

    def get(self, url, ua=M_UA, referer=None, accept="*/*", data=None, extra=None):
        headers = {"User-Agent": ua, "Accept": accept,
                   "Accept-Language": "zh-CN,zh;q=0.9"}
        if referer:
            headers["Referer"] = referer
        if extra:
            headers.update(extra)
        req = urllib.request.Request(url, data=data, headers=headers)
        with self.opener.open(req, timeout=20) as resp:
            return resp.read(), dict(resp.headers), resp.geturl()


def make_qrcode(session):
    body, _, _ = session.get(
        "https://passport.weibo.com/sso/v2/qrcode/image?entry=weibo&size=180",
        ua=PC_UA, referer="https://passport.weibo.com/sso/signin",
        accept="application/json, text/plain, */*")
    payload = json.loads(body.decode("utf-8", "replace"))
    if payload.get("retcode") != 20000000:
        raise RuntimeError("二维码接口返回异常: %s" % str(payload)[:200])
    data = payload["data"]
    qrid = data["qrid"]
    image = data["image"]
    if image.startswith("//"):
        image = "https:" + image
    png, _, _ = session.get(image, ua=PC_UA,
                            referer="https://passport.weibo.com/sso/signin")
    if not png.startswith(b"\x89PNG"):
        raise RuntimeError("二维码图片不是 PNG")
    os.makedirs(BUILD, exist_ok=True)
    with open(QR_PATH, "wb") as f:
        f.write(png)
    return qrid


def poll_scan(session, qrid, timeout):
    deadline = time.time() + timeout
    last = None
    check = ("https://passport.weibo.com/sso/v2/qrcode/check?qrid=%s&entry=weibo"
             % urllib.parse.quote(qrid, safe=""))
    while time.time() < deadline:
        time.sleep(2)
        try:
            body, _, _ = session.get(
                check, ua=PC_UA, referer="https://passport.weibo.com/sso/signin",
                accept="application/json, text/plain, */*")
            payload = json.loads(body.decode("utf-8", "replace"))
        except Exception as e:
            emit("STATUS", "轮询网络异常，重试: %s" % str(e)[:80])
            continue
        rc = payload.get("retcode")
        msg = payload.get("msg", "")
        if rc != last:
            emit("STATUS", "retcode=%s msg=%s" % (rc, msg))
            last = rc
        if rc == 20000000:
            return payload
        if rc in (50114003, 50114004, 50114015):
            raise RuntimeError("二维码已失效，请重新运行脚本生成新二维码")
    raise RuntimeError("等待扫码超时（%d 秒），请重新运行脚本" % timeout)


def jar_names(jar):
    return sorted(set(c.name for c in jar))


def exchange_cookies(session, payload):
    """扫码确认只拿到一次性 alt，必须换票 + 逐个访问跨域登录 URL 才会下发 SUB。

    实测 2026-11：passport.weibo.com/sso/v2/qrcode/check 成功时 data.alt 是登录
    令牌而不是跳转 URL，需要用 login.sina.com.cn/sso/login.php 的 JSONP 换出
    uid / nick / crossDomainUrlList，再依次 GET 完成跨域写 Cookie。为兼容不同
    版本，alt 是完整 URL、或 data 里直接带 crossDomainUrlList 时也一并支持。
    """
    data = payload.get("data") if isinstance(payload, dict) else None
    data = data if isinstance(data, dict) else {}
    fields = ",".join(sorted(data.keys())) or "(空)"
    emit("STATUS", "扫码返回字段: " + fields)

    urls = []
    login_info = {}
    for u in (data.get("crossDomainUrlList") or []):
        if isinstance(u, str) and u.startswith("http"):
            urls.append(u)

    # 实测 passport.weibo.com/sso/v2/qrcode/check 成功时字段叫 url（不是 alt），
    # 值是换票用的跳转地址；其他版本可能给 alt / redirect。这里全部兼容。
    token = None
    for key in ("url", "alt", "redirect", "loginUrl"):
        value = data.get(key)
        if not isinstance(value, str) or not value:
            continue
        if value.startswith("//"):
            value = "https:" + value
        if value.startswith("http"):
            urls.insert(0, value)
            emit("STATUS", "%s 是跳转 URL: %s" % (key, value[:140]))
        else:
            token = value
            emit("STATUS", "%s 是登录令牌，走 login.php" % key)

    if token:
        ts = int(time.time() * 100000)
        jurl = ("https://login.sina.com.cn/sso/login.php?entry=qrcodesso"
                "&returntype=TEXT&crossdomain=1&cdult=3&domain=weibo.com"
                "&alt=%s&savestate=30&callback=STK_%d"
                % (urllib.parse.quote(token, safe=""), ts))
        try:
            body, _, _ = session.get(jurl, ua=PC_UA,
                                     referer="https://passport.weibo.com/")
            m = re.search(r"\((.*)\)\s*;?\s*$",
                          body.decode("utf-8", "replace"), re.S)
            if m:
                info = json.loads(m.group(1))
                if isinstance(info, dict):
                    login_info = info
                    for u in (info.get("crossDomainUrlList") or []):
                        if isinstance(u, str) and u.startswith("http"):
                            urls.append(u)
                    emit("STATUS", "login.php uid=%s nick=%s urls=%d"
                         % (info.get("uid", "-"), info.get("nick", "-"), len(urls)))
        except Exception as e:
            emit("STATUS", "login.php 换票异常: %s" % str(e)[:100])

    emit("STATUS", "待访问跨域登录 URL 数=%d" % len(urls))
    for i, u in enumerate(urls):
        target = u
        if i == 1 and "action=" not in u:
            target = u + "&action=login"
        try:
            session.get(target, ua=PC_UA, referer="https://passport.weibo.com/")
        except Exception as e:
            emit("STATUS", "跨域 URL %d 异常: %s" % (i + 1, str(e)[:80]))

    # 用 PC 登录态补 m.weibo.cn 的移动端 Cookie，并顺便拿移动端设备标识
    try:
        session.get("https://m.weibo.cn/", ua=M_UA, referer="https://m.weibo.cn/")
    except Exception as e:
        emit("STATUS", "补移动端 Cookie 异常: %s" % str(e)[:80])

    emit("STATUS", "CookieJar 字段: " + ",".join(jar_names(session.jar)))
    return login_info


def cookie_header(jar):
    values = {}
    for c in jar:
        if c.name in COOKIE_ORDER:
            values[c.name] = c.value
    if "SUB" not in values:
        raise RuntimeError("没有拿到 SUB 登录凭证，扫码可能未真正完成")
    values["MLOGIN"] = "1"
    return "; ".join("%s=%s" % (k, values[k]) for k in COOKIE_ORDER if k in values)


def digits(value):
    if isinstance(value, bool):
        return None
    s = str(value) if value is not None else ""
    return s if s.isdigit() and len(s) >= 5 else None


def find_uid(session, scan_data, config, cookie, override):
    if override:
        return str(override)
    candidates = []
    for src in (scan_data, config.get("data", {}) if isinstance(config, dict) else {}):
        if not isinstance(src, dict):
            continue
        for key in ("uid", "user_id", "id", "oid"):
            d = digits(src.get(key))
            if d:
                candidates.append(d)
        user = src.get("user") or src.get("userInfo")
        if isinstance(user, dict):
            for key in ("id", "uid", "idstr"):
                d = digits(user.get(key))
                if d:
                    candidates.append(d)
    # SUB 是 urlsafe base64，里面通常带 uid 数字
    m = re.search(r"(?:^|;)\s*SUB=([^;]+)", cookie)
    if m:
        try:
            raw = base64.urlsafe_b64decode(m.group(1) + "===").decode("utf-8", "ignore")
            for d in re.findall(r"\d{8,}", raw):
                candidates.append(d)
        except Exception:
            pass
    # /profile 会重定向到 /u/<uid>，最可靠的一路
    try:
        body, _, final = session.get("https://m.weibo.cn/profile", ua=M_UA,
                                     referer="https://m.weibo.cn/")
        for d in re.findall(r"/u/(\d{6,})", final or ""):
            candidates.append(d)
        for d in re.findall(rb"[\"']?uid[\"']?\s*[:=]\s*[\"']?(\d{6,})", body or b""):
            candidates.append(d.decode())
    except Exception:
        pass
    if not candidates:
        return None
    # 出现次数最多的长数字最像真实 uid
    counts = {}
    for d in candidates:
        counts[d] = counts.get(d, 0) + 1
    return sorted(counts, key=lambda d: (-counts[d], -len(d)))[0]


def find_name(session, config, scan_data, uid):
    for src in (scan_data,
                config.get("data", {}) if isinstance(config, dict) else {}):
        if not isinstance(src, dict):
            continue
        for key in ("nick", "screen_name", "name"):
            v = src.get(key)
            if isinstance(v, str) and v:
                return v
        user = src.get("user") or src.get("userInfo")
        if isinstance(user, dict):
            for key in ("screen_name", "name", "nick"):
                v = user.get(key)
                if isinstance(v, str) and v:
                    return v
    # 兜底：带 Cookie 的用户资料接口 stable 返回 data.userInfo.screen_name
    try:
        if uid:
            body, _, _ = session.get(
                "https://m.weibo.cn/api/container/getIndex?containerid=100505%s" % uid,
                ua=M_UA, referer="https://m.weibo.cn/",
                accept="application/json, text/plain, */*",
                extra={"X-Requested-With": "XMLHttpRequest"})
            info = json.loads(body.decode("utf-8", "replace"))
            ui = (info.get("data") or {}).get("userInfo") or {}
            name = ui.get("screen_name")
            if isinstance(name, str) and name:
                return name
    except Exception:
        pass
    return "已登录"


def probe_feed_container(session, uid):
    """找登录后的关注流 containerid；拿不到就退回「我的微博」107603{uid}。

    微博 H5 首页 HTML 里会带首屏容器信息，先试着正则提取；不同版本差异大，
    所以任何失败都静默退回用户时间线，app 端 tab 会按 feed 前缀自行命名。"""
    fallback = ("107603%s" % uid) if uid else ""
    try:
        body, _, _ = session.get("https://m.weibo.cn/", ua=M_UA,
                                 referer="https://m.weibo.cn/")
        text = body.decode("utf-8", "ignore")
        ids = re.findall(r"containerid[\"'=:>\s]+(\d{6,}[0-9A-Za-z_\-]*)", text)
        for cid in ids:
            if cid.startswith("100505") or cid.startswith("107603"):
                continue
            if cid != "102803":
                emit("STATUS", "首页发现候选 containerid=%s" % cid)
                return cid
    except Exception:
        pass
    return fallback


def write_login_txt(uid, feed, name, cookie):
    os.makedirs(RESOURCES, exist_ok=True)
    content = "uid=%s\nfeed=%s\nname=%s\ncookie=%s\n" % (
        uid or "", feed or "", name or "已登录", cookie)
    # Cookie 是账号凭据：文件权限 600，且由 .gitignore 排除
    with open(LOGIN_TXT, "w", encoding="utf-8") as f:
        f.write(content)
    os.chmod(LOGIN_TXT, 0o600)
    emit("COOKIE_SAVED", LOGIN_TXT)


def ssh_env(password):
    env = os.environ.copy()
    if password:
        askpass = "/tmp/legacy_login_askpass_%d.sh" % os.getpid()
        with open(askpass, "w") as f:
            f.write("#!/bin/sh\nprintf '%s\\n' \"$LEGACY_SSH_PASSWORD\"\n")
        os.chmod(askpass, 0o700)
        env["LEGACY_SSH_PASSWORD"] = password
        env["SSH_ASKPASS"] = askpass
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = ":0"
    return env


SSH_OPTS = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "HostKeyAlgorithms=+ssh-rsa", "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
            "-o", "KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1",
            "-o", "Ciphers=+aes128-cbc,3des-cbc", "-o", "RequiredRSASize=1024",
            "-o", "ConnectTimeout=10"]


def push_to_device(ip, password, env):
    target = "root@%s" % ip
    subprocess.run(["scp"] + SSH_OPTS + ["-O", LOGIN_TXT,
                                        "%s:%s" % (target, APP_REMOTE)],
                   env=env, check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.PIPE)
    subprocess.run(["ssh"] + SSH_OPTS + [target,
                   "chown root:wheel %s; chmod 644 %s" % (APP_REMOTE, APP_REMOTE)],
                   env=env, check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.PIPE)
    emit("DEVICE_INJECTED", ip)
    subprocess.run(["ssh"] + SSH_OPTS + [target,
                   "killall -9 LegacyApp 2>/dev/null; sleep 1; "
                   "sblaunch com.legacy.legacyapp 2>/dev/null || true"],
                   env=env, check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.PIPE)
    emit("APP_RESTARTED", target)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default=os.environ.get("THEOS_DEVICE_IP", "192.168.8.171"))
    ap.add_argument("--password", default=os.environ.get("THEOS_DEVICE_PASSWORD", "alpine"))
    ap.add_argument("--timeout", type=int, default=240)
    ap.add_argument("--qr-only", action="store_true")
    ap.add_argument("--no-device", action="store_true")
    ap.add_argument("--uid", default="")
    args = ap.parse_args()

    os.makedirs(BUILD, exist_ok=True)
    session = Session()
    qrid = make_qrcode(session)
    emit("QR_READY", QR_PATH)
    emit("STATUS", "二维码已生成，等待手机微博 App 扫码并确认")
    if args.qr_only:
        emit("DONE", "qr-only")
        return

    scan_payload = poll_scan(session, qrid, args.timeout)
    emit("STATUS", "扫码确认成功，正在换取登录 Cookie")
    login_info = exchange_cookies(session, scan_payload)
    scan_data = dict(scan_payload.get("data") or {})
    scan_data.update(login_info)

    try:
        cookie = cookie_header(session.jar)
    except RuntimeError:
        emit("STATUS", "SUB 缺失，尝试 wapsso 备用入口")
        try:
            session.get("https://passport.weibo.com/sso/signin?entry=wapsso"
                        "&source=wapssowb&url=https%3A%2F%2Fm.weibo.cn%2F",
                        ua=M_UA, referer="https://m.weibo.cn/")
            session.get("https://m.weibo.cn/", ua=M_UA,
                       referer="https://m.weibo.cn/")
        except Exception:
            pass
        cookie = cookie_header(session.jar)

    body, _, _ = session.get(
        "https://m.weibo.cn/api/config", ua=M_UA,
        referer="https://m.weibo.cn/",
        accept="application/json, text/plain, */*",
        extra={"X-Requested-With": "XMLHttpRequest"})
    config = json.loads(body.decode("utf-8", "replace"))
    if not config.get("data", {}).get("login"):
        raise RuntimeError("/api/config 仍显示未登录，Cookie 无效")
    emit("STATUS", "/api/config login=true，Cookie 校验通过")

    uid = find_uid(session, scan_data, config, cookie, args.uid)
    name = find_name(session, config, scan_data, uid)
    feed = probe_feed_container(session, uid)
    if not uid:
        emit("STATUS", "警告：没提取到 uid，登录态仍可用，但「我的」时间线不可用")
    emit("LOGIN_OK", "uid=%s name=%s feed=%s" % (uid or "-", name, feed or "-"))

    write_login_txt(uid, feed, name, cookie)
    # 同步到当前构建产物，下次 make ipa 也会带上
    app_built = os.path.join(BUILD, "Payload", "LegacyApp.app")
    if os.path.isdir(app_built):
        subprocess.run(["cp", LOGIN_TXT, os.path.join(app_built, "Login.txt")],
                       check=False)
        os.chmod(os.path.join(app_built, "Login.txt"), 0o644)

    if not args.no_device:
        env = ssh_env(args.password)
        push_to_device(args.ip, args.password, env)
    emit("DONE", "login-ready")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        emit("ERROR", str(exc))
        sys.exit(1)
