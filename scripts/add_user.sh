#!/bin/bash
# 新增 VPN 使用者並產生 OTP QR Code
# 用法：sudo bash add_user.sh <帳號> [--force]
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "[-] 請用 sudo 執行"; exit 1; }

NAME=${1:-}
[[ "$NAME" =~ ^[a-z0-9._-]+$ ]] || { echo "用法：sudo bash $0 <帳號>（限小寫英數字 . _ -）"; exit 1; }

OTP_DIR=/etc/openvpn/otp
OUT_DIR=/home/ubuntu/openvpn_client
F="$OTP_DIR/$NAME"
ISSUER=${ISSUER:-OpenVPN-Platform}

if [ -e "$F" ] && [ "${2:-}" != "--force" ]; then
  echo "[-] $NAME 已存在。要重新產生（手機需重新綁定）請加 --force"
  exit 1
fi

install -d -o root -g root -m 700 "$OTP_DIR"
# -t 時間型  -d 禁止重用  -r 3 -R 30 每 30 秒最多 3 次  -w 3 容許 ±1 週期  -C 不互動確認
google-authenticator -t -d -f -r 3 -R 30 -w 3 -q -C -s "$F"
chown root:root "$F"
chmod 400 "$F"   # 不可讓 group/other 讀取；驗證後模組會自行重寫為 0400

SECRET=$(head -1 "$F")
URI="otpauth://totp/${ISSUER}:${NAME}?secret=${SECRET}&issuer=${ISSUER}"

mkdir -p "$OUT_DIR"
PNG="$OUT_DIR/otp_${NAME}.png"
qrencode -s 10 -m 4 -o "$PNG" "$URI"
chown ubuntu:ubuntu "$PNG"
chmod 600 "$PNG"

echo "=============================================="
echo " VPN 使用者：$NAME"
echo "=============================================="
qrencode -t ANSIUTF8 -m 2 "$URI"
echo "手動輸入金鑰：$SECRET（類型：時間型）"
echo "QR Code 圖檔：$PNG"
echo
echo "注意：QR Code／金鑰只交給本人，交付後建議刪除 PNG：rm $PNG"
