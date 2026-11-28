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
if [[ $EUID -ne 0 ]]; then
  echo "$(T 'Bu araç root yetkisi ister: sudo bash setup-restic-backup.sh' 'This tool needs root privileges: sudo bash setup-restic-backup.sh')" >&2
  exit 1
fi
LOG_FILE=/var/log/homelab-installer-restic-setup.log
exec > >(tee -a "$LOG_FILE") 2>&1
on_error() {
  local rc="$?" line="$1" cmd="$2"
  trap - ERR
  echo >&2
  echo "$(T "HATA: Restic kurulumu $line. satırda durdu (çıkış kodu: $rc)." "ERROR: Restic setup stopped at line $line (exit code: $rc).")" >&2
  echo "$(T 'Çalıştırılan komut' 'Command that was running'): $cmd" >&2
  echo "$(T 'Ayrıntılı günlük' 'Detailed log'): $LOG_FILE" >&2
  echo "$(T 'Harici yedek deposu silinmedi. Tekrar çalıştırmadan önce /etc/restic durumunu incele.' 'The external backup repository was not deleted. Inspect the state of /etc/restic before running again.')" >&2
  exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
on_signal() {
  local signal="$1" rc="$2"
  trap - INT TERM ERR
  echo >&2
  echo "$(T "Restic kurulumu durduruldu ($signal, çıkış kodu: $rc)." "Restic setup was interrupted ($signal, exit code: $rc).")" >&2
  echo "$(T "Harici depo silinmedi; yerel yapılandırmayı incele. Günlük: $LOG_FILE" "The external repository was not deleted; inspect the local configuration. Log: $LOG_FILE")" >&2
  exit "$rc"
}
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
command -v restic >/dev/null || { echo "$(T 'Restic kurulu değil. Önce KUR.sh çalıştır.' 'Restic is not installed. Run KUR.sh first.')" >&2; exit 1; }
command -v findmnt >/dev/null || { echo "$(T 'findmnt bulunamadı.' 'findmnt not found.')" >&2; exit 1; }
if [[ -e /etc/restic/homelab.env || -e /etc/restic/homelab-password || -e /etc/systemd/system/homelab-restic-backup.service ]]; then
  echo "$(T 'Restic yapılandırması zaten mevcut; mevcut yedek ayarlarını korumak için işlem durduruldu.' 'A Restic configuration already exists; stopped to keep the existing backup settings.')" >&2
  exit 1
fi

if [[ $HL_LANG == tr ]]; then
  cat <<'MSG'
RESTIC YEDEKLEME KURULUMU
------------------------
Hedef, sistem diskinin dışında bağlanmış bir disk/dosya sistemi olmalıdır.
Örnek: /media/kullanici/YEDEK/restic
Aynı sistem diskine yedek almak disk arızasına karşı koruma sağlamaz.
MSG
else
  cat <<'MSG'
RESTIC BACKUP SETUP
-------------------
The target must be a disk/file system mounted outside the system disk.
Example: /media/username/BACKUP/restic
Backing up to the same system disk gives no protection against disk failure.
MSG
fi
echo "$(T 'Bağlı harici disk adayları (/media ve /mnt altı):' 'Connected external disk candidates (under /media and /mnt):')"
findmnt -rno TARGET,SOURCE,FSTYPE | awk '$1 ~ /^\/(media|mnt)\// {print "  " $1 "  (" $2 ", " $3 ")"}' || true
echo "$(T 'Yol örneği: <bağlama noktası>/restic   (boşluk içeren ad kullanma). Boş bırakıp Enter = şimdilik atla.' 'Path example: <mount point>/restic   (do not use names containing spaces). Leave empty and press Enter = skip for now.')"
REPO=""
for _ in 1 2 3; do
  read -r -p "$(T 'Harici diskteki yedek deposu yolu' 'Backup repository path on the external disk'): " REPO
  if [[ -z "$REPO" ]]; then
    echo "$(T 'Restic kurulumu atlandı. Disk bağlayınca' 'Restic setup was skipped. Once the disk is connected, run'): sudo bash /srv/homelab/tools/setup-restic-backup.sh"
    exit 0
  fi
  [[ "$REPO" =~ ^/[A-Za-z0-9._/-]+$ ]] && break
  echo "$(T 'Mutlak yol gerekli; boşluk ve özel karakter kullanma.' 'An absolute path is required; do not use spaces or special characters.')" >&2
  REPO=""
done
[[ -n "$REPO" ]] || { echo "$(T 'Geçerli yol girilmedi; Restic kurulumu atlandı.' 'No valid path was entered; Restic setup was skipped.')" >&2; exit 1; }
[[ "$REPO" != /srv/homelab* ]] || { echo "$(T 'Yedek deposu /srv/homelab içinde olamaz.' 'The backup repository cannot be inside /srv/homelab.')" >&2; exit 1; }
PARENT="$(dirname -- "$REPO")"
[[ -d "$PARENT" ]] || { echo "$(T 'Üst dizin mevcut değil' 'Parent directory does not exist'): $PARENT" >&2; exit 1; }
MOUNT_TARGET="$(findmnt -n -o TARGET -T "$PARENT")"
MOUNT_SOURCE="$(findmnt -n -o SOURCE -T "$PARENT")"
[[ "$MOUNT_TARGET" != / ]] || {
  echo "$(T 'Bu yol ayrı bir bağlanmış dosya sisteminde görünmüyor. Harici diski bağla ve tekrar dene.' 'This path does not appear to be on a separately mounted file system. Connect the external disk and try again.')" >&2
  exit 1
}
echo "$(T 'Algılanan bağlama noktası' 'Detected mount point'): $MOUNT_TARGET ($MOUNT_SOURCE)"
ROOT_SOURCE="$(findmnt -n -o SOURCE -T / | sed 's/\[.*$//')"
BACKUP_SOURCE="${MOUNT_SOURCE%%\[*}"
if [[ -b "$ROOT_SOURCE" && -b "$BACKUP_SOURCE" ]]; then
  ROOT_DISKS="$(lsblk -s -nrpo NAME,TYPE "$ROOT_SOURCE" | awk '$2 == "disk" {print $1}' | sort -u)"
  BACKUP_DISKS="$(lsblk -s -nrpo NAME,TYPE "$BACKUP_SOURCE" | awk '$2 == "disk" {print $1}' | sort -u)"
  if [[ -n "$ROOT_DISKS" && -n "$BACKUP_DISKS" ]] && comm -12 <(printf '%s\n' "$ROOT_DISKS") <(printf '%s\n' "$BACKUP_DISKS") | grep -q .; then
    echo "$(T 'Yedek hedefi sistem diskiyle aynı fiziksel diskte görünüyor. Bu disk arızasına karşı koruma sağlamaz.' 'The backup target appears to be on the same physical disk as the system disk. This gives no protection against disk failure.')" >&2
    exit 1
  fi
fi
case "$MOUNT_TARGET" in
  /media/*|/run/media/*)
    echo "$(T 'UYARI: Bu yol masaüstü oturumu tarafından otomatik bağlanan bir disk olabilir.' 'WARNING: This path may be a disk that is auto-mounted by the desktop session.')"
    echo "$(T 'Bilgisayar açık olsa bile kullanıcı oturumu açılmadan günlük 03:15 görevi diski göremeyebilir.' 'Even if the computer is on, the daily 03:15 job may not see the disk before a user session is opened.')"
    echo "$(T 'Kesintisiz otomasyon için diskin açılışta sabit bir noktaya UUID ile bağlandığından emin ol.' 'For uninterrupted automation, make sure the disk is mounted at boot to a fixed location by UUID.')"
    read -r -p "$(T 'Bu bağlama düzeninin zamanlayıcı çalışırken hazır olacağını doğruluyor musun? [e/H]' 'Do you confirm this mount setup will be ready when the timer runs? [y/N]'): " MOUNT_CONFIRM
    [[ "$MOUNT_CONFIRM" =~ ^[EeYy]$ ]] || { echo "$(T 'Önce kalıcı bağlama yapılandır; işlem iptal edildi.' 'Configure a persistent mount first; operation cancelled.')" >&2; exit 1; }
    ;;
esac
read -r -p "$(T 'Bu hedefin sistem diskinden ayrı bir yedek diski olduğunu doğruluyor musun? [e/H]' 'Do you confirm this target is a backup disk separate from the system disk? [y/N]'): " CONFIRM
[[ "$CONFIRM" =~ ^[EeYy]$ ]] || { echo "$(T 'İptal edildi.' 'Cancelled.')"; exit 0; }

if [[ -e "$REPO" ]] && find "$REPO" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
  echo "$(T 'Hedef dizin boş değil; mevcut verileri korumak için işlem durduruldu' 'The target directory is not empty; stopped to protect the existing data'): $REPO" >&2
  exit 1
fi
read -r -s -p "$(T 'Restic şifreleme parolası (en az 20 karakter)' 'Restic encryption password (at least 20 characters)'): " PASS1; echo
read -r -s -p "$(T 'Parolayı tekrar gir' 'Enter the password again'): " PASS2; echo
[[ ${#PASS1} -ge 20 ]] || { echo "$(T 'Parola en az 20 karakter olmalı.' 'The password must be at least 20 characters.')" >&2; exit 1; }
[[ "$PASS1" == "$PASS2" ]] || { echo "$(T 'Parolalar eşleşmiyor.' 'The passwords do not match.')" >&2; exit 1; }

install -d -o root -g root -m 0700 /etc/restic /var/lib/homelab-restic /var/lib/homelab-restic/cache
mkdir -p -- "$REPO"
chmod 0700 "$REPO" 2>/dev/null || echo "$(T 'Not: Bu dosya sistemi izin ayarını desteklemiyor (exFAT/NTFS olabilir); yedek şifreli olduğu için devam ediliyor.' 'Note: This file system does not support permission settings (may be exFAT/NTFS); continuing because the backup is encrypted.')"
( umask 077; printf '%s\n' "$PASS1" > /etc/restic/homelab-password )
chmod 0600 /etc/restic/homelab-password
unset PASS1 PASS2
cat > /etc/restic/homelab.env <<EOF_ENV
RESTIC_REPOSITORY=$REPO
RESTIC_PASSWORD_FILE=/etc/restic/homelab-password
RESTIC_CACHE_DIR=/var/lib/homelab-restic/cache
EOF_ENV
chmod 0600 /etc/restic/homelab.env

if [[ -n "$(find "$REPO" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "$(T 'Depo oluşturulurken hedef boş olmaktan çıktı; işlem durduruldu.' 'The target stopped being empty while the repository was being created; operation stopped.')" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source /etc/restic/homelab.env
set +a
restic init

cat > /usr/local/sbin/homelab-restic-backup <<'EOF_BACKUP'
#!/usr/bin/env bash
set -Eeuo pipefail
# Language: read from the installer's saved choice; never prompts (runs from a systemd timer).
HL_LANG="$(head -c 2 /etc/homelab-installer/lang 2>/dev/null || true)"
case "$HL_LANG" in tr|en) ;; *) HL_LANG=en ;; esac
T() { if [[ "$HL_LANG" == tr ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
source /etc/restic/homelab.env
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR

PARENT="$(dirname -- "$RESTIC_REPOSITORY")"
[[ -d "$PARENT" ]] || { echo "$(T 'Yedek diski bulunamadı' 'Backup disk not found'): $PARENT" >&2; exit 2; }
MOUNT_TARGET="$(findmnt -n -o TARGET -T "$PARENT")"
[[ "$MOUNT_TARGET" != / ]] || { echo "$(T 'Yedek diski bağlı değil; sistem diskine yedek alınmayacak.' 'The backup disk is not mounted; no backup will be made to the system disk.')" >&2; exit 2; }

STAGE=/var/lib/homelab-restic/staging
rm -rf "$STAGE"
install -d -o root -g root -m 0700 "$STAGE/sqlite"

# Create a consistent copy of live SQLite application databases.
if [[ -d /srv/homelab/appdata ]]; then
  while IFS= read -r -d '' DB; do
    if sqlite3 "$DB" 'PRAGMA quick_check;' 2>/dev/null | grep -qx 'ok'; then
      REL="${DB#/srv/homelab/}"
      DEST="$STAGE/sqlite/$REL.snapshot"
      install -d -o root -g root -m 0700 "$(dirname -- "$DEST")"
      if sqlite3 "$DB" ".backup '$DEST'"; then
        chmod 0600 "$DEST"
      else
        echo "$(T "UYARI: $DB için tutarlı kopya alınamadı; dosya doğrudan yedeklenecek." "WARNING: Could not make a consistent copy of $DB; the file will be backed up directly.")" >&2
        rm -f -- "$DEST"
      fi
    fi
  done < <(find /srv/homelab/appdata -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \) -print0)
fi

PATHS=(/srv/homelab /etc/ssh /etc/samba /var/lib/samba /etc/docker /etc/fail2ban \
  /etc/fstab /etc/hostname /etc/hosts /etc/apt/sources.list.d /var/lib/homelab-restic/staging)
if [[ -n "${HOMELAB_BACKUP_HOME:-}" && -d "$HOMELAB_BACKUP_HOME/.ssh" ]]; then
  PATHS+=("$HOMELAB_BACKUP_HOME/.ssh")
fi

restic backup --tag homelab --exclude '**/.venv' --exclude '**/node_modules' \
  --exclude '**/__pycache__' --exclude '**/.cache' --exclude '**/*.log' \
  "${PATHS[@]}"
restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
EOF_BACKUP
chmod 0750 /usr/local/sbin/homelab-restic-backup

cat > /etc/systemd/system/homelab-restic-backup.service <<'EOF_SERVICE'
[Unit]
Description=Encrypted HomeLab backup with Restic
OnFailure=homelab-notify-failure@%n.service
Wants=network-online.target
After=network-online.target local-fs.target

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/restic/homelab.env
Environment=HOMELAB_BACKUP_HOME=__HOME_DIR__
ExecStart=/usr/local/sbin/homelab-restic-backup
Nice=19
IOSchedulingClass=best-effort
IOSchedulingPriority=7
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/lib/homelab-restic __REPO_PARENT__
TimeoutStartSec=6h
EOF_SERVICE
OWNER_HOME="${SUDO_USER_HOME:-}"
if [[ -z "$OWNER_HOME" && -n "${SUDO_USER:-}" ]]; then OWNER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"; fi
OWNER_HOME="${OWNER_HOME:-/root}"
sed -i "s|__HOME_DIR__|$OWNER_HOME|g; s|__REPO_PARENT__|$PARENT|g" /etc/systemd/system/homelab-restic-backup.service

cat > /etc/systemd/system/homelab-restic-backup.timer <<'EOF_TIMER'
[Unit]
Description=Daily HomeLab Restic backup

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=30m
Unit=homelab-restic-backup.service

[Install]
WantedBy=timers.target
EOF_TIMER

cat > /etc/systemd/system/homelab-restic-check.service <<'EOF_CHECK_SERVICE'
[Unit]
Description=Weekly Restic repository integrity check
OnFailure=homelab-notify-failure@%n.service
Wants=network-online.target
After=network-online.target local-fs.target

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/restic/homelab.env
ExecStart=/usr/bin/restic check --read-data-subset=5%
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/lib/homelab-restic/cache __REPO_PARENT__
EOF_CHECK_SERVICE
sed -i "s|__REPO_PARENT__|$PARENT|g" /etc/systemd/system/homelab-restic-check.service

cat > /etc/systemd/system/homelab-restic-check.timer <<'EOF_CHECK_TIMER'
[Unit]
Description=Weekly Restic repository check

[Timer]
OnCalendar=Sun *-*-* 05:00:00
Persistent=true
RandomizedDelaySec=20m
Unit=homelab-restic-check.service

[Install]
WantedBy=timers.target
EOF_CHECK_TIMER

systemctl daemon-reload
systemctl enable --now homelab-restic-backup.timer homelab-restic-check.timer
install -d -o root -g root -m 0700 /var/lib/homelab-installer/markers
touch /var/lib/homelab-installer/markers/restic-created
printf '\n%s: sudo systemctl start homelab-restic-backup.service\n' "$(T 'Restic kuruldu. İlk yedek için' 'Restic is set up. To run the first backup')"
printf '%s\n' "$(T 'Yedek parolasını ayrıca parola kasasında sakla; parola kaybolursa yedek açılamaz.' 'Store the backup password separately in a password manager; if the password is lost, the backup cannot be opened.')"
