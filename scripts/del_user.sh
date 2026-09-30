#!/bin/bash
# 停用 VPN 使用者（立即生效，不用重啟服務）
# 用法：sudo bash del_user.sh <帳號>
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "[-] 請用 sudo 執行"; exit 1; }

NAME=${1:-}
[[ "$NAME" =~ ^[a-z0-9._-]+$ ]] || { echo "用法：sudo bash $0 <帳號>"; exit 1; }
F=/etc/openvpn/otp/$NAME
[ -e "$F" ] || { echo "[-] 找不到使用者 $NAME"; exit 1; }

rm -f "$F" "/home/ubuntu/openvpn_client/otp_${NAME}.png"
echo "[+] 已停用 $NAME"
echo "    若該員目前連線中，會在下次重新驗證時中斷；要立即踢除請：sudo systemctl restart openvpn@server"
