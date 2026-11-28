#!/usr/bin/env bash
# Switches SSH to key-based login (disables password login). Verifies step by step so you do not lock yourself out.
# Usage: bash harden-ssh.sh        (apply)
#        bash harden-ssh.sh --geri-al   (re-enable password login; --undo works too)
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
if [[ $EUID -eq 0 ]]; then echo "$(T 'sudo ile değil, normal kullanıcıyla çalıştır.' 'Run as a normal user, not with sudo.')" >&2; exit 1; fi
CONF=/etc/ssh/sshd_config.d/10-homelab-hardening.conf
command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]] || { echo "$(T 'OpenSSH sunucusu kurulu değil.' 'The OpenSSH server is not installed.')" >&2; exit 1; }

if [[ "${1:-}" == "--geri-al" || "${1:-}" == "--undo" ]]; then
  sudo rm -f "$CONF"
  sudo /usr/sbin/sshd -t
  sudo systemctl reload ssh
  echo "$(T 'SSH sertleştirme ayarı kaldırıldı; parola girişi eski haline döndü.' 'The SSH hardening setting was removed; password login is back to its previous state.')"
  exit 0
fi

AUTH="$HOME/.ssh/authorized_keys"
if [[ ! -s "$AUTH" ]] || ! grep -Eq '(^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-sha2-)' "$AUTH"; then
  if [[ $HL_LANG == tr ]]; then
    cat <<MSG
Bu kullanıcıda kayıtlı SSH anahtarı yok ($AUTH). Parola girişini şimdi kapatırsan kilitlenirsin.
Önce anahtarını ekle. Girişe kullanacağın bilgisayarda (Linux/macOS/Windows PowerShell):

  ssh-keygen -t ed25519            # anahtar yoksa
  ssh-copy-id $(id -un)@$(hostname -s).local    # Windows'ta: anahtarı elle authorized_keys'e ekle

Sonra bu betiği tekrar çalıştır.
MSG
  else
    cat <<MSG
This user has no SSH key registered ($AUTH). If you disable password login now you will lock yourself out.
Add your key first. On the computer you will log in from (Linux/macOS/Windows PowerShell):

  ssh-keygen -t ed25519            # if you have no key yet
  ssh-copy-id $(id -un)@$(hostname -s).local    # on Windows: add the key to authorized_keys manually

Then run this script again.
MSG
  fi
  exit 1
fi
# StrictModes: if permissions are wrong, key login is silently rejected.
[[ "$(stat -c %a "$HOME/.ssh")" =~ ^7[0-5]0$|^700$ ]] || { echo "$(T 'UYARI: ~/.ssh izni 700 olmalı' 'WARNING: ~/.ssh permissions must be 700'): chmod 700 ~/.ssh" >&2; exit 1; }
[[ "$(stat -c %a "$AUTH")" =~ ^[46]00$ ]] || { echo "$(T 'UYARI: authorized_keys izni 600 olmalı' 'WARNING: authorized_keys permissions must be 600'): chmod 600 $AUTH" >&2; exit 1; }

KEY_COUNT="$(grep -Ec '(^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-sha2-)' "$AUTH")"
if [[ $HL_LANG == tr ]]; then
  cat <<MSG
Kayıtlı anahtar sayısı: $KEY_COUNT

ÖNEMLİ: Bu pencereyi KAPATMADAN, başka bir bilgisayardan (veya yeni terminalden)
ANAHTARLA giriş yapabildiğini test et:  ssh $(id -un)@$(hostname -s).local
MSG
else
  cat <<MSG
Registered keys: $KEY_COUNT

IMPORTANT: WITHOUT closing this window, test from another computer (or a new terminal)
that you can log in WITH THE KEY:  ssh $(id -un)@$(hostname -s).local
MSG
fi
read -r -p "$(T 'Anahtarla girişin çalıştığını doğrulamak için YES yaz' 'To confirm that key login works, type YES'): " OK
[[ "$OK" == "YES" ]] || { echo "$(T 'İptal edildi; hiçbir şey değişmedi.' 'Cancelled; nothing was changed.')"; exit 0; }

sudo install -d -m 0755 /etc/ssh/sshd_config.d
{
  if [[ $HL_LANG == tr ]]; then
    echo '# HomeLab: anahtar tabanlı SSH. Geri almak için: bash harden-ssh.sh --geri-al'
  else
    echo '# HomeLab: key-based SSH. To revert: bash harden-ssh.sh --undo'
  fi
  cat <<'CFG'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
CFG
} | sudo tee "$CONF" >/dev/null
if ! sudo /usr/sbin/sshd -t; then
  sudo rm -f "$CONF"
  echo "$(T 'sshd yapılandırması geçersiz çıktı; değişiklik geri alındı.' 'The sshd configuration turned out to be invalid; the change was reverted.')" >&2
  exit 1
fi
sudo systemctl reload ssh
# If another sshd_config.d file comes first, our setting has no effect; verify the real effective value.
if ! sudo /usr/sbin/sshd -T | grep -qi '^passwordauthentication no$'; then
  sudo rm -f "$CONF"
  sudo systemctl reload ssh
  echo "$(T 'HATA: PasswordAuthentication etkin değer olarak '\''no'\'' olmadı (başka bir ayar dosyası öncelikli olabilir); değişiklik geri alındı.' 'ERROR: PasswordAuthentication did not become '\''no'\'' as the effective value (another config file may take precedence); the change was reverted.')" >&2
  exit 1
fi
echo "$(T 'Etkin ayar' 'Effective setting'): $(sudo /usr/sbin/sshd -T | grep -i '^passwordauthentication')"
echo "$(T 'Parola girişi kapatıldı. Mevcut oturumunu açık tut ve yeni bir pencereden tekrar anahtarla bağlanmayı dene.' 'Password login was disabled. Keep your current session open and try connecting again with the key from a new window.')"
echo "$(T 'Sorun olursa (yerel konsoldan)' 'If something goes wrong (from the local console)'): bash $0 --geri-al"
