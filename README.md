# HomeLab — One-Click Installer

[Türkçe: README.tr.md](README.tr.md) · Repository: https://github.com/Kleanty/HomeLab

**If this is your first install, read [`INSTALL-GUIDE.md`](INSTALL-GUIDE.md) first.** This package is run after Linux Mint 22.x has been installed on the new computer; it does not install the operating system itself.

This package turns a fresh **Linux Mint 22.x Cinnamon 64-bit (Ubuntu 24.04 / noble, amd64)** computer into a basic HomeLab server.

> **Important:** This package does not install the Linux Mint operating system from USB by itself. First install Linux Mint on the computer and log in to the desktop. Then unpack the package and run `KUR.sh` with your normal user account. Before running it directly on an existing HomeLab server, take a backup and review the existing Compose files.

## Screenshots

| ![Home](docs/screenshots/home.png) | ![Services](docs/screenshots/services.png) |
|---|---|
| ![System](docs/screenshots/system.png) | ![Shortcuts](docs/screenshots/shortcuts.png) |
| ![Alerts](docs/screenshots/alerts.png) | ![Not connected](docs/screenshots/not-connected.png) |

![Settings page](docs/screenshots/settings.png)

## Test status and licence

Tested on a real machine (Intel Core i7-2600, 8 GB RAM, Linux Mint 22.x): the install steps, the settings page login, the phone app (Wi-Fi and USB pairing), File Browser login, and the Home Assistant OS virtual machine (boots, gets an address, answers on port 8123). **Not yet verified:** a complete fresh install end to end with this final package, Zigbee/Matter/Thread hardware, and a Restic restore on your own disk. After the first install on your own hardware, check the state with `bash TANI.sh`.

This project is shared under the [MIT Licence](LICENSE). The software is provided "as is"; you use it at your own responsibility.

## What gets installed?

### System packages and services

- Docker Engine, Docker Compose and Buildx
- KVM/QEMU/libvirt and the official Home Assistant OS virtual machine (optional; see "Home Assistant OS virtual machine" below)
- OpenSSH Server
- Samba file sharing
- Syncthing
- Fail2ban (basic brute-force protection for SSH)
- Restic (encrypted backup tool; an external target is needed for automatic jobs)
- SQLite3 (to prepare consistent copies of running SQLite databases)
- smartmontools, nvme-cli and lm-sensors (disk/NVMe/sensor diagnostics)
- systemd-journald logs are kept persistently; total size is limited to 500 MB and retention to 1 month
- UFW package (the firewall is **not enabled**)
- Docker log rotation: on a fresh install the `local` driver, 10 MB and at most 3 files; an existing `daemon.json` is preserved
- Hardware detection: CPU/RAM/graphics card and disks are only listed for information. **The graphics card (NVIDIA) driver is not installed by this package.**
- Ollama: on the first install the fixed model [`qwen2.5:1.5b-instruct-q4_K_M`](https://ollama.com/library/qwen2.5/tags) is downloaded (about 986 MB) and runs **on the CPU**. If there is less than 2 GiB of free disk space the download is skipped and the reason is reported; you can add any model you like later.
- Avahi/mDNS: devices on the local network that support it can try to reach the machine as `computer-name.local`; no fixed IP is configured on the router
- Docker port lock: the `homelab-docker-lan-only` service blocks new internet-originated connections to the ports Docker publishes; the local network (10/8, 172.16/12, 192.168/16), Tailscale (100.64/10) and localhost stay open. It only affects Docker traffic (IPv4); published ports are pinned to IPv4. Beszel Agent (45876), which uses the host network, is outside this filter. SSH/Samba/UFW are unchanged
- **HomeLab Panel** (phone panel): turns an old Android phone into a server panel. The HomeLab agent is built from this repository (`agent/`) with GitHub Actions and uploaded to the `v<version>` release; KUR.sh downloads it, verifies SHA-256 and runs it as a systemd user service (`homelab-agent`); it does not update itself. adb is installed too (for the USB connection). On the first install 6 pages are prepared: HomeLab (clock, status list, CPU/RAM/temperature/network), Services (tap a container: start / stop / restart), Alerts (open problems and history), System, Processes and Shortcuts. Tapping the cards opens a large chart window. The health check tests internet (ping) and services every 2 minutes; if there is a problem a large alert opens on the phone. GPU temperature needs the vendor driver; since the installer does not install an NVIDIA driver, there is no GPU widget by default. On the server, you edit the pages on the HomeLab settings page at `http://127.0.0.1:8765`, and start/stop Docker containers with on/off switches on its **Services** tab (the Services page of the phone panel does the same; your user must be in the `docker` group, so log out and back in once after the install). The interface is in Turkish, with an AMOLED + turquoise theme.
- Tailscale and RustDesk (remote desktop; connects without opening ports on the modem)
- Sleep/suspend lock so the server does not go to sleep (the power-button setting is preserved) and automatic login (LightDM; left alone if already set)

### Docker services

| Service | Address / port | Description |
|---|---|---|
| Dockge | `http://SERVER-IP:5001` | Docker Compose management |
| Beszel Hub | `http://SERVER-IP:8090` | System and container monitoring hub |
| Uptime Kuma | `http://SERVER-IP:3001` | Service availability and uptime |
| Scrutiny | `http://SERVER-IP:8081` | HDD/SSD/NVMe SMART health tracking |
| File Browser | `http://SERVER-IP:8080` | File interface |
| n8n | `http://SERVER-IP:5678` | Automation |
| Home Assistant (VM) | `http://SERVER-IP:8123` | Official Home Assistant OS in a KVM virtual machine (optional, home network only); manage with `sudo homelab-haos` |
| Ollama API | `http://127.0.0.1:11434` | Server's localhost only; the Qwen model is downloaded automatically after the RAM/disk check |
| Your own website (Caddy) | `http://127.0.0.1:8088` | Empty placeholder page that you replace with your own site; listens on 127.0.0.1 only unless you change the Caddyfile/compose port; domain/HTTPS is configured later |
| AdGuard Home | `:3000` by IP, then `:3002`; DNS `:53` | Optional; binds only to the selected LAN IP |

AdGuard Home is asked about separately during installation. The router's DNS/DHCP settings are not changed and the AdGuard DHCP server is not enabled.

### Beszel Agent

Beszel Hub is installed automatically. The Agent Compose file is prepared too; because the Agent needs a key/token that exist only after the first admin account and system record are created in the Hub, it is started with a separate helper:

```bash
bash /srv/homelab/tools/configure-beszel-agent.sh
```

First open `http://SERVER-IP:8090`, create a system record in Beszel via **Add System** and get the KEY/TOKEN values the Hub gives you. The helper writes them to a root-readable `.env` file with `0600` permissions and starts the Agent container. On the Hub side use the server's LAN IP and port `45876`. The Agent is not started or stopped from a panel; once its container exists it appears in the Services list of the phone panel and of the settings page.

The Agent container mounts `/var/run/docker.sock` read-only for Docker statistics. Mounting the Docker socket read-only does not make API access truly read-only; the Docker socket is a highly privileged interface. So the Agent should only run on a local server you trust, and its port must not be forwarded to the internet.

### Scrutiny disk access

The installer detects physical disks with `lsblk` and passes only those disks to the Scrutiny container as `/dev/...` mappings (USB/removable disks and zram are excluded; the container could not start if one were removed). SATA/SAS disks are passed with their own device paths; NVMe disks are passed with the NVMe controller device that the Scrutiny documentation asks for. The `SYS_RAWIO` capability is added. If NVMe is detected, the `SYS_ADMIN` capability is optionally asked about; the default choice should be **No**. This capability is broad and should be considered separately only if NVMe SMART data cannot be read. `--privileged` is not used.

If Scrutiny looks empty, it may mean the disk does not support SMART data, a USB bridge blocks SMART passthrough, or NVMe needs the extra capability. SMART data is not guaranteed for every disk behind RAID/USB converters.

## Restic automatic backup

The Restic package is installed; at the end of the install an external disk is asked about as the target for automatic backup. If no external disk is connected this step can be skipped:

```bash
sudo bash /srv/homelab/tools/setup-restic-backup.sh
```

The tool:

1. Asks for the backup repository path on a separately mounted filesystem. It refuses to create a backup inside `/srv/homelab` or on the system disk's root filesystem; if the sources are block devices it also checks whether they are on the same physical disk as the system disk.
2. Asks twice for a Restic encryption password of at least 20 characters.
3. Stores the password in `/etc/restic/homelab-password` with root-only `0600` permissions. Also save the password in a secure password vault; if it is lost the backup cannot be opened.
4. Initialises the Restic repository and enables the daily backup and weekly integrity check timers.

Schedule and retention policy:

- A backup every day at about 03:15; jobs missed at boot are caught up.
- 14 daily, 8 weekly and 12 monthly snapshots are kept; cleaning old snapshots and `prune` run at the end of the backup job.
- Weekly Restic repository integrity check.
- If the backup disk is mounted by the desktop session under `/media/...` or `/run/media/...`, the installer warns. For the timer to see the disk without a desktop login, a fixed mount point mounted at boot is needed (preferably a UUID-based `/etc/fstab` entry or a systemd mount). The installer does not change this critical system file on its own.
- For SQLite databases it tries to prepare a consistent copy from the live database with `sqlite3 .backup`.
- `/srv/homelab`, the SSH/Samba configuration and the user's `.ssh` directory are covered.

Start the first backup manually:

```bash
sudo systemctl start homelab-restic-backup.service
sudo systemctl status homelab-restic-backup.service --no-pager
sudo journalctl -u homelab-restic-backup.service -n 100 --no-pager
```

Check the snapshot list and a sample restore:

```bash
sudo bash -c 'set -a; . /etc/restic/homelab.env; set +a; restic snapshots'
sudo mkdir -p /tmp/homelab-restore-test
sudo bash -c 'set -a; . /etc/restic/homelab.env; set +a; restic restore latest --target /tmp/homelab-restore-test --include /srv/homelab/web/public/index.html'
```

After the restore test you can delete the temporary `/tmp/homelab-restore-test` directory. This example restores only a single small web file; it does not unpack the whole backup into a temporary directory and fill up the system. The `--include` path must match the path inside the snapshot; for your own file, rely on the output of `restic ls latest`.

Check the timers:

```bash
systemctl list-timers 'homelab-restic*'
```

### Full restore (on a newly installed machine)

1. Complete the normal `KUR.sh` install, connect the external backup disk and recreate `/etc/restic/homelab.env` and the password file (`/etc/restic/homelab-password`). Without the password the backup cannot be opened.
2. Stop the services: `cd /srv/homelab && sudo docker compose -f <stack>/docker-compose.yml down` (for each stack).
3. First restore to a temporary directory and check the contents: `sudo bash -c 'set -a; . /etc/restic/homelab.env; set +a; restic restore latest --target /srv/restore-tmp'`
4. SQLite databases are backed up as consistent snapshots rather than live files: `/srv/restore-tmp/var/lib/homelab-restic/staging/sqlite/.../<name>.snapshot`. When putting a database back, copy the relevant `.snapshot` file to the original path (`/srv/homelab/appdata/...`) under its original name; do not copy while the service is running.
5. Move the remaining files from `/srv/restore-tmp/srv/homelab` into `/srv/homelab` with `sudo rsync -a`, then start the services again.
6. These steps have not been tried on a real machine; after the first backup, do a trial restore into an empty directory.

If the backup target disk is not connected the job fails on purpose; it never silently writes a backup to the system disk. Ollama model files are under `/srv/homelab` too, so they are included in the backup and the first backup can be large. Choose the external disk's capacity accordingly. After the backup completes, do a restore test to a different location; the fact that a backup is being taken does not by itself prove that it can be restored.

Instead of keeping the Restic repository on an SMB/CIFS share, a directly attached USB/SATA disk or a suitable SFTP/S3/REST target is preferred. Do not keep the password and the backup repository as a single copy on the same physical disk.

## 1. Install Linux Mint

1. Download the Linux Mint 22.x Cinnamon 64-bit ISO from https://linuxmint.com/download.php.
2. Prepare the USB stick with Mint USB Image Writer or Balena Etcher.
3. Boot the computer from the USB stick and install Linux Mint.
4. If you use the erase-disk option during installation, choose the correct disk; the data on that disk is erased.
5. Create a normal user, log in to the desktop, connect to the internet and complete the updates.

## 2. Unpack and run the package

Unzip the ZIP. `KUR.sh`, `setup-restic-backup.sh`, `configure-beszel-agent.sh` and the other helper files must stay in the same parent folder.

```bash
chmod +x KUR.sh
./KUR.sh
```

`sudo` may ask for your password. The installer first asks **Language / Dil** (1 English, 2 Türkçe; Enter = English; `HL_LANG=tr bash KUR.sh` skips the question). It asks for one username and one password (the password is asked twice, at least 14 characters; if it is too short or does not match, it says why and asks again). The same password is used for the settings page login, Samba, RustDesk, ntfy and Syncthing; Samba uses the Linux account as the username. It also asks once whether to set up the Home Assistant VM (default yes). After that it proceeds without asking questions. Do not close the terminal during the install. The install log is kept under `~/HomeLab_Logs/kurulum-*.log`; at the end of the install the IP, links, RustDesk ID and ntfy details are written to `~/HomeLab_Logs/kurulum-ozeti-*.txt` and shown on screen (it contains secrets and is not written to the log). If an error occurs, the terminal shows the error line, exit code, command and log path. Before sharing the log, review it for private IPs or usernames.

After the install, log out and back in once (docker and plugdev groups): USB pairing and Docker control only work after that.

During the install:

- Tailscale, RustDesk, AdGuard, automatic security updates and a Timeshift snapshot are installed/taken without questions. For the Tailscale login you need to open the link shown in the summary at the end of the install in a browser (the install does not wait). Restic needs an external disk, so it is set up with a separate tool.
- AdGuard Home is installed automatically; the server's local-network IPv4 address is found automatically (if it cannot be found the step is skipped and a warning is written).
- The processor, RAM, graphics card and disks are detected and listed automatically; no graphics card driver or GPU configuration is done, and Ollama runs on the CPU.
- Regardless of the amount of RAM, `qwen2.5:1.5b-instruct-q4_K_M` is explicitly downloaded on the first install. The model file in the official Ollama library is about 986 MB. Only if the HomeLab disk has less than 2 GiB free is the download skipped, to protect storage, and a warning is shown. If needed, the user can download another model by hand later.
- The disk list is detected for Scrutiny; if NVMe is present you are asked whether extra capability should be granted.
- The username and a password of at least 14 characters are taken (they are also the settings page login).
- The same password is used for Samba (the username is the Linux account).
- If the external backup disk is connected, Restic automation can be configured.
- If Tailscale is selected, the login step is asked at the end of the install.
- The Cinnamon power button is set to shut down directly, with the previous user preference backed up; a restart is needed for the systemd setting.

Packages and Docker images are downloaded from the internet. The install may take a while depending on connection speed.
If a Docker stack cannot start (image could not be downloaded, port conflict, etc.) the install does not stop; it is written to the warning list and at the end it shows which stack must be started by hand.

## 3. First steps after the install

If any service does not start, run `TANI.sh` from the package as a normal user:

```bash
bash TANI.sh
```

The report is created under `~/HomeLab_Logs/tani-*.txt`. This report checks service states, Docker containers, Compose validation, ports and Restic/Agent status; it does not print password and token values.


1. Create the Beszel Hub admin account at `http://SERVER-IP:8090`.
2. In the Hub start the system record with **Add System**; run `configure-beszel-agent.sh` with the key and token given.
3. Check the Scrutiny disk status at `http://SERVER-IP:8081`.
4. If AdGuard was selected, complete the first-run wizard at `http://ADGUARD-LAN-IP:3000`. After setup, the admin interface is at `http://ADGUARD-LAN-IP:3002`. Change the clients' DNS settings by hand only after you have tested it and fixed the server IP with a DHCP reservation/static IP.
5. Check your own website (Caddy), an empty placeholder page that you replace with your own site, on the server itself at `http://127.0.0.1:8088`. The web files are in `/srv/homelab/web/public` and the Caddy configuration in `/srv/homelab/config/caddy/Caddyfile`. On a clean install these can be edited by your normal Linux account. After changing the Caddyfile, reload the configuration with `sudo docker compose -f /srv/homelab/compose/web/compose.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile`.
6. If Restic is configured, start the first backup and check the systemd log.

### Notification, security and maintenance tools

- **ntfy (notifications, `http://SERVER-IP:2586`):** The install creates a random topic name and a `homelab` user (`sudo cat /etc/homelab-installer/ntfy.env`). In the ntfy app on your phone add the server address, this user and the topic. Tailscale is needed to receive them away from home. `homelab-health-check` checks every 10 minutes for disk above 90%, failed services, stopped containers and backups older than 48 hours; it notifies only on a new problem and when it is fixed. A notification is also sent when the Restic backup/check services fail.
- **Timeshift:** Recommends taking a system snapshot before the install (Timeshift must already be set up).
- **Automatic security updates (optional):** Ubuntu security repository only; Docker packages are excluded; no automatic reboot. Because the default setting does not match on Mint, the source is written explicitly.
- **SSH key login:** `bash /srv/homelab/tools/harden-ssh.sh` checks your key and the permissions, asks you to type that you verified key login, then disables password login. To undo, use `--geri-al`.
- **Web login reset:** if you forget the settings page login, run `bash /srv/homelab/tools/reset-web-login.sh` (no restart needed).

### Do these immediately on first login

Dockge, Beszel, Uptime Kuma and n8n let whoever opens them first create the admin account; create it yourself right after the install. File Browser uses the installation username and password. Scrutiny has no login screen. Add a password to the Syncthing interface (127.0.0.1:8384). The same list is printed on screen at the end of the install.

## 4. HomeLab settings page login

- The only HomeLab web page is the agent's settings page, `http://127.0.0.1:8765`, in the server's own browser.
- It asks for a login (HTTP Basic; the browser asks once per session): the same username and password you chose during the installation.
- The login is stored as a PBKDF2 hash in `~/.config/HomeLab/web-login` (mode 600).
- Local scripts that push alerts (`/api/info`, `/api/notify`, `/api/push`) stay open without a login because the port is loopback-only.
- The **Services** page of the settings and of the phone panel start/stop Docker containers; your user must be in the `docker` group (log out and back in once after the install).
- If you forget the login: `bash /srv/homelab/tools/reset-web-login.sh` (no restart needed).

Remember that a Linux account added to the Docker group can obtain near-root privileges through Docker. The install records the first membership; on removal it only reverts a membership that this package added.

## 5. Data and configuration locations

- Compose files: `/srv/homelab/compose/`
- Persistent application data: `/srv/homelab/appdata/`
- Shared files: `/srv/homelab/data/`
- Website files: `/srv/homelab/web/public/`
- Caddy configuration: `/srv/homelab/config/caddy/Caddyfile`
- Helper install tools: `/srv/homelab/tools/` (`setup-restic-backup.sh`, `configure-beszel-agent.sh`, `reset-web-login.sh`, `harden-ssh.sh`, `lang.sh`)

Compose files are kept root-owned; use `sudo` to change them. Existing Compose files are not overwritten. No broad `chown -R` is applied to existing data folders.

## 6. Security and external access limits

- The UFW package is installed but the firewall is not enabled; a wrong rule could cut off SSH/RustDesk access.
- Fail2ban is enabled against SSH login attempts.
- Some Docker services publish ports on LAN interfaces. Do not forward ports 22, 445, 5001, 8090, 3001, 8081, 8080, 5678, 53 or 45876 on the router to the internet.
- Important: traffic to ports published by Docker can bypass UFW rules. Simply running `ufw enable` does not secure these container ports; before any internet exposure, the Docker `DOCKER-USER` chain and a LAN/Tailscale access policy must be designed separately.
- Your own website (Caddy) is served only on `127.0.0.1:8088` unless you change the Caddyfile/compose port.
- AdGuard binds to the selected LAN IP; the router DNS or DHCP settings are not changed.
- No connection is made to a Cloudflare account, and no DNS record/Tunnel/Access policy is created.
- A fixed public IP is not needed on a home connection; Cloudflare Tunnel makes an outbound connection from the server. However, the domain must be in Cloudflare DNS, and a Tunnel token and hostname mapping are needed; these will be supplied by the user in a later stage. The local network IP may change with DHCP; a DHCP reservation on the router is optional. On devices that support mDNS the `computer-name.local` name can be tried.
- Domain, HTTPS, Cloudflare Tunnel and Access configuration for the public website is a separate later stage.

Recommended final architecture:

- `yourdomain.com`: public personal website

Do not open external access before the Cloudflare side is configured separately.

## 7. Running on top of an existing installation

This package is designed primarily for a **clean Linux Mint 22.x install**. Some operations can be re-run:

- Existing Compose YAML files are not overwritten.
- Existing application data is not deleted.
- Missing new service stack files are added.

However, existing Compose projects are re-applied with `up -d`; the Docker daemon setting, service versions and existing container behaviour may change. Before running directly on an existing server, back up `/srv/homelab` and the Docker configuration. Adding an Agent to a Beszel Hub installed differently before, and AdGuard port/IP conflicts, must also be checked separately.

## Home Assistant OS virtual machine (KVM)

HomeLab can run the **official Home Assistant OS** as a virtual machine (KVM/QEMU/libvirt) next to the Docker services. The installer asks once at the start ("Set up the Home Assistant VM? [Y/n]") and does the work in step 11. Run `HL_HAOS=no bash KUR.sh` to skip it without a question.

**What the installer does:** checks the hardware, installs `qemu`, `libvirt`, `virt-install`, `OVMF` and `socat`, downloads the latest official `haos_ova` image from the `home-assistant/operating-system` GitHub releases (SHA-256 verified when GitHub publishes it), creates the VM `homeassistant` (UEFI, virtio disk, NAT network with a fixed address `192.168.122.10`), turns on autostart, lets the VM network through next to Docker (`homelab-libvirt-fw.service`) and forwards the computer's port **8123** to the VM for the home network only (`homelab-ha-forward.service`).

**Automatic sizing (override with `HAOS_RAM_MB`, `HAOS_VCPUS`, `HAOS_DISK_GB`):**

| Computer | VM memory | VM CPUs | VM disk |
|---|---|---|---|
| under 6 GB RAM | not created (reason shown) | - | - |
| 6-8 GB RAM (e.g. an 8 GB server) | 2 GB | 1-2 | 32 GB |
| 9-16 GB RAM | 4 GB | 2-4 | 32 GB |
| more than 16 GB RAM | 6 GB | 2-4 | 32 GB |

**When the VM cannot be created** the installation does **not** fail. The reason is written to `/var/lib/homelab-installer/haos.status`, listed in the final summary and shown in the "Home Assistant" row of the phone panel. Typical reasons: virtualization is off in BIOS/UEFI (enable *Intel VT-x* / *AMD-V / SVM Mode*), the computer is itself a virtual machine, less than 6 GB RAM, less than 40 GB free disk, or no internet. Alternatives: run Home Assistant Container in Docker (`ghcr.io/home-assistant/home-assistant:stable`, host network, no add-ons), or use a separate small computer with Home Assistant OS. After fixing the cause, run `bash /srv/homelab/tools/setup-haos-vm.sh` again (it is safe to repeat; an existing VM is never recreated).

**Use it:** open `http://<server-IP>:8123` from the home network and create the owner account yourself (using the same username and password as the rest of HomeLab is recommended). The first start can take 10-20 minutes. Manage the VM with `sudo homelab-haos status|start|stop|restart|backup`; the phone panel shows its state on the Home page and has *Home Assistant: start VM / stop VM* keys under Shortcuts. To control entities from the panel, create a long-lived access token in Home Assistant and enter the address and token in the HomeLab settings page (`http://127.0.0.1:8765`, Home Assistant section; the existing mechanism is used, there is no second one).

**Zigbee / Matter / Thread / ESPHome:** the infrastructure is ready but nothing is configured, because you have no devices yet. When you plug in a USB adapter (for example a Zigbee or Thread stick), run `sudo homelab-haos usb list` (adapters that look like Zigbee/Z-Wave/Thread sticks are marked `*`), then `sudo homelab-haos usb attach <vendor:product>`, or `sudo homelab-haos usb auto` to attach every known adapter that is plugged in. It works the same on any computer and the attachment survives reboots. Then add the *Zigbee Home Automation*, *Matter* or *Thread* integration inside Home Assistant; ESPHome can be installed as a Home Assistant add-on.

**Security:** port 8123 is reachable from the home network only; **do not forward it on the router**. Use Tailscale for remote access. HomeLab does not touch router, DNS, Cloudflare or Tailscale settings.

**Backup and restore:** the best backup is Home Assistant's own (*Settings > System > Backups*, keep a copy off the VM). `sudo homelab-haos backup` additionally makes a cold copy of the VM disk in `/srv/homelab/backups/haos` (newest 3 kept). To restore: stop the VM (`sudo homelab-haos stop`), copy the backup file over `/var/lib/libvirt/images/haos.qcow2` (`sudo cp --sparse=always <backup> /var/lib/libvirt/images/haos.qcow2`), then `sudo homelab-haos start`. Or reinstall with the setup script and restore the Home Assistant backup in its welcome screen.

**Tested:** on an Intel i7-2600 with 8 GB RAM the VM boots, gets the address `192.168.122.10`, and Home Assistant answers on port 8123 from the home network. **Not tested:** USB adapters and Zigbee/Matter/Thread devices (none available), and VM restore.

**Troubleshooting the VM:**
- *The installer says the VM was not set up because of virtualization:* enable Intel VT-x / AMD-V (SVM) in BIOS/UEFI, then run `bash /srv/homelab/tools/setup-haos-vm.sh`.
- *The VM is "running" but has no address (`sudo virsh net-dhcp-leases default` is empty, the panel says "no network address yet"):* look at the console with `sudo virsh console homeassistant` (exit with Ctrl+]). A UEFI menu means the VM did not boot; the installer creates the VM with Secure Boot and enrolled keys **off** for this reason. Recreate it with `HAOS_RECREATE=1 bash /srv/homelab/tools/setup-haos-vm.sh` (this deletes the VM and its Home Assistant data).
- *No Home Assistant VM image is found:* a brand-new Home Assistant OS release may exist before the PC image is attached; the installer then uses the newest release that has it.
- *Port 8123 does not answer yet:* the first start takes 10-20 minutes; test with `curl -s -o /dev/null -w "%{http_code}\n" http://SERVER-IP:8123` (a `302`/`307` answer means it is up).
- *The phone Services page shows a Docker error:* the agent needs the `docker` group; log out and in (or reboot) once after the install.

## USB (ADB) connection: phone-side setup

The computer side is automatic, but Android must allow the computer once:

1. **Developer options:** Settings > About phone > tap **Build number** 7 times.
2. Settings > System > Developer options > turn on **USB debugging**.
3. Plug in the USB cable and choose **File transfer** (not "Charging only") in the USB notification.
4. On the phone, a prompt "Allow USB debugging?" appears: tick **Always allow from this computer** and tap **Allow**.
5. Log out and in once after the install (the `plugdev` group), then check `adb devices`: the state must be `device`.

If `adb devices` shows `unauthorized`, the HomeLab agent shows "no phone connected, waiting" (it counts only `device`). Fix: Developer options > **Revoke USB debugging authorizations**, unplug, turn USB debugging off and on, plug in again and accept the prompt. Try another cable or another USB mode if no prompt appears.

## GitHub Pages pairing page: first setup

The pairing page `https://kleanty.github.io/HomeLab/pair/` is published by `.github/workflows/pages.yml`. One-time repository setting: **Settings > Pages > Build and deployment > Source: GitHub Actions** (not "Deploy from a branch"). The workflow has two jobs, `build` (uploads the `site/` artifact) and `deploy` (needs `build`); a single combined job can fail with `Found 0 artifact(s)` / `Fetching artifact metadata failed`. If a run fails with "Pages not enabled", set the Source and re-run the workflow.

## 8. Check commands

```bash
sudo docker ps
sudo docker compose ls --all
sudo systemctl status fail2ban ssh smbd docker systemd-journald --no-pager
sudo timedatectl status
sudo nvme list
sudo systemctl status homelab-restic-backup.timer homelab-restic-check.timer --no-pager
```

## 9. Known limits / next stages

- The Linux Mint operating system is not installed automatically from USB.
- Graphics card driver and GPU acceleration are not in this package; Ollama always runs on the CPU. If you wish, you can install the driver and the NVIDIA Container Toolkit by hand afterwards.
- The model choice does not change with hardware; every install uses the `qwen2.5:1.5b-instruct-q4_K_M` model. Response speed on the CPU depends on the processor and RAM.
- The AdGuard DNS setting is not applied to the router automatically; the static DHCP reservation and client DNS setting are done by the user.
- Caddy does not configure the domain, HTTPS or Cloudflare Tunnel on its own.
- Scrutiny cannot guarantee SMART passthrough of USB-SATA bridges or RAID controllers.
- UPS/NUT configuration is not added without knowing a real UPS model and connection type.
- Automatic operating-system updating is not enabled; run updates in a controlled way through Mint Update Manager. A firewall and an SSH key policy should be applied to the server separately.
- Beszel Agent needs Docker socket access for Docker statistics; this is highly privileged access.
- RustDesk is downloaded from the official GitHub releases (.deb); if GitHub provides a checksum (digest) the SHA-256 is verified, then it is installed with apt. If the download or verification fails the install is skipped and a warning is written.
- The RustDesk permanent password is asked at the start of the install and set with `rustdesk --password` (while the command runs, the password may briefly be visible in the process list). If it cannot be set a warning appears; you can set it by hand under RustDesk > Settings > Security.
- In headless (no monitor) operation the screen may come up black; plug in an HDMI/DisplayPort 'dummy' plug. Linux Mint Cinnamon uses X11, so RustDesk is compatible (limited on a Wayland session).
- Sleep prevention: the sleep/suspend/hibernate targets are masked, lid close and idle sleep are ignored, and screen blanking and the screen lock are turned off in Cinnamon. The previous Cinnamon values are backed up and restored by KALDIR.sh. Because the screen lock is off, anyone with physical access to the computer sees the desktop.
- Automatic login (LightDM) is enabled automatically during the install; anyone with physical access to the computer can get into the desktop.
- When uploading to GitHub: .gitignore and .gitattributes (LF line endings) are ready in the package; if you upload from Windows the execute permission is lost, so run the scripts with `bash KUR.sh`.


## 10. Removing a previous HomeLab installation

If you did a clean Linux Mint install you do not need to run `KALDIR.sh`. This tool is only for removing a previous HomeLab installation on the same computer.

`KALDIR.sh` in the package removes this installation's known containers, the Restic timers and the HomeLab system configuration. Run it as a normal user:

```bash
bash KALDIR.sh
```

The process asks for the `YES` confirmation. By default it keeps the application data in `/srv/homelab`, Ollama models, shared files, web content and local backups. If you want to delete everything you must additionally type `DELETE`. This choice cannot be undone. The external Restic repository is never deleted under any condition.

Removing system packages is a separate, second choice. The newer version records the existing packages before the install and, during removal, tries to remove only the packages this install added; it keeps previously installed packages. In particular, if OpenSSH is removed your remote connection may be cut. If there is no ownership record for earlier packages, the package-removal step is skipped so that no package is deleted by mistake. So use it only while sitting at the computer. If package removal is not selected, KUR.sh may reinstall missing services on its next run.

The removal log is kept under `~/HomeLab_Logs/kaldirma-*.log`. Some system settings the install added are tracked with marker files; the removal script preserves pre-existing configuration as far as possible. The removal script has not been run on a real Linux Mint computer in this environment; only Bash syntax and static content checks have been done. Back up important data before removal.

## Phone agent and app: build order

Repository: https://github.com/Kleanty/HomeLab

0. Once: in the repository choose **Settings > Pages > Source: GitHub Actions**, then run **Actions > pages > Run workflow**. The phone pairing QR points to the page `https://kleanty.github.io/HomeLab/pair/` (the code is in the `site/` folder); if this page is not published the QR does not open.
1. The phone app is built by GitHub Actions: in the GitHub repository run **Actions > build-agent > Run workflow** (then build-apk). build-agent builds the agent and publishes it as the `v<version>` release. `KUR.sh` downloads the agent from there; without this step the agent is not installed (the install continues otherwise and warns at the end).
2. **Actions > build-apk > Run workflow**: builds the APK. Without a signing key, the debug-signed APK appears only under **Artifacts** as `homelab-panel-apk`; it is not attached to the release. For permanent signing add `HOMELAB_KEYSTORE_BASE64`, `HOMELAB_STORE_PASSWORD`, `HOMELAB_KEY_ALIAS` and `HOMELAB_KEY_PASSWORD` under Settings > Secrets and variables > Actions; in that case `HomeLab-<version>.apk` and `SHA256SUMS-<version>.txt` are attached to the `v<version>` release. Do not lose or change the signing key: if it changes you must uninstall the app on the phone and install it again. Send the APK to the phone and install it ("install from unknown sources" permission is required).
3. Install the agent and the APK from the same version (the pairing link changed: an old APK does not recognise the new QR). Connect the phone by USB (USB debugging turned on in developer options) or by Wi-Fi (the "Pair phone over Wi-Fi" QR on the settings page).
