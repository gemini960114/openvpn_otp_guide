#!/bin/bash
# 產生用戶端憑證與 .ovpn 連線檔
# 用法：sudo bash make_client.sh <憑證名稱> <對外IP>
#   例：sudo bash make_client.sh client1 203.0.113.10
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "[-] 請用 sudo 執行"; exit 1; }

CN=${1:-}
IP=${2:-}
[[ "$CN" =~ ^[A-Za-z0-9._-]+$ ]] && [ -n "$IP" ] || { echo "用法：sudo bash $0 <憑證名稱> <對外IP>"; exit 1; }

PKI_DIR=/etc/openvpn/easy-rsa
OUT_DIR=/home/ubuntu/openvpn_client
cd "$PKI_DIR"
if [ ! -f "pki/issued/$CN.crt" ]; then
  EASYRSA_BATCH=1 ./easyrsa build-client-full "$CN" nopass
fi

mkdir -p "$OUT_DIR"
OVPN="$OUT_DIR/$CN.ovpn"
cat > "$OVPN" <<EOF
client
dev tun
proto udp
remote $IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
key-direction 1
auth-user-pass

<ca>
$(cat /etc/openvpn/ca.crt)
</ca>
<cert>
$(sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' "pki/issued/$CN.crt")
</cert>
<key>
$(cat "pki/private/$CN.key")
</key>
<tls-auth>
$(cat /etc/openvpn/ta.key)
</tls-auth>
EOF
chown ubuntu:ubuntu "$OVPN"
chmod 600 "$OVPN"
echo "[+] 已產生 $OVPN（內含私鑰，請以安全管道交付）"
