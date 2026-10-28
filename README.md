# SweenLab Personal Proxmox Scripts

Hi, I'm Sween. 👋

I'm building and learning through my personal homelab, **Sween Lab**.

This repository contains scripts I've created to make managing **Proxmox VE** and Linux systems a little easier. I learn best by doing, experimenting, and occasionally breaking things before figuring out how to fix them. If you're the kind of person who learns through hands-on experience instead of memorizing commands, I hope these tools are useful to you too.

Every script is something I built because I wanted it for my own lab first. If it helps someone else learn or saves them some time, that's even better.

Have fun!

<p align="center">
  <a href="https://buymeacoffee.com/sweenlab">
    <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" width="220">
  </a>
</p>

---

# Debian LXC Creation Wizard

Create a Debian 12 or 13 LXC through a fully guided, step-by-step wizard. Every configuration stage is shown; no packages are preselected.

| Script | Purpose | Documentation |
|---------|---------|---------------|
| [Debian LXC Creation Wizard](scripts/proxmox-debian-lxc-create.sh) | Choose container ID, hostname, tags, networking, resources, packages, features and optional device passthrough. | [View Guide](docs/proxmox-debian-lxc-create.md) |

The installer is embedded in this single script and runs inside the new container.

## Features

- Consistent orange/green screens, compact input highlights, complete Tab/arrow navigation, and an aligned Create/Abort review. Password confirmation always starts blank.
- Explicit unprivileged or privileged container selection.
- Name-only Proxmox bridge/storage choices and IPv4/IPv6 configuration; other network settings use background defaults. Runtime Docker/firewall bridges are hidden.
- Selectable git, curl, wget, Tailscale, Docker Engine/Compose, nano, jq, unzip, ping, OpenSSH and sudo.
- Orange/green terminal accents, horizontal Yes/No controls, FUSE and GPU defaulting to No, and automatic device UID/GID settings.
- Mandatory root password, host-derived timezone and locale, 10 GiB initial root disk, memory conversion chart and already-downloaded Debian templates.
- Optional automatic Tailscale sign-in with SSH/DNS/route settings and a browser login link.
- Correct Proxmox directory creation permissions, private logs, read-only extraction diagnostics.
- Simplified networking with background defaults and arrow-key navigation between fields, lists and buttons.
- Required package choice with Select all/clear all and exclusive None, optional Python 3/pip/venv, editable host-derived locale, full Debian upgrade after locale setup, and quiet or verbose emoji/color installation progress.
- Official package repositories, signed packages, rerunnable tool installation and logs.
- No additional installer shell scripts are downloaded or executed.

## Quick Start

Use the copy button on the command block below, then paste it into your **Proxmox node shell as root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/SweenLab/personal-proxmox-scripts/f78511fd1ff6c6e9b6e17daa4c89db1b6576dba9/scripts/proxmox-debian-lxc-create.sh)"
```

This command is pinned to version 0.1.11 so it does not depend on a cached main-branch download. This downloads and runs the SweenLab wizard. Back preserves your entries; the final Create action begins provisioning. The guest installer is embedded; no companion file or additional shell script download is required.

For a first test, choose a new disposable container ID. Follow the [step-by-step guide](docs/proxmox-debian-lxc-create.md) for prerequisites, passthrough permissions, retries and testing. You can inspect the script on GitHub before running it.

## Testing Status

Version 0.1.11 is an initial test build. Bash syntax and simulated workflow checks pass; live Proxmox, Docker, Tailscale and GPU validation is still required. Start with a disposable container.

## Documentation

- [Debian LXC Creation Wizard guide](docs/proxmox-debian-lxc-create.md)

## Releases

Every tweak and update is recorded in the [changelog](CHANGELOG.md) and on the [Releases page](https://github.com/SweenLab/personal-proxmox-scripts/releases). Historical releases can contain tools no longer present on the main branch.

## Contributing

Suggestions and bug reports are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer

These scripts are provided as-is without warranty. Review the code and configuration before running it, and make backups of important systems. Use at your own risk.

## License

This project is licensed under the [MIT License](LICENSE).
