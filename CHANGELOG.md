# Changelog

Each user-visible update is recorded here and on the [GitHub Releases page](https://github.com/SweenLab/personal-proxmox-scripts/releases). Debian wizard tags use `debian-lxc-vX.Y.Z`; older `v1.x` releases belong to the retired maintenance wizard.

## Debian LXC Wizard 0.1.5 — 2026-10-28

- Fixed the wizard's private `umask 077` leaking into Proxmox commands. Container commands now use a scoped `022` mask so newly created CT paths can be traversed by mapped container root; private wizard files keep their restrictive permissions.
- Reject CT IDs with leftover host directories or symlinks before creation, without changing or deleting existing state.
- Updated the guide with the identified extraction failure cause and a fresh-ID test procedure. Updated README and guide launchers to the immutable corrected script commit.

Validation: all 22 local tests pass, including reproduction of the original `0700` directories with Proxmox's Perl directory-creation mechanism, corrected `0755` modes, private `0600` files, preserved failure statuses, and leftover-directory/symlink rejection. Bash syntax passes. Live Proxmox creation and package installation remain to be tested.

## Debian LXC Wizard 0.1.4 — 2026-10-28

- Replaced one-way menus with an embedded terminal UI: Back on every configuration screen, remembered values, horizontal Back/Yes/No/Abort controls, Yes initially highlighted, and a grouped Back/Create/Abort overview.
- Bridge and storage options show names only. Added a MiB/GiB conversion chart to memory entry.
- Hid firewall, CPU limit/weight, swap, startup order/delays, device group ID, deletion protection and upgrade questions. Background values: firewall on, CPU limit 0/weight 100, swap 512 MiB, Proxmox startup defaults, device UID/GID 0, protection off, mandatory Debian upgrades.
- Timezone is prefilled from the Proxmox host (UTC fallback). Root password and confirmation are mandatory and hidden.
- Removed the template catalog refresh and Debian-release chooser. Select template storage and a matching Debian template already downloaded there; no automatic template downloads.
- Removed htop, vim-tiny, tmux, rsync, and dnsutils from the package choices. Removed arbitrary extra character-device passthrough.
- Added optional automatic `tailscale up`, with SSH and keep-existing-DNS selected initially, optional routes/shields settings, QR output, a bounded authentication wait, and no login URL in host logs. Browser authentication still requires the user.
- Nesting, keyctl, TUN and host-boot choices start at Yes. Other Yes/No screens also initially highlight Yes; choices are retained when going back.
- Added a read-only mapped-root traversal preflight and explicit path/mount diagnostics on creation failure. The reported host rootfs permission problem is not claimed repaired: no host permissions, ACLs or security settings are changed automatically.
- Updated the README, guide, pinned launcher, and release notes.

Validation: 20 committed bridge/workflow/UI tests plus single-file syntax/help and a real 93×24 pseudo-terminal Yes/No smoke check. No live Proxmox deployment or repair of the user's host was performed.

## Debian LXC Wizard 0.1.3 — 2026-10-28

- Fixed the network bridge menu listing Docker and temporary per-guest firewall bridges.
- Read active Linux bridges from the Proxmox node network API, preserving custom configured bridge names rather than restricting choices to `vmbr*`.
- Explicitly exclude Docker and Proxmox firewall runtime bridge names, sort choices naturally, and verify the selected bridge belongs to the eligible list.
- Stop with a clear message if network discovery fails or no eligible bridge exists; do not fall back to listing every runtime bridge.
- Updated the README, guide, and version-specific launch command.

Validation: fixtures reproduce the reported mixed bridge list, verify `vmbr0`/`vmbr1` and custom configured bridges are kept, and check API errors, malformed responses, no eligible bridge, and invalid selection. Existing simulated creation/cancellation/failure and single-file launch checks pass. Live Proxmox validation is still required; no running guest or host networking was changed.

## Debian LXC Wizard 0.1.2 — 2026-10-28

- Removed the prefilled `sweenlab-debian` hostname. The field starts blank; an empty hostname stops the wizard before creation with a clear required-field error.
- Pinned the documented launcher to a verified script commit because the raw main-branch URL served a stale cached copy.
- Added visible version 0.1.2 so users can identify the downloaded wizard.
- Made the command easy to copy from the README and the guide's Quick Start section.
- Updated the README to focus on the Debian wizard and removed the Task Scheduler, Health Check, Host & LXC Maintenance Wizard, VM Maintenance Wizard, and their four guides from main. Historical releases remain available.
- Added a release requirement for every future user-visible tweak or update.

Validation: Bash syntax; one-file `bash -c` launch help; embedded installer extraction and syntax; required-hostname rejection; simulated cancellation, static IPv4/IPv6 and tag arguments, creation settings, and failure preservation. A commit-specific download was verified to contain version 0.1.2 and the blank required hostname. Live Proxmox, Docker, Tailscale, and GPU testing is still required.

## Debian LXC Wizard 0.1.1 — 2026-10-28

- Combined host creation and guest setup into a single self-contained script.
- Removed the separate companion installer from the repository.
- Added one-line launch instructions to the README and guide.
- Kept an embedded guest installer saved inside the created CT for reviewed retries.

## Debian LXC Wizard 0.1.0 — 2026-10-28

- Added a fully step-by-step Debian 12/13 LXC creation wizard with resource, networking, tags, access, startup, and protection choices.
- Added selectable Debian utilities, Docker Engine, Docker Compose, and Tailscale using package repositories.
- Added explicit unprivileged/privileged selection, nesting, keyctl, FUSE, TUN, and GPU/character-device options.
- Added final plan confirmation, restrictive logging, and preservation of the new CT if installation fails.

Earlier development versions are recorded retrospectively from this repository's commits. Version 0.1.2 is the first dedicated Debian wizard GitHub release.
