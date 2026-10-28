# SweenLab Debian LXC Creation Wizard

Version 0.1.3 (initial test build). A step-by-step Debian LXC wizard with selectable packages and explicit container feature and device choices. Live Proxmox testing is still required.

## Quick Start: copy and paste

Use the copy button in the top-right corner of the command block below, then paste the command into your **Proxmox node shell as root**. No cloning or companion file is needed:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/SweenLab/personal-proxmox-scripts/13c446679ede9a9d30228a94b41dea0cb9d14785/scripts/proxmox-debian-lxc-create.sh)"
```

This command is pinned to the verified version 0.1.3 commit, avoiding stale copies of the main-branch download. The link should be updated when a newer script version is published.

The wizard contains its guest setup code. After final confirmation it writes that embedded code to a temporary host file, copies it into the newly created CT, runs it there, and removes the temporary host file on exit. The saved copy inside the CT supports reviewed retries. No second script is fetched from the internet.

The launch command explicitly downloads and runs this SweenLab script. You can inspect it on GitHub first. Docker and Tailscale are installed through signed package repositories; their convenience shell scripts are not used.

## Step-by-step workflow

There is no Default/Advanced shortcut. Suggested input values remain editable and every configuration stage is shown. All package checkboxes initially start off.

1. Choose the container ID. The wizard checks availability cluster-wide.
2. Enter a hostname. The field starts blank; a hostname is required. Leaving it empty stops the wizard before container creation.
3. Enter tags, separated by semicolons, or explicitly leave blank.
4. Configure networking: active configured Proxmox Linux bridge (runtime Docker/firewall bridges are hidden); DHCP, static or manual IPv4; manual, SLAAC, DHCPv6 or static IPv6; gateways; VLAN; MTU; MAC; network rate limit; interface firewall flag; DNS server and search domain.
5. Choose CPU cores, CPU limit and weight, RAM, swap, disk size, root storage, and timezone. Locale setup uses `en_US.UTF-8`.
6. Choose unprivileged or privileged mode. Provide an optional SSH public key file. Choose whether to set a root console password; it is collected secretly and never written to the plan or log. SSH password access is not enabled by the wizard.
7. Choose whether to refresh the official Proxmox template catalog, then Debian 12 or 13, exact matching template, and template storage.
8. Select packages: git, curl, wget, Tailscale, Docker Engine, Docker Compose plugin, nano, vim-tiny, htop, jq, tmux, rsync, unzip, DNS tools, ping, SSH server, sudo. Compose includes Engine and Buildx. Nothing is preselected. Tailscale sign-in is a separate manual step.
9. Explicitly select nesting, keyctl for unprivileged containers, FUSE, and TUN passthrough. Docker requires nesting and, in unprivileged mode, keyctl. Tailscale requires TUN. Incompatible choices lead to another confirmation of the required feature, with Esc available to cancel.
10. Choose optional GPU passthrough from discovered `/dev/dri/card*` and `/dev/dri/renderD*` character devices. Optionally specify one additional character device, such as a USB serial adapter. Choose a guest group ID for each passed device; permissions are `0660`, owner UID 0. Host device ownership is not changed.
11. Choose host-boot startup, startup order, and deletion protection.
12. Choose whether to upgrade Debian packages in the new container.
13. Review the entire plan and confirm creation. The wizard downloads the selected template if missing, creates and starts the container, configures credentials, and installs selected tools.

Choose Cancel or Esc on an input/menu to stop. No at final confirmation exits without creating a container. Catalog refresh, when explicitly accepted earlier, downloads metadata before that final confirmation.

## First test on Proxmox

1. Review the script, especially the execution plan and embedded guest setup.
2. Open the Proxmox node shell as root.
3. Use a terminal at least 80 columns by 24 rows.
4. Make sure `whiptail`, `python3`, and the normal Proxmox tools are available. The script reports missing dependencies; it never installs host packages automatically.
5. Copy and paste the command from [Quick Start](#quick-start-copy-and-paste).
6. At the bridge step, select your configured Proxmox bridge (for example `vmbr0` or `vmbr1`). Docker and temporary firewall bridges are excluded. Use a new disposable container ID. First test cancellation at the final review, then rerun to create the disposable CT.
7. For Docker, select Compose, unprivileged mode, nesting and keyctl. Validate inside the CT:

   ```bash
   docker info
   docker compose version
   ```

   A workload test such as `docker run --rm hello-world` is a separate, deliberate download and execution of an image. The wizard does not run third-party images automatically.

8. For Tailscale, select TUN, then use `pct exec YOUR_CTID -- tailscale up` separately to authenticate. No auth key is requested or logged.
9. For GPU access, check the device inside the CT and match its numeric group ID to the guest application's group. Add your intended non-root application user to that group manually. GPU libraries/drivers inside the guest depend on your GPU and workload; the wizard does not guess or install them.

## Safety and behavior

- Uses official Proxmox templates through `pveam`, then `pct create`. No remote helper framework is sourced.
- Installs Docker and Tailscale through vendor repositories with per-repository `Signed-By` keyrings and APT signature verification. TLS certificate verification stays enabled. Docker's expected signing fingerprint is checked; a key rotation fails for review. Tailscale's signing key is bootstrapped over verified HTTPS from its package domain and checked for valid key format.
- Does not disable AppArmor, use an unconfined profile, chmod host devices, or install packages on the host.
- Unprivileged mode is presented first, but explicitly chosen. Privileged containers, nesting, FUSE and passed devices broaden host exposure. Proxmox recommends a VM when stronger isolation is required for nested application containers.
- GPU passthrough here shares existing host GPU device nodes. It is not PCI/VFIO passthrough and does not detach the host's display GPU. Host GPU drivers and working `/dev/dri` nodes must exist first.
- TUN and GPU/custom device selection require a PVE version advertising the `dev[n]` API. Older hosts fail with an explanation rather than receive raw LXC configuration edits.
- Only one Linux bridge network interface is configured. Bonding, SDN VNet creation, extra NICs, host bind mounts, PCI passthrough, arbitrary raw LXC options, and host driver changes are outside this version. There is no claim to cover every possible Proxmox API setting.
- A checked interface firewall flag does not create firewall rules or enable the cluster/node firewall. Docker-published ports require deliberate exposure rules; review Docker's documented firewall behavior before publishing services.
- A root console password does not enable SSH root password authentication. With no password, use the Proxmox console through `pct enter`; an installed SSH server still follows Debian's SSH policy. Selecting sudo does not create a user or grant permissions.
- Logs are written beneath `/var/log/sweenlab-debian-lxc/` with restrictive permissions. Installer hash, settings and command output are recorded; passwords and Tailscale credentials are excluded.
- Failures preserve the newly created container and any downloaded template. No destroy, forced stop, automatic rollback, reboot, prune or changes to an existing container are performed. A partially failed `pct create` can leave state even before the created flag is set: inspect the requested ID before retrying.
- Creation is intentionally not a repeat-on-existing-ID operation. Reusing an ID is rejected. The embedded tools installer is rerunnable: managed repository files are rewritten consistently, installed packages remain installed, and no Docker data or Tailscale identity is removed. Re-running can install newer available package versions.
- Conflicting distribution Docker packages or an independently managed vendor repository require manual review rather than automatic removal. Retry support is intended for this wizard's newly created CT, not arbitrary existing guests.

## Retry an interrupted tools installation

Read the host log first. Enter the preserved container:

```bash
pct enter YOUR_CTID
```

Run the saved installer with the same reviewed selections, for example:

```bash
bash /root/sweenlab-debian-tools.sh --timezone America/New_York --upgrade 0 git curl wget compose tailscale
```

The retry command is an explicit change to that CT. Confirm its identity and original package choices before running it. The installer remains at `/root/sweenlab-debian-tools.sh`.

## Validation status

Passed locally: Bash syntax, help output, numeric bounds and injection rejection, mocked step-by-step cancellation, static IPv4/IPv6 and tag arguments, creation command construction, and preserving the CT on simulated installer failure. Machine prerequisites, Proxmox commands and host logging were replaced with test doubles in these tests. They do not prove a successful live deployment.

Still required on a disposable real Proxmox CT: terminal interaction, template extraction, static/DHCP connectivity, vendor package downloads, repeat installation, Docker daemon/workloads, Tailscale authentication, GPU application access, and behavior with the actual host kernel/storage combination. This build is for review and live testing, not a production-tested release.

## Release history

Every user-visible update gets a new version and a GitHub release. See the [changelog](../CHANGELOG.md) and [release pages](https://github.com/SweenLab/personal-proxmox-scripts/releases) for the recorded changes and validation status.

## References

- Existing project: https://github.com/SweenLab/personal-proxmox-scripts
- Community Debian entry point (workflow inspiration only): https://github.com/community-scripts/ProxmoxVE/blob/main/ct/debian.sh
- Proxmox container documentation: https://github.com/proxmox/pve-docs/blob/master/pct.adoc
- Proxmox feature/device definitions: https://github.com/proxmox/pve-docs/blob/master/generated/pct.conf.5-opts.adoc
- Docker's Debian repository installation: https://docs.docker.com/engine/install/debian/
- Tailscale Debian package instructions: https://pkgs.tailscale.com/stable/
- Tailscale LXC device passthrough: https://tailscale.com/docs/features/containers/lxc/lxc-unprivileged
