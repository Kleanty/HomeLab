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
if [[ $EUID -eq 0 ]]; then
  echo "$(T 'Bu aracı sudo ile değil normal kullanıcıyla çalıştır: bash TANI.sh' 'Run this tool as a normal user, not with sudo: bash TANI.sh')" >&2
  exit 1
fi
LOG_DIR="$HOME/HomeLab_Logs"
mkdir -p "$LOG_DIR"
chmod 0700 "$LOG_DIR"
REPORT="$LOG_DIR/tani-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$REPORT") 2>&1
trap 'rc=$?; echo "$(T "TANI HATASI: satır $LINENO, çıkış kodu $rc, komut: $BASH_COMMAND" "DIAGNOSTIC ERROR: line $LINENO, exit code $rc, command: $BASH_COMMAND")" >&2; echo "$(T Rapor Report): $REPORT" >&2; exit "$rc"' ERR

BASE=/srv/homelab
STACKS="$BASE/compose"

echo "$(T 'HOMELAB - OTOMATİK TANI RAPORU' 'HOMELAB - AUTOMATIC DIAGNOSTIC REPORT')"
echo "$(T Tarih Date): $(date --iso-8601=seconds)"
echo "$(T Bilgisayar Computer): $(hostname)"
echo "$(T Kullanıcı User): $(id -un)"
echo "$(T Rapor Report): $REPORT"
echo
sudo -v

section() { printf '\n========== %s ==========\n' "$1"; }
section "$(T 'SİSTEM' 'SYSTEM')"
cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_CODENAME)=' || true
uname -a
df -h /
free -h

section "$(T 'BAŞARISIZ SYSTEMD SERVİSLERİ' 'FAILED SYSTEMD SERVICES')"
systemctl --failed --no-pager || true

section "$(T 'TEMEL SERVİSLER' 'CORE SERVICES')"
for unit in docker ssh smbd fail2ban avahi-daemon "syncthing@$(id -un)" homelab-docker-lan-only; do
  printf '\n--- %s ---\n' "$unit"
  systemctl is-active "$unit" 2>/dev/null || true
  systemctl is-enabled "$unit" 2>/dev/null || true
done

section "HOMELAB"
systemctl --user is-active homelab-agent.service 2>/dev/null || echo "$(T 'HomeLab kullanıcı servisi çalışmıyor veya kurulu değil.' 'The HomeLab user service is not running or not installed.')"
curl -fsS --max-time 2 http://127.0.0.1:8765/api/info >/dev/null 2>&1 && echo "$(T 'HomeLab ajanı yanıt veriyor (8765).' 'The HomeLab agent is responding (8765).')" || echo "$(T 'HomeLab ajanı yanıt vermiyor.' 'The HomeLab agent is not responding.')"

section "$(T 'UYKU ENGELİ' 'SLEEP BLOCK')"
systemctl is-enabled sleep.target suspend.target hibernate.target 2>/dev/null || true
if [[ -f /etc/systemd/logind.conf.d/91-homelab-installer-no-sleep.conf ]]; then echo "$(T 'logind uyku engeli: var' 'logind sleep block: present')"; else echo "$(T 'logind uyku engeli: yok' 'logind sleep block: absent')"; fi

section "DOCKER"
if command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
  sudo docker version --format 'Client={{.Client.Version}} Server={{.Server.Version}}' 2>&1 || true
  sudo docker compose version 2>&1 || true
  sudo docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || true
else
  echo "$(T 'Docker kurulu değil veya daemon çalışmıyor.' 'Docker is not installed or the daemon is not running.')"
fi

section "$(T 'DONANIM VE OLLAMA' 'HARDWARE AND OLLAMA')"
if command -v lspci >/dev/null 2>&1; then
  lscpu | grep -E '^(Model name|CPU\(s\)):' | head -n 2 || true
  free -h | awk 'NR == 2 {print "RAM: " $2}'
  lspci -nn | grep -Ei 'VGA compatible controller|3D controller|Display controller' || echo "$(T 'Ekran kartı PCI listesinde bulunamadı.' 'No graphics card found in the PCI list.')"
fi
if sudo docker inspect ollama >/dev/null 2>&1; then
  sudo docker exec ollama ollama list 2>&1 || true
else
  echo "$(T 'Ollama konteyneri çalışmıyor.' 'The Ollama container is not running.')"
fi

section "$(T 'DOCKER PORT KİLİDİ (LAN-ONLY)' 'DOCKER PORT LOCK (LAN-ONLY)')"
sudo iptables -w -S HOMELAB-LAN-ONLY 2>&1 | head -n 12 || echo "$(T 'Kilit zinciri yok (homelab-docker-lan-only etkin değil).' 'No lock chain (homelab-docker-lan-only is not active).')"

section "$(T 'COMPOSE DOSYALARI' 'COMPOSE FILES')"
for stack in dockge monitoring cloud ai storage web adguard monitoring-agent notify; do
  file="$STACKS/$stack/compose.yaml"
  [[ -f "$file" ]] || { echo "$stack: $(T 'dosya yok (isteğe bağlı/henüz oluşturulmamış olabilir)' 'file missing (may be optional/not created yet)')"; continue; }
  echo -n "$stack: "
  if [[ -f "$STACKS/$stack/.env" ]]; then
    if sudo docker compose --env-file "$STACKS/$stack/.env" -f "$file" config -q >/dev/null 2>&1; then echo "YAML/Compose OK"; else echo "$(T 'HATA - docker compose config başarısız' 'ERROR - docker compose config failed')"; fi
  else
    if sudo docker compose -f "$file" config -q >/dev/null 2>&1; then echo "YAML/Compose OK"; else echo "$(T 'HATA - docker compose config başarısız veya .env eksik' 'ERROR - docker compose config failed or .env is missing')"; fi
  fi
done

section "$(T 'PORT DİNLEYİCİLERİ' 'PORT LISTENERS')"
ss -Hlnptu 2>/dev/null | grep -E ':(22|53|80|443|3000|3001|3002|5001|5678|8080|8081|8088|8090|2586|45876|8765|8766)([[:space:]]|$)' || echo "$(T 'İzlenen portlarda dinleyici bulunamadı veya ss bilgisi kısıtlı.' 'No listener found on the monitored ports, or ss information is restricted.')"

section "RESTIC"
if command -v restic >/dev/null 2>&1; then
  restic version
else
  echo "$(T 'Restic kurulu değil.' 'Restic is not installed.')"
fi
for unit in homelab-restic-backup.timer homelab-restic-check.timer homelab-health-check.timer; do
  printf '%s: ' "$unit"
  systemctl is-active "$unit" 2>/dev/null || true
done
if sudo test -f /etc/restic/homelab.env; then
  echo "$(T 'Restic yapılandırması mevcut (parola/depo yolu rapora yazdırılmadı).' 'The Restic configuration exists (password/repository path were not written to the report).')"
else
  echo "$(T 'Restic deposu henüz yapılandırılmamış.' 'The Restic repository has not been configured yet.')"
fi

section "BESZEL AGENT"
if sudo docker inspect beszel-agent >/dev/null 2>&1; then
  sudo docker inspect --format "$(T Durum Status)={{.State.Status}}" beszel-agent || true
else
  echo "$(T 'Agent henüz kurulmamış; Hub'\''da Add System sonrası configure-beszel-agent.sh çalıştır.' 'The agent is not installed yet; run configure-beszel-agent.sh after Add System in the Hub.')"
fi

echo
echo "$(T 'TANI TAMAMLANDI. Rapor' 'DIAGNOSTIC COMPLETE. Report'): $REPORT"
echo "$(T 'Bu rapor parola/token değerlerini özellikle yazdırmaz. Paylaşmadan önce yerel IP ve bilgisayar adını gözden geçir.' 'This report deliberately does not print password/token values. Review the local IP and computer name before sharing it.')"
