#!/bin/bash
# 在與 openvpn@server 相同的 systemd 沙箱條件下測試 OTP 驗證
# （直接在 shell 跑 pamtester 不受 ProtectHome 限制，結果不準）
# 用法：sudo bash test_auth.sh <帳號> [OTP]
#   不給 OTP 時，自動用伺服器端金鑰算出當下的碼（會用掉這組碼，手機要等下一組）
set -uo pipefail
[ "$EUID" -eq 0 ] || { echo "[-] 請用 sudo 執行"; exit 1; }

NAME=${1:-}
[ -n "$NAME" ] || { echo "用法：sudo bash $0 <帳號> [OTP]"; exit 1; }
F=/etc/openvpn/otp/$NAME
[ -f "$F" ] || { echo "[-] 找不到 $F"; exit 1; }

CODE=${2:-$(oathtool --totp -b "$(head -1 "$F")")}
echo "測試帳號：$NAME　OTP：$CODE"

PROPS=()
for p in ProtectHome ProtectSystem PrivateTmp CapabilityBoundingSet; do
  v=$(systemctl show openvpn@server -p "$p" --value)
  [ -n "$v" ] && PROPS+=(-p "$p=$v")
done

echo "$CODE" | systemd-run --wait --pipe -q "${PROPS[@]}" pamtester openvpn "$NAME" authenticate
rc=$?
[ $rc -eq 0 ] && echo "[OK] 驗證成功" || echo "[FAIL] 驗證失敗，請看：journalctl -u openvpn@server -n 30 "
exit $rc
