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

- Step-by-step terminal menus with a complete review before creation.
- Explicit unprivileged or privileged container selection.
- IPv4/IPv6, bridge, VLAN, MTU, DNS, resource and startup configuration.
- Optional git, curl, wget, Tailscale, Docker Engine, Docker Compose and useful utilities.
- Explicit nesting, keyctl, FUSE, TUN and GPU device choices.
- Official package repositories, signed packages, rerunnable tool installation and logs.
- No additional installer shell scripts are downloaded or executed.

## Quick Start

Use the copy button on the command block below, then paste it into your **Proxmox node shell as root**:

```bash
bash -c "$(curl -fsSL "https://raw.githubusercontent.com/SweenLab/personal-proxmox-scripts/main/scripts/proxmox-debian-lxc-create.sh?nocache=$(date +%s)")"
```

The timestamp in the download URL avoids a stale cached copy after an update. This downloads and runs the SweenLab wizard. All menus and the final creation confirmation remain interactive. The guest installer is embedded; no companion file or additional shell script download is required.

For a first test, choose a new disposable container ID. Follow the [step-by-step guide](docs/proxmox-debian-lxc-create.md) for prerequisites, passthrough permissions, retries and testing. You can inspect the script on GitHub before running it.

## Testing Status

Version 0.1.2 is an initial test build. Bash syntax and simulated workflow checks pass; live Proxmox, Docker, Tailscale and GPU validation is still required. Start with a disposable container.

## Documentation

- [Debian LXC Creation Wizard guide](docs/proxmox-debian-lxc-create.md)

## Releases

Version history and release notes are available on the [Releases page](https://github.com/SweenLab/personal-proxmox-scripts/releases). Historical releases can contain tools no longer present on the main branch.

## Contributing

Suggestions and bug reports are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer

These scripts are provided as-is without warranty. Review the code and configuration before running it, and make backups of important systems. Use at your own risk.

## License

This project is licensed under the [MIT License](LICENSE).
