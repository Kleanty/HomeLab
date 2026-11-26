#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# Shared language helper: the language is asked here, before any other output.
if [[ ! -r "$SCRIPT_DIR/lang.sh" ]]; then echo "lang.sh not found next to KUR.sh / lang.sh, KUR.sh dosyasının yanında bulunamadı."; exit 1; fi
# shellcheck source=lang.sh
source "$SCRIPT_DIR/lang.sh"
# Language question (asked only on an interactive terminal when HL_LANG is not set). Enter = English.
if [[ -z "${HL_LANG:-}" && -t 0 ]]; then
  echo "Language / Dil:  1) English   2) Türkçe"
  read -r -p "Choose / Seç [1]: " HL_LANG_ANS
  case "${HL_LANG_ANS:-1}" in 2|tr|TR|t|T) HL_LANG=tr ;; *) HL_LANG=en ;; esac
fi
hl_lang_init
if [[ $EUID -eq 0 ]]; then echo "$(T 'Bu dosyayı sudo ile değil, normal kullanıcıyla çalıştır: ./KUR.sh' 'Do not run this file with sudo; run it as a normal user: ./KUR.sh')"; exit 1; fi
USER_NAME="$(id -un)"
USER_GROUP="$(id -gn)"
LOG_DIR="$HOME/HomeLab_Logs"
mkdir -p "$LOG_DIR"
chmod 0700 "$LOG_DIR"
LOG_FILE="$LOG_DIR/kurulum-$(date +%Y%m%d-%H%M%S).log"
exec 3>&1
exec > >(tee -a "$LOG_FILE") 2>&1
on_error() {
  local rc="$?" line="$1" cmd="$2"
  trap - ERR
  echo
  echo "$(T "HATA: Kurulum $line. satırda durdu (çıkış kodu: $rc)." "ERROR: Installation stopped at line $line (exit code: $rc).")" >&2
  echo "$(T "Çalıştırılan komut: $cmd" "Command that was running: $cmd")" >&2
  echo "$(T "Ayrıntılı günlük: $LOG_FILE" "Detailed log: $LOG_FILE")" >&2
  echo "$(T 'Bu dosyayı paylaşırken parola/token içermediğini kontrol et.' 'Before sharing this file, check that it contains no passwords or tokens.')" >&2
  exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
on_signal() {
  local signal="$1" rc="$2"
  trap - INT TERM ERR
  echo >&2
  echo "$(T "Kurulum kullanıcı tarafından durduruldu ($signal, çıkış kodu: $rc)." "Installation was stopped by the user ($signal, exit code: $rc).")" >&2
  echo "$(T "Yarım kurulum otomatik geri alınmadı; günlük: $LOG_FILE" "The partial installation was not rolled back automatically; log: $LOG_FILE")" >&2
  exit "$rc"
}
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

source /etc/os-release
[[ "${ID:-}" == linuxmint && "${UBUNTU_CODENAME:-}" == noble ]] || {
  echo "$(T 'Bu paket Linux Mint 22.x (Ubuntu noble tabanı) içindir.' 'This package is for Linux Mint 22.x (Ubuntu noble base).')"; exit 1;
}
[[ "$(dpkg --print-architecture)" == amd64 ]] || { echo "$(T 'Yalnızca amd64/x86_64 destekleniyor.' 'Only amd64/x86_64 is supported.')"; exit 1; }
BASE=/srv/homelab
STACKS="$BASE/compose"

# Does not print long command output to the screen; writes it to the log only. On failure, shows the last lines.
quiet_run() {
  local rc=0 out
  out="$(mktemp)"
  "$@" >"$out" 2>&1 || rc=$?
  cat "$out" >> "$LOG_FILE"
  if (( rc != 0 )); then
    echo "$(T "  ! Komut başarısız (kod $rc): $*" "  ! Command failed (code $rc): $*")" >&2
    tail -n 15 "$out" >&2
  fi
  rm -f "$out"
  return "$rc"
}
APT_Q=(sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -qq)

# Asks for the password twice; if it is too short or does not match, explains why and asks again.
ask_new_password() {
  local label="$1" min="$2" var="$3" p1 p2
  while true; do
    read -r -s -p "$label ($(T "en az $min karakter" "at least $min characters")): " p1; echo
    if (( ${#p1} < min )); then echo "$(T "  ! En az $min karakter olmalı, tekrar dene." "  ! It must be at least $min characters; try again.")"; continue; fi
    read -r -s -p "$label ($(T 'tekrar' 'repeat')): " p2; echo
    if [[ "$p1" != "$p2" ]]; then echo "$(T '  ! İki parola aynı değil, baştan gir.' '  ! The two passwords do not match; start over.')"; continue; fi
    printf -v "$var" '%s' "$p1"
    return 0
  done
}
ask_username() {
  local u
  while true; do
    read -r -p "$(T "Kullanıcı adı (panel, RustDesk, ntfy, Syncthing için) [$USER_NAME]: " "Username (for the panel, RustDesk, ntfy, Syncthing) [$USER_NAME]: ")" u
    u="${u:-$USER_NAME}"
    if [[ "$u" =~ ^[A-Za-z0-9._@-]{1,64}$ ]]; then ACCOUNT_USER="$u"; return 0; fi
    echo "$(T '  ! Kullanıcı adı yalnızca harf, rakam, . _ @ - içerebilir (örnek: admin). Parola bir sonraki adımda sorulur, buraya yazma.' '  ! The username may only contain letters, digits and . _ @ - (example: admin). The password is asked in the next step; do not type it here.')"
  done
}

ADGUARD_INSTALL=no
ADGUARD_IP=""
TS_INSTALL_OK=no
INSTALL_WARNINGS=()
OLLAMA_MODEL=qwen2.5:1.5b-instruct-q4_K_M

echo "======================================================"
echo " $(T 'HOMELAB - TEK PAKET KURULUM' 'HOMELAB - ONE-CLICK INSTALLATION')"
echo "======================================================"
echo "$(T "Linux kullanıcısı : $USER_NAME" "Linux user        : $USER_NAME")"
echo "$(T "Kurulum dizini    : $BASE" "Install directory : $BASE")"
echo
echo "$(T 'Bu kurulum Docker, SSH, Samba, Syncthing ve telefon panelini hazırlar.' 'This installer sets up Docker, SSH, Samba, Syncthing and the phone panel.')"
echo "$(T 'Tailscale ve RustDesk de otomatik kurulur.' 'Tailscale and RustDesk are installed automatically as well.')"
echo "$(T "Kurulum günlüğü: $LOG_FILE" "Installation log: $LOG_FILE")"
echo "$(T 'Mevcut /srv/homelab Compose dosyaları varsa üzerine yazılmayacaktır.' 'Existing /srv/homelab Compose files will not be overwritten.')"
echo "$(T 'Cloudflare, DNS, router, UFW ve Tailscale yapılandırması izinsiz değiştirilmez.' 'Cloudflare, DNS, router, UFW and Tailscale settings are not changed without your permission.')"
echo
# Fail early if the ZIP was extracted incompletely or expected tools are missing.
REQUIRED_FILES=(
  "$SCRIPT_DIR/homelab-docker-lan-only"
  "$SCRIPT_DIR/setup-restic-backup.sh"
  "$SCRIPT_DIR/configure-beszel-agent.sh"
  "$SCRIPT_DIR/reset-web-login.sh"
  "$SCRIPT_DIR/harden-ssh.sh"
  "$SCRIPT_DIR/setup-haos-vm.sh"
  "$SCRIPT_DIR/homelab-haos"
  "$SCRIPT_DIR/homelab-notify"
  "$SCRIPT_DIR/homelab-health-check"
  "$SCRIPT_DIR/TANI.sh"
)
for REQUIRED in "${REQUIRED_FILES[@]}"; do
  [[ -s "$REQUIRED" ]] || { echo "$(T "PAKET HATASI: Gerekli dosya eksik/boş: $REQUIRED" "PACKAGE ERROR: Required file is missing or empty: $REQUIRED")"; exit 1; }
done
for TOOL in sudo curl apt-get python3 ss lsblk; do
  command -v "$TOOL" >/dev/null 2>&1 || { echo "$(T "SİSTEM HATASI: Gerekli komut bulunamadı: $TOOL" "SYSTEM ERROR: Required command not found: $TOOL")"; exit 1; }
done
ROOT_FREE_KB="$(df -Pk / | awk 'NR==2 {print $4}')"
if [[ -n "$ROOT_FREE_KB" && "$ROOT_FREE_KB" -lt 10485760 ]]; then
  echo "$(T "UYARI: Kök diskte 10 GiB'tan az boş alan var. Ollama modelleri için ek alan gerekebilir." "WARNING: Less than 10 GiB free on the root disk. Ollama models may need more space.")"
fi
echo "$(T 'Ön kontrol tamamlandı.' 'Pre-check complete.')"
echo
sudo -v
hl_lang_save
# Keep sudo from asking for the password again during the long installation.
( while true; do sudo -n true; sleep 50; done ) >/dev/null 2>&1 &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; sudo -n rm -f /etc/apt/apt.conf.d/99homelab-lock-wait 2>/dev/null || true' EXIT

# The background automatic update (unattended-upgr) may hold the package lock; wait instead of failing.
echo 'DPkg::Lock::Timeout "900";' | sudo tee /etc/apt/apt.conf.d/99homelab-lock-wait >/dev/null
wait_apt_idle() {
  local i
  for i in $(seq 1 180); do
    sudo fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1 || return 0
    ((i == 1)) && echo "$(T '  Başka bir paket işlemi (otomatik güncelleme) bitiyor, bekleniyor...' '  Another package operation (automatic update) is finishing, waiting...')"
    sleep 5
  done
  echo "$(T '  UYARI: Paket kilidi 15 dakikada açılmadı; devam ediliyor.' '  WARNING: The package lock was not released within 15 minutes; continuing.')"
}

# Ports used by another program (our own Docker containers do not count, so a reinstall does not warn).
for PORT in 5001 8090 3001 8080 5678 8081 8088 2586; do
  if sudo ss -Hlnpt "sport = :$PORT" 2>/dev/null | grep -v 'docker-proxy' | grep -q .; then
    echo "$(T "UYARI: TCP $PORT portu başka bir program tarafından kullanılıyor; ilgili konteyner başlatılırken çakışma olabilir." "WARNING: TCP port $PORT is in use by another program; there may be a conflict when the related container starts.")"
  fi
done

echo "$(T 'Kurulum için bir kullanıcı adı ve bir parola gerekiyor. Bu parola panel, Samba, RustDesk, ntfy ve Syncthing için aynı olacak.' 'The installation needs a username and a password. The same password will be used for the panel, Samba, RustDesk, ntfy and Syncthing.')"
echo "$(T "(Samba, kullanıcı adı olarak Linux hesabını '$USER_NAME' kullanır; bunu değiştirmiyoruz.)" "(Samba uses the Linux account '$USER_NAME' as its username; we do not change that.)")"
ACCOUNT_USER=""; ACCOUNT_PW=""
ask_username
ask_new_password "$(T 'Parola' 'Password')" 14 ACCOUNT_PW
HAOS_INSTALL=yes
if [[ "${HL_HAOS:-}" == no ]]; then HAOS_INSTALL=no
elif [[ -t 0 && -z "${HL_HAOS:-}" ]]; then
  echo
  echo "$(T 'İsteğe bağlı: Home Assistant OS sanal makinesi (KVM) kurulsun mu? Akıllı ev için; en az 6 GB RAM ve işlemcide sanallaştırma gerekir. Uygun değilse kurulum bunu atlar ve nedenini panelde gösterir.' 'Optional: set up a Home Assistant OS virtual machine (KVM)? For the smart home; needs at least 6 GB RAM and CPU virtualization. If the computer cannot do it, the installer skips it and shows the reason in the panel.')"
  read -r -p "$(T 'Home Assistant VM kurulsun mu? [E/h]: ' 'Set up the Home Assistant VM? [Y/n]: ')" HA_ANS
  case "${HA_ANS:-y}" in n|N|h|H|no|No|NO|hayır|Hayır) HAOS_INSTALL=no ;; esac
fi
echo "$(T 'Bilgiler alındı. Kurulum 5 saniye içinde başlıyor (iptal: Ctrl+C)...' 'Details received. Installation starts in 5 seconds (cancel: Ctrl+C)...')"
sleep 5
sudo install -d -m 0700 -o root -g root /var/lib/homelab-installer/markers

echo "$(T 'Sistem anlık görüntüsü (Timeshift)' 'System snapshot (Timeshift)')"
if command -v timeshift >/dev/null 2>&1; then
  if quiet_run sudo timeshift --create --scripted --comments "$(T 'HomeLab kurulumu oncesi' 'Before HomeLab installation')" --tags O; then
    echo "$(T 'Timeshift anlık görüntüsü alındı.' 'Timeshift snapshot created.')"
  else
    echo "$(T 'UYARI: Timeshift anlık görüntüsü alınamadı (ayarlanmamış olabilir); kurulum devam ediyor.' 'WARNING: Could not create a Timeshift snapshot (it may not be set up); the installation continues.')"
    INSTALL_WARNINGS+=("$(T "Timeshift anlık görüntüsü alınamadı; Timeshift'i açıp yedek diskini seç" "Could not create a Timeshift snapshot; open Timeshift and choose a backup disk")")
  fi
else
  echo "$(T 'Timeshift kurulu değil; anlık görüntü atlandı.' 'Timeshift is not installed; snapshot skipped.')"
fi
PACKAGE_CANDIDATES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin restic smartmontools nvme-cli sqlite3 lm-sensors fail2ban samba syncthing openssh-server ufw rustdesk tailscale pciutils avahi-daemon libnss-mdns unattended-upgrades)
PREEXISTING_TMP="$(mktemp)"
for PKG in "${PACKAGE_CANDIDATES[@]}"; do
  if dpkg-query -W -f='${db:Status-Status}' "$PKG" 2>/dev/null | grep -qx installed; then
    echo "$PKG" >> "$PREEXISTING_TMP"
  fi
done
sudo install -o root -g root -m 0600 "$PREEXISTING_TMP" /var/lib/homelab-installer/markers/preexisting-packages
rm -f "$PREEXISTING_TMP"

echo "$(T '[1/12] Sistem paketleri' '[1/12] System packages')"
wait_apt_idle
echo "$(T '  paket listesi güncelleniyor ve paketler kuruluyor (birkaç dakika sürebilir)...' '  updating the package list and installing packages (may take a few minutes)...')"
quiet_run "${APT_Q[@]}" update
quiet_run "${APT_Q[@]}" install ca-certificates curl wget gnupg lsb-release \
  python3 python3-venv python3-pip unzip samba syncthing openssh-server ufw \
  restic smartmontools nvme-cli sqlite3 lm-sensors fail2ban \
  pciutils avahi-daemon libnss-mdns

echo "$(T '[1/12] Donanım algılandı' '[1/12] Hardware detected')"
echo "$(T 'İşlemci:' 'Processor:')"
lscpu | grep -E '^(Model name|CPU\(s\)):' | head -n 2 || true
echo "$(T 'Bellek:' 'Memory:')"
free -h | awk -v l="$(T 'RAM toplam: ' 'Total RAM: ')" 'NR == 2 {print l $2}'
echo "$(T 'Ekran kartları:' 'Graphics cards:')"
if command -v lspci >/dev/null 2>&1; then
  lspci -nn | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true
fi

echo "$(T 'Not: Ekran kartı sürücüsü kurulmaz; Ollama CPU ile çalışır.' 'Note: No graphics driver is installed; Ollama runs on the CPU.')"

echo "$(T '[2/12] Docker Engine ve Compose' '[2/12] Docker Engine and Compose')"
sudo install -m 0755 -d /etc/apt/keyrings
if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
  sudo touch /var/lib/homelab-installer/markers/docker-key-created
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
fi
sudo chmod a+r /etc/apt/keyrings/docker.asc
if [[ ! -f /etc/apt/sources.list.d/docker.sources ]]; then
  sudo touch /var/lib/homelab-installer/markers/docker-source-created
  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
fi
echo "$(T '  Docker kuruluyor...' '  Installing Docker...')"
quiet_run "${APT_Q[@]}" update
quiet_run "${APT_Q[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
quiet_run sudo systemctl enable --now docker
if ! sudo test -e /var/lib/homelab-installer/markers/docker-group-added \
  && ! sudo test -e /var/lib/homelab-installer/markers/docker-group-preexisting; then
  if id -nG "$USER_NAME" | tr ' ' '\n' | grep -Fxq docker; then
    sudo touch /var/lib/homelab-installer/markers/docker-group-preexisting
  else
    sudo touch /var/lib/homelab-installer/markers/docker-group-added
  fi
fi
sudo usermod -aG docker "$USER_NAME"
# Default log rotation; preserve a pre-existing Docker daemon configuration.
if [[ ! -e /etc/docker/daemon.json ]]; then
  sudo touch /var/lib/homelab-installer/markers/docker-daemon-json-created
  sudo install -d -m 0755 /etc/docker
  sudo tee /etc/docker/daemon.json >/dev/null <<'EOF_DOCKER'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF_DOCKER
  quiet_run sudo systemctl restart docker
else
  echo "$(T 'Mevcut /etc/docker/daemon.json korundu; log rotasyonu elle gözden geçirilmeli.' 'Existing /etc/docker/daemon.json was kept; review log rotation manually.')"
fi

echo "[3/12] Tailscale"
wait_apt_idle
if [[ ! -e /etc/apt/sources.list.d/tailscale.list ]]; then sudo touch /var/lib/homelab-installer/markers/tailscale-source-created; fi
if quiet_run bash -c 'set -o pipefail; curl -fsSL https://tailscale.com/install.sh | sh'; then
  quiet_run sudo systemctl enable --now tailscaled
  TS_INSTALL_OK=yes
  echo "$(T 'Tailscale kuruldu. Oturum açma bağlantısı kurulumun sonunda gösterilecek.' 'Tailscale installed. The login link will be shown at the end of the installation.')"
else
  echo "$(T 'Tailscale kurulumu başarısız oldu; ana kurulum devam ediyor.' 'Tailscale installation failed; the main installation continues.')"
  INSTALL_WARNINGS+=("$(T 'Tailscale kurulamadı' 'Tailscale could not be installed')")
fi

echo "$(T '[4/12] RustDesk uzaktan masaüstü' '[4/12] RustDesk remote desktop')"
RUSTDESK_OK=no
RUSTDESK_ID=""
if dpkg-query -W -f='${db:Status-Status}' rustdesk 2>/dev/null | grep -qx installed; then
  echo "$(T 'RustDesk zaten kurulu; indirme atlandı.' 'RustDesk is already installed; download skipped.')"
  RUSTDESK_OK=yes
else
  RD_DIR="$(mktemp -d)"
  chmod 0755 "$RD_DIR"
  echo "$(T "  RustDesk son sürümü GitHub'dan indiriliyor..." "  Downloading the latest RustDesk release from GitHub...")"
  RD_URL=""; RD_SHA=""
  if RD_INFO="$(curl -fsSL --max-time 30 https://api.github.com/repos/rustdesk/rustdesk/releases/latest 2>/dev/null | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
for a in d.get("assets", []):
    if re.fullmatch(r"rustdesk-[0-9][0-9A-Za-z.\-]*-x86_64\.deb", a.get("name", "")):
        print(a["browser_download_url"], (a.get("digest") or "").replace("sha256:", ""))
        break
' 2>/dev/null)" && [[ -n "$RD_INFO" ]]; then
    read -r RD_URL RD_SHA <<<"$RD_INFO"
  fi
  if [[ -n "$RD_URL" ]] && curl -fsSL --max-time 600 -o "$RD_DIR/rustdesk.deb" "$RD_URL" \
    && { [[ -z "$RD_SHA" ]] || echo "$RD_SHA  $RD_DIR/rustdesk.deb" | sha256sum -c --quiet -; } \
    && chmod 0644 "$RD_DIR/rustdesk.deb" \
    && quiet_run "${APT_Q[@]}" install "$RD_DIR/rustdesk.deb"; then
    RUSTDESK_OK=yes
  else
    echo "$(T 'RustDesk kurulumu başarısız oldu (indirme, doğrulama veya paket hatası); ana kurulum devam ediyor.' 'RustDesk installation failed (download, verification or package error); the main installation continues.')"
    INSTALL_WARNINGS+=("$(T 'RustDesk kurulamadı; https://rustdesk.com adresinden elle kurabilirsin' 'RustDesk could not be installed; you can install it manually from https://rustdesk.com')")
  fi
  rm -rf "$RD_DIR"
fi
if [[ "$RUSTDESK_OK" == yes ]]; then
  quiet_run sudo systemctl enable --now rustdesk || INSTALL_WARNINGS+=("$(T "RustDesk servisi etkinleştirilemedi: RustDesk > Ayarlar > Güvenlik'ten 'Servisi etkinleştir' seç" "Could not enable the RustDesk service: in RustDesk > Settings > Security choose 'Enable service'")")
  if sudo timeout 30 rustdesk --password "$ACCOUNT_PW" >/dev/null 2>&1; then
    quiet_run sudo systemctl restart rustdesk || true
    echo "$(T 'RustDesk kuruldu ve parolan ayarlandı.' 'RustDesk installed and your password was set.')"
  else
    echo "$(T 'UYARI: RustDesk parolası komutla ayarlanamadı.' 'WARNING: Could not set the RustDesk password from the command line.')"
    INSTALL_WARNINGS+=("$(T "RustDesk parolası ayarlanamadı; RustDesk > Ayarlar > Güvenlik > Kalıcı parola'dan kendin belirle" "Could not set the RustDesk password; set it yourself in RustDesk > Settings > Security > Permanent password")")
  fi
  RUSTDESK_ID="$(sudo timeout 20 rustdesk --get-id 2>/dev/null | tail -n 1 || true)"
  [[ "$RUSTDESK_ID" =~ ^[0-9]+$ ]] || RUSTDESK_ID=""
fi

echo "$(T 'HomeLab telefon paneli ajanı' 'HomeLab phone panel agent')"
# adb for USB connection (USB path of the phone panel); if it cannot be installed, the Wi-Fi path still works.
if ! command -v adb >/dev/null 2>&1; then
  quiet_run "${APT_Q[@]}" install android-tools-adb \
    || INSTALL_WARNINGS+=("$(T 'adb kurulamadı (USB ile telefon bağlama çalışmaz; Wi-Fi çalışır): sudo apt install android-tools-adb' 'adb could not be installed (connecting the phone over USB will not work; Wi-Fi works): sudo apt install android-tools-adb')")
fi
sudo usermod -aG plugdev "$USER_NAME" 2>/dev/null || true
HOMELAB_OK=no
HOMELAB_NEW=no
PB_VERSION=0.9.27
PB_REPO=Kleanty/HomeLab
PB_ARCH=""
case "$(uname -m)" in x86_64|amd64) PB_ARCH=x64;; aarch64|arm64) PB_ARCH=arm64;; esac
PB_UNIT="$HOME/.config/systemd/user/homelab-agent.service"
PB_URL=http://127.0.0.1:8765
if [[ -z "$PB_ARCH" ]]; then
  echo "$(T "HomeLab ajanı bu işlemci için kurulamaz ($(uname -m)); atlandı." "The HomeLab agent cannot be installed for this CPU ($(uname -m)); skipped.")"
elif ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "$(T 'UYARI: Kullanıcı systemd oturumu yok; HomeLab ajanı kurulmadı.' 'WARNING: There is no user systemd session; the HomeLab agent was not installed.')"
  INSTALL_WARNINGS+=("$(T 'HomeLab ajanı kurulamadı: kullanıcı systemd oturumu yok' 'Could not install the HomeLab agent: there is no user systemd session')")
elif [[ -e /var/lib/homelab-installer/markers/homelab-installed && ( -e "$PB_UNIT" || -x "$HOME/.local/share/HomeLab/app/HomeLabAgent" ) ]]; then
  echo "$(T 'HomeLab ajanı zaten kurulu; dokunulmadı.' 'The HomeLab agent is already installed; left untouched.')"
  curl -fsS --max-time 2 "$PB_URL/api/info" >/dev/null 2>&1 && HOMELAB_OK=yes
else
  PB_TMP="$(mktemp -d)"
  PB_BASE="https://github.com/$PB_REPO/releases/download/v$PB_VERSION"
  PB_ZIP="HomeLabAgent-$PB_VERSION-linux-$PB_ARCH.zip"
  PB_SUM=""
  PB_APP=""
  echo "$(T "  HomeLab ajanı $PB_VERSION indiriliyor (yaklaşık 45 MB)..." "  Downloading HomeLab agent $PB_VERSION (about 45 MB)...")"
  if curl -fsSL --max-time 60 -o "$PB_TMP/SHA256SUMS.txt" "$PB_BASE/SHA256SUMS-$PB_VERSION.txt" \
    && curl -fsSL --max-time 900 -o "$PB_TMP/$PB_ZIP" "$PB_BASE/$PB_ZIP" \
    && PB_SUM="$(awk -v n="$PB_ZIP" '{ f=$2; sub(/^\*/,"",f); if (f==n) { print tolower($1); exit } }' "$PB_TMP/SHA256SUMS.txt")" \
    && [[ "$PB_SUM" =~ ^[0-9a-f]{64}$ ]] \
    && echo "$PB_SUM  $PB_TMP/$PB_ZIP" | sha256sum -c --quiet - \
    && unzip -q -o "$PB_TMP/$PB_ZIP" -d "$PB_TMP/agent" \
    && chmod +x "$PB_TMP/agent/HomeLabAgent" \
    && PB_APP="$("$PB_TMP/agent/HomeLabAgent" --print-install-dir 2>/dev/null | tail -n 1)" \
    && [[ "$PB_APP" == /*/HomeLab/app && "$PB_APP" != *[\$\"\'\\]* ]]; then
    systemctl --user disable --now homelab-agent.service >/dev/null 2>&1 || true
    rm -f "$HOME/.config/systemd/user/homelab.service"
    mkdir -p "$(dirname "$PB_APP")"
    rm -rf "$PB_APP.new"
    cp -R "$PB_TMP/agent" "$PB_APP.new" && mv "$PB_APP.new" "$PB_APP"
    mkdir -p "$(dirname "$PB_UNIT")"
    cat > "$PB_UNIT" <<EOF_PBUNIT
[Unit]
Description=$(T 'HomeLab ajanı (telefon paneli ve servis kontrolü)' 'HomeLab agent (phone panel and service control)')

[Service]
ExecStart="$PB_APP/HomeLabAgent"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF_PBUNIT
    printf '%s\n' "$PB_APP" | sudo tee /var/lib/homelab-installer/homelab-app >/dev/null
    sudo touch /var/lib/homelab-installer/markers/homelab-installed
    HOMELAB_NEW=yes
    systemctl --user daemon-reload
    if systemctl --user enable homelab-agent.service >/dev/null 2>&1 && systemctl --user restart homelab-agent.service >/dev/null 2>&1; then
      for _ in $(seq 1 30); do
        curl -fsS --max-time 2 "$PB_URL/api/info" >/dev/null 2>&1 && HOMELAB_OK=yes && break
        sleep 1
      done
    fi
  else
    echo "$(T 'UYARI: HomeLab ajanı indirilemedi veya doğrulanamadı; kurulmadı.' 'WARNING: The HomeLab agent could not be downloaded or verified; it was not installed.')"
    INSTALL_WARNINGS+=("$(T "HomeLab ajanı kurulamadı: https://github.com/$PB_REPO > Actions > build-agent çalıştırılmış ve v$PB_VERSION sürümü yayımlanmış olmalı; sonra KUR.sh'yi yeniden çalıştır" "Could not install the HomeLab agent: https://github.com/$PB_REPO > Actions > build-agent must have been run and release v$PB_VERSION published; then run KUR.sh again")")
  fi
  rm -rf "$PB_TMP"
  if [[ "$HOMELAB_OK" == yes ]]; then
    # Turn off automatic updates; on a first install, write pages suited to a server.
    if ! HL_LANG="$HL_LANG" PB_NEW="$HOMELAB_NEW" HL_WEB_USER="$ACCOUNT_USER" HL_WEB_PW="$ACCOUNT_PW" python3 -I - "$PB_URL" <<'PY_PBCFG'
import json, os, sys, urllib.request
lang = "tr" if os.environ.get("HL_LANG") == "tr" else "en"
S = {
    "tr": {"homelab": "HomeLab", "server": "Sunucu", "services": "Servisler", "services_tap": "Servisler · dokun",
           "alerts": "Uyarılar", "now": "Şu an", "history": "Geçmiş", "system": "Sistem",
           "procs": "İşlemler", "shortcuts": "Kısayollar"},
    "en": {"homelab": "HomeLab", "server": "Server", "services": "Services", "services_tap": "Services · tap",
           "alerts": "Alerts", "now": "Now", "history": "History", "system": "System",
           "procs": "Processes", "shortcuts": "Shortcuts"},
}[lang]
base = sys.argv[1]
with urllib.request.urlopen(base + "/api/settings", timeout=10) as r:
    version = r.headers.get("X-Config-Version")
    cfg = json.load(r)
cfg.setdefault("updates", {})["auto"] = False
if os.environ.get("PB_NEW") == "yes":
    disp = cfg.setdefault("display", {})
    disp.update(language=os.environ.get("HL_LANG", "en"), theme="amoled", accent="#2dd4bf")
    disp["appearance"] = {"style": "cards"}
    cfg["pages"] = [
        {"id": "homelab", "title": S["homelab"], "icon": "🖥️", "widgets": [
            {"type": "clock", "x": 0, "y": 0, "w": 5, "h": 4, "options": {"providers": []}},
            {"type": "push", "x": 5, "y": 0, "w": 7, "h": 4, "options": {"key": "homelab-status", "title": S["server"], "style": "list"}},
            {"type": "stat", "x": 0, "y": 4, "w": 3, "h": 2, "options": {"metric": "cpu"}},
            {"type": "stat", "x": 3, "y": 4, "w": 3, "h": 2, "options": {"metric": "ram"}},
            {"type": "stat", "x": 6, "y": 4, "w": 3, "h": 2, "options": {"metric": "cputemp"}},
            {"type": "stat", "x": 9, "y": 4, "w": 3, "h": 2, "options": {"metric": "net"}},
        ]},
        {"id": "detay", "title": S["services"], "icon": "🐳", "widgets": [
            {"type": "docker", "x": 0, "y": 0, "w": 8, "h": 6, "options": {"title": S["services_tap"], "control": True}},
            {"type": "inbox", "x": 8, "y": 0, "w": 4, "h": 6},
        ]},
        {"id": "uyarilar", "title": S["alerts"], "icon": "⚠️", "widgets": [
            {"type": "push", "x": 0, "y": 0, "w": 5, "h": 6, "options": {"key": "homelab-alerts-now", "title": S["now"], "style": "list"}},
            {"type": "push", "x": 5, "y": 0, "w": 7, "h": 6, "options": {"key": "homelab-alerts-history", "title": S["history"], "style": "list"}},
        ]},
        {"id": "sistem", "title": S["system"], "icon": "📊", "widgets": [
            {"type": "chart", "x": 0, "y": 0, "w": 6, "h": 3, "options": {"metrics": ["cpu"]}},
            {"type": "chart", "x": 6, "y": 0, "w": 6, "h": 3, "options": {"metrics": ["cputemp"]}},
            {"type": "meters", "x": 0, "y": 3, "w": 6, "h": 3},
            {"type": "chart", "x": 6, "y": 3, "w": 6, "h": 3, "options": {"metrics": ["down", "up"]}},
        ]},
        {"id": "islemler", "title": S["procs"], "icon": "⚙️", "widgets": [
            {"type": "processes", "x": 0, "y": 0, "w": 12, "h": 6},
        ]},
        {"id": "kisayollar", "title": S["shortcuts"], "icon": "🎛️", "widgets": [
            {"type": "shortcuts", "x": 0, "y": 0, "w": 12, "h": 6, "options": {"columns": 4}},
        ]},
    ]
    cfg["shortcuts"] = [x for x in cfg.get("shortcuts", []) if x.get("id") != "spotify"]
shortcuts = cfg.setdefault("shortcuts", [])
for sid, label, icon, arg in (("ha-start", "Home Assistant: start VM", "▶️", "start"), ("ha-stop", "Home Assistant: stop VM", "⏹️", "stop")):
    if not any(x.get("id") == sid for x in shortcuts):
        shortcuts.append({"id": sid, "label": label, "icon": icon, "color": "#2dd4bf", "cmd": "sudo", "args": "-n /usr/local/sbin/homelab-haos " + arg})
headers = {"Content-Type": "application/json"}
if os.environ.get("HL_WEB_USER"):  # the settings page login, when one is set (harmless when not)
    import base64
    headers["Authorization"] = "Basic " + base64.b64encode((os.environ["HL_WEB_USER"] + ":" + os.environ["HL_WEB_PW"]).encode("utf-8")).decode("ascii")
if version:
    headers["X-Config-Version"] = version
req = urllib.request.Request(base + "/api/settings", data=json.dumps(cfg).encode("utf-8"), method="PUT", headers=headers)
urllib.request.urlopen(req, timeout=10).read()
PY_PBCFG
    then
      INSTALL_WARNINGS+=("$(T 'HomeLab ayarları yazılamadı; http://127.0.0.1:8765 > ayarlarında otomatik güncellemeyi kapat' 'Could not write the HomeLab settings; turn off automatic updates in the settings at http://127.0.0.1:8765')")
    else
      echo "$(T 'HomeLab ajanı çalışıyor; otomatik güncelleme kapatıldı.' 'The HomeLab agent is running; automatic updates were turned off.')"
    fi
    # Login for the settings page (same username and password as everything else). Written last, so the calls above need none.
    if HL_WEB_USER="$ACCOUNT_USER" HL_WEB_PW="$ACCOUNT_PW" HL_WEB_FILE="$HOME/.config/HomeLab/web-login" python3 -I - <<'PY_WEBLOGIN'
import base64, hashlib, os, secrets
user, pw, path = os.environ["HL_WEB_USER"], os.environ["HL_WEB_PW"], os.environ["HL_WEB_FILE"]
salt, iterations = secrets.token_bytes(16), 600000
digest = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), salt, iterations, 32)
b64 = lambda b: base64.b64encode(b).decode("ascii")
line = "v1 %s %d %s %s\n" % (b64(user.encode("utf-8")), iterations, b64(salt), b64(digest))
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(line)
os.replace(tmp, path)
PY_WEBLOGIN
    then
      echo "$(T 'Ayar sayfası (127.0.0.1:8765) giriş şifresi ayarlandı: kullanıcı adı ve parola kurulumdakiyle aynı.' 'The settings page (127.0.0.1:8765) now asks for a login: the same username and password as the installation.')"
    else
      INSTALL_WARNINGS+=("$(T 'Ayar sayfası giriş şifresi yazılamadı; 127.0.0.1:8765 şifresiz açık kalır' 'Could not write the settings page login; 127.0.0.1:8765 stays open without a password')")
    fi
  fi
fi

echo "$(T '[5/12] AdGuard Home (yerel DNS)' '[5/12] AdGuard Home (local DNS)')"
ADGUARD_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
if [[ "$ADGUARD_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$ADGUARD_IP"; then
  ADGUARD_INSTALL=yes
  echo "$(T "AdGuard yalnızca $ADGUARD_IP üzerinde DNS/kurulum portları açacak. Router DNS ayarı değiştirilmeyecek." "AdGuard will open its DNS/setup ports only on $ADGUARD_IP. The router DNS setting will not be changed.")"
else
  echo "$(T 'Sunucunun yerel ağ IPv4 adresi bulunamadı; AdGuard bu kurulumda atlanacak.' 'The server LAN IPv4 address was not found; AdGuard will be skipped in this installation.')"
  ADGUARD_IP=""
  INSTALL_WARNINGS+=("$(T 'AdGuard için LAN IP bulunamadı, kurulmadı' 'No LAN IP found for AdGuard; it was not installed')")
fi

echo "$(T '[6/12] Syncthing, temel servisler ve güç düğmesi' '[6/12] Syncthing, core services and power button')"
if ! sudo test -e /var/lib/homelab-installer/markers/linger-added \
  && ! sudo test -e /var/lib/homelab-installer/markers/linger-preexisting; then
  if [[ "$(sudo loginctl show-user "$USER_NAME" -p Linger --value 2>/dev/null || true)" == yes ]]; then
    sudo touch /var/lib/homelab-installer/markers/linger-preexisting
  else
    sudo touch /var/lib/homelab-installer/markers/linger-added
  fi
fi
sudo loginctl enable-linger "$USER_NAME" || true
quiet_run sudo systemctl enable --now "syncthing@${USER_NAME}.service"
for _ in $(seq 1 30); do
  syncthing cli show system >/dev/null 2>&1 && break
  sleep 2
done
ST_OK=no
for _ in 1 2 3 4 5; do
  if syncthing cli config gui user set "$ACCOUNT_USER" >/dev/null 2>&1 \
    && syncthing cli config gui password set "$ACCOUNT_PW" >/dev/null 2>&1; then ST_OK=yes; break; fi
  sleep 3
done
if [[ "$ST_OK" == yes ]]; then
  quiet_run sudo systemctl restart "syncthing@${USER_NAME}.service" || true
  echo "$(T 'Syncthing arayüz girişi ayarlandı.' 'Syncthing web UI login was set.')"
else
  echo "$(T 'UYARI: Syncthing arayüz kullanıcı/parolası ayarlanamadı.' 'WARNING: Could not set the Syncthing web UI username/password.')"
  INSTALL_WARNINGS+=("$(T "Syncthing: http://127.0.0.1:8384 > Ayarlar > GUI'den kullanıcı/parola belirle" "Syncthing: set the username/password at http://127.0.0.1:8384 > Settings > GUI")")
fi
quiet_run sudo systemctl enable --now ssh
quiet_run sudo systemctl enable --now smbd
if ! quiet_run sudo systemctl enable --now avahi-daemon; then
  echo "$(T 'UYARI: mDNS servisi başlatılamadı; yerel ağda .local adı kullanılamayabilir.' 'WARNING: The mDNS service could not be started; the .local name may not work on the local network.')"
  INSTALL_WARNINGS+=("$(T 'Avahi/mDNS başlatılamadı; sunucuya LAN IP adresiyle eriş' 'Avahi/mDNS could not be started; reach the server by its LAN IP address')")
fi

# When the power button is pressed, Cinnamon shuts down directly instead of showing a confirmation dialog.
# The previous user setting is backed up; it can be restored if KALDIR.sh is run.
if command -v gsettings >/dev/null 2>&1 && gsettings writable org.cinnamon.settings-daemon.plugins.power button-power >/dev/null 2>&1; then
  sudo install -d -m 0700 /var/lib/homelab-installer
  if ! sudo test -f /var/lib/homelab-installer/cinnamon-button-power.before; then
    PREVIOUS_POWER_ACTION="$(gsettings get org.cinnamon.settings-daemon.plugins.power button-power 2>/dev/null || true)"
    if [[ -n "$PREVIOUS_POWER_ACTION" ]]; then
      printf '%s\n' "$PREVIOUS_POWER_ACTION" | sudo tee /var/lib/homelab-installer/cinnamon-button-power.before >/dev/null
      sudo chmod 0600 /var/lib/homelab-installer/cinnamon-button-power.before
    fi
  fi
  if gsettings set org.cinnamon.settings-daemon.plugins.power button-power 'shutdown'; then
    echo "$(T 'Cinnamon güç düğmesi: doğrudan kapat.' 'Cinnamon power button: shut down directly.')"
  else
    echo "$(T "UYARI: Cinnamon güç düğmesi ayarı yazılamadı; Ayarlar > Güç Yönetimi bölümünden 'Hemen kapat' seç." "WARNING: Could not write the Cinnamon power button setting; choose 'Shut down immediately' in Settings > Power Management.")"
  fi
else
  echo "$(T 'UYARI: Cinnamon gsettings oturumu bulunamadı; güç düğmesi ayarını masaüstü oturumunda tamamla.' 'WARNING: No Cinnamon gsettings session found; finish the power button setting in a desktop session.')"
fi
sudo install -d -m 0755 /etc/systemd/logind.conf.d
if [[ ! -f /etc/systemd/logind.conf.d/90-homelab-installer-power-button.conf ]]; then
  sudo touch /var/lib/homelab-installer/markers/logind-power-created
  sudo tee /etc/systemd/logind.conf.d/90-homelab-installer-power-button.conf >/dev/null <<'EOF_POWER'
[Login]
HandlePowerKey=poweroff
EOF_POWER
fi
echo "$(T 'systemd güç düğmesi ayarı yazıldı; tam etkisi için yeniden başlatma gerekir.' 'The systemd power button setting was written; a reboot is needed for it to take full effect.')"

echo "$(T 'Uyku modu kapatılıyor (sunucu uyumasın)' 'Disabling sleep mode (so the server does not sleep)')"
for SLEEP_TARGET in sleep suspend hibernate hybrid-sleep; do
  if [[ "$(systemctl is-enabled "$SLEEP_TARGET.target" 2>/dev/null || true)" != masked ]]; then
    sudo touch "/var/lib/homelab-installer/markers/sleep-masked-$SLEEP_TARGET"
  fi
done
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 \
  || INSTALL_WARNINGS+=("$(T 'Uyku hedefleri kilitlenemedi (systemctl mask)' 'Could not mask the sleep targets (systemctl mask)')")
sudo install -d -m 0755 /etc/systemd/logind.conf.d
if [[ ! -f /etc/systemd/logind.conf.d/91-homelab-installer-no-sleep.conf ]]; then
  sudo touch /var/lib/homelab-installer/markers/logind-nosleep-created
fi
sudo tee /etc/systemd/logind.conf.d/91-homelab-installer-no-sleep.conf >/dev/null <<'EOF_NOSLEEP'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF_NOSLEEP
sudo systemctl kill -s HUP systemd-logind >/dev/null 2>&1 || true
if command -v gsettings >/dev/null 2>&1 && gsettings writable org.cinnamon.settings-daemon.plugins.power button-power >/dev/null 2>&1; then
  SLEEP_BACKUP=/var/lib/homelab-installer/gsettings-sleep.before
  SLEEP_SETTINGS=(
    "org.cinnamon.settings-daemon.plugins.power|sleep-inactive-ac-type|'nothing'"
    "org.cinnamon.settings-daemon.plugins.power|sleep-inactive-battery-type|'nothing'"
    "org.cinnamon.settings-daemon.plugins.power|sleep-inactive-ac-timeout|0"
    "org.cinnamon.settings-daemon.plugins.power|sleep-inactive-battery-timeout|0"
    "org.cinnamon.settings-daemon.plugins.power|sleep-display-ac|0"
    "org.cinnamon.settings-daemon.plugins.power|sleep-display-battery|0"
    "org.cinnamon.settings-daemon.plugins.power|lid-close-ac-action|'nothing'"
    "org.cinnamon.settings-daemon.plugins.power|lid-close-battery-action|'nothing'"
    "org.cinnamon.desktop.session|idle-delay|uint32 0"
    "org.cinnamon.desktop.screensaver|lock-enabled|false"
  )
  SLEEP_FIRST=no
  sudo test -f "$SLEEP_BACKUP" || SLEEP_FIRST=yes
  SLEEP_TMP="$(mktemp)"
  SLEEP_FAIL=0
  for ENTRY in "${SLEEP_SETTINGS[@]}"; do
    IFS='|' read -r SCHEMA KEY VALUE <<<"$ENTRY"
    if gsettings writable "$SCHEMA" "$KEY" >/dev/null 2>&1; then
      [[ "$SLEEP_FIRST" == yes ]] && printf '%s|%s|%s\n' "$SCHEMA" "$KEY" "$(gsettings get "$SCHEMA" "$KEY")" >> "$SLEEP_TMP"
      gsettings set "$SCHEMA" "$KEY" "$VALUE" 2>/dev/null || SLEEP_FAIL=1
    fi
  done
  if [[ "$SLEEP_FIRST" == yes && -s "$SLEEP_TMP" ]]; then sudo install -o root -g root -m 0600 "$SLEEP_TMP" "$SLEEP_BACKUP"; fi
  rm -f "$SLEEP_TMP"
  if (( SLEEP_FAIL )); then
    INSTALL_WARNINGS+=("$(T "Bazı Cinnamon uyku ayarları yazılamadı; Ayarlar > Güç Yönetimi'nden kontrol et" "Some Cinnamon sleep settings could not be written; check them in Settings > Power Management")")
  fi
  echo "$(T 'Uyku, ekran kapanması, kapak kapanışı ve ekran kilidi kapatıldı.' 'Sleep, screen blanking, lid-close action and screen lock were turned off.')"
else
  echo "$(T 'UYARI: Cinnamon gsettings oturumu yok; Cinnamon uyku ayarları atlandı (systemd uykusu yine de kilitlendi).' 'WARNING: No Cinnamon gsettings session; Cinnamon sleep settings were skipped (systemd sleep is still masked).')"
fi

echo "$(T 'Otomatik oturum açma' 'Automatic login')"
if [[ -d /etc/lightdm ]]; then
  if grep -qsE '^[[:space:]]*autologin-user=' /etc/lightdm/lightdm.conf; then
    echo "$(T 'Otomatik giriş zaten /etc/lightdm/lightdm.conf içinde ayarlı; dokunulmadı.' 'Automatic login is already set in /etc/lightdm/lightdm.conf; left untouched.')"
  else
    sudo install -d -m 0755 /etc/lightdm/lightdm.conf.d
    if [[ ! -f /etc/lightdm/lightdm.conf.d/70-homelab-installer-autologin.conf ]]; then
      sudo touch /var/lib/homelab-installer/markers/autologin-created
    fi
    sudo tee /etc/lightdm/lightdm.conf.d/70-homelab-installer-autologin.conf >/dev/null <<EOF_AUTOLOGIN
[Seat:*]
autologin-user=${USER_NAME}
autologin-user-timeout=0
EOF_AUTOLOGIN
    echo "$(T 'Otomatik giriş açıldı (sonraki açılıştan itibaren).' 'Automatic login enabled (from the next boot).')"
  fi
else
  echo "$(T 'LightDM bulunamadı; otomatik giriş ayarlanmadı.' 'LightDM not found; automatic login was not set.')"
fi

echo "$(T 'Otomatik güvenlik güncellemeleri' 'Automatic security updates')"
wait_apt_idle
if quiet_run "${APT_Q[@]}" install unattended-upgrades; then
  if [[ ! -e /etc/apt/apt.conf.d/52homelab-unattended-upgrades ]]; then
    sudo touch /var/lib/homelab-installer/markers/unattended-created
    # On Mint, ${distro_id} is "LinuxMint", so the default origin does not match; the Ubuntu security repository is written explicitly.
    UU_UBUNTU_CODENAME="$(. /etc/os-release; echo "${UBUNTU_CODENAME:-noble}")"
    UU_MINT_CODENAME="$(. /etc/os-release; echo "${VERSION_CODENAME:-zena}")"
    # Mint's default 50unattended-upgrades file enables ALL Mint updates (not just security); it is cleared here.
    sudo tee /etc/apt/apt.conf.d/52homelab-unattended-upgrades >/dev/null <<EOF_UU
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Origins-Pattern { "origin=Ubuntu,codename=${UU_UBUNTU_CODENAME}-security"; "origin=Linuxmint,archive=${UU_MINT_CODENAME}-security"; };
Unattended-Upgrade::Package-Blacklist { "docker-ce"; "docker-ce-cli"; "containerd.io"; "docker-compose-plugin"; "docker-buildx-plugin"; };
Unattended-Upgrade::Automatic-Reboot "false";
EOF_UU
  fi
else
  echo "$(T 'UYARI: unattended-upgrades kurulamadı; otomatik güvenlik güncellemesi etkin değil.' 'WARNING: unattended-upgrades could not be installed; automatic security updates are not enabled.')"
  INSTALL_WARNINGS+=("$(T 'unattended-upgrades kurulamadı' 'unattended-upgrades could not be installed')")
fi

echo "$(T '[7/12] HomeLab klasörleri ve Compose dosyaları' '[7/12] HomeLab folders and Compose files')"
sudo mkdir -p "$BASE"/{data/shared,data/documents,data/projects,data/media,backups,tools,web/public,config/caddy,appdata/{ntfy/{cache,lib},dockge,beszel,beszel-agent,uptime-kuma,filebrowser,n8n,ollama,scrutiny/{config,influxdb},caddy/{data,config},adguardhome/{work,conf}},compose/{dockge,monitoring,cloud,ai,storage,web,adguard,monitoring-agent,notify}}
# Ownership of the Compose files: files that existed before the installation (not ours) are not deleted by KALDIR.sh.
for STACK_NAME in dockge monitoring cloud ai storage web notify adguard monitoring-agent; do
  if [[ ! -e "$STACKS/$STACK_NAME/compose.yaml" ]]; then
    sudo touch "/var/lib/homelab-installer/markers/compose-owned-$STACK_NAME"
  elif ! sudo test -e "/var/lib/homelab-installer/markers/compose-owned-$STACK_NAME"; then
    sudo touch "/var/lib/homelab-installer/markers/compose-foreign-$STACK_NAME"
  fi
done
sudo chown "$USER_NAME:$USER_GROUP" "$BASE/data" "$BASE/data/shared" "$BASE/data/documents" "$BASE/data/projects" "$BASE/data/media"
sudo chown root:"$USER_GROUP" "$BASE"
sudo chmod 750 "$BASE"
# Common Docker images use UID/GID 1000 for writable application data.
# Only empty directories are adjusted; existing user data is never recursively chowned.
for APPDATA_DIR in dockge beszel uptime-kuma filebrowser n8n caddy/data caddy/config; do
  TARGET="$BASE/appdata/$APPDATA_DIR"
  if [[ -d "$TARGET" ]] && ! find "$TARGET" -mindepth 1 -print -quit | grep -q .; then
    sudo chown 1000:1000 "$TARGET"
  fi
done
# Create only files that do not exist; existing configurations are preserved.
if [[ ! -f "$STACKS/dockge/compose.yaml" ]]; then
sudo tee "$STACKS/dockge/compose.yaml" >/dev/null <<EOF
services:
  dockge:
    image: louislam/dockge:1
    container_name: dockge
    restart: unless-stopped
    ports: ["0.0.0.0:5001:5001"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $STACKS:$STACKS
      - $BASE/appdata/dockge:/app/data
    environment:
      DOCKGE_STACKS_DIR: $STACKS
EOF
fi
if [[ ! -f "$STACKS/monitoring/compose.yaml" ]]; then
sudo tee "$STACKS/monitoring/compose.yaml" >/dev/null <<EOF
services:
  beszel:
    image: henrygd/beszel:latest
    container_name: beszel
    restart: unless-stopped
    ports: ["0.0.0.0:8090:8090"]
    volumes: [$BASE/appdata/beszel:/beszel_data]
  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: uptime-kuma
    restart: unless-stopped
    ports: ["0.0.0.0:3001:3001"]
    volumes: [$BASE/appdata/uptime-kuma:/app/data]
EOF
fi
FB_LOGIN_SET=no
if [[ ! -f "$STACKS/cloud/compose.yaml" ]]; then
# File Browser first-start login = the installation username and password (single quotes keep the value literal for Compose)
if [[ "$ACCOUNT_PW" != *"'"* && "$ACCOUNT_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
  (umask 077; printf "FILEBROWSER_ADMIN_PASSWORD='%s'\n" "$ACCOUNT_PW" | sudo tee "$STACKS/cloud/filebrowser.env" >/dev/null)
  sudo chmod 600 "$STACKS/cloud/filebrowser.env"
  printf 'auth:\n  adminUsername: %s\n' "$ACCOUNT_USER" | sudo tee "$BASE/appdata/filebrowser/config.yaml" >/dev/null
  FB_LOGIN_SET=yes
else
  : | sudo tee "$STACKS/cloud/filebrowser.env" >/dev/null
fi
sudo tee "$STACKS/cloud/compose.yaml" >/dev/null <<EOF
services:
  filebrowser:
    image: ghcr.io/gtsteffaniak/filebrowser:stable-slim
    container_name: filebrowser
    restart: unless-stopped
    env_file: [filebrowser.env]
    ports: ["0.0.0.0:8080:80"]
    volumes:
      - $BASE/data:/folder
      - $BASE/appdata/filebrowser:/home/filebrowser/data
EOF
fi
if [[ ! -f "$STACKS/ai/compose.yaml" ]]; then
sudo tee "$STACKS/ai/compose.yaml" >/dev/null <<EOF
# HOMELAB_MANAGED_AI_STACK
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports: ["127.0.0.1:11434:11434"]
    volumes: [$BASE/appdata/ollama:/root/.ollama]
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports: ["0.0.0.0:5678:5678"]
    environment:
      TZ: Europe/Istanbul
      GENERIC_TIMEZONE: Europe/Istanbul
      # $(T "LAN'da http:// ile açıldığı için gerekli; HTTPS/Cloudflare Tunnel kurulunca true yap veya satırı sil." "Needed because it is opened over http:// on the LAN; set it to true or delete the line once HTTPS/Cloudflare Tunnel is set up.")
      N8N_SECURE_COOKIE: "false"
    volumes: [$BASE/appdata/n8n:/home/node/.n8n]
    depends_on: [ollama]
EOF
fi
# Samba share: add only if the section does not exist.
if ! sudo grep -q '^\[Paylasim\]' /etc/samba/smb.conf; then
sudo touch /var/lib/homelab-installer/markers/samba-share-created
sudo tee -a /etc/samba/smb.conf >/dev/null <<EOF

[Paylasim]
   path = $BASE/data/shared
   browseable = yes
   read only = no
   guest ok = no
   valid users = $USER_NAME
   create mask = 0664
   directory mask = 0775
EOF
fi
quiet_run sudo testparm -s
quiet_run sudo systemctl restart smbd
# SSH brute-force mitigation; no firewall rules or router changes are made.
sudo install -d -m 0755 /etc/fail2ban/jail.d
if [[ ! -f /etc/fail2ban/jail.d/homelab-sshd.local ]]; then
  sudo touch /var/lib/homelab-installer/markers/fail2ban-created
  sudo tee /etc/fail2ban/jail.d/homelab-sshd.local >/dev/null <<'EOF_FAIL2BAN'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF_FAIL2BAN
fi
quiet_run sudo systemctl enable --now fail2ban
# Keep persistent system journals bounded; preserve an existing custom drop-in.
sudo install -d -m 0755 /etc/systemd/journald.conf.d
if [[ ! -f /etc/systemd/journald.conf.d/homelab.conf ]]; then
  sudo touch /var/lib/homelab-installer/markers/journald-created
  sudo tee /etc/systemd/journald.conf.d/homelab.conf >/dev/null <<'EOF_JOURNAL'
[Journal]
Storage=persistent
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=1month
EOF_JOURNAL
  sudo install -d -o root -g systemd-journal -m 2755 /var/log/journal
  quiet_run sudo systemctl restart systemd-journald
fi

# New, isolated Compose stacks are created only when their files do not exist.
if [[ ! -f "$STACKS/storage/compose.yaml" ]]; then
  DISK_LINES=""
  NVME_CONTROLLERS=""
  while IFS= read -r DISK_LINE; do
    DEVICE="" DISK_TYPE="" DISK_TRAN="" DISK_RM="0"
    [[ "$DISK_LINE" =~ NAME=\"([^\"]*)\" ]] && DEVICE="${BASH_REMATCH[1]}"
    [[ "$DISK_LINE" =~ TYPE=\"([^\"]*)\" ]] && DISK_TYPE="${BASH_REMATCH[1]}"
    [[ "$DISK_LINE" =~ TRAN=\"([^\"]*)\" ]] && DISK_TRAN="${BASH_REMATCH[1]}"
    [[ "$DISK_LINE" =~ RM=\"([^\"]*)\" ]] && DISK_RM="${BASH_REMATCH[1]}"
    [[ "$DISK_TYPE" == disk && "$DEVICE" =~ ^/dev/[A-Za-z0-9_]+$ ]] || continue
    # When USB/removable disks are unplugged the Scrutiny container cannot start; zram is not a real disk.
    if [[ "$DISK_TRAN" == usb || "$DISK_RM" == 1 || "$DEVICE" == /dev/zram* ]]; then
      echo "$(T "Scrutiny: $DEVICE (USB/çıkarılabilir/zram) izleme listesine eklenmedi." "Scrutiny: $DEVICE (USB/removable/zram) was not added to the watch list.")"
      continue
    fi
    if [[ "$DEVICE" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
      CONTROLLER="${DEVICE%n*}"
      if [[ -e "$CONTROLLER" ]] && ! grep -Fq "$CONTROLLER:$CONTROLLER" <<<"$NVME_CONTROLLERS"; then
        NVME_CONTROLLERS+="      - $CONTROLLER:$CONTROLLER"$'\n'
      fi
    else
      DISK_LINES+="      - $DEVICE:$DEVICE"$'\n'
    fi
  done < <(lsblk -dnPpo NAME,TYPE,TRAN,RM)
  DISK_LINES+="$NVME_CONTROLLERS"
  SCRUTINY_NVME_CAP=""
  if [[ -n "$NVME_CONTROLLERS" ]]; then
    echo "$(T "NVMe disk bulundu; Scrutiny'ye geniş SYS_ADMIN yetkisi verilmedi (güvenli varsayılan)." "NVMe disk found; Scrutiny was not given the broad SYS_ADMIN capability (safe default).")"
  fi
  {
    cat <<EOF_SCRUTINY
services:
  scrutiny:
    image: ghcr.io/analogj/scrutiny:v0.10.0-omnibus
    container_name: scrutiny
    restart: unless-stopped
    cap_add:
      - SYS_RAWIO
EOF_SCRUTINY
    if [[ -n "$SCRUTINY_NVME_CAP" ]]; then printf '      - SYS_ADMIN\n'; fi
    cat <<EOF_SCRUTINY2
    ports:
      - "0.0.0.0:8081:8080"
    volumes:
      - /run/udev:/run/udev:ro
      - $BASE/appdata/scrutiny/config:/opt/scrutiny/config
      - $BASE/appdata/scrutiny/influxdb:/opt/scrutiny/influxdb
EOF_SCRUTINY2
    if [[ -n "$DISK_LINES" ]]; then printf '    devices:
%s' "$DISK_LINES"; fi
  } | sudo tee "$STACKS/storage/compose.yaml" >/dev/null
fi

if [[ ! -f "$STACKS/web/compose.yaml" ]]; then
  if [[ ! -f "$BASE/config/caddy/Caddyfile" ]]; then
    sudo tee "$BASE/config/caddy/Caddyfile" >/dev/null <<'EOF_CADDY'
:80 {
    root * /srv
    encode zstd gzip
    file_server
}
EOF_CADDY
    sudo chown "$USER_NAME:$USER_GROUP" "$BASE/config/caddy/Caddyfile"
  fi
  if [[ ! -f "$BASE/web/public/index.html" ]]; then
    if [[ $HL_LANG == tr ]]; then
    sudo tee "$BASE/web/public/index.html" >/dev/null <<'EOF_SITE'
<!doctype html>
<html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>HomeLab</title>
<style>body{font-family:system-ui,sans-serif;max-width:760px;margin:12vh auto;padding:0 24px;line-height:1.6;color:#202936}h1{font-size:2.4rem}p{color:#596579}</style></head>
<body><h1>HomeLab</h1><p>Kişisel web sitesi için başlangıç sayfası. Alan adı ve içerik yapılandırması sonraki aşamada yapılacaktır.</p></body></html>
EOF_SITE
    else
    sudo tee "$BASE/web/public/index.html" >/dev/null <<'EOF_SITE_EN'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>HomeLab</title>
<style>body{font-family:system-ui,sans-serif;max-width:760px;margin:12vh auto;padding:0 24px;line-height:1.6;color:#202936}h1{font-size:2.4rem}p{color:#596579}</style></head>
<body><h1>HomeLab</h1><p>Starter page for a personal website. Domain and content setup will be done at a later stage.</p></body></html>
EOF_SITE_EN
    fi
    sudo chown "$USER_NAME:$USER_GROUP" "$BASE/web/public/index.html"
  fi
  sudo chown "$USER_NAME:$USER_GROUP" "$BASE/web" "$BASE/web/public" "$BASE/config/caddy"
  sudo tee "$STACKS/web/compose.yaml" >/dev/null <<EOF_CADDY_COMPOSE
services:
  caddy:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    ports:
      - "127.0.0.1:8088:80"
    volumes:
      - $BASE/config/caddy:/etc/caddy:ro
      - $BASE/web/public:/srv:ro
      - $BASE/appdata/caddy/data:/data
      - $BASE/appdata/caddy/config:/config
EOF_CADDY_COMPOSE
fi

if [[ ! -f "$STACKS/adguard/compose.yaml" && "$ADGUARD_INSTALL" == yes ]]; then
  sudo tee "$STACKS/adguard/.env" >/dev/null <<EOF_ADGUARD_ENV
ADGUARD_BIND_IP=$ADGUARD_IP
EOF_ADGUARD_ENV
  sudo chmod 600 "$STACKS/adguard/.env"
  sudo tee "$STACKS/adguard/compose.yaml" >/dev/null <<'EOF_ADGUARD_COMPOSE'
services:
  adguardhome:
    image: adguard/adguardhome:v0.107.80
    container_name: adguardhome
    restart: unless-stopped
    ports:
      - "${ADGUARD_BIND_IP}:53:53/tcp"
      - "${ADGUARD_BIND_IP}:53:53/udp"
      - "${ADGUARD_BIND_IP}:3000:3000/tcp"
      - "${ADGUARD_BIND_IP}:3002:80/tcp"
    volumes:
      - /srv/homelab/appdata/adguardhome/work:/opt/adguardhome/work
      - /srv/homelab/appdata/adguardhome/conf:/opt/adguardhome/conf
EOF_ADGUARD_COMPOSE
fi

# Beszel Agent is kept in a separate Compose file until its Hub-generated key/token exist.
if [[ ! -f "$STACKS/monitoring-agent/compose.yaml" ]]; then
  sudo tee "$STACKS/monitoring-agent/compose.yaml" >/dev/null <<EOF_AGENT
services:
  beszel-agent:
    image: henrygd/beszel-agent:latest
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    volumes:
      - $BASE/appdata/beszel-agent:/var/lib/beszel-agent
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      LISTEN: 45876
      KEY: \${BESZEL_AGENT_KEY}
      TOKEN: \${BESZEL_AGENT_TOKEN}
EOF_AGENT
fi


if [[ ! -f "$STACKS/notify/compose.yaml" ]]; then
  HOST_SHORT="$(hostname -s)"
  sudo tee "$STACKS/notify/compose.yaml" >/dev/null <<EOF_NTFY_COMPOSE
services:
  ntfy:
    image: binwiederhier/ntfy:latest
    container_name: ntfy
    command: serve
    restart: unless-stopped
    environment:
      TZ: Europe/Istanbul
      NTFY_BASE_URL: http://${HOST_SHORT}.local:2586
      NTFY_CACHE_FILE: /var/cache/ntfy/cache.db
      NTFY_AUTH_FILE: /var/lib/ntfy/user.db
      NTFY_AUTH_DEFAULT_ACCESS: deny-all
    ports:
      - "0.0.0.0:2586:80"
    volumes:
      - $BASE/appdata/ntfy/cache:/var/cache/ntfy
      - $BASE/appdata/ntfy/lib:/var/lib/ntfy
EOF_NTFY_COMPOSE
fi

echo "$(T 'Docker portları yerel ağa kilitleniyor (internet kaynaklı yeni bağlantılar engellenir).' 'Locking Docker ports to the local network (new connections from the internet are blocked).')"
sudo install -o root -g root -m 0750 "$SCRIPT_DIR/homelab-docker-lan-only" /usr/local/sbin/homelab-docker-lan-only
sudo touch /var/lib/homelab-installer/markers/lan-lock-created
sudo tee /etc/systemd/system/homelab-docker-lan-only.service >/dev/null <<EOF_LAN_UNIT
[Unit]
Description=$(T 'Docker yayınlanan portlarını LAN/Tailscale kaynaklarıyla sınırla (HomeLab)' 'Restrict Docker published ports to LAN/Tailscale sources (HomeLab)')
After=docker.service network-online.target
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/homelab-docker-lan-only apply
ExecStop=/usr/local/sbin/homelab-docker-lan-only remove

[Install]
WantedBy=multi-user.target
EOF_LAN_UNIT
sudo systemctl daemon-reload
LAN_LOCK_OK=no
if quiet_run sudo systemctl enable --now homelab-docker-lan-only.service \
  && sudo iptables -S DOCKER-USER 2>/dev/null | grep -q 'HOMELAB-LAN-ONLY'; then
  LAN_LOCK_OK=yes
else
  echo "$(T 'UYARI: Docker port kilidi etkinleştirilemedi veya doğrulanamadı; portlar LAN dışına açık kalabilir.' 'WARNING: The Docker port lock could not be enabled or verified; ports may stay open beyond the LAN.')"
  INSTALL_WARNINGS+=("$(T 'Docker port kilidi (LAN-only) doğrulanamadı: sudo journalctl -u homelab-docker-lan-only' 'Could not verify the Docker port lock (LAN-only): sudo journalctl -u homelab-docker-lan-only')")
fi

echo "$(T '[8/12] Docker servisleri doğrulanıyor ve başlatılıyor' '[8/12] Validating and starting Docker services')"
for f in "$STACKS/dockge/compose.yaml" "$STACKS/monitoring/compose.yaml" "$STACKS/cloud/compose.yaml" "$STACKS/ai/compose.yaml" "$STACKS/storage/compose.yaml" "$STACKS/web/compose.yaml" "$STACKS/notify/compose.yaml"; do
  STACK_NAME="$(basename -- "$(dirname -- "$f")")"
  # If one stack fails to start (image could not be pulled, port conflict, etc.), let the rest of the installation finish anyway.
  if ! sudo docker compose -f "$f" config -q; then
    echo "$(T "UYARI: $STACK_NAME Compose dosyası doğrulanamadı; başlatılmadı." "WARNING: The $STACK_NAME Compose file could not be validated; it was not started.")"
    INSTALL_WARNINGS+=("$(T "$STACK_NAME Compose dosyası geçersiz; başlatılmadı" "The $STACK_NAME Compose file is invalid; it was not started")")
  elif ! { echo "$(T "[Docker] $STACK_NAME indiriliyor/başlatılıyor (ilerleme çubuğu gizli, birkaç dakika sürebilir)..." "[Docker] Pulling/starting $STACK_NAME (progress bar hidden, may take a few minutes)...")"; sudo docker compose --progress quiet -f "$f" up -d --quiet-pull; }; then
    echo "$(T "UYARI: $STACK_NAME stack'i başlatılamadı (imaj indirme veya port sorunu olabilir)." "WARNING: The $STACK_NAME stack could not be started (could be an image pull or port problem).")"
    INSTALL_WARNINGS+=("$(T "$STACK_NAME stack'i başlatılamadı; sudo docker compose -f $f up -d ile tekrar dene" "The $STACK_NAME stack could not be started; try again with sudo docker compose -f $f up -d")")
  fi
done
if [[ -f "$STACKS/adguard/compose.yaml" && "$ADGUARD_INSTALL" == yes && -f "$STACKS/adguard/.env" ]]; then
  if ! sudo docker compose --env-file "$STACKS/adguard/.env" -f "$STACKS/adguard/compose.yaml" config -q; then
    echo "$(T 'UYARI: AdGuard Compose dosyası doğrulanamadı; başlatılmadı.' 'WARNING: The AdGuard Compose file could not be validated; it was not started.')"
    INSTALL_WARNINGS+=("$(T 'AdGuard Compose dosyası geçersiz; başlatılmadı' 'The AdGuard Compose file is invalid; it was not started')")
    ADGUARD_INSTALL=no
  fi
fi
if [[ -f "$STACKS/adguard/compose.yaml" && "$ADGUARD_INSTALL" == yes && -f "$STACKS/adguard/.env" ]]; then
  # Do not steal DNS if another process already listens on wildcard or the selected LAN address.
  DNS_LISTENERS="$(sudo ss -Hlnptun 'sport = :53' 2>/dev/null || true)"
  if sudo docker compose --env-file "$STACKS/adguard/.env" -f "$STACKS/adguard/compose.yaml" ps --status running -q 2>/dev/null | grep -q .; then
    echo "$(T 'AdGuard zaten çalışıyor; olduğu gibi bırakıldı.' 'AdGuard is already running; left as it is.')"
  elif grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]):53([[:space:]]|$)' <<<"$DNS_LISTENERS" || grep -Fq "$ADGUARD_IP:53" <<<"$DNS_LISTENERS"; then
    echo "$(T 'Port 53 zaten kullanımda; AdGuard Compose dosyası hazırlandı ancak konteyner başlatılmadı.' 'Port 53 is already in use; the AdGuard Compose file was prepared but the container was not started.')"
    INSTALL_WARNINGS+=("$(T 'Port 53 kullanımda olduğu için AdGuard başlatılmadı' 'AdGuard was not started because port 53 is in use')")
  elif ! { echo "$(T '[Docker] adguard indiriliyor/başlatılıyor...' '[Docker] Pulling/starting adguard...')"; sudo docker compose --progress quiet --env-file "$STACKS/adguard/.env" -f "$STACKS/adguard/compose.yaml" up -d --quiet-pull; }; then
    echo "$(T 'UYARI: AdGuard başlatılamadı.' 'WARNING: AdGuard could not be started.')"
    INSTALL_WARNINGS+=("$(T 'AdGuard başlatılamadı' 'AdGuard could not be started')")
  fi
fi

echo "$(T 'İlk kurulumun sabit Ollama modeli indiriliyor.' 'Downloading the fixed Ollama model for the first installation.')"
ROOT_FREE_KB="$(df -Pk "$BASE" | awk 'NR == 2 {print $4}')"
if [[ ! "$ROOT_FREE_KB" =~ ^[0-9]+$ ]] || ((ROOT_FREE_KB < 2097152)); then
  echo "$(T "Diskte en az 2 GiB boş alan bulunamadı; $OLLAMA_MODEL indirmesi atlandı." "Less than 2 GiB of free disk space; the $OLLAMA_MODEL download was skipped.")"
  INSTALL_WARNINGS+=("$(T 'Yeterli disk alanı olmadığı için Ollama modeli indirilmedi' 'The Ollama model was not downloaded because there is not enough disk space')")
else
  echo "$(T "İlk kurulum modeli: $OLLAMA_MODEL (Q4_K_M, model dosyası yaklaşık 986 MB; CPU üzerinde çalışır)" "First-install model: $OLLAMA_MODEL (Q4_K_M, model file about 986 MB; runs on the CPU)")"
  MODEL_READY=no
  for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
      MODEL_READY=yes
      break
    fi
    sleep 2
  done
  if [[ "$MODEL_READY" == yes ]] \
    && { echo "$(T "  model indiriliyor: $OLLAMA_MODEL (boyuta göre uzun sürebilir, ilerleme gizli)..." "  downloading model: $OLLAMA_MODEL (may take a long time depending on size, progress hidden)...")"; quiet_run sudo docker compose -f "$STACKS/ai/compose.yaml" exec -T ollama ollama pull "$OLLAMA_MODEL"; }; then
    echo "$(T "Ollama modeli indirildi: $OLLAMA_MODEL" "Ollama model downloaded: $OLLAMA_MODEL")"
  else
    echo "$(T 'Ollama modeli şu anda indirilemedi. Docker hizmetini ve günlükleri kontrol edip daha sonra modeli elle çekebilirsin.' 'The Ollama model could not be downloaded right now. Check the Docker service and the logs, then pull the model manually later.')"
    INSTALL_WARNINGS+=("$(T 'Ollama modeli indirilemedi' 'The Ollama model could not be downloaded')")
  fi
fi

echo "$(T 'Bildirim sistemi (ntfy) ve sağlık denetimi hazırlanıyor' 'Preparing the notification system (ntfy) and the health check')"
sudo install -o root -g root -m 0750 "$SCRIPT_DIR/homelab-notify" /usr/local/sbin/homelab-notify
sudo install -o root -g root -m 0750 "$SCRIPT_DIR/homelab-health-check" /usr/local/sbin/homelab-health-check
sudo touch /var/lib/homelab-installer/markers/notify-created
sudo tee /etc/systemd/system/homelab-notify-failure@.service >/dev/null <<EOF_NOTIFY_UNIT
[Unit]
Description=$(T 'HomeLab %i için hata bildirimi' 'HomeLab failure notification for %i')

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-notify "$(T 'Servis basarisiz' 'Service failed')" "$(T '%i basarisiz oldu. Ayrinti: journalctl -u %i' '%i failed. Details: journalctl -u %i')" 4 rotating_light
EOF_NOTIFY_UNIT
NTFY_CONF=/etc/homelab-installer/ntfy.env
if sudo docker container inspect ntfy >/dev/null 2>&1 && ! sudo test -f "$NTFY_CONF"; then
  for _ in $(seq 1 30); do
    curl -fsS --max-time 3 http://127.0.0.1:2586/v1/health >/dev/null 2>&1 && break
    sleep 2
  done
  NTFY_ADMIN_USER=homelab
  [[ "$ACCOUNT_USER" == homelab ]] && NTFY_ADMIN_USER=homelab-bot
  NTFY_ADMIN_PASS="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
  NTFY_TOPIC_NAME="homelab-installer-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
  if sudo env NTFY_PASSWORD="$NTFY_ADMIN_PASS" docker compose -f "$STACKS/notify/compose.yaml" exec -T -e NTFY_PASSWORD ntfy ntfy user add --role=admin "$NTFY_ADMIN_USER"; then
    sudo install -d -m 0700 -o root -g root /etc/homelab-installer
    ( umask 077; sudo tee "$NTFY_CONF" >/dev/null <<EOF_NTFY_ENV
NTFY_URL=http://127.0.0.1:2586
NTFY_TOPIC=$NTFY_TOPIC_NAME
NTFY_USER=$NTFY_ADMIN_USER
NTFY_PASSWORD=$NTFY_ADMIN_PASS
EOF_NTFY_ENV
    )
    sudo chmod 0600 "$NTFY_CONF"
    sudo /usr/local/sbin/homelab-notify "HomeLab" "$(T 'Bildirim sistemi kuruldu ve çalışıyor.' 'The notification system is installed and running.')" 3 tada \
      || INSTALL_WARNINGS+=("$(T 'ntfy test bildirimi gönderilemedi' 'Could not send the ntfy test notification')")
  else
    echo "$(T 'UYARI: ntfy kullanıcısı oluşturulamadı; bildirimler etkin değil.' 'WARNING: Could not create the ntfy user; notifications are not enabled.')"
    INSTALL_WARNINGS+=("$(T 'ntfy kullanıcısı oluşturulamadı; elle: sudo docker exec -it ntfy ntfy user add --role=admin homelab' 'Could not create the ntfy user; manually: sudo docker exec -it ntfy ntfy user add --role=admin homelab')")
  fi
  unset NTFY_ADMIN_PASS
fi
if sudo docker container inspect ntfy >/dev/null 2>&1; then
  # A separate ntfy account with your own username and password, for signing in from the phone.
  if ! sudo env NTFY_PASSWORD="$ACCOUNT_PW" docker compose -f "$STACKS/notify/compose.yaml" exec -T -e NTFY_PASSWORD ntfy ntfy user add --role=admin "$ACCOUNT_USER" >/dev/null 2>&1 \
    && ! sudo env NTFY_PASSWORD="$ACCOUNT_PW" docker compose -f "$STACKS/notify/compose.yaml" exec -T -e NTFY_PASSWORD ntfy ntfy user change-pass "$ACCOUNT_USER" >/dev/null 2>&1; then
    INSTALL_WARNINGS+=("$(T "ntfy hesabın oluşturulamadı; elle: sudo docker exec -it ntfy ntfy user add --role=admin $ACCOUNT_USER" "Could not create your ntfy account; manually: sudo docker exec -it ntfy ntfy user add --role=admin $ACCOUNT_USER")")
  fi
fi
if sudo test -f "$NTFY_CONF"; then
  sudo tee /etc/systemd/system/homelab-health-check.service >/dev/null <<EOF_HEALTH_SVC
[Unit]
Description=$(T 'HomeLab sağlık denetimi' 'HomeLab health check')

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-health-check
EOF_HEALTH_SVC
  sudo tee /etc/systemd/system/homelab-health-check.timer >/dev/null <<EOF_HEALTH_TIMER
[Unit]
Description=$(T 'HomeLab sağlık denetimini her 10 dakikada bir çalıştır' 'Run HomeLab health check every 10 minutes')

[Timer]
OnBootSec=3min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF_HEALTH_TIMER
  sudo systemctl daemon-reload
  quiet_run sudo systemctl enable --now homelab-health-check.timer || INSTALL_WARNINGS+=("$(T 'homelab-health-check.timer etkinleştirilemedi' 'Could not enable homelab-health-check.timer')")
fi

echo "$(T '[9/12] Yardımcı araçlar kuruluyor' '[9/12] Installing helper tools')"
sudo mkdir -p "$BASE/tools"
for TOOL in setup-restic-backup.sh configure-beszel-agent.sh reset-web-login.sh harden-ssh.sh setup-haos-vm.sh homelab-haos lang.sh; do
  sudo install -o "$USER_NAME" -g "$(id -gn)" -m 0755 "$SCRIPT_DIR/$TOOL" "$BASE/tools/$TOOL"
done

echo "$(T '[10/12] Samba ve Restic yedekleme yapılandırması' '[10/12] Samba and Restic backup configuration')"
printf '%s\n%s\n' "$ACCOUNT_PW" "$ACCOUNT_PW" | sudo smbpasswd -a -s "$USER_NAME" >/dev/null
echo "$(T "Restic kuruldu. Yedek, harici disk gerektirir; diski bağlayınca: sudo bash $BASE/tools/setup-restic-backup.sh" "Restic installed. Backups need an external disk; once you connect it: sudo bash $BASE/tools/setup-restic-backup.sh")"
TS_LOGIN_URL=""
if [[ "$TS_INSTALL_OK" == yes ]] && ! sudo tailscale ip -4 >/dev/null 2>&1; then
  TS_OUT="$(mktemp)"
  sudo timeout 15 tailscale up >"$TS_OUT" 2>&1 || true
  TS_LOGIN_URL="$(grep -Eo 'https://login\.tailscale\.com/[^[:space:]]+' "$TS_OUT" | head -n 1 || true)"
  rm -f "$TS_OUT"
fi

# Record only packages that were absent before this installer and are installed now.
INSTALLED_TMP="$(mktemp)"
while IFS= read -r PKG; do
  if ! sudo grep -Fxq "$PKG" /var/lib/homelab-installer/markers/preexisting-packages && dpkg-query -W -f='${db:Status-Status}' "$PKG" 2>/dev/null | grep -qx installed; then
    echo "$PKG" >> "$INSTALLED_TMP"
  fi
done < <(printf '%s\n' "${PACKAGE_CANDIDATES[@]}")
sudo install -o root -g root -m 0600 "$INSTALLED_TMP" /var/lib/homelab-installer/markers/installed-packages
rm -f "$INSTALLED_TMP"

SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
SERVER_IP="${SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
SERVER_IP="${SERVER_IP:-$(T 'SUNUCU-IP' 'SERVER-IP')}"
TS_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
SUMMARY_FILE="$LOG_DIR/kurulum-ozeti-$(date +%Y%m%d-%H%M%S).txt"
NTFY_URL_S=""; NTFY_TOPIC_S=""
if sudo test -f /etc/homelab-installer/ntfy.env; then
  while IFS='=' read -r K V; do
    if [[ "$K" == NTFY_TOPIC ]]; then NTFY_TOPIC_S="$V"; fi
  done < <(sudo cat /etc/homelab-installer/ntfy.env)
  NTFY_URL_S="http://$SERVER_IP:2586"
fi
if [[ "$FB_LOGIN_SET" == yes ]]; then
  FB_INFO="user: $ACCOUNT_USER   password: same"
else
  FB_INFO="user: admin   initial password: sudo docker logs filebrowser 2>&1 | grep -i password"
fi
(
  umask 077
  {
    if [[ $HL_LANG == tr ]]; then
    echo "HOMELAB KURULUM ÖZETİ - $(date '+%d.%m.%Y %H:%M')   (bu dosya gizli bilgi içerir; paylaşma)"
    echo "======================================================================"
    echo "Sunucu adı        : $(hostname)"
    echo "Yerel ağ IP       : $SERVER_IP"
    echo "Tailscale IP      : ${TS_IP:-bağlı değil}"
    if [[ -z "$TS_IP" && "$TS_INSTALL_OK" == yes ]]; then
      echo "Tailscale girişi  : ${TS_LOGIN_URL:-sudo tailscale up}   (tarayıcıda aç; çalışmazsa 'sudo tailscale up' ile yeni bağlantı al)"
    fi
    echo
    echo "YEREL WEB SAYFASI (sunucunun kendi tarayıcısında): http://127.0.0.1:8088"
    echo
    if [[ "$HOMELAB_OK" == yes ]]; then
      echo "TELEFON PANELİ (HomeLab ajanı $PB_VERSION, otomatik güncelleme kapalı): ayarlar sunucuda http://127.0.0.1:8765   kullanıcı: $ACCOUNT_USER   parola: kurulumda belirlediğin"
      echo "  Telefonu bağlamak için: 1) APK: GitHub deponda Actions > build-apk > homelab-panel-apk (HomeLab Panel) indirip telefona kur."
      echo "  2a) USB: telefonda Geliştirici seçenekleri > USB hata ayıklama açık, kabloyu sunucuya tak, telefondaki 'Bu bilgisayara izin ver' sorusunu onayla (adb kurulu; yeniden girişten sonra aktif)."
      echo "  2b) Wi-Fi: sunucuda 127.0.0.1:8765 > Settings > General > Wi-Fi & Tailscale > 'Pair a phone over Wi-Fi' ve QR kodu telefondan okut."
      echo "  Sayfalar: HomeLab, Servisler (konteynere dokun: başlat/durdur), Uyarılar, Sistem, İşlemler, Kısayollar. Kartlara dokununca büyük grafik açılır. Panel açıkken ekran hep açık kalır; telefon yeniden başlarsa uygulamayı elle aç (Android otomatik açmaya izin vermez). Şarjda sürekli açık kalması için: Geliştirici seçenekleri > Şarjdayken uyanık kal."
      echo "  Wi-Fi için TCP 8766 yerel ağda açık olmalıdır (UFW kullanılmıyor). Docker sayfasının çalışması için kullanıcın docker grubunda olmalı (yeniden girişten sonra)."
      echo
    fi
    echo "AĞDAN ERİŞİLENLER (aynı ağdaki bilgisayar/telefon):"
    echo "  Dockge       http://$SERVER_IP:5001"
    echo "  Beszel       http://$SERVER_IP:8090"
    echo "  Uptime Kuma  http://$SERVER_IP:3001"
    echo "  Scrutiny     http://$SERVER_IP:8081"
    echo "  Syncthing    http://127.0.0.1:8384   kullanıcı: $ACCOUNT_USER   parola: aynı"
    echo "  File Browser http://$SERVER_IP:8080   $FB_INFO"
    echo "  n8n          http://$SERVER_IP:5678"
    if [[ "$ADGUARD_INSTALL" == yes ]]; then echo "  AdGuard      http://$ADGUARD_IP:3000 (ilk kurulum) / http://$ADGUARD_IP:3002"; fi
    echo "  Samba        \\\\$SERVER_IP\\Paylasim   kullanıcı: $USER_NAME   parola: kurulumda sen belirledin"
    echo
    echo "UZAKTAN MASAÜSTÜ (RustDesk): ID: ${RUSTDESK_ID:-bulunamadı (RustDesk uygulamasında görünür)}   parola: kurulumda sen belirledin"
    if [[ -n "$NTFY_URL_S" ]]; then
      echo
      echo "BİLDİRİM (ntfy): adres: $NTFY_URL_S"
      echo "  kullanıcı: $ACCOUNT_USER   parola: aynı"
      echo "  konu     : $NTFY_TOPIC_S   (telefondaki ntfy uygulamasına bu adres, kullanıcı ve konuyu ekle)"
    fi
    echo
    echo "İLK GİRİŞTE hesabı SEN açan servisler (Dockge, Beszel, Uptime Kuma, n8n, AdGuard): kullanıcı adı olarak $ACCOUNT_USER ve aynı parolayı gir."
    echo
    if [[ -f /var/lib/homelab-installer/haos.status ]]; then
      echo
      echo "HOME ASSISTANT (sanal makine): $(sudo /usr/local/sbin/homelab-haos brief 2>/dev/null | cut -d'|' -f2)"
      echo "  Adres (ev ağı): http://$SERVER_IP:8123   (ilk açılış 10-20 dk sürebilir; hesabı sen oluşturursun: $ACCOUNT_USER + aynı parola önerilir)"
      echo "  Yönetim: sudo homelab-haos status|start|stop|restart|backup   (telefon panelinde Kısayollar'da da var)"
      echo "  Yapman gereken: Home Assistant'ı aç, hesabı oluştur; Zigbee/Matter için USB adaptör taktığında VM'e USB aktar (README: Home Assistant)."
    fi
    echo "Beszel Agent anahtarı: Beszel'de sistem ekleyince çıkar; sonra: bash $BASE/tools/configure-beszel-agent.sh"
    echo "Kurulum günlüğü: $LOG_FILE"
    else
    echo "HOMELAB INSTALLATION SUMMARY - $(date '+%d.%m.%Y %H:%M')   (this file contains secrets; do not share it)"
    echo "======================================================================"
    echo "Server name       : $(hostname)"
    echo "LAN IP            : $SERVER_IP"
    echo "Tailscale IP      : ${TS_IP:-not connected}"
    if [[ -z "$TS_IP" && "$TS_INSTALL_OK" == yes ]]; then
      echo "Tailscale login   : ${TS_LOGIN_URL:-sudo tailscale up}   (open it in a browser; if it does not work, get a new link with 'sudo tailscale up')"
    fi
    echo
    echo "LOCAL WEB PAGE (in the server's own browser): http://127.0.0.1:8088"
    echo
    if [[ "$HOMELAB_OK" == yes ]]; then
      echo "PHONE PANEL (HomeLab agent $PB_VERSION, automatic updates off): settings on the server at http://127.0.0.1:8765   user: $ACCOUNT_USER   password: the one you chose during setup"
      echo "  To connect the phone: 1) APK: in your GitHub repo go to Actions > build-apk > homelab-panel-apk (HomeLab Panel), download it and install it on the phone."
      echo "  2a) USB: on the phone enable Developer options > USB debugging, plug the cable into the server and accept the 'Allow this computer' prompt on the phone (adb is installed; active after you log in again)."
      echo "  2b) Wi-Fi: on the server open 127.0.0.1:8765 > Settings > General > Wi-Fi & Tailscale > 'Pair a phone over Wi-Fi' and scan the QR code with the phone."
      echo "  Pages: HomeLab, Services (tap a container: start/stop), Alerts, System, Processes, Shortcuts. Tapping a card opens a large chart. The screen stays on while the panel is open; if the phone restarts, open the app manually (Android does not allow auto-start). To keep it on while charging: Developer options > Stay awake while charging."
      echo "  For Wi-Fi, TCP 8766 must be open on the local network (UFW is not used). For the Docker page to work, your user must be in the docker group (after logging in again)."
      echo
    fi
    echo "REACHABLE OVER THE NETWORK (computer/phone on the same network):"
    echo "  Dockge       http://$SERVER_IP:5001"
    echo "  Beszel       http://$SERVER_IP:8090"
    echo "  Uptime Kuma  http://$SERVER_IP:3001"
    echo "  Scrutiny     http://$SERVER_IP:8081"
    echo "  Syncthing    http://127.0.0.1:8384   user: $ACCOUNT_USER   password: same"
    echo "  File Browser http://$SERVER_IP:8080   $FB_INFO"
    echo "  n8n          http://$SERVER_IP:5678"
    if [[ "$ADGUARD_INSTALL" == yes ]]; then echo "  AdGuard      http://$ADGUARD_IP:3000 (first setup) / http://$ADGUARD_IP:3002"; fi
    echo "  Samba        \\\\$SERVER_IP\\Paylasim   user: $USER_NAME   password: the one you chose during setup"
    echo
    echo "REMOTE DESKTOP (RustDesk): ID: ${RUSTDESK_ID:-not found (shown in the RustDesk app)}   password: the one you chose during setup"
    if [[ -n "$NTFY_URL_S" ]]; then
      echo
      echo "NOTIFICATIONS (ntfy): address: $NTFY_URL_S"
      echo "  user: $ACCOUNT_USER   password: same"
      echo "  topic    : $NTFY_TOPIC_S   (add this address, user and topic in the ntfy app on your phone)"
    fi
    echo
    echo "On FIRST LOGIN to the services where YOU create the account (Dockge, Beszel, Uptime Kuma, n8n, AdGuard): enter $ACCOUNT_USER as the username and the same password."
    echo
    if [[ -f /var/lib/homelab-installer/haos.status ]]; then
      echo
      echo "HOME ASSISTANT (virtual machine): $(sudo /usr/local/sbin/homelab-haos brief 2>/dev/null | cut -d'|' -f2)"
      echo "  Address (home network): http://$SERVER_IP:8123   (first start can take 10-20 min; you create the account yourself: $ACCOUNT_USER + the same password is recommended)"
      echo "  Manage: sudo homelab-haos status|start|stop|restart|backup   (also in the phone panel under Shortcuts)"
      echo "  To do: open Home Assistant and create the account; when you plug in a Zigbee/Matter USB adapter, pass it to the VM (README: Home Assistant)."
    fi
    echo "Beszel Agent key: it appears when you add a system in Beszel; then: bash $BASE/tools/configure-beszel-agent.sh"
    echo "Installation log: $LOG_FILE"
    fi
  } > "$SUMMARY_FILE"
)
echo "$(T '[11/12] Home Assistant OS sanal makinesi (KVM)' '[11/12] Home Assistant OS virtual machine (KVM)')"
sudo install -d -m 0755 /var/lib/homelab-installer
if [[ "$HAOS_INSTALL" == yes ]]; then
  # never stops the installation: problems are written to the status file and shown in the panel
  if ! HL_LANG="$HL_LANG" SUDO_USER="$USER_NAME" bash "$BASE/tools/setup-haos-vm.sh" 2>&1 | tee -a "$LOG_FILE"; then
    INSTALL_WARNINGS+=("$(T 'Home Assistant VM kurulumu hata verdi; günlüğe bak' 'The Home Assistant VM setup reported an error; see the log')")
  fi
  HAOS_LINE="$(sudo /usr/local/sbin/homelab-haos brief 2>/dev/null || true)"
  case "${HAOS_LINE%%|*}" in
    warn|error) INSTALL_WARNINGS+=("Home Assistant VM: ${HAOS_LINE#*|}") ;;
  esac
else
  echo "$(T 'Home Assistant VM atlandı (seçim). Sonradan: bash '"$BASE"'/tools/setup-haos-vm.sh' 'Home Assistant VM skipped (your choice). Later: bash '"$BASE"'/tools/setup-haos-vm.sh')"
  printf 'state=skipped\nreason=not selected during setup\n' | sudo tee /var/lib/homelab-installer/haos.status >/dev/null
fi

echo "$(T '[12/12] Son durum ve erişim bilgileri' '[12/12] Final status and access details')"
echo
if [[ $HL_LANG == tr ]]; then
echo "================ KURULUM TAMAMLANDI ================"
echo "Kurulum günlüğü: $LOG_FILE"
if ((${#INSTALL_WARNINGS[@]})); then
  echo "DURUM: Ana kurulum tamamlandı ancak isteğe bağlı bazı bileşenler kurulamadı."
  for WARNING in "${INSTALL_WARNINGS[@]}"; do echo "  - $WARNING"; done
  echo "Bu bileşenleri ve günlükleri tamamlanma mesajından önce kontrol et."
else
  echo "DURUM: Seçilen kurulum adımları tamamlandı."
fi
echo "Yerel web sayfası (sunucuda): http://127.0.0.1:8088"
if [[ "${HOMELAB_OK:-no}" == yes ]]; then echo "HomeLab ayarları (sunucuda): http://127.0.0.1:8765"; fi
echo "Dockge       : http://$SERVER_IP:5001"
echo "Beszel       : http://$SERVER_IP:8090"
echo "Uptime Kuma  : http://$SERVER_IP:3001"
echo "Scrutiny     : http://$SERVER_IP:8081"
echo "File Browser : http://$SERVER_IP:8080"
echo "n8n          : http://$SERVER_IP:5678"
echo "ntfy (bildirim): http://$SERVER_IP:2586  (telefon uygulamasına bu adresi ekle; kullanıcı/parola/konu: sudo cat /etc/homelab-installer/ntfy.env)"
echo "Ollama       : http://127.0.0.1:11434"
if [[ "$ADGUARD_INSTALL" == yes ]]; then echo "AdGuard ilk kurulum: http://$ADGUARD_IP:3000 ; sonrası: http://$ADGUARD_IP:3002"; fi
echo "Syncthing    : http://127.0.0.1:8384"
echo "Yerel ad     : http://$(hostname -s).local:8090 (mDNS destekleyen ağ/cihazlarda)"
echo "Samba        : \\\\$SERVER_IP\\Paylasim"
echo
echo "Kontrol: sudo docker ps"
echo "Beszel Agent ayarı: bash $BASE/tools/configure-beszel-agent.sh"
echo "Restic yedekleme:   sudo bash $BASE/tools/setup-restic-backup.sh"
echo "SSH anahtar girişi: bash $BASE/tools/harden-ssh.sh   (önce anahtarını ekle; kendini kilitlemeden doğrular)"
echo "Ayar sayfası girişini sıfırla: bash $BASE/tools/reset-web-login.sh"
echo
echo "================ İLK GİRİŞTE HEMEN YAP ================"
echo "Bu servislerin ilk hesabını SEN oluştur (ilk açan kişi yönetici olur). Kullanıcı adı: $ACCOUNT_USER, parola: kurulumda belirlediğin aynı parola:"
echo "  Dockge       : http://$SERVER_IP:5001  -> yönetici hesabı oluştur"
echo "  Beszel       : http://$SERVER_IP:8090  -> yönetici hesabı oluştur"
echo "  Uptime Kuma  : http://$SERVER_IP:3001  -> yönetici hesabı oluştur"
echo "  n8n          : http://$SERVER_IP:5678  -> sahip (owner) hesabı oluştur"
echo "  File Browser : $FB_INFO"
echo "  Scrutiny     : giriş ekranı YOKTUR; yalnızca yerel ağda kalmalı."
echo "  AdGuard      : kurulum sihirbazında yönetici hesabı oluştur"
if [[ "${LAN_LOCK_OK:-no}" == yes ]]; then
  echo "Docker portları internetten gelen yeni IPv4 bağlantılarına kapatıldı (yerel ağ ve Tailscale açık)."
else
  echo "UYARI: Docker port kilidi doğrulanamadı; portlar LAN dışına açık olabilir. Router'da port yönlendirme yapma."
fi
echo "Beszel Agent (45876) ve SSH/Samba ana makine servisleridir; router'dan yönlendirme yapma."
echo "UFW etkinleştirilmedi; SSH/RustDesk erişimini kilitlememek için."
echo "Cloudflare/DNS/router ayarlarına dokunulmadı."
echo "ÖNEMLİ: Router'da servis portlarını internete yönlendirme."
else
echo "================ INSTALLATION COMPLETE ================"
echo "Installation log: $LOG_FILE"
if ((${#INSTALL_WARNINGS[@]})); then
  echo "STATUS: The main installation finished, but some optional components could not be installed."
  for WARNING in "${INSTALL_WARNINGS[@]}"; do echo "  - $WARNING"; done
  echo "Check these components and the logs before treating the installation as complete."
else
  echo "STATUS: The selected installation steps are complete."
fi
echo "Local web page (on the server): http://127.0.0.1:8088"
if [[ "${HOMELAB_OK:-no}" == yes ]]; then echo "HomeLab settings (on the server): http://127.0.0.1:8765"; fi
echo "Dockge       : http://$SERVER_IP:5001"
echo "Beszel       : http://$SERVER_IP:8090"
echo "Uptime Kuma  : http://$SERVER_IP:3001"
echo "Scrutiny     : http://$SERVER_IP:8081"
echo "File Browser : http://$SERVER_IP:8080"
echo "n8n          : http://$SERVER_IP:5678"
echo "ntfy (notifications): http://$SERVER_IP:2586  (add this address in the phone app; user/password/topic: sudo cat /etc/homelab-installer/ntfy.env)"
echo "Ollama       : http://127.0.0.1:11434"
if [[ "$ADGUARD_INSTALL" == yes ]]; then echo "AdGuard first setup: http://$ADGUARD_IP:3000 ; afterwards: http://$ADGUARD_IP:3002"; fi
echo "Syncthing    : http://127.0.0.1:8384"
echo "Local name   : http://$(hostname -s).local:8090 (on networks/devices that support mDNS)"
echo "Samba        : \\\\$SERVER_IP\\Paylasim"
echo
echo "Check:   sudo docker ps"
echo "Beszel Agent setup: bash $BASE/tools/configure-beszel-agent.sh"
echo "Restic backup:      sudo bash $BASE/tools/setup-restic-backup.sh"
echo "SSH key login: bash $BASE/tools/harden-ssh.sh   (add your key first; it verifies without locking you out)"
echo "Reset the settings page login: bash $BASE/tools/reset-web-login.sh"
echo
echo "================ DO THIS RIGHT AFTER FIRST LOGIN ================"
echo "Create the first account of these services YOURSELF (whoever opens them first becomes the admin). Username: $ACCOUNT_USER, password: the same password you chose during setup:"
echo "  Dockge       : http://$SERVER_IP:5001  -> create the admin account"
echo "  Beszel       : http://$SERVER_IP:8090  -> create the admin account"
echo "  Uptime Kuma  : http://$SERVER_IP:3001  -> create the admin account"
echo "  n8n          : http://$SERVER_IP:5678  -> create the owner account"
echo "  File Browser : $FB_INFO"
echo "  Scrutiny     : has NO login screen; it must stay on the local network only."
echo "  AdGuard      : create the admin account in the setup wizard"
if [[ "${LAN_LOCK_OK:-no}" == yes ]]; then
  echo "Docker ports are closed to new IPv4 connections from the internet (local network and Tailscale stay open)."
else
  echo "WARNING: The Docker port lock could not be verified; ports may be open beyond the LAN. Do not set up port forwarding on the router."
fi
echo "Beszel Agent (45876) and SSH/Samba are host services; do not forward them on the router."
echo "UFW was not enabled, so as not to lock you out of SSH/RustDesk."
echo "Cloudflare/DNS/router settings were not touched."
echo "IMPORTANT: Do not forward service ports to the internet on the router."
fi

unset ACCOUNT_PW
sleep 1
echo
echo "$(T "Özet dosyası (gizli bilgi içerir): $SUMMARY_FILE" "Summary file (contains secrets): $SUMMARY_FILE")"
echo "$(T 'Aşağıdaki özet güvenlik için kurulum günlüğüne yazılmaz; yalnızca ekranda ve özet dosyasında bulunur.' 'For security, the summary below is not written to the installation log; it is only on screen and in the summary file.')"
echo
cat "$SUMMARY_FILE" >&3
