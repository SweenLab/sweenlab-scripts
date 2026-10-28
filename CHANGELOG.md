# Changelog

Each user-visible update is recorded here and on the [GitHub Releases page](https://github.com/SweenLab/personal-proxmox-scripts/releases). Debian wizard tags use `debian-lxc-vX.Y.Z`; older `v1.x` releases belong to the retired maintenance wizard.

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
