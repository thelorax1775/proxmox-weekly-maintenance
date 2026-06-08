# proxmox-weekly-maintenance

![ShellCheck](https://github.com/thelorax1775/proxmox-weekly-maintenance/actions/workflows/shellcheck.yml/badge.svg)

Automated weekly maintenance for Proxmox VE. Downloads and runs the official [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE) maintenance tools every Sunday at 03:00 via a systemd timer.

---

## Features

- **Three-step maintenance pipeline** — repo updates → LXC updates → app updates, run in order
- **Fully unattended** — neutralises the upstream `whiptail`/`clear` prompts so it runs headless under systemd with no TTY
- **Fresh downloads every run** — always uses the latest upstream scripts, no stale caches
- **Retry logic** — retries failed downloads up to 3 times with a configurable delay
- **Concurrent-run protection** — `flock`-based lock prevents overlapping executions
- **Timestamped log file** — persistent record at `/var/log/proxmox-weekly-maintenance.log`
- **Colored console output** — instant visual status when running interactively
- **Optional Discord notifications** — webhook alerts on success and failure
- **Optional email notifications** — summary emails via `mail`
- **Systemd timer** — runs every Sunday at 03:00, catches up if the host was offline

---

## Requirements

- Proxmox VE 7.x or 8.x
- `curl`, `flock`, `bash` (all present on a standard PVE install)
- Internet access from the PVE host

---

## Installation

```bash
# 1. Clone the repository
git clone https://github.com/thelorax1775/proxmox-weekly-maintenance.git

# 2. Enter the directory
cd proxmox-weekly-maintenance

# 3. Install the script to a system path
sudo cp scripts/weekly-maintenance.sh /usr/local/sbin/proxmox-weekly-maintenance
sudo chmod 750 /usr/local/sbin/proxmox-weekly-maintenance

# 4. Install and enable the systemd units
sudo cp systemd/* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now proxmox-weekly-maintenance.timer
```

---

## Configuration

Optional settings can be placed in `/etc/proxmox-weekly-maintenance.conf`.
The file is sourced as bash, so values are plain variable assignments:

```bash
# /etc/proxmox-weekly-maintenance.conf

# Discord webhook URL for success/failure notifications
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN"

# Email address for notifications (requires mailutils or sendmail)
NOTIFICATION_EMAIL="admin@example.com"

# Download retry settings
MAX_RETRIES=3
RETRY_DELAY=10      # seconds between retries
CURL_TIMEOUT=60     # seconds per curl attempt

# update-apps.sh behaviour (controls the app-update step)
APP_CONTAINER_SELECTION="all_running"  # all | all_running | all_stopped | "101,102,105"
APP_BACKUP="no"                        # yes | no — backup each container before its app update
APP_BACKUP_STORAGE=""                  # storage name, required only if APP_BACKUP=yes
APP_AUTO_REBOOT="no"                   # yes | no — reboot containers that request it
APP_CONTINUE_ON_ERROR="yes"            # yes | no — keep updating remaining apps if one fails
```

All settings are optional. The script runs without a config file.

### Unattended execution

The three upstream scripts are interactive by default (`whiptail` dialogs and,
for `update-apps.sh`, `var_*` prompts). This wrapper runs them **fully
unattended** with no TTY:

- `update-apps.sh` is driven by the `var_*` environment variables shown above.
- `update-repo.sh` and `update-lxcs.sh` have no non-interactive mode upstream, so
  the wrapper injects a small preamble at runtime that neutralises `clear` and
  auto-answers `whiptail` (proceed = yes, skip non-running containers = yes, no
  exclusions). The upstream scripts are still downloaded **verbatim** on every
  run — only their runtime environment is controlled, the files are never edited.

---

## Usage

### Run manually

```bash
sudo proxmox-weekly-maintenance
# or
sudo bash /usr/local/sbin/proxmox-weekly-maintenance
```

### Run via systemd (on demand)

```bash
sudo systemctl start proxmox-weekly-maintenance.service
```

---

## Logs

The script appends timestamped entries to `/var/log/proxmox-weekly-maintenance.log`.

```bash
# Tail the log
tail -f /var/log/proxmox-weekly-maintenance.log

# View the most recent run in the systemd journal
journalctl -u proxmox-weekly-maintenance.service -n 100

# View all journal entries for the service
journalctl -u proxmox-weekly-maintenance.service
```

---

## Timer management

```bash
# Check timer status and next trigger time
systemctl status proxmox-weekly-maintenance.timer

# List all timers (with next/last trigger)
systemctl list-timers proxmox-weekly-maintenance.timer

# Disable the timer
sudo systemctl disable --now proxmox-weekly-maintenance.timer

# Re-enable the timer
sudo systemctl enable --now proxmox-weekly-maintenance.timer

# View service logs (current boot)
journalctl -u proxmox-weekly-maintenance.service -b
```

---

## Troubleshooting

**Timer not firing**
```bash
systemctl status proxmox-weekly-maintenance.timer
systemctl list-timers | grep proxmox
```
Check that the unit is enabled (`enabled; vendor preset: disabled` is normal — it just means it was not pre-enabled by the distro).

**Script fails with "no internet access"**
```bash
curl -fsSL --head https://raw.githubusercontent.com
```
Verify the PVE host can reach GitHub. Check firewall rules and DNS resolution.

**Script fails with "another instance is running"**
```bash
ls -la /var/lock/proxmox-weekly-maintenance.lock
```
If no script is actually running (e.g. after a crash), remove the stale lock:
```bash
sudo rm -f /var/lock/proxmox-weekly-maintenance.lock
```

**Email notifications not arriving**
Verify `mail` is installed and configured:
```bash
which mail
echo "test" | mail -s "test subject" your@email.com
```
Install if missing: `apt-get install mailutils`

**Discord notifications not arriving**
Test the webhook manually:
```bash
curl -X POST "$DISCORD_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{"content":"test"}'
```

---

## Scripts executed

| Script | Source URL |
|---|---|
| `update-repo.sh` | `https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/update-repo.sh` |
| `update-lxcs.sh` | `https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/update-lxcs.sh` |
| `update-apps.sh` | `https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/update-apps.sh` |

Scripts are downloaded fresh on every run — no caching.

---

## License

[MIT](LICENSE)
