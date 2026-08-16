# vpn-server-preparation-4-amnezia

A Bash script that prepares and hardens an Ubuntu server before it is used with Amnezia VPN.

The script configures the operating system, administrator account, SSH, UFW, fail2ban, automatic updates, and BBR. It does **not** install Amnezia VPN, Docker, or a VPN protocol by itself.

> [!WARNING]
> This script changes passwords, SSH access, firewall rules, sudo permissions, packages, update/reboot behavior, logging, and kernel network settings. Take a VPS snapshot, keep provider console/rescue access available, and do not close the original SSH session until login on the new SSH port has been verified.

## Download and run

### Previous-style one-line run with IPv6 disabled

Run the following command from the existing working SSH session:

```bash
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 && sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1 && sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1 && sudo wget https://raw.githubusercontent.com/rinxster/vpn-server-preparation-4-amnezia/main/vpn-server-preparation-4-amnezia.sh -O vpn-server-preparation-4-amnezia.sh && sudo chmod +x vpn-server-preparation-4-amnezia.sh && sudo bash vpn-server-preparation-4-amnezia.sh
```

This command disables IPv6 immediately for all interfaces, default interfaces, and loopback; downloads the script from the repository's `main` branch; makes it executable; and starts the first run. Because the commands use `&&`, script execution stops if any preceding command fails.

The three `sysctl -w` changes apply to the running system only and are normally lost after a reboot unless equivalent settings are stored in a persistent sysctl configuration. Disabling IPv6 loopback can also affect software that expects `::1`. Use the method below when IPv6 must remain enabled.

### Download for review or reuse without disabling IPv6

The following commands install the script in a shared location that remains accessible during both stages of the SSH migration:

```bash
sudo wget -O /usr/local/sbin/vpn-server-preparation-4-amnezia.sh \
    https://raw.githubusercontent.com/rinxster/vpn-server-preparation-4-amnezia/main/vpn-server-preparation-4-amnezia.sh
sudo chmod 0755 /usr/local/sbin/vpn-server-preparation-4-amnezia.sh
```

Review the script and its settings before running it:

```bash
sudo less /usr/local/sbin/vpn-server-preparation-4-amnezia.sh
sudoedit /usr/local/sbin/vpn-server-preparation-4-amnezia.sh
```

If you are already logged in as `root`, `sudo` may be omitted.

Both download methods expect the script to be published on GitHub as `vpn-server-preparation-4-amnezia.sh` in the `main` branch.

### First run: stage the SSH migration

If you used the one-line command above, it has already started the first run. Otherwise, run the installed copy from the existing working SSH session:

```bash
sudo /usr/local/sbin/vpn-server-preparation-4-amnezia.sh
```

The script asks for one non-empty password and confirmation. That password is assigned to both the configured administrator and `root`.

On a normal first run, the script intentionally keeps the fallback SSH port `22`, the new port `222`, and any detected current custom SSH port available. Root SSH login also remains temporarily enabled. If the script is already being run with `sudo` by the configured administrator over port `222`, it proceeds directly to finalization instead. A successful staging run ends with:

```text
SSH MIGRATION IS STAGED, NOT FINALIZED.
```

Do not close this session.

### Test the new SSH connection

Open a second terminal on your computer and connect using the new administrator and port. Replace `SERVER_IP` with the public IP address of the server:

```bash
ssh -p 222 0dmin4eg@SERVER_IP
```

The same command works in Windows PowerShell, macOS, and Linux when the OpenSSH client is installed.

If your VPS provider has a separate cloud firewall or security group, allow TCP port `222` there before testing. The script manages UFW on the server only.

### Second run: finalize the SSH migration

After login on port `222` succeeds, run the script again from that exact new session. If you installed the shared copy, use:

```bash
sudo /usr/local/sbin/vpn-server-preparation-4-amnezia.sh
```

If the first one-line command saved the script in a directory the new administrator cannot access, download and run it again from the new session:

```bash
sudo wget https://raw.githubusercontent.com/rinxster/vpn-server-preparation-4-amnezia/main/vpn-server-preparation-4-amnezia.sh -O vpn-server-preparation-4-amnezia.sh && sudo chmod +x vpn-server-preparation-4-amnezia.sh && sudo bash vpn-server-preparation-4-amnezia.sh
```

Finalization occurs only when the script verifies that:

- the connection is using the configured new SSH port; and
- the configured administrator invoked the script through `sudo`.

The final run removes the script-managed fallback-port rule, configures SSH to use only port `222`, disables root SSH login, applies the final fail2ban policy, and offers an optional reboot.

Running the script directly as `root`, through `su`, or from the old SSH port intentionally leaves it in migration mode.

## Supported systems and requirements

- Ubuntu `18.04`, `20.04`, `22.04`, `24.04`, or `26.04`.
- A systemd-based Ubuntu server or VPS.
- An existing working OpenSSH server. The script does not install `openssh-server`.
- Root privileges and the `sudo` package, including `visudo`. The script uses `visudo` even when launched directly as `root`.
- Working Internet access and Ubuntu APT repositories.
- `wget` for the download command shown above.
- Provider console/rescue access and a server snapshot are strongly recommended.

Test the script in a disposable VM before using it on a production server.

## Configuration

Edit the constants near the beginning of the script before the first run:

| Setting | Default | Purpose |
| --- | --- | --- |
| `SSH_PORT` | `222` | Final SSH server port. |
| `SSH_FALLBACK_PORT` | `22` | Temporary recovery port used during migration. |
| `ENABLE_SSH_PASSWORD_AUTH` | `true` | Controls the global SSH password-authentication policy. |
| `ADMIN_USER` | `0dmin4eg` | Administrator account created or updated by the script. |
| `UPDATE_SCHEDULE` | `Sun *-*-* 23:00:00` | Weekly update time in the server's local timezone. |
| `FAIL2BAN_BANTIME` | `1h` | Final fail2ban ban duration. |
| `FAIL2BAN_FINDTIME` | `10m` | Final fail2ban retry observation window. |
| `FAIL2BAN_MAX_RETRY` | `10` | Final number of failed attempts allowed in the observation window. |
| `ALLOWED_TCP_PORTS` | `222`, `443` | TCP ports managed and allowed by UFW. |
| `ALLOWED_UDP_PORTS` | empty | UDP ports managed and allowed by UFW. |

With the default `ENABLE_SSH_PASSWORD_AUTH="true"`, SSH password authentication is enabled globally for accounts allowed by the rest of the SSH policy. During staging, this also permits root password login because temporary recovery mode sets `PermitRootLogin yes`.

If `ENABLE_SSH_PASSWORD_AUTH` is changed to `false`, make sure the administrator has a usable SSH public key **before the first run**. The staging run applies this setting immediately, and a missing key would prevent the required test login on the new port.

### Firewall ports

Add or remove quoted entries in the arrays at the beginning of the script. Individual ports and UFW port ranges are supported:

```bash
readonly -a ALLOWED_TCP_PORTS=(
    "${SSH_PORT}"
    "443"
    "8000:8010"
)

readonly -a ALLOWED_UDP_PORTS=(
    "51820"
)
```

Keep `"${SSH_PORT}"` in `ALLOWED_TCP_PORTS`; the script refuses to configure UFW without it. Add every TCP or UDP port required by the VPN configuration before running the script.

UFW rules created by the script are displayed as numeric ports and protocols, without application-profile names or rule comments. Unrelated UFW rules are preserved, while obsolete rules previously recorded as script-managed are removed.

## What the script does

### Administrator and passwords

- Rejects an empty password and asks again when the confirmation does not match.
- Creates a new `ADMIN_USER` with `/bin/bash`, or validates that an existing account already uses `/bin/bash`; it also unlocks the account and adds it to the `sudo` group.
- Sets the entered password for both `ADMIN_USER` and `root`.
- Grants the administrator unrestricted passwordless sudo through `/etc/sudoers.d/`.
- Copies unique authorized SSH keys from `root` and the user who invoked `sudo`, when available.

### Packages

- Runs `apt-get update` and `apt-get upgrade -y`.
- Installs UFW, fail2ban, the fail2ban systemd backend dependency, unattended upgrades, and reboot-notification support.
- Tries to install the optional convenience packages `curl`, `mc`, and `speedtest-cli`.

### Weekly unattended updates

- Installs a persistent systemd timer that runs every Sunday at `23:00` by default.
- Updates package indexes and installs unattended updates.
- Schedules a reboot one minute later only when Ubuntu creates `/run/reboot-required`.
- Disables the standard daily unattended-upgrade timer so installation is controlled by the weekly job.

Because the timer is persistent, a scheduled run missed while the server is powered off can start shortly after the next boot. The job reboots whenever `/run/reboot-required` exists after unattended-upgrade finishes, including when that marker was created before the current weekly run. Choose a schedule that is safe for the server's users.

### UFW firewall

- Sets the default incoming policy to `deny` and outgoing policy to `allow`.
- Adds the desired numeric TCP and UDP rules before removing obsolete script-managed rules.
- Keeps both old and new SSH ports open during migration.
- Enables UFW immediately and at boot, then verifies that every requested rule is active.

### Safe two-stage SSH configuration

- Detects the current SSH client, server port, server address, and invoking user.
- Supports traditional `ssh.service` activation and Ubuntu 24.04+ socket activation.
- Keeps a recovery port and root login during staging.
- Validates the generated configuration with `sshd`, checks the effective administrator authentication policy, restarts the correct SSH units, and performs a real local SSH handshake on every required port.
- Automatically restores the previous SSH configuration if validation, restart, or handshake checks fail during the run.
- Disables root SSH login and removes fallback access only after a proven administrator login on the new port.

### fail2ban and security logging

- Removes the legacy `/etc/systemd/journald.conf.d/no-logs.conf` override, restarts `systemd-journald`, and enables and starts `rsyslog` when its service is installed.
- Keeps SSH events available to fail2ban through the systemd journal.
- Enables the fail2ban `sshd` jail with the systemd backend and verifies that the service and jail are operational.
- During migration, uses a temporary `5m` ban, allows `20` retries, and ignores the detected provisioning client IP when possible.
- After finalization, uses the configured final defaults: a `1h` ban, a `10m` observation window, and `10` retries.

### Network settings

- Enables the BBR TCP congestion-control algorithm.
- Selects the `fq` queue discipline used with BBR.
- Disables IPv4 ICMP echo replies. The server therefore will not answer ordinary IPv4 `ping` requests after this step.

### Result reporting

Each operation is tracked separately. The final summary displays completed steps in green and failed or skipped steps in red. The script exits with a non-zero status when any tracked operation fails.

Do not close the original connection or reboot when the summary contains a failure.

## Verify the result

Check SSH and numeric firewall rules:

```bash
sudo sshd -t
sudo ss -lntp
sudo ufw status numbered
```

Inspect the effective SSH policy for the administrator. Set `CLIENT_IP` to the public IP address from which the administrator connects:

```bash
CLIENT_IP="203.0.113.10"
sudo sshd -T -C "user=0dmin4eg,host=localhost,addr=${CLIENT_IP},laddr=127.0.0.1,lport=222" \
    | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|authenticationmethods)'
```

Check fail2ban and the weekly update timer:

```bash
sudo fail2ban-client status sshd
sudo systemctl status ufw fail2ban weekly-unattended-upgrades.timer --no-pager
systemctl list-timers weekly-unattended-upgrades.timer
```

Check BBR, the queue discipline, and the IPv4 ping policy:

```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
sysctl net.ipv4.icmp_echo_ignore_all
```

The expected values are `bbr`, `fq`, and `1` respectively.

## Important notes

- Complete the second run promptly. Migration mode temporarily retains root SSH access and relaxed fail2ban limits.
- The administrator receives `NOPASSWD: ALL`. Change this policy if it is not appropriate for your security model.
- Password validation requires a non-empty matching value but does not enforce password complexity.
- Port `443/tcp` is allowed by default. Required Amnezia/VPN UDP ports are not opened automatically; add them to `ALLOWED_UDP_PORTS`.
- A provider firewall, security group, or NAT configuration is outside the scope of this script.
- Re-running the script repeats package upgrades and asks for the administrator/root password again.
- Do not use a `curl | bash` or `wget | bash` pipeline. Download and review the script before executing it as root.

## Development checks

Changes to the script should pass:

```bash
bash -n vpn-server-preparation-4-amnezia.sh
shellcheck vpn-server-preparation-4-amnezia.sh
```

Run provisioning tests only in a clean, disposable Ubuntu VM, including a second run to verify finalization and idempotency.
