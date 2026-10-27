# OpenVPN + Google Authenticator（OTP）安裝與維運手冊

> 適用環境：Ubuntu 24.04 LTS／OpenVPN 2.6／libpam-google-authenticator 20191231
> 驗證方式：OpenVPN Connect（Windows）以帳號＋OTP 實際連線成功
> 文件中的 `<VPN_SERVER_IP>` 請換成你的 VPN 伺服器對外 IP

---

## 一、架構

```
院區電腦 (OpenVPN Connect)
   │  第 1 道：用戶端憑證（內嵌在 .ovpn 檔）
   │  第 2 道：帳號 + 手機 6 位數 OTP
   ▼
TCP 443 ──► 雲端安全群組 ──► VPN 伺服器 (OpenVPN)
                                 │  PAM → pam_google_authenticator
                                 │        讀取 /etc/openvpn/otp/<帳號>
                                 ▼
                          NAT 轉送到平台網路
```

| 項目 | 設定 |
|---|---|
| 通道 | TCP 443，TLS 1.3，資料加密 AES-256-GCM |
| 控制通道保護 | tls-auth（ta.key）＋ HMAC-SHA256 |
| 第一因子 | 用戶端 X.509 憑證（`verify-client-cert require`） |
| 第二因子 | TOTP 6 位數／30 秒（PAM） |
| OTP 金鑰位置 | `/etc/openvpn/otp/<帳號>`，root 擁有，權限 0400（目錄 0700） |
| VPN 網段 | 10.8.0.0/24 |

**VPN 帳號不是 Linux 帳號。** 帳號就是 `/etc/openvpn/otp/` 底下的檔名，不需要 `useradd`。

---

## 二、檔案說明

| 檔案 | 用途 |
|---|---|
| `scripts/01_install.sh` | 全新主機一次安裝（套件、憑證、設定、NAT） |
| `scripts/add_user.sh` | 新增 VPN 使用者並產生 OTP QR Code |
| `scripts/del_user.sh` | 停用／刪除 VPN 使用者 |
| `scripts/make_client.sh` | 產生用戶端憑證與 `.ovpn` 連線檔 |
| `scripts/test_auth.sh` | 在與 OpenVPN **相同的沙箱條件**下測試 OTP 驗證 |
| `scripts/diagnose.sh` | 一鍵檢查服務狀態、設定與最近的驗證日誌 |

所有腳本都要用 `sudo` 執行。

---

## 三、全新安裝步驟

### 步驟 0：雲端平台先開安全群組

在雲端管理介面的安全群組新增入站規則：**TCP 443，來源 0.0.0.0/0**（正式上線建議限縮為院區出口 IP）。
沒開這條，用戶端會一直停在 connecting，伺服器日誌也不會有任何紀錄。

### 步驟 1：安裝

```bash
sudo bash scripts/01_install.sh
```

會完成：安裝套件、建立 CA／伺服器憑證、寫入 `server.conf` 與 `/etc/pam.d/openvpn`、開啟 IP 轉送與 NAT、啟動服務。

### 步驟 2：產生用戶端連線檔

```bash
sudo bash scripts/make_client.sh client1 <VPN_SERVER_IP>
```

第二個參數請填**用戶端實際要連的對外 IP**（雲端的浮動 IP），不要依賴 `curl ifconfig.me`（見注意事項 9）。
產出：`/home/ubuntu/openvpn_client/client1.ovpn`

### 步驟 3：新增使用者

```bash
sudo bash scripts/add_user.sh vpnuser
```

畫面會顯示 QR Code，並存一份 PNG 到 `/home/ubuntu/openvpn_client/otp_vpnuser.png`。使用者以手機 Google Authenticator 掃描。

### 步驟 4：伺服器端自我測試

```bash
sudo bash scripts/test_auth.sh vpnuser
```

看到 `successfully authenticated` 才算成功。**這個測試會用掉當下那組 OTP**，使用者要等下一組（30 秒後）再連線。

### 步驟 5：用戶端連線

1. 電腦安裝 OpenVPN Connect，匯入 `client1.ovpn`
2. Username：`vpnuser`
3. Password：手機上當下的 6 位數 OTP
4. 顯示 **Securely Connected** 即成功

---

## 四、日常維運

```bash
# 新增人員
sudo bash scripts/add_user.sh dr_chen

# 停用人員（立即生效，不用重啟服務）
sudo bash scripts/del_user.sh dr_chen

# 看目前有哪些人
sudo ls /etc/openvpn/otp/

# 看誰連線中
sudo cat /var/log/openvpn-status.log

# 即時看驗證日誌
sudo journalctl -u openvpn@server -f
```

同一份 `client1.ovpn` 可以發給多位同仁，靠「帳號＋各自的 OTP」區分身分。
如果要做到「每人一張憑證、可單獨撤銷憑證」，就為每人執行一次 `make_client.sh <名稱> <IP>`。

---

## 五、注意事項（這次實際踩過的坑）

以下依照「最難查」排序。**第 1 點是這次卡最久的根本原因。**

### 1. systemd 的 `ProtectHome=true` 讓 OpenVPN 看不到 /home

- **症狀**：日誌出現
  `Failed to read "/home/vpnuser/.google_authenticator" for "vpnuser"`，
  但檔案明明存在，權限怎麼改都沒用。
- **原因**：Ubuntu 內建的 `openvpn@.service` 有 `ProtectHome=true`，OpenVPN 程序（包含 PAM）完全看不到 `/home`。
- **解法**：OTP 金鑰改放 `/etc/openvpn/otp/`，PAM 設定加上 `secret=` 與 `user=root`：
  ```
  auth required pam_google_authenticator.so secret=/etc/openvpn/otp/${USER} user=root
  ```
- 查詢方式：`systemctl cat openvpn@server | grep Protect`

### 2. 在終端機用 pamtester 測試成功，不代表 OpenVPN 會成功

- 直接在 shell 跑 `pamtester` 不受 systemd 沙箱限制，所以會「測試成功、實際失敗」，這次因此被誤導好幾輪。
- **一律用 `scripts/test_auth.sh`**，它透過 `systemd-run` 套用和 OpenVPN 相同的 `ProtectHome`／`ProtectSystem` 條件。

### 3. OTP 金鑰檔的擁有者、權限與目錄

- Google Authenticator 每次驗證都會**重寫**金鑰檔（記錄用過的碼以防重放、記錄嘗試次數），做法是在同一目錄寫暫存檔再改名，並把新檔設成 `0400`。
- 所以重點是：
  - 檔案擁有者必須是 PAM 設定中 `user=` 指定的帳號（本設定為 root）
  - 檔案**不能**讓 group／other 讀取（`0400` 或 `0600` 都可以，驗證後會自動變成 `0400`）
  - 所在目錄必須讓該帳號可寫（`/etc/openvpn/otp` 為 `root 0700`）
- 當初在 `/home/vpnuser` 的失敗，真正原因是第 1 點（ProtectHome），不是檔案權限。

### 4. 不要加 `nullok`

- `nullok` 的意思是「沒有 OTP 金鑰的帳號可以跳過驗證」。配合 `account pam_permit.so`，可能讓不存在的帳號也通過。
- 本設定沒有 `nullok`：沒有金鑰檔的帳號一律拒絕。

### 5. 不要用 `forward_pass`

- 最初版本的 PAM 設定用了 `forward_pass` + `pam_permit.so optional`。`forward_pass` 的設計是「密碼＋OTP 串在一起輸入」再轉交給下一個模組，跟我們「密碼欄只輸入 OTP」的用法不符，拿掉即可。

### 6. QR Code 要用 otpauth:// 格式產生

- **錯誤做法**：`qrencode < ~/.google_authenticator`，這是把整個設定檔內容做成 QR，手機掃了不認得。
- **正確做法**：
  ```
  otpauth://totp/<標籤>?secret=<檔案第一行>&issuer=<發行者>
  ```
  `add_user.sh` 已處理好。手機掃不到時，也可以在 App 裡選「輸入設定金鑰」，手動輸入金鑰，類型選「時間型」。

### 7. 同一組 OTP 只能用一次

- 啟用了防重放（`DISALLOW_REUSE`）。剛跑完 `test_auth.sh`，或上一次連線失敗後馬上重試，如果手機還是同一組碼就會失敗，**等下一組碼**再試。
- 另有頻率限制：每 30 秒最多嘗試 3 次，連續打錯要稍等。

### 8. 伺服器時間必須準確

- TOTP 依時間計算，伺服器與手機時間差超過約 30 秒就會一直失敗。
- 檢查：`timedatectl`，要看到 `System clock synchronized: yes`。

### 9. `.ovpn` 裡的 remote IP 要確認

- 雲端主機的「出網 IP」（`curl ifconfig.me` 查到的）不一定等於「入網的浮動 IP」。IP 填錯，用戶端會一直停在 connecting。
- `make_client.sh` 要求手動填 IP，就是為了避免這個問題。

### 10. 改過 .ovpn 後，用戶端要刪掉舊 profile 重新匯入

- OpenVPN Connect 匯入時會複製一份，之後改伺服器上的檔案不會自動同步。

### 11. 用戶端憑證與 `verify-client-cert`

- 最初設定是 `verify-client-cert none`（只靠 OTP），後來改成 `require`，並把用戶端憑證與私鑰內嵌進 `.ovpn`，變成真正的雙因子（持有憑證＋持有手機）。
- `.ovpn` 內含私鑰，要當作機敏檔案保管，不要放公開位置。

### 12. `user nobody` 與權限

- 本範例的 `server.conf` 沒有使用 `user nobody`／`group nogroup`（排錯時拿掉的）。
- OpenVPN 的 auth-pam 外掛會在降權**之前**就 fork 出一個 root 權限的驗證程序，所以理論上把 `user nobody` 加回來仍可正常驗證，也比較安全。**尚未實測**：要加回時，請改完、重啟後，實際用 OpenVPN Connect 連一次確認。

### 13. 自動化執行 sudo

- 背景腳本或 AI 助理執行 `sudo` 時沒有鍵盤可以輸入密碼，會卡住。需要的話可設定免密碼：
  ```bash
  echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$USER
  ```
  這會讓該帳號擁有不需密碼的完整 root 權限，**完成建置後建議移除**：`sudo rm /etc/sudoers.d/$USER`

### 14. 安全群組的 SSH（TCP 22）

- 建置階段常會對 0.0.0.0/0 開放，正式上線請把來源限縮為管理端 IP。

### 15. VPN 到內部主機的路由

- VPN 閘道與要存取的內部主機若不在同一網段，連上 VPN 後仍可能連不到內部主機。
- 須確認兩個網段之間有路由（並檢查安全群組是否允許），或將 VPN 閘道接上內部主機所在的網路。

---

## 六、排錯流程

先跑：

```bash
sudo bash scripts/diagnose.sh
```

再對照日誌關鍵字：

| 日誌訊息 | 意義 | 處理 |
|---|---|---|
| （伺服器完全沒日誌） | 封包沒進來 | 檢查安全群組 TCP 443、`.ovpn` 的 remote IP |
| `TLS Error: tls-auth` / `HMAC authentication failed` | ta.key 不符 | 重新產生並匯入 `.ovpn` |
| `VERIFY ERROR` / `certificate verify failed` | 用戶端憑證不符 | 重新執行 `make_client.sh`，重新匯入 |
| `Failed to read "..." for "xxx"` | PAM 讀不到金鑰檔 | 看注意事項 1、3；確認 `/etc/openvpn/otp/xxx` 存在 |
| `No secret configured for user xxx` | 該帳號沒有金鑰檔 | `add_user.sh xxx` |
| `Invalid verification code` | OTP 錯誤 | 看注意事項 7、8；確認手機綁的是正確帳號 |
| `Accepted google_authenticator for xxx` | OTP 驗證成功 | 若仍失敗，往後看路由／推送設定 |
| `Username/Password authentication succeeded` | 驗證全部通過 | — |

---

## 七、有效設定範例

`/etc/pam.d/openvpn`
```
auth required pam_google_authenticator.so secret=/etc/openvpn/otp/${USER} user=root
account required pam_permit.so
session required pam_permit.so
```

`/etc/openvpn/server.conf`（重點）
```
port 443
proto tcp
dev tun
tls-auth /etc/openvpn/ta.key 0
topology subnet
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
cipher AES-256-GCM
auth SHA256
plugin /usr/lib/x86_64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so openvpn
verify-client-cert require
```

