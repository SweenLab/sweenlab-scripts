# SweenLab Debian LXC Creation Wizard

Version 0.1.4 (initial test build). One self-contained script, fully step by step, with Back navigation and a final Create/Abort review. Live Proxmox testing is still required.

## Quick Start: copy and paste

Use the copy button in the top-right corner of this block, then paste into your **Proxmox node shell as root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/SweenLab/personal-proxmox-scripts/5b5c23b973d471f085eca94edf77c102eb9bc786/scripts/proxmox-debian-lxc-create.sh)"
```

The command is pinned to the verified version 0.1.4 script to avoid stale raw GitHub main-branch downloads. No clone, companion file, or additional shell-script download is needed.

If an older wizard is still open, abort it and restart with this command. Use a new disposable CT ID for the first test. Do not reuse an ID left by a failed creation until its state has been inspected.

## Before starting

- Run on a Proxmox VE host as root, with its standard `pct`, `pvesh`, `pvesm`, `pveam`, and `lxc-usernsexec` tools.
- Python 3 with its standard `curses` terminal support is required. There is no whiptail/dialog dependency and no automatic installation of host packages.
- Use a normal terminal of at least 80 columns by 24 rows. The UI adapts when you resize it.
- Download a Debian 12 or 13 standard template using Proxmox's template interface first. This wizard lists only templates already downloaded to the selected template storage, matching the host's amd64/arm64 architecture.
- GPU host drivers and GPU device nodes must already work if you want GPU passthrough. Tailscale requires a working host `/dev/net/tun` device.

## Moving through the wizard

Every configuration screen has **Back** and **Abort**. Input, menu, and package screens show **Back / Next / Abort**. Yes/No screens show **Back / Yes / No / Abort** horizontally, with Yes initially highlighted. The final overview shows **Back / Create / Abort**, with Create highlighted.

- Use Up/Down to select a menu item.
- Use Space to toggle package or Tailscale checkboxes.
- Use Tab or Shift+Tab to move between the content and buttons; Left/Right moves across buttons.
- Press Enter to accept the highlighted action. Esc aborts before creation.
- Inputs remember values when you go back. Conditional screens, such as Tailscale options, follow the packages you selected.
- The overview scrolls with Up/Down or Page Up/Page Down. Back lets you revise settings; Abort creates nothing.

After Create, provisioning begins and Back navigation ends. Failures preserve any remaining new CT/storage state for inspection; the wizard never destroys it automatically.

## Configuration screens

1. **Container details:** unused cluster-wide ID, blank required hostname, and optional tags separated by semicolons.
2. **Networking:** choose an active configured Proxmox Linux bridge. Choices show only names such as `vmbr0` and `vmbr1`; Docker and temporary firewall bridges are hidden. Choose IPv4/IPv6 mode, addresses/gateways where relevant, VLAN, MTU, optional MAC/rate limit, DNS and search domain.
3. **Resources:** CPU cores, memory in MiB, root disk size in GiB, and container storage. Storage choices show names only.
4. **Timezone:** automatically prefilled from the Proxmox host's timezone; edit if needed. If the host timezone cannot be resolved, UTC is shown.
5. **Access:** unprivileged mode is initially Yes. Choose an optional host SSH public-key file. Enter and confirm a mandatory root console password. Passwords remain hidden and are never logged or included in command arguments. Setting a console password does not enable root password login over SSH.
6. **Downloaded templates:** select template storage, then one of the Debian templates already downloaded there. There is no catalog refresh, separate Debian-release chooser, or automatic template download. If the selected storage has none, Back selects another storage; Abort lets you download a template in Proxmox first.
7. **Packages:** git, curl, wget, Tailscale, Docker Engine/Buildx, Docker Compose (includes Engine), nano, jq, unzip, ping, OpenSSH server, and sudo. Packages are initially unselected. htop, vim-tiny, tmux, rsync, and dnsutils are no longer choices.
8. **Tailscale:** when selected, choose whether to start sign-in automatically and configure its options (details below).
9. **Features:** nesting, keyctl for unprivileged containers, FUSE, and TUN use horizontal Yes/No controls. Yes is initially selected. Docker requires nesting and keyctl in unprivileged mode; Tailscale requires TUN. Invalid combinations cannot continue.
10. **GPU:** shown only when GPU nodes exist. Choose whether to pass them through, then select individual devices. There is no arbitrary additional-character-device question or numeric guest-group prompt.
11. **Start at host boot:** Yes is initially selected. Startup order and delays use Proxmox defaults.
12. **Overview:** a grouped summary of container, resources, networking, software/features, and automatic settings. Choose Create or Abort, or Back to revise settings.

The UI no longer presents the old numbered template-catalog or package-upgrade steps.

### Memory conversion

The memory screen includes this chart:

| Memory | Enter in MiB |
|---|---:|
| 0.5 GiB | 512 |
| 1 GiB | 1024 |
| 2 GiB | 2048 |
| 4 GiB | 4096 |
| 8 GiB | 8192 |
| 16 GiB | 16384 |

### Automatic settings

These are applied in the background and shown in the overview:

| Setting | Value |
|---|---|
| Interface firewall flag | Enabled (`firewall=1`); existing Proxmox firewall enablement/rules still apply |
| CPU limit / weight | `0` (unlimited) / `100` |
| Swap | 512 MiB |
| Package upgrades | Always enabled inside the new Debian CT |
| Guest locale | `en_US.UTF-8` |
| Passed device UID/GID / permissions | `0:0`, `0660` |
| Startup order / delays | Proxmox defaults |
| Deletion protection | Off |

No firewall, CPU limit/weight, swap, device group-ID, startup-order/delay, protection, or package-upgrade questions are shown. For GPU applications that run as a non-root user, configure guest group access separately after creation.

## Tailscale sign-in and options

When Tailscale is selected, **Run tailscale up automatically** starts as Yes. A checkbox screen offers:

| Option | Initial selection | Effect |
|---|---|---|
| Enable Tailscale SSH | Selected | `--ssh=true`; access still follows tailnet policy |
| Keep existing DNS | Selected | `--accept-dns=false` |
| Accept advertised subnet routes | Unselected | `--accept-routes=true` if selected |
| Block incoming Tailscale connections | Unselected | `--shields-up=true` if selected |
| Display login QR code | Selected | `--qr=true` |

After package installation, the wizard runs `tailscale up` with explicit values for these flags and a 120-second timeout. The login URL/QR is shown only on the terminal, outside the host run log. **You still need to authenticate in your browser.** No auth key is requested or stored.

If authentication times out or fails, the created CT and installed packages remain. The wizard prints a retry command using your chosen flags and clearly reports sign-in as incomplete. You can also choose No to automatic sign-in and run it later yourself.

References: [Tailscale up options](https://tailscale.com/docs/reference/tailscale-cli/up), [Tailscale SSH policy](https://tailscale.com/docs/features/tailscale-ssh).

## Rootfs extraction permission errors

The reported error:

```text
tar: /var/lib/lxc/204/rootfs: Cannot open: Permission denied
```

occurs inside Proxmox's template extraction, before this wizard can start the container or run its guest setup. It does not establish which path component, ACL, or mounted filesystem caused the denial. Proxmox's unprivileged extraction runs with container-root mapped to a host UID (100000 with this wizard's default mapping).

Version 0.1.4 adds a read-only namespace traversal preflight for `/var`, `/var/lib`, and `/var/lib/lxc`. If mapped container root cannot traverse a parent, creation stops and names that path. This detects a common cause; it cannot prove that the future mounted root filesystem will allow extraction.

If `pct create` still fails, the wizard prints path/mount diagnostics, identifies the failed CT ID, and preserves any remaining state. It does **not** chmod/chown host directories, change ACLs, disable security protections, destroy the CT, or retry as privileged.

For the reported CT/storage, these commands are read-only and can help diagnose it:

```bash
namei -l /var/lib/lxc/204/rootfs
findmnt -T /var/lib/lxc -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T /mnt/4tbstorage -o TARGET,SOURCE,FSTYPE,OPTIONS
pct config 204
```

Some paths or the CT configuration may no longer exist after Proxmox's own cleanup. Do not run another creation with ID 204 until the remaining configuration/storage has been inspected. Share the diagnostic output and host log to identify the actual permission problem before applying a repair.

## Logs, safety, and retry behavior

Host logs are saved under `/var/log/sweenlab-debian-lxc/` with restrictive permissions. The final plan, installer hash, package output, and read-only diagnostics are recorded. Passwords and Tailscale login URLs are excluded.

The script uses official Proxmox creation commands and signed vendor package repositories. It does not source external shell installers, disable AppArmor, change host device ownership, install host packages, automatically reboot, prune data, or mutate an existing CT. A VM is the stronger-isolation option for nested application containers.

The embedded guest installer stays at `/root/sweenlab-debian-tools.sh` in the newly created CT. For a reviewed retry after a package failure, enter the correct CT and rerun the installer with the same selected packages and timezone. For example:

```bash
pct enter YOUR_CTID
bash /root/sweenlab-debian-tools.sh --timezone America/New_York --upgrade 1 git curl compose tailscale
```

That retry example applies only after the CT has been created and the installer copied successfully. It cannot fix template-extraction errors. Re-running APT installs can install newer available versions; Docker data and Tailscale identity are preserved.

## Validation and release history

Local checks cover bridge filtering, cached-template filtering through the real configuration flow, required hostname/passwords, Back preserving values, abort-before-mutation, hidden defaults, Tailscale flags/auth-output isolation, namespace preflight failure, creation diagnostics, and installer-failure preservation. UI rendering/key-handling tests cover the button layouts, defaults, masking, selections, and navigation. A 93×24 pseudo-terminal smoke test confirmed the Yes/No UI and Enter selecting Yes.

These are simulated/terminal checks, not a successful live Proxmox installation. Live extraction, packages, Docker workloads, Tailscale login, GPU access, and your host's actual permissions remain to be validated.

Every user-visible update has a new version, [changelog entry](../CHANGELOG.md), and [GitHub release](https://github.com/SweenLab/personal-proxmox-scripts/releases).
