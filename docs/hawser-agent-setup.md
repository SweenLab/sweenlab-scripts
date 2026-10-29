# Hawser Agent Setup Wizard 0.1.0

Install Hawser directly as a systemd service inside each Linux LXC that runs Docker. No Compose file is needed. One agent manages the Docker daemon in that LXC, including all its Docker containers. The agent does not manage Proxmox itself.

## Run the wizard

Run as root **inside the Docker LXC**, not on your Proxmox node:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/8bfd8b389a76f2a426ae8fa5bcfc31543a6f8d7b/scripts/hawser-agent-setup.sh)"
```

This immutable launcher runs version 0.1.0. Requires working Docker, systemd, internet access to GitHub, and an interactive terminal at least 74 columns × 22 rows. On Debian/Ubuntu, missing Python 3 is installed automatically before the menus; aborting afterward does not remove that prerequisite. Other systems must already provide Python 3 with curses and trusted HTTPS certificates.

## Token and menus

1. Name the LXC/agent, for example `homarr` or `entertainment`.
2. Paste the token generated in Dockhand's Add Environment window. **The exact same token must be used on both sides.** If your Dockhand version has no Generate button, press **F2 in the wizard's token field** to generate one locally; copy it into Dockhand after installation. Tokens are hidden while you type, never sent to a third party, and excluded from installer logs.
3. Choose the directory for new agent-managed stacks; `/data/stacks` is the default. This does not import or move existing application directories.
4. Choose verbose output (default No).
5. Review the configuration and choose **Install**. Back edits earlier entries; Abort exits. Tab/Shift+Tab reaches the field and every button, arrows navigate, and Space/Enter explicitly selects Yes/No before focusing Next. Ctrl+U clears an input field; Backspace deletes its last character.

The orange/green menus have centered prompts, visible input fields and mandatory-field validation. The agent name and directory cannot contain spaces. Installation displays progress and a final success checklist.

## What it installs

- Latest official Hawser Linux release for amd64, arm64 or ARMv7, checked against the release's published SHA-256 checksums.
- Binary: `/usr/local/bin/hawser`.
- Private configuration: `/etc/hawser/config`, root-only mode 0600.
- Native service: `/etc/systemd/system/hawser.service`, started now and enabled at boot.
- Standard HTTP agent on port **2376**, with required token authentication.
- Docker socket access and a writable stack directory matching the native service's filesystem permissions.

This downloads the official executable and checksums directly; it does not execute an additional downloaded shell installer. Checksums establish agreement with the published release, not an independent publisher signature.

Before changing an existing installation, config, binary and service files are backed up under `/var/backups/sweenlab-hawser/`. If configuration/startup/health verification fails, the wizard restores previous files and attempts to restore the prior service startup state. Installer output is stored under `/var/log/sweenlab-hawser/` without the token. The token is shown privately in the final terminal summary for copying into Dockhand.

Only Hawser is restarted. Docker and application containers are not stopped/recreated. Existing Edge/TLS/custom-bind installations and an existing Docker Hawser container are rejected rather than silently converted. Re-running a normal native installation allows updating Hawser and changing its name/token/stack directory after review; unrelated configuration entries are preserved.

## Add to Dockhand

Open **Settings → Environments → Add Environment**:

| Field | Value |
|---|---|
| Name | The agent/LXC name |
| Connection type | Hawser agent (standard) |
| Agent host | LXC address reachable from Dockhand |
| Agent port | `2376` |
| Protocol | HTTP |
| Agent token | Exact token used in the wizard |
| Remote stack path (for backup) | The directory chosen in the wizard |
| Public IP | LXC IP used for clickable application links |

Click **Test connection**, then **Add**. The on-screen manual-run example is unnecessary: systemd already runs Hawser. Connecting discovers containers, but importing existing Compose stacks is a separate Dockhand operation.

Hawser has administrative access to Docker. This HTTP configuration is for a trusted LAN or an encrypted Tailscale path; do not internet-forward port 2376. HTTP does not encrypt the token. Use Hawser TLS/Edge setup separately when encrypted application transport is required.

## Checks and troubleshooting

```bash
systemctl status hawser --no-pager
journalctl -u hawser -n 40 --no-pager
```

A successful local health check proves the service can reach Docker. Dockhand's **Test connection** additionally checks the route and token from the Dockhand server. A local success cannot verify your firewall or the IP entered in Dockhand.

Validation: Bash syntax and 57 local tests pass, including navigation, required selections, token validation/redaction, checksum rejection, simulated installation, private file permissions and rollback on service failure. Live systemd installation in a user LXC has not yet been tested for this wizard.

Sources: [Hawser official repository](https://github.com/Finsys/hawser), [Dockhand manual](https://dockhand.pro/manual/).
