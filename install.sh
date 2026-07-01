#!/usr/bin/env bash
#
# install.sh — one-command, step-by-step installer for wifi-audit.
#
#   curl -fsSL https://raw.githubusercontent.com/mariamtchelidze66/wifi-audit/main/install.sh | bash
#   # or:
#   wget -qO- https://raw.githubusercontent.com/mariamtchelidze66/wifi-audit/main/install.sh | bash
#
# It asks before every step (y/n), auto-detects the OS/package manager, works
# whether piped into bash or run directly, and needs NO GitHub token (the repo
# is expected to be public). No secrets are stored in this repo.
#
set -uo pipefail

# ---------- project settings (change these per repo) ----------
PROJECT="wifi-audit"
REPO_URL="https://github.com/mariamtchelidze66/wifi-audit.git"
RAW_URL="https://raw.githubusercontent.com/mariamtchelidze66/wifi-audit/main/install.sh"
DEST="${WIFI_AUDIT_DIR:-$HOME/wifi-audit}"
# system packages this project needs:
PKGS_APT="git aircrack-ng iw wireless-tools"
PKGS_PACMAN="git aircrack-ng iw wireless_tools"
PKGS_DNF="git aircrack-ng iw wireless-tools"

# ---------- colors / logging ----------
if [[ -t 1 ]]; then
  R="\033[31m"; G="\033[32m"; Y="\033[33m"; C="\033[36m"; B="\033[1m"; N="\033[0m"
else R=""; G=""; Y=""; C=""; B=""; N=""; fi
info(){ echo -e "${C}[*]${N} $*"; }
ok(){   echo -e "${G}[+]${N} $*"; }
warn(){ echo -e "${Y}[!]${N} $*"; }
err(){  echo -e "${R}[x]${N} $*" >&2; }
step(){ echo; echo -e "${B}==== $* ====${N}"; }

# ---------- read from the real terminal even when piped (curl | bash) ----------
# Open the actual controlling terminal on fd 3 so prompts work even when this
# script itself arrives on stdin (curl ... | bash). If there is no terminal
# (CI, plain pipe), we must NOT silently assume "yes" — set ASSUME_YES=1 to
# opt into a fully non-interactive run instead.
HAVE_TTY=0
if { exec 3</dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi
ASSUME_YES="${ASSUME_YES:-0}"
need_tty(){
  [[ $HAVE_TTY -eq 1 || "$ASSUME_YES" == "1" ]] && return 0
  err "No interactive terminal detected."
  err "This installer asks questions, so run it one of these ways:"
  err "   bash <(curl -fsSL $RAW_URL)        # keeps the terminal for prompts"
  err "   curl -fsSL $RAW_URL | ASSUME_YES=1 bash   # non-interactive, accept all"
  exit 1
}
ask(){  # ask "question" [default y|n] -> returns 0 for yes
  local q="$1" def="${2:-y}" ans hint="[Y/n]"
  [[ "$def" == "n" ]] && hint="[y/N]"
  if [[ "$ASSUME_YES" == "1" ]]; then ans="$def"
  else read -rp "$(echo -e "${Y}[?]${N} $q $hint ")" -u 3 ans || ans=""; fi
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy]$ ]]
}
prompt(){  # prompt "question" -> echoes the typed line
  local q="$1" ans
  if [[ "$ASSUME_YES" == "1" ]]; then echo ""; return; fi
  read -rp "$(echo -e "${Y}[?]${N} $q ")" -u 3 ans || ans=""
  echo "$ans"
}

# ---------- detect environment ----------
step "0) Detecting environment"
OS="$(uname -s)"
IS_WSL=0
grep -qiE "microsoft|wsl" /proc/version 2>/dev/null && IS_WSL=1
if   command -v apt    >/dev/null 2>&1; then PM=apt;    PKGS="$PKGS_APT"
elif command -v pacman >/dev/null 2>&1; then PM=pacman; PKGS="$PKGS_PACMAN"
elif command -v dnf    >/dev/null 2>&1; then PM=dnf;    PKGS="$PKGS_DNF"
else PM=""; PKGS="$PKGS_APT"; fi
info "OS: $OS   WSL: $([[ $IS_WSL -eq 1 ]] && echo yes || echo no)   package manager: ${PM:-unknown}"
need_tty   # bail out early if we can't ask questions and ASSUME_YES isn't set
[[ "$OS" != "Linux" ]] && warn "This tool targets Linux; other systems are untested."
if [[ $IS_WSL -eq 1 ]]; then
  warn "You're on WSL. Wi-Fi monitor mode usually does NOT work under WSL —"
  warn "the audit itself needs a real Linux laptop with a monitor-mode Wi-Fi card."
  warn "You can still install here, but running the audit likely needs bare-metal Linux."
fi

# sudo helper (root runs commands directly)
SUDO=""
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else warn "Not root and no sudo; package install may fail."; fi
fi

echo
info "About to install '${PROJECT}':"
info "  1. install system packages:  $PKGS"
info "  2. clone the repo into:       $DEST"
info "  3. optionally run the audit"
ask "Continue?" y || { err "Aborted by user."; exit 1; }

# ---------- 1) system packages ----------
step "1) System packages"
if [[ -z "$PM" ]]; then
  err "No known package manager (apt/pacman/dnf). Install manually: $PKGS"
elif ask "Install/verify packages ($PKGS)?" y; then
  case "$PM" in
    apt)    $SUDO apt-get update -y && $SUDO apt-get install -y $PKGS ;;
    pacman) $SUDO pacman -Sy --noconfirm $PKGS ;;
    dnf)    $SUDO dnf install -y $PKGS ;;
  esac && ok "Packages ready." || err "Package install had errors (continuing)."
else
  warn "Skipped package install."
fi

# ---------- 2) clone / update the repo ----------
step "2) Get the code"
if [[ -d "$DEST/.git" ]]; then
  info "$DEST already exists."
  if ask "Update it (git pull)?" y; then git -C "$DEST" pull --ff-only || warn "pull failed."; fi
else
  if ask "Clone $REPO_URL into $DEST?" y; then
    git clone "$REPO_URL" "$DEST" && ok "Cloned into $DEST" || { err "Clone failed."; exit 1; }
  else
    warn "Skipped clone — nothing to run."; exit 0
  fi
fi
chmod +x "$DEST/wifi-audit.sh" 2>/dev/null || true

# ---------- 3) run / test ----------
step "3) Run the audit"
ok "Installed. To run it later:  sudo $DEST/wifi-audit.sh"
if ask "Run the Wi-Fi audit now (needs root + a monitor-mode Wi-Fi card)?" n; then
  WL="$(prompt 'Optional wordlist path (blank = auto-detect rockyou etc.):')"
  # hand the real terminal to the audit script so its own prompts work
  $SUDO "$DEST/wifi-audit.sh" $WL <&3
else
  info "You can run it anytime with:  sudo $DEST/wifi-audit.sh"
fi

echo
ok "Done."
