#!/bin/bash
# 一鍵檢查 OpenVPN + OTP 狀態
# 用法：sudo bash diagnose.sh
[ "$EUID" -eq 0 ] || { echo "[-] 請用 sudo 執行"; exit 1; }

sec() { echo; echo "===== $1 ====="; }

sec "服務狀態"
systemctl is-active openvpn@server
ss -tlnp | grep ':443 ' || echo "!! 沒有程序在監聽 TCP 443"

sec "時間同步（TOTP 需要）"
timedatectl | grep -E 'synchronized|NTP'

sec "systemd 沙箱"
systemctl show openvpn@server -p ProtectHome -p ProtectSystem

sec "PAM 設定"
grep -v '^#' /etc/pam.d/openvpn
grep -v '^#' /etc/pam.d/openvpn | grep -q nullok && echo "!! 發現 nullok，建議移除"

sec "server.conf 重點"
grep -E '^(port|proto|topology|plugin|verify-client-cert|user|group|server |push)' /etc/openvpn/server.conf

sec "OTP 使用者"
ls -l /etc/openvpn/otp/ 2>/dev/null || echo "!! /etc/openvpn/otp 不存在"
find /etc/openvpn/otp -type f -perm /077 2>/dev/null | sed 's|^|!! group/other 可讀取，請 chmod 400：|'
find /etc/openvpn/otp -type f ! -user root 2>/dev/null | sed 's|^|!! 擁有者不是 root：|'

sec "IP 轉送與 NAT"
sysctl net.ipv4.ip_forward
iptables -t nat -S POSTROUTING | grep MASQUERADE || echo "!! 沒有 NAT 規則"

sec "目前連線"
cat /var/log/openvpn-status.log 2>/dev/null | sed -n '/Common Name/,/ROUTING/p'

sec "最近驗證紀錄"
journalctl -u openvpn@server --since "-2h" --no-pager \
  | grep -E 'google_authenticator|authentication|AUTH_FAILED|VERIFY|TLS Error' | tail -20
