#!/usr/bin/env bash
set -Eeuo pipefail
# Language support: shared lang.sh (next to this script, then /srv/homelab/tools), tiny fallback otherwise.
_HL_SELF_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")"
if [[ -r "$_HL_SELF_DIR/lang.sh" ]]; then
  # shellcheck source=/dev/null
  . "$_HL_SELF_DIR/lang.sh"
elif [[ -r /srv/homelab/tools/lang.sh ]]; then
  # shellcheck source=/dev/null
  . /srv/homelab/tools/lang.sh
else
  hl_lang_init() {
    case "${HL_LANG:-}" in tr|en) return 0 ;; esac
    HL_LANG="$(head -c 2 /etc/homelab-installer/lang 2>/dev/null || true)"
    case "$HL_LANG" in tr|en) ;; *) HL_LANG=en ;; esac
  }
  T() { if [[ "${HL_LANG:-en}" == tr ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
fi
hl_lang_init
LOG_DIR="$HOME/HomeLab_Logs"
mkdir -p "$LOG_DIR"
chmod 0700 "$LOG_DIR"
LOG_FILE="$LOG_DIR/beszel-agent-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'rc=$?; echo "$(T "HATA: Beszel Agent ayarı satır $LINENO üzerinde durdu (çıkış kodu: $rc). Komut: $BASH_COMMAND. Günlük: $LOG_FILE" "ERROR: Beszel Agent setup stopped at line $LINENO (exit code: $rc). Command: $BASH_COMMAND. Log: $LOG_FILE")" >&2; exit "$rc"' ERR
BASE=/srv/homelab
STACK="$BASE/compose/monitoring-agent"

if [[ $EUID -eq 0 ]]; then
  echo "$(T 'Bu aracı sudo ile değil normal kullanıcıyla çalıştır: bash configure-beszel-agent.sh' 'Run this tool as a normal user, not with sudo: bash configure-beszel-agent.sh')" >&2
  exit 1
fi
[[ -f "$STACK/compose.yaml" ]] || { echo "$(T 'Agent Compose dosyası bulunamadı. Önce KUR.sh çalıştır.' 'Agent Compose file not found. Run KUR.sh first.')" >&2; exit 1; }
command -v docker >/dev/null || { echo "$(T 'Docker bulunamadı.' 'Docker not found.')" >&2; exit 1; }

if sudo test -e "$STACK/.env"; then
  echo "$(T 'Mevcut Beszel Agent kimlik bilgileri bulundu.' 'Existing Beszel Agent credentials found.')"
  read -r -p "$(T 'Bu kimlik bilgileri değiştirilsin mi? [e/H]' 'Replace these credentials? [y/N]'): " REPLACE
  [[ "$REPLACE" =~ ^[EeYy]$ ]] || { echo "$(T 'Mevcut dosya korundu; işlem iptal edildi.' 'The existing file was kept; operation cancelled.')"; exit 0; }
fi

if [[ $HL_LANG == tr ]]; then
  cat <<'MSG'
BESZEL AGENT BAĞLANTISI
----------------------
Önce Beszel Hub'ı aç: http://SUNUCU-IP:8090
Add System bölümünde yeni sistem oluştur ve ekranda verilen KEY ve TOKEN değerlerini al.
Bu araç o değerleri korumalı .env dosyasına yazar ve Agent konteynerini başlatır.
MSG
else
  cat <<'MSG'
BESZEL AGENT CONNECTION
-----------------------
First open the Beszel Hub: http://SERVER-IP:8090
In the Add System section create a new system and copy the KEY and TOKEN values shown on screen.
This tool writes those values to a protected .env file and starts the Agent container.
MSG
fi
read -r -p "$(T "Beszel Hub'daki KEY" 'KEY from the Beszel Hub'): " KEY
read -r -s -p "$(T "Beszel Hub'daki TOKEN" 'TOKEN from the Beszel Hub'): " TOKEN; echo
[[ -n "$KEY" && -n "$TOKEN" ]] || { echo "$(T 'KEY ve TOKEN boş olamaz.' 'KEY and TOKEN cannot be empty.')" >&2; exit 1; }
case "$KEY$TOKEN" in
  *'"'*|*'\'*|*'$'*|*$'\n'*)
    echo "$(T "KEY/TOKEN beklenmeyen karakter içeriyor. Hub'dan tekrar kopyala." 'KEY/TOKEN contains unexpected characters. Copy it again from the Hub.')" >&2
    exit 1
    ;;
esac
TMP_ENV="$(mktemp)"
trap 'rm -f "$TMP_ENV"' EXIT
chmod 0600 "$TMP_ENV"
printf 'BESZEL_AGENT_KEY="%s"\nBESZEL_AGENT_TOKEN="%s"\n' "$KEY" "$TOKEN" > "$TMP_ENV"
sudo install -o root -g root -m 0600 "$TMP_ENV" "$STACK/.env"
rm -f "$TMP_ENV"
trap - EXIT
unset KEY TOKEN
cd "$STACK"
sudo docker compose -f compose.yaml config -q
sudo docker compose --progress quiet -f compose.yaml up -d --quiet-pull

echo
echo "$(T "Agent konteyneri başlatıldı. Beszel Hub'daki sistem kaydında bu sunucunun LAN IP adresini ve 45876 portunu kullan." 'The Agent container was started. In the system entry in the Beszel Hub, use this server'\''s LAN IP address and port 45876.')"
echo "$(T 'Beszel Agent günlüğü' 'Beszel Agent log'): $LOG_FILE"
echo "$(T 'Durum' 'Status'): sudo docker ps --filter name=beszel-agent"
