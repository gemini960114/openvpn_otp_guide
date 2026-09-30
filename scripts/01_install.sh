#!/bin/bash
# OpenVPN + Google Authenticator (OTP) 全新安裝
# 用法：sudo bash 01_install.sh [--rebuild-pki]
#   --rebuild-pki  重建 CA 與伺服器憑證（會讓所有既有用戶端 .ovpn 失效）
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "[-] 請用 sudo 執行"; exit 1; }

VPN_NET=10.8.0.0
VPN_MASK=255.255.255.0
PKI_DIR=/etc/openvpn/easy-rsa
OTP_DIR=/etc/openvpn/otp

echo "[1/7] 安裝套件"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y openvpn easy-rsa libpam-google-authenticator qrencode oathtool pamtester iptables-persistent

PAM_PLUGIN=$(find /usr/lib -name openvpn-plugin-auth-pam.so | head -1)
[ -n "$PAM_PLUGIN" ] || { echo "[-] 找不到 openvpn-plugin-auth-pam.so"; exit 1; }

echo "[2/7] 建立憑證（PKI）"
if [ -d "$PKI_DIR/pki" ] && [ "${1:-}" != "--rebuild-pki" ]; then
  echo "    已存在 $PKI_DIR/pki，略過（要重建請加 --rebuild-pki）"
else
  rm -rf "$PKI_DIR"
  mkdir -p "$PKI_DIR"
  cp -r /usr/share/easy-rsa/* "$PKI_DIR/"
  cd "$PKI_DIR"
  ./easyrsa init-pki
  EASYRSA_BATCH=1 ./easyrsa build-ca nopass
  EASYRSA_BATCH=1 ./easyrsa gen-dh
  EASYRSA_BATCH=1 ./easyrsa build-server-full server nopass
  openvpn --genkey secret /etc/openvpn/ta.key
  cp pki/ca.crt pki/dh.pem pki/issued/server.crt pki/private/server.key /etc/openvpn/
  chmod 600 /etc/openvpn/server.key /etc/openvpn/ta.key
fi

echo "[3/7] OTP 金鑰目錄（不可放 /home：openvpn@.service 有 ProtectHome=true）"
install -d -o root -g root -m 700 "$OTP_DIR"

echo "[4/7] PAM 設定"
[ -f /etc/pam.d/openvpn ] && cp /etc/pam.d/openvpn "/etc/pam.d/openvpn.bak.$(date +%Y%m%d%H%M%S)"
cat > /etc/pam.d/openvpn <<'EOF'
# 不要加 nullok（會讓沒有金鑰的帳號通過）；不要用 forward_pass
auth required pam_google_authenticator.so secret=/etc/openvpn/otp/${USER} user=root
account required pam_permit.so
session required pam_permit.so
EOF

echo "[5/7] OpenVPN 伺服器設定"
[ -f /etc/openvpn/server.conf ] && cp /etc/openvpn/server.conf "/etc/openvpn/server.conf.bak.$(date +%Y%m%d%H%M%S)"
cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca /etc/openvpn/ca.crt
cert /etc/openvpn/server.crt
key /etc/openvpn/server.key
dh /etc/openvpn/dh.pem
tls-auth /etc/openvpn/ta.key 0

server $VPN_NET $VPN_MASK
ifconfig-pool-persist /etc/openvpn/ipp.txt

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"

keepalive 10 120
cipher AES-256-GCM
auth SHA256
persist-key
persist-tun
status /var/log/openvpn-status.log
verb 3

# 第一因子：用戶端憑證；第二因子：帳號 + OTP（PAM）
plugin $PAM_PLUGIN openvpn
verify-client-cert require
EOF

echo "[6/7] IP 轉送與 NAT"
sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null
OUT_IF=$(ip route | awk '/^default/{print $5; exit}')
iptables -t nat -C POSTROUTING -s $VPN_NET/24 -o "$OUT_IF" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s $VPN_NET/24 -o "$OUT_IF" -j MASQUERADE
iptables-save > /etc/iptables/rules.v4

echo "[7/7] 啟動服務"
systemctl enable openvpn@server
systemctl restart openvpn@server
sleep 2
systemctl is-active openvpn@server

cat <<EOF

安裝完成。接下來：
  1. 雲端安全群組開放 UDP 1194 入站
  2. sudo bash make_client.sh client1 <對外IP>
  3. sudo bash add_user.sh <帳號>
  4. sudo bash test_auth.sh <帳號>
EOF
