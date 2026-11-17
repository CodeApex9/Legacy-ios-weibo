#!/bin/bash
# 把构建好的 app 装进越狱 iOS 5 / 6 / 7 设备。
#
# 设备前提：已装 OpenSSH 与 AppSync Unified（ad-hoc 签名必需）
#
# 用法：
#   THEOS_DEVICE_IP=192.168.8.171 THEOS_DEVICE_PASSWORD=alpine ./scripts/install.sh
#   THEOS_DEVICE_IP=192.168.8.171 ./scripts/install.sh respring   # 装完重启 SpringBoard
#   THEOS_DEVICE_IP=192.168.8.171 ./scripts/install.sh launch     # 装完用 sblaunch 启动并查进程
#   ./scripts/install.sh usb                                     # USB 装 ipa（需 ideviceinstaller）
#
#   DIAG=1 THEOS_DEVICE_IP=... THEOS_DEVICE_PASSWORD=alpine ./scripts/install.sh
#          # 带启动自检：设备上 /tmp/legacy_boot.txt 记录 main 与 setupWindow 是否执行；
#          # /tmp/legacy_net.txt 记录 NSURLConnection 联网 + NSJSONSerialization 解析自检
#          # （含局域网 HTTP 对照，需 Mac 在 8765 端口起临时服务，IP 见 src/NetProbe.m）
#
# 可选环境变量：THEOS_DEVICE_PORT（默认 22）、THEOS_DEVICE_USER（默认 root）、
#              THEOS_DEVICE_PASSWORD（不设则走交互式输密码）、
#              DIAG（1 = 编译启动自检标记）
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=LegacyApp.app
REMOTE_DIR=/Applications/$APP_NAME
MODE="${1:-ssh}"

# macOS 27 自带 OpenSSH 10.x，默认禁用 iOS 5/6/7 越狱机上老 OpenSSH 使用的
# ssh-rsa 主机密钥、group1/group14 KEX 与 CBC cipher。不显式放宽会直接报
# "Unable to negotiate ... no matching host key type found"。
COMMON_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o HostKeyAlgorithms=+ssh-rsa
  -o PubkeyAcceptedAlgorithms=+ssh-rsa
  -o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1
  -o Ciphers=+aes128-cbc,3des-cbc
  -o RequiredRSASize=1024
  -o ConnectTimeout=10
)

# 设置了密码就走 SSH_ASKPASS 自动应答，让脚本里的多次 ssh/scp 无需人工干预。
# 密码经环境变量传给 askpass 脚本，避免引号/特殊字符被 shell 二次解释。
if [ -n "${THEOS_DEVICE_PASSWORD:-}" ]; then
    ASKPASS="$(mktemp -t legacy-askpass.XXXXXX)"
    cat > "$ASKPASS" <<'ASKPASS_EOF'
#!/bin/sh
printf '%s\n' "$LEGACY_SSH_PASSWORD"
ASKPASS_EOF
    chmod 700 "$ASKPASS"
    trap 'rm -f "$ASKPASS"' EXIT
    export LEGACY_SSH_PASSWORD="$THEOS_DEVICE_PASSWORD"
    export SSH_ASKPASS="$ASKPASS"
    export SSH_ASKPASS_REQUIRE=force
    export DISPLAY="${DISPLAY:-:0}"
fi

PORT="${THEOS_DEVICE_PORT:-22}"
USER="${THEOS_DEVICE_USER:-root}"
TARGET="$USER@${THEOS_DEVICE_IP:-}"

# ssh 用 -p，scp 用 -P，两者不能共用同一组参数。
ssh_run() { ssh "${COMMON_OPTS[@]}" -p "$PORT" "$TARGET" "$@"; }
scp_run() { scp "${COMMON_OPTS[@]}" -P "$PORT" -O -r "$@"; }

if [ "$MODE" = "usb" ]; then
    if ! command -v ideviceinstaller >/dev/null 2>&1; then
        echo "未找到 ideviceinstaller（本机 Homebrew 沙盒受限，未能自动安装）。" >&2
        echo "  手动安装：brew install ideviceinstaller" >&2
        echo "  但对 iOS 5/6/7 越狱机，推荐改用更可靠的 SSH 路径：" >&2
        echo "  THEOS_DEVICE_IP=<设备IP> ./scripts/install.sh" >&2
        exit 1
    fi
    make DIAG="${DIAG:-0}" UIPROBE="${UIPROBE:-0}" UIEXTRA="${UIEXTRA:-0}" UIFEED="${UIFEED:-}" UIGEST="${UIGEST:-0}" DETAILCHECK="${DETAILCHECK:-0}" DETAIL_NO_TAP="${DETAIL_NO_TAP:-0}" ACCOUNTCHECK="${ACCOUNTCHECK:-0}" ACCOUNT_CLOSE_CHECK="${ACCOUNT_CLOSE_CHECK:-0}" LOGOUTCHECK="${LOGOUTCHECK:-0}" FRIENDSCHECK="${FRIENDSCHECK:-0}" SHOTCHECK="${SHOTCHECK:-0}" COMMENTCHECK="${COMMENTCHECK:-0}" GALLERY="${GALLERY:-0}" ipa >/dev/null
    ideviceinstaller -i build/LegacyApp.ipa
    exit 0
fi

if [ -z "${THEOS_DEVICE_IP:-}" ]; then
    echo "请设置设备 IP：THEOS_DEVICE_IP=192.168.1.20 ./scripts/install.sh" >&2
    echo "（设备与 Mac 需在同一 Wi-Fi；IP 在 设置 > Wi-Fi > 蓝色箭头 里查看）" >&2
    exit 1
fi

echo "==> 构建 (DIAG=${DIAG:-0}, UIPROBE=${UIPROBE:-0}, UIEXTRA=${UIEXTRA:-0})"
make DIAG="${DIAG:-0}" UIPROBE="${UIPROBE:-0}" UIEXTRA="${UIEXTRA:-0}" UIFEED="${UIFEED:-}" UIGEST="${UIGEST:-0}" DETAILCHECK="${DETAILCHECK:-0}" DETAIL_NO_TAP="${DETAIL_NO_TAP:-0}" ACCOUNTCHECK="${ACCOUNTCHECK:-0}" ACCOUNT_CLOSE_CHECK="${ACCOUNT_CLOSE_CHECK:-0}" LOGOUTCHECK="${LOGOUTCHECK:-0}" FRIENDSCHECK="${FRIENDSCHECK:-0}" SHOTCHECK="${SHOTCHECK:-0}" COMMENTCHECK="${COMMENTCHECK:-0}" GALLERY="${GALLERY:-0}" ipa >/dev/null

echo "==> 连通性检查 $TARGET:$PORT"
if ! ssh_run 'echo ok' >/dev/null 2>&1; then
    echo "连不上设备。请确认：已装 OpenSSH、IP 正确、同一 Wi-Fi、root 密码（默认 alpine）。" >&2
    exit 1
fi

echo "==> 删除旧版本"
ssh_run "rm -rf $REMOTE_DIR"

echo "==> 传送 $APP_NAME"
# -O 走旧 scp 协议：老设备常缺 sftp-server，新版 scp 默认用 SFTP 会失败。
scp_run "build/Payload/$APP_NAME" "$TARGET:$REMOTE_DIR" >/dev/null

echo "==> 修正属主与权限"
ssh_run "chown -R root:wheel $REMOTE_DIR; chmod -R 755 $REMOTE_DIR; chmod 755 $REMOTE_DIR/LegacyApp"

echo "==> 刷新图标缓存"
ssh_run '
  if [ -x /usr/bin/uicache ]; then
      su mobile -c /usr/bin/uicache 2>/dev/null || /usr/bin/uicache 2>/dev/null || true
  elif command -v uicache >/dev/null 2>&1; then
      su mobile -c uicache 2>/dev/null || uicache 2>/dev/null || true
  fi
' || true

if [ "$MODE" = "respring" ]; then
    echo "==> 重启 SpringBoard"
    ssh_run 'killall SpringBoard' || true
fi

if [ "$MODE" = "launch" ]; then
    echo "==> 通过 SpringBoard 启动并验证进程"
    # 越狱机上的 sblaunch 才是可靠的启动方式；uiopen 只接受 URL，不吃 bundle id。
    ssh_run 'killall -9 LegacyApp 2>/dev/null; sleep 1; if command -v sblaunch >/dev/null 2>&1; then sblaunch com.legacy.legacyapp; sleep 2; ps aux | grep -i legacyapp | grep -v grep; else echo "设备上无 sblaunch，请在主屏幕手动点图标"; fi' || true
fi

echo "完成：主屏幕应出现「Legacy微博」。若图标没刷新，执行："
echo "  THEOS_DEVICE_IP=$THEOS_DEVICE_IP ./scripts/install.sh respring"
