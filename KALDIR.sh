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
LOG_FILE="$LOG_DIR/kaldirma-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
on_error() {
  local rc="$?" line="$1" cmd="$2"
  trap - ERR
  echo >&2
  echo "$(T "HATA: Kaldırma $line. satırda durdu (çıkış kodu: $rc)." "ERROR: Uninstall stopped at line $line (exit code: $rc).")" >&2
  echo "$(T 'Çalıştırılan komut' 'Command that was running'): $cmd" >&2
  echo "$(T 'Ayrıntılı günlük' 'Detailed log'): $LOG_FILE" >&2
  exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# Removes the known services created by the HomeLab installer.
# By default it does not delete user data or operating system packages.

if [[ $EUID -eq 0 ]]; then
  echo "$(T 'Bu dosyayı sudo ile değil normal kullanıcıyla çalıştır: bash KALDIR.sh' 'Run this file as a normal user, not with sudo: bash KALDIR.sh')" >&2
  exit 1
fi

SUDO_USER_NAME="$(id -un)"
BASE=/srv/homelab
STACKS="$BASE/compose"

if [[ $HL_LANG == tr ]]; then
cat <<'BANNER'
============================================================
 HOMELAB - KONTROLLÜ KALDIRMA ARACI
============================================================
Bu araç yalnızca HomeLab kurulumunda kullanılan bilinen
servisleri, paneli ve yardımcı yapılandırmaları hedefler.

Varsayılan davranış:
- Bilinen HomeLab konteynerlerini ve Compose ağlarını durdurur/kaldırır.
- Restic zamanlayıcılarını kaldırır.
- HomeLab'e ait sudoers, Fail2ban, journald ve Samba paylaşım
  yapılandırmalarını kaldırır.
- /srv/homelab içindeki dosyaları varsayılan olarak KORUR.
- Docker / SSH / Samba / Syncthing gibi sistem paketlerini
  varsayılan olarak KALDIRMAZ.
- Harici Restic yedek deposunu hiçbir koşulda silmez.

UYARI: Paket kaldırma seçeneği SSH erişimini ve diğer ağ
servislerini etkileyebilir. Uzaktan SSH oturumunda çalıştırma.
BANNER
else
cat <<'BANNER'
============================================================
 HOMELAB - GUIDED UNINSTALL TOOL
============================================================
This tool only targets the known services, the panel and the
helper configurations used by the HomeLab installation.

Default behavior:
- Stops/removes the known HomeLab containers and Compose networks.
- Removes the Restic timers.
- Removes the HomeLab sudoers, Fail2ban, journald and Samba share
  configurations.
- KEEPS the files inside /srv/homelab by default.
- Does NOT remove system packages such as Docker / SSH / Samba /
  Syncthing by default.
- Never deletes the external Restic backup repository.

WARNING: The package removal option may affect SSH access and other
network services. Do not run it over a remote SSH session.
BANNER
fi

echo
read -r -p "$(T 'Devam etmek için TAM OLARAK YES yaz' 'To continue, type EXACTLY YES'): " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "$(T 'İptal edildi.' 'Cancelled.')"; exit 0; }
sudo -v

remove_compose_stack() {
  local name="$1" file="$2" envfile="${3:-}"
  if sudo test -f "/var/lib/homelab-installer/markers/compose-foreign-$name"; then
    echo "[Docker] $name: $(T 'Compose dosyası kurulumdan önce vardı; dokunulmadı.' 'the Compose file existed before the installation; left untouched.')"
    return 0
  fi
  if sudo test -f "$file" && sudo docker info >/dev/null 2>&1; then
    echo "[Docker] $(T "$name durduruluyor..." "Stopping $name...")"
    if [[ -n "$envfile" ]] && sudo test -f "$envfile"; then
      sudo docker compose --env-file "$envfile" -f "$file" down --remove-orphans || \
        echo "$(T "UYARI: $name Compose projesi tamamen kaldırılamadı; konteyner kontrolü ayrıca yapılacak." "WARNING: Compose project $name could not be removed completely; containers will be checked separately.")"
    else
      sudo docker compose -f "$file" down --remove-orphans || \
        echo "$(T "UYARI: $name Compose projesi tamamen kaldırılamadı; konteyner kontrolü ayrıca yapılacak." "WARNING: Compose project $name could not be removed completely; containers will be checked separately.")"
    fi
  fi
}

echo
echo "[1/7] $(T 'HomeLab konteynerleri ve ağları' 'HomeLab containers and networks')"
if command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
  remove_compose_stack dockge "$STACKS/dockge/compose.yaml"
  remove_compose_stack monitoring "$STACKS/monitoring/compose.yaml"
  remove_compose_stack cloud "$STACKS/cloud/compose.yaml"
  remove_compose_stack ai "$STACKS/ai/compose.yaml"
  remove_compose_stack storage "$STACKS/storage/compose.yaml"
  remove_compose_stack web "$STACKS/web/compose.yaml"
  remove_compose_stack notify "$STACKS/notify/compose.yaml"
  remove_compose_stack adguard "$STACKS/adguard/compose.yaml" "$STACKS/adguard/.env"
  remove_compose_stack monitoring-agent "$STACKS/monitoring-agent/compose.yaml" "$STACKS/monitoring-agent/.env"

  # Even if the Compose file is deleted/broken, only this package's fixed container names are targeted.
  for c in dockge beszel uptime-kuma filebrowser ollama n8n scrutiny caddy adguardhome beszel-agent ntfy; do
    if sudo docker container inspect "$c" >/dev/null 2>&1; then
      # Remove only if the Compose working directory is one of this installation's stack folders and the file is ours.
      WD="$(sudo docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c" 2>/dev/null || true)"
      if [[ "$WD" == "$STACKS"/* ]] && ! sudo test -f "/var/lib/homelab-installer/markers/compose-foreign-${WD##*/}"; then
        sudo docker rm -f "$c"
      else
        echo "[Docker] $(T "$c bu kurulumun Compose yığınına ait görünmüyor; dokunulmadı." "$c does not appear to belong to this installation's Compose stack; left untouched.")"
      fi
    fi
  done
else
  echo "$(T 'Docker çalışmıyor veya kurulu değil; konteyner adımı atlandı.' 'Docker is not running or not installed; container step skipped.')"
fi

echo
echo "[2/7] $(T 'Restic zamanlayıcıları' 'Restic timers')"

# Remove Restic units only if the installer created them (not pre-existing).
if sudo test -f /var/lib/homelab-installer/markers/restic-created; then
  for unit in homelab-restic-backup.service homelab-restic-backup.timer homelab-restic-check.service homelab-restic-check.timer; do
    sudo systemctl disable --now "$unit" >/dev/null 2>&1 || true
  done
  sudo rm -f /etc/systemd/system/homelab-restic-backup.service \
    /etc/systemd/system/homelab-restic-backup.timer \
    /etc/systemd/system/homelab-restic-check.service \
    /etc/systemd/system/homelab-restic-check.timer \
    /usr/local/sbin/homelab-restic-backup
fi
sudo systemctl daemon-reload
sudo systemctl reset-failed >/dev/null 2>&1 || true

# Docker port lock (LAN-only) rules and unit
if sudo test -x /usr/local/sbin/homelab-docker-lan-only; then
  sudo /usr/local/sbin/homelab-docker-lan-only remove || true
fi
sudo systemctl disable --now homelab-docker-lan-only.service >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/homelab-docker-lan-only.service /usr/local/sbin/homelab-docker-lan-only

# Restic password and local cache are deleted; the external RESTIC_REPOSITORY is kept.
if sudo test -f /var/lib/homelab-installer/markers/restic-created; then
  if sudo test -f /etc/restic/homelab.env; then
    REPO_PATH="$(sudo sed -n 's/^RESTIC_REPOSITORY=//p' /etc/restic/homelab.env | head -n1)"
    [[ -z "$REPO_PATH" ]] || echo "$(T 'Harici Restic deposu korunacak' 'The external Restic repository will be kept'): $REPO_PATH"
  fi
  sudo rm -f /etc/restic/homelab.env /etc/restic/homelab-password
  sudo rmdir /etc/restic 2>/dev/null || true
  sudo rm -rf /var/lib/homelab-restic
else
  echo "$(T 'Restic yapılandırması bu paket tarafından oluşturulmamış; korunuyor.' 'The Restic configuration was not created by this package; keeping it.')"
fi

# Restore the Cinnamon power button setting if the previous value was saved.
POWER_BACKUP=/var/lib/homelab-installer/cinnamon-button-power.before
if sudo test -f "$POWER_BACKUP" && command -v gsettings >/dev/null 2>&1; then
  PREVIOUS_POWER_ACTION="$(sudo cat "$POWER_BACKUP")"
  if [[ -n "$PREVIOUS_POWER_ACTION" ]] && gsettings set org.cinnamon.settings-daemon.plugins.power button-power "$PREVIOUS_POWER_ACTION" 2>/dev/null; then
    echo "$(T 'Cinnamon güç düğmesi önceki ayarına döndürüldü.' 'Cinnamon power button restored to its previous setting.')"
  else
    echo "$(T 'UYARI: Cinnamon güç düğmesi önceki ayarına otomatik döndürülemedi.' 'WARNING: Could not automatically restore the Cinnamon power button to its previous setting.')"
  fi
fi
if sudo test -f /var/lib/homelab-installer/markers/logind-power-created; then
  sudo rm -f /etc/systemd/logind.conf.d/90-homelab-installer-power-button.conf
  sudo rmdir /etc/systemd/logind.conf.d 2>/dev/null || true
fi
# HomeLab agent: removed only if this installation installed it; user settings and phone pairings are not deleted.
if sudo test -f /var/lib/homelab-installer/markers/homelab-installed; then
  PB_APP="$(sudo cat /var/lib/homelab-installer/homelab-app 2>/dev/null || true)"
  systemctl --user disable --now homelab-agent.service >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/homelab-agent.service"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if [[ "$PB_APP" == /*/HomeLab/app && -d "$PB_APP" ]]; then rm -rf "$PB_APP"; fi
  sudo rm -f /var/lib/homelab-installer/homelab-app
  echo "$(T 'HomeLab ajanı kaldırıldı (ayarlar ve telefon eşleşmeleri korundu).' 'HomeLab agent removed (settings and phone pairings were kept).')"
fi
# Home Assistant VM: it holds the smart-home data, so it is removed only after a separate confirmation.
if sudo test -f /var/lib/homelab-installer/haos.status && command -v virsh >/dev/null 2>&1 && sudo virsh -c qemu:///system dominfo homeassistant >/dev/null 2>&1; then
  echo
  echo "$(T 'Home Assistant sanal makinesi bulundu. Silinirse tüm Home Assistant verisi (cihazlar, otomasyonlar, geçmiş) kaybolur.' 'A Home Assistant virtual machine was found. If it is deleted, all Home Assistant data (devices, automations, history) is lost.')"
  read -r -p "$(T 'Silmek için TAM OLARAK DELETE yaz (boş bırak = koru): ' 'To delete it, type EXACTLY DELETE (empty = keep it): ')" HAOS_CONFIRM
  if [[ "$HAOS_CONFIRM" == "DELETE" ]]; then
    sudo virsh -c qemu:///system destroy homeassistant >/dev/null 2>&1 || true
    sudo virsh -c qemu:///system undefine homeassistant --nvram >/dev/null 2>&1 || sudo virsh -c qemu:///system undefine homeassistant >/dev/null 2>&1 || true
    sudo rm -f /var/lib/libvirt/images/haos.qcow2
    sudo systemctl disable --now homelab-ha-forward.service homelab-libvirt-fw.service >/dev/null 2>&1 || true
    sudo rm -f /etc/systemd/system/homelab-ha-forward.service /etc/systemd/system/homelab-libvirt-fw.service /etc/sudoers.d/homelab-haos /usr/local/sbin/homelab-haos /var/lib/homelab-installer/haos.status /var/lib/homelab-installer/haos.desired
    sudo systemctl daemon-reload
    echo "$(T 'Home Assistant sanal makinesi silindi. (KVM/libvirt paketleri kaldırılmadı.)' 'The Home Assistant VM was deleted. (The KVM/libvirt packages were not removed.)')"
  else
    echo "$(T 'Home Assistant sanal makinesi korundu.' 'The Home Assistant VM was kept.')"
  fi
fi
# Undo the sleep block, auto-login and the saved Cinnamon sleep settings.
for SLEEP_TARGET in sleep suspend hibernate hybrid-sleep; do
  if sudo test -f "/var/lib/homelab-installer/markers/sleep-masked-$SLEEP_TARGET"; then
    sudo systemctl unmask "$SLEEP_TARGET.target" >/dev/null 2>&1 || true
  fi
done
if sudo test -f /var/lib/homelab-installer/markers/logind-nosleep-created; then
  sudo rm -f /etc/systemd/logind.conf.d/91-homelab-installer-no-sleep.conf
  sudo rmdir /etc/systemd/logind.conf.d 2>/dev/null || true
  sudo systemctl kill -s HUP systemd-logind >/dev/null 2>&1 || true
fi
if sudo test -f /var/lib/homelab-installer/gsettings-sleep.before && command -v gsettings >/dev/null 2>&1; then
  while IFS='|' read -r SCHEMA KEY VALUE; do
    [[ -n "$SCHEMA" && -n "$KEY" ]] && gsettings set "$SCHEMA" "$KEY" "$VALUE" 2>/dev/null || true
  done < <(sudo cat /var/lib/homelab-installer/gsettings-sleep.before)
  sudo rm -f /var/lib/homelab-installer/gsettings-sleep.before
  echo "$(T 'Cinnamon uyku ayarları önceki değerlerine döndürüldü.' 'Cinnamon sleep settings restored to their previous values.')"
fi
if sudo test -f /var/lib/homelab-installer/markers/autologin-created; then
  sudo rm -f /etc/lightdm/lightdm.conf.d/70-homelab-installer-autologin.conf
  sudo rmdir /etc/lightdm/lightdm.conf.d 2>/dev/null || true
fi
# Helper tools live only under /srv/homelab/tools; the whole data directory is kept.
sudo rm -f "$BASE/tools/setup-restic-backup.sh" "$BASE/tools/configure-beszel-agent.sh" "$BASE/tools/reset-web-login.sh" "$BASE/tools/harden-ssh.sh" "$BASE/tools/lang.sh"

# Notification system and health check
sudo systemctl disable --now homelab-health-check.timer >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/homelab-health-check.timer /etc/systemd/system/homelab-health-check.service \
  /etc/systemd/system/homelab-notify-failure@.service /usr/local/sbin/homelab-notify /usr/local/sbin/homelab-health-check
sudo rm -rf /etc/homelab-installer
sudo rm -f /var/lib/homelab-installer/health-state
sudo systemctl daemon-reload

# Automatic security update setting (only if this installation created it)
if sudo test -f /var/lib/homelab-installer/markers/unattended-created; then
  sudo rm -f /etc/apt/apt.conf.d/52homelab-unattended-upgrades
fi
if [[ -f /etc/ssh/sshd_config.d/10-homelab-hardening.conf ]]; then
  echo "$(T 'Not: SSH sertleştirme ayarı (parola girişi kapalı) bilerek korundu. Geri almak için' 'Note: the SSH hardening setting (password login disabled) was intentionally kept. To revert'): sudo rm /etc/ssh/sshd_config.d/10-homelab-hardening.conf && sudo systemctl reload ssh"
fi
sudo rmdir "$BASE/tools" 2>/dev/null || true

echo
echo "[3/7] $(T "HomeLab'e ait sistem yapılandırmaları" 'System configurations that belong to HomeLab')"
if sudo test -f /var/lib/homelab-installer/markers/docker-group-added \
  && getent group docker >/dev/null 2>&1; then
  if sudo gpasswd -d "$SUDO_USER_NAME" docker >/dev/null; then
    echo "$(T 'Bu kurulumun eklediği Docker grup üyeliği kaldırıldı.' 'Docker group membership added by this installation was removed.')"
  else
    echo "$(T "UYARI: Docker grup üyeliği kaldırılamadı; gerekirse elle kaldır: sudo gpasswd -d $SUDO_USER_NAME docker" "WARNING: Could not remove Docker group membership; remove it manually if needed: sudo gpasswd -d $SUDO_USER_NAME docker")"
  fi
fi
if sudo test -f /var/lib/homelab-installer/markers/linger-added; then
  sudo loginctl disable-linger "$SUDO_USER_NAME" || \
    echo "$(T 'UYARI: Bu kurulumun eklediği lingering ayarı kaldırılamadı.' 'WARNING: Could not remove the lingering setting added by this installation.')"
fi
if sudo test -f /var/lib/homelab-installer/markers/fail2ban-created; then
  sudo rm -f /etc/fail2ban/jail.d/homelab-sshd.local
  sudo rmdir /etc/fail2ban/jail.d 2>/dev/null || true
fi
if sudo test -f /var/lib/homelab-installer/markers/journald-created; then
  sudo rm -f /etc/systemd/journald.conf.d/homelab.conf
  sudo rmdir /etc/systemd/journald.conf.d 2>/dev/null || true
fi
if sudo systemctl is-active --quiet fail2ban 2>/dev/null; then sudo systemctl restart fail2ban || true; fi
if sudo systemctl is-active --quiet systemd-journald 2>/dev/null; then sudo systemctl restart systemd-journald || true; fi

# Remove the [Paylasim] Samba section added by KUR.sh while keeping other share definitions.
if sudo test -f /var/lib/homelab-installer/markers/samba-share-created && sudo test -f /etc/samba/smb.conf && sudo grep -q '^\[Paylasim\][[:space:]]*$' /etc/samba/smb.conf; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  sudo cp -a /etc/samba/smb.conf "/etc/samba/smb.conf.before-homelab-remove-$STAMP"
  sudo python3 - <<'PY'
from pathlib import Path
p = Path('/etc/samba/smb.conf')
lines = p.read_text(encoding='utf-8', errors='replace').splitlines(keepends=True)
out = []
skip = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith('[') and stripped.endswith(']'):
        if stripped.lower() == '[paylasim]':
            skip = True
            continue
        skip = False
    if not skip:
        out.append(line)
p.write_text(''.join(out), encoding='utf-8')
PY
  if command -v testparm >/dev/null 2>&1; then sudo testparm -s >/dev/null; fi
  sudo systemctl reload smbd 2>/dev/null || sudo systemctl restart smbd 2>/dev/null || true
fi

# Docker daemon.json is removed only if it exactly matches the installer's default log settings.
if sudo test -f /var/lib/homelab-installer/markers/docker-daemon-json-created && sudo test -f /etc/docker/daemon.json; then
  if sudo python3 - <<'PY'
import json
from pathlib import Path
p=Path('/etc/docker/daemon.json')
try:
    d=json.loads(p.read_text())
except Exception:
    raise SystemExit(1)
expected={'log-driver':'local','log-opts':{'max-size':'10m','max-file':'3'}}
raise SystemExit(0 if d == expected else 1)
PY
  then
    sudo rm -f /etc/docker/daemon.json
    if sudo systemctl is-active --quiet docker; then sudo systemctl restart docker; fi
  else
    echo "$(T 'Mevcut /etc/docker/daemon.json farklı/özelleştirilmiş; korunuyor.' 'The existing /etc/docker/daemon.json is different/customized; keeping it.')"
  fi
fi

# Remove the known HomeLab Compose definitions. Do not touch projects with other names.
for f in \
  "$STACKS/dockge/compose.yaml" \
  "$STACKS/monitoring/compose.yaml" \
  "$STACKS/cloud/compose.yaml" \
  "$STACKS/ai/compose.yaml" \
  "$STACKS/storage/compose.yaml" \
  "$STACKS/web/compose.yaml" \
  "$STACKS/notify/compose.yaml" \
  "$STACKS/adguard/compose.yaml" "$STACKS/adguard/.env" \
  "$STACKS/monitoring-agent/compose.yaml" "$STACKS/monitoring-agent/.env"; do
  STACK_OF="${f#"$STACKS"/}"; STACK_OF="${STACK_OF%%/*}"
  if sudo test -f "/var/lib/homelab-installer/markers/compose-foreign-$STACK_OF"; then continue; fi
  sudo rm -f "$f"
done

# Panel sources were copied by the installer; user data directories are not kept here.
# The panel folder is deleted with a separate confirmation; other /srv/homelab content is not touched.

echo
echo "[4/7] $(T '/srv/homelab dosyaları' '/srv/homelab files')"
read -r -p "$(T '/srv/homelab içindeki TÜM dosyalar (appdata, paylaşılan dosyalar, Ollama modelleri, web sitesi ve yerel yedekler dahil) silinsin mi? [e/H]' 'Delete ALL files inside /srv/homelab (including appdata, shared files, Ollama models, the website and local backups)? [y/N]'): " WIPE_DATA
if [[ "$WIPE_DATA" =~ ^[EeYy]$ ]]; then
  echo "$(T 'Bu işlem geri alınamaz. Harici Restic deposu bu klasörün dışındaysa korunur.' 'This cannot be undone. The external Restic repository is kept if it is outside this folder.')"
  read -r -p "$(T 'Onaylamak için TAM OLARAK DELETE yaz' 'To confirm, type EXACTLY DELETE'): " WIPE_CONFIRM
  if [[ "$WIPE_CONFIRM" == "DELETE" ]]; then
    sudo rm -rf --one-file-system -- "$BASE"
    echo "$(T '/srv/homelab tamamen silindi.' '/srv/homelab was deleted completely.')"
  else
    echo "$(T 'Veri silme onayı eşleşmedi; /srv/homelab korundu.' 'The data deletion confirmation did not match; /srv/homelab was kept.')"
  fi
else
  # appdata/data/web and custom content are kept; only known Compose definitions are removed.
  sudo rmdir "$STACKS/dockge" "$STACKS/monitoring" "$STACKS/cloud" "$STACKS/ai" \
    "$STACKS/storage" "$STACKS/web" "$STACKS/adguard" "$STACKS/monitoring-agent" "$STACKS/notify" 2>/dev/null || true
  sudo rmdir "$STACKS" 2>/dev/null || true
  echo "$(T 'Kullanıcı verileri korundu; yalnızca bilinen Compose tanımları kaldırıldı.' 'User data was kept; only the known Compose definitions were removed.')"
fi

echo
echo "[5/7] $(T 'İsteğe bağlı sistem paketleri' 'Optional system packages')"
if [[ $HL_LANG == tr ]]; then
cat <<'PKGNOTE'
Aşağıdaki paketler KUR.sh tarafından kurulmuş olabilir. Ancak bunlardan bazıları
önceden de kurulu olabilir. Seçersen Docker, SSH, Samba ve Syncthing gibi sistem
bileşenleri kaldırılır. Özellikle SSH kaldırılırsa uzaktan bağlantın kesilir.
PKGNOTE
else
cat <<'PKGNOTE'
The packages below may have been installed by KUR.sh. However, some of them
may have been installed before. If you choose yes, system components such as
Docker, SSH, Samba and Syncthing are removed. If SSH is removed in particular,
your remote connection will be cut.
PKGNOTE
fi
read -r -p "$(T 'Docker, Restic, Samba, Syncthing, OpenSSH, Fail2ban, RustDesk ve Tailscale paketleri de kaldırılsın mı? [e/H]' 'Also remove the Docker, Restic, Samba, Syncthing, OpenSSH, Fail2ban, RustDesk and Tailscale packages? [y/N]'): " PURGE_PACKAGES
if [[ "$PURGE_PACKAGES" =~ ^[EeYy]$ ]]; then
  echo "$(T 'UYARI: Bu işlem SSH dahil sistem servislerini kaldırabilir. Yerel konsolda olduğundan emin ol.' 'WARNING: This may remove system services including SSH. Make sure you are on the local console.')"
  read -r -p "$(T 'Son onay için TAM OLARAK PURGE yaz' 'For the final confirmation, type EXACTLY PURGE'): " PURGE_CONFIRM
  if [[ "$PURGE_CONFIRM" == "PURGE" ]]; then
    if sudo test -f /var/lib/homelab-installer/markers/installed-packages; then
      mapfile -t OWN_PACKAGES < <(sudo cat /var/lib/homelab-installer/markers/installed-packages | grep -E '^[a-z0-9][a-z0-9+.-]*$' || true)
      if ((${#OWN_PACKAGES[@]})); then
        printf '%s: %s\n' "$(T 'Bu kurulumun eklediği paketler kaldırılacak' 'The packages added by this installation will be removed')" "${OWN_PACKAGES[*]}"
        sudo apt-get purge -y "${OWN_PACKAGES[@]}" || echo "$(T 'UYARI: Bazı paketler kaldırılamadı; apt çıktısını kontrol et.' 'WARNING: Some packages could not be removed; check the apt output.')"
      else
        echo "$(T 'Bu kurulum tarafından eklenen paket bulunamadı; paketler korunuyor.' 'No packages added by this installation were found; keeping the packages.')"
      fi
    else
      echo "$(T 'Paket sahipliği kaydı yok; yanlışlıkla önceden kurulu paketleri silmemek için sistem paketleri korunuyor.' 'There is no package ownership record; keeping the system packages to avoid accidentally removing pre-installed ones.')"
    fi
    if sudo test -f /var/lib/homelab-installer/markers/docker-source-created; then sudo rm -f /etc/apt/sources.list.d/docker.sources; fi
    if sudo test -f /var/lib/homelab-installer/markers/docker-key-created; then sudo rm -f /etc/apt/keyrings/docker.asc; fi
    if sudo test -f /var/lib/homelab-installer/markers/tailscale-source-created; then sudo rm -f /etc/apt/sources.list.d/tailscale.list; fi
    sudo apt-get update || true
  else
    echo "$(T 'Sistem paketleri korunuyor.' 'Keeping the system packages.')"
  fi
else
  echo "$(T 'Sistem paketleri korundu.' 'System packages were kept.')"
fi

echo
sudo rm -rf /var/lib/homelab-installer/markers
sudo rmdir /var/lib/homelab-installer 2>/dev/null || true
echo "[6/7] $(T 'Son kontrol' 'Final check')"
sudo systemctl daemon-reload
if command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
  echo "$(T 'Kalan konteynerler:' 'Remaining containers:')"
  sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}' || true
else
  echo "$(T 'Docker etkin değil veya kaldırılmış.' 'Docker is not active or has been removed.')"
fi
if sudo test -d "$BASE"; then
  echo "$(T 'Korunan /srv/homelab üst düzey klasörleri:' 'Kept top-level /srv/homelab folders:')"
  sudo find "$BASE" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
fi

echo
echo "[7/7] $(T 'İşlem özeti' 'Summary')"
echo "$(T 'Bilinen HomeLab servisleri kaldırma işleminden geçirildi.' 'The known HomeLab services went through the removal process.')"
echo "$(T 'Harici Restic deposu silinmedi. Sistem paketleri seçimine göre korunmuş olabilir.' 'The external Restic repository was not deleted. System packages may have been kept depending on your choice.')"
echo "$(T 'Kaldırma tamamlandı. Ayrıntı gerekiyorsa terminaldeki çıktıyı paylaş.' 'Uninstall complete. If you need help, share the terminal output.')"
