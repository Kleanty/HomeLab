# shellcheck shell=bash
# Shared language support for every HomeLab script (source this file, do not run it).
#   HL_LANG = tr | en   (env override, e.g. HL_LANG=tr ./KUR.sh > saved choice in /etc/homelab-installer/lang > en)
#   T "Türkçe metin" "English text"   prints the text for the selected language (no newline)
HL_LANG_FILE=/etc/homelab-installer/lang

hl_lang_init() {
  case "${HL_LANG:-}" in tr|en) return 0 ;; esac
  HL_LANG=""
  if [[ -r "$HL_LANG_FILE" ]]; then
    HL_LANG="$(head -c 2 "$HL_LANG_FILE" 2>/dev/null || true)"
  fi
  case "$HL_LANG" in tr|en) return 0 ;; esac
  HL_LANG=en
}

hl_lang_save() {
  # Persist the choice so later scripts (uninstall, diagnostics, backup setup, notifications) use the same language.
  sudo install -d -m 0755 /etc/homelab-installer 2>/dev/null || return 0
  printf '%s\n' "$HL_LANG" | sudo tee "$HL_LANG_FILE" >/dev/null 2>&1 || true
}

T() {
  if [[ "${HL_LANG:-en}" == tr ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# Keeps the terminal window open when a script was started by double-click (so the output can be read).
hl_pause() {
  [[ -t 0 ]] || return 0
  printf '\n%s ' "$(T 'Kapatmak için Enter tuşuna bas...' 'Press Enter to close...')" >&2
  read -r _ || true
}
