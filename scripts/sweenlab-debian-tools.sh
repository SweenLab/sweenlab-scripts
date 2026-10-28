#!/usr/bin/env bash
# SweenLab Debian tools installer — MIT
# Run ONLY inside the intended Debian 12/13 LXC, never on the Proxmox host.
set -Eeuo pipefail
TEMP_DIR=''
trap '[[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"' EXIT
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
main() {
    [[ ${1:-} != --help ]] || { printf 'Inside Debian LXC: bash %s --timezone America/New_York --upgrade 0 git curl compose\n' "$0"; return; }
    (( EUID == 0 )) || fail 'Root is required.'
    [[ ! -d /etc/pve ]] || fail 'Refusing to install on a Proxmox host.'
    [[ $(systemd-detect-virt --container) == lxc ]] || fail 'Run only inside an LXC container.'
    # Debian owns this configuration file.
    . /etc/os-release
    [[ "$ID" == debian && "$VERSION_ID" =~ ^(12|13)$ ]] || fail 'Debian 12 or 13 required.'
    local tz=America/New_York upgrade=0 docker=0 compose=0 tailscale=0 item
    local -a packages=(locales tzdata) tools=()
    while (($#)); do
        case "$1" in
            --timezone|--upgrade)
                (($# >= 2)) || fail "Missing value for $1"
                case "$1" in --timezone) tz=$2;; --upgrade) upgrade=$2;; esac
                shift 2;;
            git|curl|wget|nano|vim-tiny|htop|jq|tmux|rsync|unzip|dnsutils|iputils-ping|openssh-server|sudo)
                packages+=("$1"); tools+=("$1"); shift;;
            docker) docker=1; shift;;
            compose) docker=1; compose=1; shift;;
            tailscale) tailscale=1; shift;;
            *) fail "Unknown option/tool: $1";;
        esac
    done
    [[ "$upgrade" == 0 || "$upgrade" == 1 ]] || fail 'Upgrade must be 0 or 1.'
    [[ "$tz" != *..* && "$tz" =~ ^[a-zA-Z0-9_+/-]+$ && -f "/usr/share/zoneinfo/$tz" ]] || fail 'Invalid timezone.'
    if (( docker )); then
        for item in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
            if [[ $(dpkg-query -W -f='${Status}' "$item" 2>/dev/null || true) == 'install ok installed' ]]; then
                fail "Conflicting package $item is installed. Review removal manually; no automatic replacement."
            fi
        done
    fi
    if (( tailscale )); then [[ -c /dev/net/tun ]] || fail 'TUN device is missing.'; fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o Acquire::Retries=3 update
    if (( upgrade )); then apt-get -o Dpkg::Options::=--force-confold -y upgrade; fi
    if (( docker || tailscale )); then packages+=(ca-certificates curl gnupg); fi
    apt-get install -y --no-install-recommends "${packages[@]}"
    if ! grep -Eq '^en_US.UTF-8[[:space:]]+UTF-8$' /etc/locale.gen; then
        printf '\nen_US.UTF-8 UTF-8\n' >> /etc/locale.gen
    fi
    locale-gen
    update-locale LANG=en_US.UTF-8
    ln -snf "/usr/share/zoneinfo/$tz" /etc/localtime
    printf '%s\n' "$tz" > /etc/timezone
    dpkg-reconfigure -f noninteractive tzdata
    TEMP_DIR=$(mktemp -d)
    install -d -m 0755 /etc/apt/keyrings
    if (( docker )); then
        # Refuse ambiguous existing sources rather than overwrite personal config.
        if grep -Rqs 'download.docker.com' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
            [[ -f /etc/apt/sources.list.d/sweenlab-docker.sources ]] || fail 'Existing Docker repository requires manual review.'
        fi
        curl --proto '=https' --tlsv1.2 -fsSL --retry 3 https://download.docker.com/linux/debian/gpg -o "$TEMP_DIR/docker.asc"
        local fingerprint
        fingerprint=$(gpg --batch --show-keys --with-colons "$TEMP_DIR/docker.asc" | awk -F: '$1=="fpr" {print $10; exit}')
        [[ "$fingerprint" == 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 ]] || fail 'Docker signing key fingerprint mismatch. Review upstream key rotation.'
        install -m 0644 "$TEMP_DIR/docker.asc" /etc/apt/keyrings/sweenlab-docker.asc
        cat > /etc/apt/sources.list.d/sweenlab-docker.sources <<REPO
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/sweenlab-docker.asc
REPO
    fi
    if (( tailscale )); then
        if grep -Rqs 'pkgs.tailscale.com' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
            [[ -f /etc/apt/sources.list.d/sweenlab-tailscale.sources ]] || fail 'Existing Tailscale repository requires manual review.'
        fi
        # Trust bootstrap: key fetched over verified TLS from the vendor's package domain.
        curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "https://pkgs.tailscale.com/stable/debian/$VERSION_CODENAME.noarmor.gpg" -o "$TEMP_DIR/tailscale.gpg"
        gpg --batch --show-keys "$TEMP_DIR/tailscale.gpg" >/dev/null
        install -m 0644 "$TEMP_DIR/tailscale.gpg" /etc/apt/keyrings/sweenlab-tailscale.gpg
        cat > /etc/apt/sources.list.d/sweenlab-tailscale.sources <<REPO
Types: deb
URIs: https://pkgs.tailscale.com/stable/debian
Suites: $VERSION_CODENAME
Components: main
Signed-By: /etc/apt/keyrings/sweenlab-tailscale.gpg
REPO
    fi
    if (( docker || tailscale )); then apt-get -o Acquire::Retries=3 update; fi
    if (( docker )); then
        local -a docker_packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin)
        (( compose == 0 )) || docker_packages+=(docker-compose-plugin)
        apt-get install -y --no-install-recommends "${docker_packages[@]}"
        systemctl enable --now docker
        docker info >/dev/null
        (( compose == 0 )) || docker compose version
    fi
    if (( tailscale )); then
        apt-get install -y --no-install-recommends tailscale
        systemctl enable --now tailscaled
        systemctl is-active --quiet tailscaled
        printf 'Tailscale installed. Run tailscale up separately to sign in.\n'
    fi
    for item in ${tools[@]+"${tools[@]}"}; do
        [[ $(dpkg-query -W -f='${Status}' "$item") == 'install ok installed' ]] || fail "Verification failed: $item"
    done
    printf '[OK] Selected tools installed; locale en_US.UTF-8; timezone %s.\n' "$tz"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
