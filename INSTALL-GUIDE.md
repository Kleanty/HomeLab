# HomeLab — Installation Guide

[Türkçe: KURULUM-REHBERI.md](KURULUM-REHBERI.md) · Repository: https://github.com/Kleanty/HomeLab

This guide is for installing the HomeLab package **after Linux Mint has been installed on an empty/new computer**. `KUR.sh` does not install Linux Mint; once the Mint desktop is up, it prepares Docker and the HomeLab services.

## 1. Before you start

### Computer and operating system

- You need Linux Mint **22.x Cinnamon 64-bit**, an Ubuntu 24.04 `noble` base and an `amd64` processor. For any other version/architecture this install script stops on purpose.
- Install Linux Mint from USB, create a normal (non-root) user and log in to the desktop.
- An internet connection is required. Docker, Python packages and container images are downloaded; the download time can be long depending on the connection.
- The computer must not be switched off during the install and the terminal must stay open.
- About **10 GiB of free space** on the root disk is recommended. Ollama model files may need much more extra space.
- Have physical access to the machine. The install enables SSH/Samba services and may make settings that need a restart.

### What to prepare at this stage

- A username and a strong **password of at least 14 characters** for the HomeLab settings page login.
- A username and password you will use (the same password for everything, including Samba).
- If you want Restic automatic backup, an external disk separate from the system disk. The backup setup can be postponed.
- At the start of the install you are first asked for a language, then a username and a password. The password is entered twice; if it is wrong you are asked again. There is no other yes/no question.

> Because a clean install is the target, there is no update scenario that preserves existing system data. Choosing the wrong disk during the Linux Mint install may erase the data on that disk.

## 2. Unpack the ZIP correctly

Extract the ZIP into a folder on the Linux Mint desktop. The files in the archive must stay in the same parent folder with the same folder structure:

```text
HomeLab/
├── KUR.sh
├── lang.sh
├── KURULUM-REHBERI.md
├── KALDIR.sh
├── TANI.sh
├── homelab-docker-lan-only
├── homelab-notify
├── homelab-health-check
├── reset-web-login.sh
├── harden-ssh.sh
├── setup-restic-backup.sh
└── configure-beszel-agent.sh
```

Do not copy `KUR.sh` on its own somewhere else; it needs to find the helper files next to it.

## 3. Start the install

Open the terminal in this folder. In the file manager you can right-click the folder and use "Open in Terminal", or change to the folder in Terminal. Then:

```bash
chmod +x KUR.sh
./KUR.sh
```

**Do not run `sudo ./KUR.sh`.** The script starts as a normal Linux user and asks for privileges with `sudo` when needed. If it is started as root it stops on purpose.

If the pre-check fails it is expected to stop without changing anything on the system. After the passwords are taken, the install starts after 5 seconds; press `Ctrl+C` to cancel. After the install has started you can also stop it with `Ctrl+C`.

## 4. Choices asked during the install

**Asked at the start of the install:** the language (Language / Dil: English or Türkçe; the choice is used for all installer messages, notifications and the helper scripts), the username (if you leave it empty, your Linux account name; only letters, digits, `.` `_` `@` `-`) and the password (at least 14 characters, twice). The same details are applied to the settings page login, RustDesk, ntfy and Syncthing; the password is also applied to Samba (the username is the Linux account). You create the first account of Dockge, Beszel, Uptime Kuma, n8n and AdGuard yourself with the same details. The first File Browser password is random (it is in the summary file).

| Component | How it is installed |
|---|---|
| Timeshift snapshot | Taken automatically if installed; if it cannot be taken a warning is written and the install continues. |
| Tailscale | Installed automatically; you open the link in the summary at the end in a browser and log in (the install does not wait). |
| RustDesk | Downloaded from the official GitHub release, installed, and the password you gave at the start is set. The ID is in the summary file. |
| HomeLab Panel (phone panel) | The agent is built from this repository (GitHub > Actions > build-agent, `v<version>` release); KUR.sh downloads it, verifies SHA-256 and runs it as the `homelab-agent` user service; automatic update is off. adb (for the USB connection) is installed. The phone app is in `android-panel/` (GitHub > Actions > build-apk). Pairing: plug in the cable via USB and approve the permission on the phone, or on the server scan the QR "Telefonu Wi-Fi ile eşleştir" (pair the phone over Wi-Fi) at `http://127.0.0.1:8765` > Genel > Wi-Fi & Tailscale (TCP 8766 opens on the local network). The Docker page, the Services on/off switches and USB pairing work after you log out and back in following the install (docker and plugdev groups). 6 pages are prepared (HomeLab, Services, Alerts, System, Processes, Shortcuts); GPU temperature needs the vendor driver, and since the installer does not install an NVIDIA driver there is no GPU widget by default. The phone app is built by GitHub Actions: Actions > build-agent, then build-apk; the APK artifact is named `homelab-panel-apk`, and without the signing secrets it is debug-signed and is not attached to the release. The pairing page is https://kleanty.github.io/HomeLab/pair/ (needs Settings > Pages > Source: GitHub Actions). The health check tests internet (ping) and service responses every 2 minutes; alerts appear open/past on the phone's Alerts page (last 200 records, /var/lib/homelab-installer/health-history). The settings page asks for the same username and password (HTTP Basic, once per session). You can start/stop containers from the `http://127.0.0.1:8765` > Services tab. Beszel Agent appears in this list (and in the phone panel) once its container exists. KALDIR.sh removes the agent and keeps the settings. |
| Automatic login | Turned on automatically (left alone if already set). Needed for RustDesk after a restart on a monitorless server. |
| AdGuard Home | Installed automatically; the LAN IP is found automatically. The router DNS setting is not changed. |
| Graphics card / Ollama | No graphics card driver is installed. Ollama runs on the CPU. |
| Scrutiny NVMe capability | `SYS_ADMIN` is not granted (safe default). |
| Settings page login | Created with the username and password asked at the start; stored as a PBKDF2 hash in `~/.config/HomeLab/web-login` (mode 600), not in plain text. If you forget it: `bash /srv/homelab/tools/reset-web-login.sh` (no restart needed). |
| ntfy / Syncthing | Account/interface login is set with the same username and password. |
| Samba | The same password is set; the username is the Linux account. |
| Restic | The package is installed; since the backup target needs an external disk, it is set up with `sudo bash /srv/homelab/tools/setup-restic-backup.sh` after you connect the disk. |

If optional steps such as AdGuard or Restic are skipped, the main install continues.

## 5. What does KUR.sh do?

The install proceeds in the order below. If a critical error occurs in a step, the script logs the error and stops; it does not go on to later stages.

1. **Pre-check:** Verifies the Linux Mint version and the `amd64` architecture; checks the required commands and the files in the ZIP; reports free disk space and possible port conflicts.
2. **Base packages:** Installs Python/venv, Samba, Syncthing, OpenSSH, the UFW package, Restic, Fail2ban and disk/sensor diagnostic tools. UFW is installed but not enabled automatically.
3. **Docker:** Installs Docker Engine/Compose and starts the service. Adds the user to the `docker` group and writes the Docker log rotation default only on a fresh install. The Docker group is highly privileged.
4. **Remote tools:** Tailscale and RustDesk are installed automatically. Also locks sleep mode (so the server does not sleep) and sets up automatic login.
5. **Optional local DNS:** Verifies the LAN IP for AdGuard Home. It does not change the DNS settings of the router or clients itself.
6. **Base services:** Sets up the user systemd session so it can run at boot (linger), enables Syncthing, SSH, Samba and the mDNS service. For the Cinnamon power-button setting it tries to record the previous value.
7. **Directories and Compose definitions:** Prepares data, application settings and Compose files under `/srv/homelab`. It does not overwrite existing Compose files. Dockge, Beszel, Uptime Kuma, File Browser, Ollama+n8n, Scrutiny and your own website (Caddy) are created; AdGuard and Beszel Agent are configured optionally/separately.
8. **Containers and local AI:** Compose files are validated and started. If a stack does not start the install does not stop; it is written to the warning list on the final screen. Regardless of RAM, `qwen2.5:1.5b-instruct-q4_K_M` is downloaded on the first install (the model file is about 986 MB, runs on the CPU). Only with less than 2 GiB of free storage is the download skipped and a warning given.
9. **Helper tools:** Installs `setup-restic-backup.sh`, `configure-beszel-agent.sh`, `reset-web-login.sh`, `harden-ssh.sh` and `lang.sh` into `/srv/homelab/tools`. (The HomeLab agent itself is downloaded, SHA-256 verified and started during the early steps; its settings page login is written right after that, as a PBKDF2 hash in `~/.config/HomeLab/web-login`.)
10. **Samba and backup:** Prepares the Samba user with the same password and installs the Restic package. Because the backup needs an external disk, `setup-restic-backup.sh` is run separately.
11. **Result:** Shows the service access addresses, the status check commands and security warnings. If one of the optional components failed it lists a separate warning.

## 6. Main areas the install creates

| Path | Contents |
|---|---|
| `/srv/homelab/compose/` | Docker Compose service definitions |
| `/srv/homelab/appdata/` | Persistent configuration/data of the containers |
| `/srv/homelab/data/` | Shared documents, projects and media |
| `/srv/homelab/web/public/` | Files of your own website (Caddy); an empty placeholder page at first |
| `/srv/homelab/tools/` | Helper tools: `setup-restic-backup.sh`, `configure-beszel-agent.sh`, `reset-web-login.sh`, `harden-ssh.sh`, `lang.sh` |
| `~/HomeLab_Logs/` | Install, diagnostic and helper operation logs |

The settings page login is stored as a PBKDF2 hash in `~/.config/HomeLab/web-login` (mode 600). Do not share that file, the real `.env` files or the Restic password with anyone.

## 7. After a successful install

First log out and back in once (docker and plugdev groups); USB pairing and Docker control only work after that.

When the install is complete, first check the local services:

```bash
sudo docker ps
sudo docker compose ls --all
sudo systemctl status docker ssh smbd fail2ban --no-pager
```

Main addresses:

| Application | Address |
|---|---|
| HomeLab settings (asks for your login) | `http://127.0.0.1:8765` — on the server only |
| Dockge | `http://SERVER-IP:5001` |
| Beszel | `http://SERVER-IP:8090` |
| Uptime Kuma | `http://SERVER-IP:3001` |
| Scrutiny | `http://SERVER-IP:8081` |
| File Browser | `http://SERVER-IP:8080` |
| n8n | `http://SERVER-IP:5678` |
| Ollama API | `http://127.0.0.1:11434` |
| Your own website (Caddy) | `http://127.0.0.1:8088` — on the server only |

Replace `SERVER-IP` with the Linux Mint computer's current local network IP address. A fixed **public** IP is not needed on a home connection: a Cloudflare Tunnel set up later makes an outbound connection from the server. However, Tunnel/Access is not installed by this package; the domain must be in Cloudflare DNS, and a token and hostname mapping are needed. The local IP may change with DHCP; a DHCP reservation on the router is optional. On network devices that support mDNS a local name of the form `http://computer-name.local:8090` can be used. You cannot open the settings page or your Caddy website directly from another device (both listen on 127.0.0.1 only, unless you change the Caddyfile/compose port); this is a deliberate security boundary.

After the first install:

1. Create the admin account in the Beszel Hub, get the KEY/TOKEN with **Add System** and run `bash /srv/homelab/tools/configure-beszel-agent.sh`.
2. Define the applications you want to monitor in Uptime Kuma.
3. After preparing the external backup disk, configure Restic separately with `sudo bash /srv/homelab/tools/setup-restic-backup.sh`. Do the first backup and a restore test.
4. Do not forward service ports to the internet on the router. Ports published by Docker may bypass UFW.

## 8. If something goes wrong: what to do?

### Install script error handling

On critical Bash errors `KUR.sh` automatically enters its error-handling function. In the terminal it shows:

- the error line,
- the exit code,
- the failed command,
- the path of the detailed log file

The main install log is written under the normal user account at `~/HomeLab_Logs/kurulum-YYYYMMDD-HHMMSS.log`. If you see a "install not completed" message, do not count it as a successful install.

If you interrupt the install with `Ctrl+C`, the log records that the operation was stopped by the user. Half-finished system changes are not deleted automatically; this is deliberate, to protect data.

**Optional** install steps such as Tailscale, RustDesk and Restic may be skipped on some errors without stopping the main install. In that case a `WARNINGS` list is shown on the final screen (printed in the language you chose at the start). Even if you see the "install completed" text, read the warning list and check whether that component was installed.

To open the log:

```bash
ls -lt ~/HomeLab_Logs/
less ~/HomeLab_Logs/kurulum-*.log
```

Press `q` to exit `less`. Before sharing the log for support, review the username, local IP, machine name and private information.

### First diagnostic step

If the install stops halfway, follow this order:

1. **Do not run `KALDIR.sh` and do not delete the `/srv/homelab` folder.** The install script does not delete data automatically on failure; this is protective behaviour. Do not rush to remove half-installed packages or services.
2. Note the first `ERROR` line shown in the terminal and the `Detailed log` path. In the log the real error is usually before the error-handling line that appears later.
3. Open the last part of the log:

   ```bash
   ls -lt ~/HomeLab_Logs/kurulum-*.log | head
   tail -n 120 ~/HomeLab_Logs/kurulum-LATEST.log
   ```

   Instead of `kurulum-LATEST.log` write the real file name from the `ls` output.
4. Get a diagnostic report:

```bash
bash TANI.sh
```

The diagnostic report is written under `~/HomeLab_Logs/tani-*.txt`. The report collects the system, failed systemd services, Docker/containers, Compose file validation, monitored ports and Restic status. It is intended not to print passwords and tokens; still check the contents before sharing.

5. If the error has a fixable cause such as internet/download problems or a temporary APT lock, fix the internet and wait for other package manager operations to finish. Then restart `./KUR.sh` as a normal user **from inside the same extracted package**. In this clean-install scenario, retrying completes missing package steps; it does not automatically delete existing `/srv/homelab` data. It re-validates the existing Compose projects and starts them with `up -d`. So before retrying, check `TANI.sh` and the log output; if there is an unknown error, get support first.
6. If the same error occurs again on re-running, stop retrying over and over. Share the first error message, the last 100-120 log lines, the result of `bash TANI.sh` and the computer's Linux Mint version. Do not share `.env`, passwords, tokens or the Restic password file.

**Restic special case:** The Restic step runs separately from the main install. If `setup-restic-backup.sh` fails after it has begun creating the password/repository settings, the same helper may refuse to run again in order to preserve the existing `/etc/restic` files. In that case do not delete the repository or the contents of `/etc/restic`; check the output of `sudo tail -n 120 /var/log/homelab-installer-restic-setup.log` for secrets and get help first. Do not lose the external repository password.

### Check the service logs

```bash
sudo journalctl -u docker -n 100 --no-pager
sudo docker ps -a
sudo docker compose -f /srv/homelab/compose/monitoring/compose.yaml logs --tail 100
```

If a Docker container does not start, first look at the output of `sudo docker ps -a` and `docker compose ... logs`.

### Why is there no automatic rollback?

The install makes changes in different areas: APT packages, services, Docker containers, the Samba share, the settings page login and a possible external Restic repository. Automatically removing all of them at the moment of an error could delete running Docker data, earlier settings or the backup repository. So the script **does not roll back automatically**; it records what was done and the error in the log and preserves data. Because this is a clean Linux install, for most temporary errors the solution is to fix the error and re-run `./KUR.sh`. Only if the Restic password/repository step stopped halfway, get support first; do not "clean up" by deleting files.

In case of a Docker, SSH, Samba or DNS port conflict, do not stop the service or change the port without identifying which process is using the port.

## 9. External access and security

- The settings page (`127.0.0.1:8765`) and your Caddy website (`127.0.0.1:8088`) listen on the server only; do not publish them externally by opening UFW. The settings page asks for a login; local scripts that push alerts (`/api/info`, `/api/notify`, `/api/push`) stay open because the port is loopback-only.
- External access should only be planned with HTTPS, Cloudflare Tunnel and Cloudflare Access. Creating a Tunnel without an Access application does not by itself provide user authentication.
- The Docker port lock (`homelab-docker-lan-only`) blocks new connections from the internet on Docker ports; this still does not change the fact that you must not set up router forwarding. Status: `sudo iptables -S HOMELAB-LAN-ONLY` and `sudo systemctl status homelab-docker-lan-only`.
- Access to Dockge, n8n, File Browser and the Docker API can have a high impact. Do not set up router port forwarding.
- `KALDIR.sh` is a separate tool that can have destructive results. It is not run for installation. The option to delete data additionally asks for strong confirmation; if you are not sure, do not use it.

## 10. What this package does not do

- It does not write Linux Mint to USB or install the operating system.
- It does not change domain, DNS, Cloudflare Tunnel, Cloudflare Access or router settings.
- It does not create a public portfolio site, a blog, a comment system or a project repository interface; it only puts an empty placeholder web page.
- It does not install a graphics card (NVIDIA) driver or GPU acceleration; Ollama runs on the CPU.
- On the first install, regardless of RAM, `qwen2.5:1.5b-instruct-q4_K_M` (about 986 MB model file) is downloaded; if there is less than 2 GiB free it is skipped and a warning is shown. You can add another model by hand later. No user token is needed to download the Ollama model.
- Ollama response speed depends on the processor and the amount of RAM; if the model is too slow, a smaller model can be added by hand.
- It does not configure UPS/NUT or router DNS.
- Without running on a real server, hardware compatibility, SMART passthrough, mounting of the backup disk at boot or Cloudflare external access cannot be guaranteed.
