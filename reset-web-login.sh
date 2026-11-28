#!/usr/bin/env bash
# Reset the login of the settings page (http://127.0.0.1:8765): bash /srv/homelab/tools/reset-web-login.sh
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
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/HomeLab"
[[ -d "$CONF" ]] || { echo "$(T "HomeLab ajanı kurulu görünmüyor ($CONF). Önce KUR.sh çalıştır." "The HomeLab agent does not look installed ($CONF). Run KUR.sh first.")" >&2; exit 1; }
HL_LANG="$HL_LANG" HL_WEB_FILE="$CONF/web-login" python3 -I - <<'PY'
import base64, getpass, hashlib, os, secrets
TR = os.environ.get("HL_LANG") == "tr"
def tx(tr, en): return tr if TR else en
user = input(tx("Kullanıcı adı: ", "Username: ")).strip()
if not user: raise SystemExit(tx("Kullanıcı adı boş olamaz.", "The username cannot be empty."))
p = getpass.getpass(tx("Yeni parola (en az 14 karakter): ", "New password (at least 14 characters): "))
q = getpass.getpass(tx("Parolayı tekrar girin: ", "Enter the password again: "))
if len(p) < 14: raise SystemExit(tx("Parola en az 14 karakter olmalı.", "The password must be at least 14 characters."))
if p != q: raise SystemExit(tx("Parolalar eşleşmiyor.", "The passwords do not match."))
path = os.environ["HL_WEB_FILE"]
salt, iterations = secrets.token_bytes(16), 600000
digest = hashlib.pbkdf2_hmac("sha256", p.encode("utf-8"), salt, iterations, 32)
b64 = lambda b: base64.b64encode(b).decode("ascii")
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write("v1 %s %d %s %s\n" % (b64(user.encode("utf-8")), iterations, b64(salt), b64(digest)))
os.replace(tmp, path)
print(tx("Ayar sayfası girişi güncellendi (127.0.0.1:8765). Yeniden başlatma gerekmez.", "Settings page login updated (127.0.0.1:8765). No restart needed."))
PY
