#!/usr/bin/env bash
# setup-haos-vm.sh - installs KVM/QEMU/libvirt and creates the official Home Assistant OS virtual machine.
# Never fails the HomeLab install: every problem is written to the status file (shown in the phone panel) and the log.
# Run by KUR.sh (step 11) or alone:  bash setup-haos-vm.sh
# Env: HL_LANG=en|tr   HAOS_RAM_MB / HAOS_VCPUS / HAOS_DISK_GB (override the automatic sizing)   HAOS_SKIP=1 (skip)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lang.sh
[[ -f "$SCRIPT_DIR/lang.sh" ]] && . "$SCRIPT_DIR/lang.sh" && hl_lang_init
: "${HL_LANG:=en}"
T() { if [[ "$HL_LANG" == tr ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

VM=homeassistant
STATE_DIR=/var/lib/homelab-installer
STATUS_FILE="$STATE_DIR/haos.status"
IMG_DIR=/var/lib/libvirt/images
DISK="$IMG_DIR/haos.qcow2"
VM_MAC="52:54:00:48:41:01"
VM_IP="192.168.122.10"
REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"

sudo install -d -m 0755 "$STATE_DIR"
write_status() { # state reason [extra key=value ...]
  local st="$1" reason="$2"; shift 2
  { echo "state=$st"; echo "reason=$reason"; echo "updated=$(date -Is)"; for kv in "$@"; do echo "$kv"; done; } | sudo tee "$STATUS_FILE" >/dev/null
  sudo chmod 0644 "$STATUS_FILE"
}
skip() { # reason text: not an installer failure, but the feature is limited; shown in the panel
  echo "  ! $(T 'Home Assistant VM kurulmadı:' 'Home Assistant VM was not set up:') $1"
  write_status skipped "$1"
  exit 0
}
fail() { echo "  ! $(T 'Home Assistant VM hatası:' 'Home Assistant VM error:') $1" >&2; write_status failed "$1"; exit 0; }

[[ "${HAOS_SKIP:-0}" == 1 ]] && skip "$(T 'kullanıcı atladı (HAOS_SKIP=1)' 'skipped by the owner (HAOS_SKIP=1)')"

# ---- 1. Hardware check -------------------------------------------------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) HAOS_ARCH=x86-64 ;;
  aarch64) HAOS_ARCH=aarch64 ;;
  *) skip "$(T "desteklenmeyen işlemci mimarisi: $ARCH" "unsupported CPU architecture: $ARCH")" ;;
esac
CORES="$(nproc 2>/dev/null || echo 1)"
RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
FREE_GB="$(df -Pk /var/lib 2>/dev/null | awk 'NR==2 {print int($4/1048576)}')"
echo "$(T '  Donanım: ' '  Hardware: ')${CORES} CPU, ${RAM_MB} MB RAM, ${FREE_GB} GB $(T 'boş disk' 'free disk')"

grep -Eq '(vmx|svm)' /proc/cpuinfo || skip "$(T 'işlemci sanallaştırmayı desteklemiyor veya BIOS/UEFI içinde kapalı (Intel VT-x / AMD-V / SVM Mode)' 'the CPU has no hardware virtualization, or it is off in BIOS/UEFI (Intel VT-x / AMD-V / SVM Mode)')"
if systemd-detect-virt -q 2>/dev/null; then
  skip "$(T 'bu bilgisayar kendisi bir sanal makine; iç içe sanallaştırma kapalı olabilir' 'this computer is itself a virtual machine; nested virtualization is usually off')"
fi
((RAM_MB >= 5500)) || skip "$(T "RAM yetersiz (${RAM_MB} MB). En az 6 GB gerekir; Home Assistant yine Docker ile kurulabilir (README: alternatifler)" "not enough RAM (${RAM_MB} MB). At least 6 GB is needed; Home Assistant can still run in Docker (README: alternatives)")"

# automatic sizing: an 8 GB machine keeps most of its memory for the other services
if   ((RAM_MB < 9000));  then AUTO_RAM=2048
elif ((RAM_MB < 17000)); then AUTO_RAM=4096
else AUTO_RAM=6144; fi
if ((CORES <= 2)); then AUTO_CPU=1; elif ((CORES <= 4)); then AUTO_CPU=2; else AUTO_CPU=4; fi
VM_RAM="${HAOS_RAM_MB:-$AUTO_RAM}"; VM_CPU="${HAOS_VCPUS:-$AUTO_CPU}"; VM_DISK_GB="${HAOS_DISK_GB:-32}"
((FREE_GB >= VM_DISK_GB + 8)) || skip "$(T "disk alanı yetersiz (${FREE_GB} GB boş; en az $((VM_DISK_GB + 8)) GB gerekir)" "not enough disk space (${FREE_GB} GB free; at least $((VM_DISK_GB + 8)) GB needed)")"

# ---- 2. Packages ---------------------------------------------------------------------------------------------------
echo "$(T '  KVM/libvirt paketleri kuruluyor...' '  Installing KVM/libvirt packages...')"
PKGS=(qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst ovmf xz-utils socat curl python3 usbutils)
[[ "$HAOS_ARCH" == aarch64 ]] && PKGS=(qemu-system-arm qemu-utils libvirt-daemon-system libvirt-clients virtinst qemu-efi-aarch64 xz-utils socat curl python3 usbutils)
sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -qq install "${PKGS[@]}" >/dev/null 2>&1 || fail "$(T 'KVM paketleri kurulamadı (apt)' 'could not install the KVM packages (apt)')"
sudo modprobe kvm 2>/dev/null || true
sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
[[ -e /dev/kvm ]] || skip "$(T '/dev/kvm yok: sanallaştırma BIOS/UEFI içinde kapalı olabilir' '/dev/kvm is missing: virtualization may be disabled in BIOS/UEFI')"
sudo systemctl enable --now libvirtd >/dev/null 2>&1 || sudo systemctl enable --now libvirtd.socket >/dev/null 2>&1 || true
sudo usermod -aG libvirt,kvm "$REAL_USER" 2>/dev/null || true
export LIBVIRT_DEFAULT_URI=qemu:///system
for _ in 1 2 3 4 5; do sudo virsh list >/dev/null 2>&1 && break; sleep 2; done
sudo virsh list >/dev/null 2>&1 || fail "$(T 'libvirt çalışmıyor (sudo systemctl status libvirtd)' 'libvirt is not running (sudo systemctl status libvirtd)')"

# default NAT network (192.168.122.0/24) with a fixed address for Home Assistant
sudo virsh net-info default >/dev/null 2>&1 || { [[ -f /usr/share/libvirt/networks/default.xml ]] && sudo virsh net-define /usr/share/libvirt/networks/default.xml >/dev/null 2>&1; }
sudo virsh net-autostart default >/dev/null 2>&1 || true
sudo virsh net-start default >/dev/null 2>&1 || true
sudo virsh net-info default 2>/dev/null | grep -q 'Active:.*yes' || fail "$(T 'libvirt "default" ağı başlatılamadı' 'could not start the libvirt "default" network')"
if ! sudo virsh net-dumpxml default | grep -q "$VM_MAC"; then
  if sudo virsh net-dumpxml default | grep -q "address='192.168.122.1'"; then
    sudo virsh net-update default add ip-dhcp-host "<host mac='$VM_MAC' name='$VM' ip='$VM_IP'/>" --live --config >/dev/null 2>&1 || VM_IP=""
  else VM_IP=""; fi
fi

# Docker sets the FORWARD policy to DROP; let the VM network through, before Docker's own rules (idempotent, survives reboots)
sudo tee /etc/systemd/system/homelab-libvirt-fw.service >/dev/null <<'EOF'
[Unit]
Description=HomeLab: allow libvirt NAT traffic next to Docker
After=docker.service libvirtd.service network-online.target
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -nL DOCKER-USER >/dev/null 2>&1 || iptables -N DOCKER-USER; for r in "-i virbr0 -j ACCEPT" "-o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"; do iptables -C DOCKER-USER $r 2>/dev/null || iptables -I DOCKER-USER 1 $r; done'

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now homelab-libvirt-fw.service >/dev/null 2>&1 || true

# ---- 3. Official Home Assistant OS image -------------------------------------------------------------------------------
if ! sudo virsh dominfo "$VM" >/dev/null 2>&1; then
  WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
  echo "$(T '  Resmi Home Assistant OS imajı aranıyor...' '  Looking up the official Home Assistant OS image...')"
  REL="$WORK/release.json"
  curl -fsSL --max-time 30 https://api.github.com/repos/home-assistant/operating-system/releases/latest -o "$REL" 2>/dev/null || fail "$(T 'GitHub sürüm bilgisi alınamadı (internet?)' 'could not read the release info from GitHub (internet?)')"
  mapfile -t META < <(python3 -I - "$REL" "$HAOS_ARCH" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); arch = sys.argv[2]
want = "haos_ova-" if arch == "x86-64" else "haos_generic-aarch64-"
for a in d.get("assets", []):
    n = a.get("name", "")
    if n.startswith(want) and n.endswith(".qcow2.xz"):
        print(a["browser_download_url"]); print((a.get("digest") or "").replace("sha256:", "")); print(d.get("tag_name", "")); break
PY
)
  URL="${META[0]:-}"; SHA="${META[1]:-}"; VERSION="${META[2]:-unknown}"
  [[ "$URL" == https://github.com/home-assistant/operating-system/releases/download/* ]] || fail "$(T 'uygun Home Assistant OS imajı bulunamadı' 'no suitable Home Assistant OS image was found')"
  echo "$(T '  İndiriliyor: ' '  Downloading: ')$VERSION (~400 MB)"
  curl -fL --retry 3 --max-time 1800 -o "$WORK/haos.qcow2.xz" "$URL" 2>/dev/null || fail "$(T 'imaj indirilemedi' 'the image download failed')"
  if [[ -n "$SHA" ]]; then
    [[ "$(sha256sum "$WORK/haos.qcow2.xz" | awk '{print $1}')" == "$SHA" ]] || fail "$(T 'imaj sağlama toplamı (SHA-256) uyuşmuyor; kurulum durduruldu' 'image checksum (SHA-256) mismatch; setup stopped')"
    echo "$(T '  SHA-256 doğrulandı.' '  SHA-256 verified.')"
  else
    echo "  $(T 'Uyarı: GitHub bu sürüm için sağlama toplamı vermedi; yalnızca HTTPS ile doğrulandı.' 'Warning: GitHub gave no checksum for this release; verified by HTTPS only.')"
  fi
  xz -dc "$WORK/haos.qcow2.xz" > "$WORK/haos.qcow2" || fail "$(T 'imaj açılamadı' 'could not unpack the image')"
  sudo install -d -m 0711 "$IMG_DIR"
  sudo install -o root -g root -m 0644 "$WORK/haos.qcow2" "$DISK" || fail "$(T 'imaj kopyalanamadı (disk dolu mu?)' 'could not copy the image (disk full?)')"
  sudo qemu-img resize "$DISK" "${VM_DISK_GB}G" >/dev/null 2>&1 || true
  rm -rf "$WORK"; trap - EXIT

  # ---- 4. Create the VM --------------------------------------------------------------------------------------------
  echo "$(T '  VM oluşturuluyor: ' '  Creating the VM: ')${VM_CPU} vCPU, ${VM_RAM} MB RAM, ${VM_DISK_GB} GB"
  BOOT=uefi; [[ "$HAOS_ARCH" == aarch64 ]] && BOOT=uefi
  sudo virt-install --name "$VM" --memory "$VM_RAM" --vcpus "$VM_CPU" --cpu host-passthrough \
    --machine q35 --os-variant generic --import --boot "$BOOT" \
    --disk "path=$DISK,format=qcow2,bus=virtio" \
    --network "network=default,model=virtio,mac=$VM_MAC" \
    --graphics none --console pty,target_type=serial --noautoconsole --autostart >/dev/null 2>&1 \
    || fail "$(T 'VM oluşturulamadı (virt-install)' 'could not create the VM (virt-install)')"
  sudo virsh autostart "$VM" >/dev/null 2>&1 || true
  sudo rm -f "$STATE_DIR/haos.desired"
  write_status created "" "version=$VERSION" "disk=$DISK" "vm_ip=$VM_IP" "ram_mb=$VM_RAM" "vcpus=$VM_CPU" "disk_gb=$VM_DISK_GB"
else
  echo "$(T '  Home Assistant VM zaten var; yeniden oluşturulmadı.' '  The Home Assistant VM already exists; not recreated.')"
  sudo virsh autostart "$VM" >/dev/null 2>&1 || true
  [[ "$(sudo virsh domstate "$VM" 2>/dev/null)" == running ]] || [[ "$(cat "$STATE_DIR/haos.desired" 2>/dev/null)" == stopped ]] || sudo virsh start "$VM" >/dev/null 2>&1 || true
  [[ -f "$STATUS_FILE" ]] || write_status created "" "disk=$DISK" "vm_ip=$VM_IP"
fi

# ---- 5. LAN access to Home Assistant (port 8123) through a small forwarder -----------------------------------------------
# The VM lives on the private libvirt network; this forwards the computer's own port 8123 to it, for the home network only.
# Do not forward port 8123 on the router: use Tailscale for remote access.
if [[ -n "$VM_IP" ]]; then
  sudo tee /etc/systemd/system/homelab-ha-forward.service >/dev/null <<EOF
[Unit]
Description=HomeLab: forward port 8123 to the Home Assistant VM
After=libvirtd.service network-online.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:8123,fork,reuseaddr TCP:$VM_IP:8123
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now homelab-ha-forward.service >/dev/null 2>&1 || true
fi

# ---- 6. Management command and phone-panel permission ----------------------------------------------------------------------
if [[ -f "$SCRIPT_DIR/homelab-haos" ]]; then
  sudo install -m 0755 "$SCRIPT_DIR/homelab-haos" /usr/local/sbin/homelab-haos
  SUDOERS_TMP="$(mktemp)"
  echo "$REAL_USER ALL=(root) NOPASSWD: /usr/local/sbin/homelab-haos start, /usr/local/sbin/homelab-haos stop, /usr/local/sbin/homelab-haos restart, /usr/local/sbin/homelab-haos brief, /usr/local/sbin/homelab-haos status" > "$SUDOERS_TMP"
  if sudo visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then sudo install -o root -g root -m 0440 "$SUDOERS_TMP" /etc/sudoers.d/homelab-haos; fi
  rm -f "$SUDOERS_TMP"
fi

# Attach Zigbee/Z-Wave/Thread adapters that are already plugged in (none is fine; more can be added later with: sudo homelab-haos usb auto)
[[ -x /usr/local/sbin/homelab-haos ]] && sudo /usr/local/sbin/homelab-haos usb auto 2>/dev/null || true

# Wait (up to ~4 min) for the first boot to get an address; it is normal for Home Assistant to need 10-20 more minutes to finish its first start.
UP=no
for _ in $(seq 1 24); do
  if [[ -n "$VM_IP" ]] && curl -s -o /dev/null --max-time 3 "http://$VM_IP:8123/"; then UP=yes; break; fi
  sleep 10
done
if [[ "$UP" == yes ]]; then
  echo "$(T '  Home Assistant yanıt veriyor: http://<bu-bilgisayar>:8123' '  Home Assistant is answering: http://<this-computer>:8123')"
else
  echo "$(T '  VM çalışıyor; Home Assistant ilk açılışta 10-20 dakika hazırlanabilir. Sonra: http://<bu-bilgisayar>:8123' '  The VM is running; Home Assistant may need 10-20 minutes for its first start. Then open http://<this-computer>:8123')"
fi
exit 0
