#!/usr/bin/env bash
# SweenLab Debian LXC Creation Wizard
# Repository: https://github.com/SweenLab/personal-proxmox-scripts
# License: MIT
# Run the reviewed local file on a Proxmox VE host, as root.
set -Eeuo pipefail
SCRIPT_VERSION=0.1.0
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INSTALLER="$BASE/sweenlab-debian-tools.sh"
CTID='' CREATED=0 LOG='' TMP=''
DIALOG_HEIGHT=20 DIALOG_WIDTH=76 LIST_HEIGHT=11
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup() {
    local rc=$?
    [[ -z "$TMP" ]] || rm -f -- "$TMP"
    if (( rc != 0 )); then
        printf '\nStopped with status %s. Log: %s\n' "$rc" "${LOG:-not started}" >&2
        if (( CREATED )); then
            printf 'Container %s was preserved. Inspect it before retrying installation.\n' "$CTID" >&2
        fi
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ask() { whiptail --title "SweenLab Debian LXC · $SCRIPT_VERSION" --inputbox "$1" 10 "$DIALOG_WIDTH" "$2" 3>&1 1>&2 2>&3; }
yesno() {
    local rc=0
    whiptail --title 'SweenLab' --defaultno --yesno "$1" 13 "$DIALOG_WIDTH" || rc=$?
    (( rc != 255 )) || exit 0
    return "$rc"
}
menu() { local prompt=$1; shift; whiptail --title 'SweenLab · Step by step' --menu "$prompt" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" "$@" 3>&1 1>&2 2>&3; }
number() { [[ "$1" =~ ^[1-9][0-9]{0,8}$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 )); }
choose_storage() {
    local content=$1 line; local -a choices=()
    while read -r line; do
        [[ -n "$line" ]] && choices+=("$line" "$content storage")
    done < <(pvesm status --content "$content" | awk 'NR>1 && $3=="active" {print $1}')
    ((${#choices[@]})) || die "No active $content storage found."
    whiptail --title 'Storage' --menu "Choose storage for $content" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" "${choices[@]}" 3>&1 1>&2 2>&3
}
main() {
    [[ ${1:-} != --help ]] || { printf 'Run as root on Proxmox VE. Keep sweenlab-debian-tools.sh beside this file. Interactive only.\n'; return; }
    (($# == 0)) || die 'Unknown argument; use --help.'
    (( EUID == 0 )) || die 'Run as root on the Proxmox host.'
    [[ -d /etc/pve ]] || die 'This must run on Proxmox VE.'
    local cmd
    for cmd in pct pvesh pvesm pveam whiptail python3 flock sha256sum; do
        command -v "$cmd" >/dev/null || die "Missing $cmd. Install it manually, then rerun."
    done
    [[ -r "$INSTALLER" ]] || die "Missing companion installer: $INSTALLER"
    bash -n "$INSTALLER"
    local rows cols
    rows=$(tput lines 2>/dev/null || echo 24); cols=$(tput cols 2>/dev/null || echo 80)
    [[ "$rows" =~ ^[0-9]+$ && "$cols" =~ ^[0-9]+$ ]] || die 'Cannot determine terminal size.'
    (( rows >= 24 && cols >= 80 )) || die 'Enlarge the terminal to at least 80 columns by 24 rows.'
    DIALOG_HEIGHT=$((rows - 4)); DIALOG_WIDTH=$((cols - 4))
    (( DIALOG_HEIGHT <= 30 )) || DIALOG_HEIGHT=30
    (( DIALOG_WIDTH <= 100 )) || DIALOG_WIDTH=100
    LIST_HEIGHT=$((DIALOG_HEIGHT - 9))
    exec </dev/tty
    exec 9>/run/lock/sweenlab-debian-lxc.lock
    flock -n 9 || die 'Another SweenLab creation wizard is running.'
    printf '\nSweenLab Debian LXC Creation Wizard %s\n' "$SCRIPT_VERSION"
    local release template_store root_store template arch item pct_help
    local hostname tags cores memory swap disk bridge ip gateway='' vlan mtu dns search tz
    local unpriv nesting=0 onboot protection firewall keyfile upgrade=0 net features selected
    local ipmode ip6mode ip6 gateway6='' mac rate cpulimit cpuunits startup tun=0 fuse=0 keyctl=0
    local password='' password2='' device gid device_index=0
    local -a devices=() device_options=() bridges=() templates=()
    CTID=$(ask 'Step 1 · New container ID (must be unused cluster-wide)' "$(pvesh get /cluster/nextid)")
    number "$CTID" 100 999999999 || die 'Invalid container ID.'
    pvesh get /cluster/nextid --vmid "$CTID" >/dev/null || die 'Container ID is unavailable.'
    hostname=$(ask 'Step 2 · Hostname (one DNS label)' sweenlab-debian)
    [[ ${#hostname} -le 63 && "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || die 'Invalid hostname.'
    tags=$(ask 'Step 3 · Tags separated by semicolons (blank for none)' '')
    [[ -z "$tags" || "$tags" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.+-]*(\;[a-zA-Z0-9_][a-zA-Z0-9_.+-]*)*$ ]] || die 'Invalid tags.'
    for item in /sys/class/net/*; do
        [[ ! -d "$item/bridge" ]] || bridges+=("${item##*/}" 'Linux bridge')
    done
    ((${#bridges[@]})) || die 'No Linux bridge found.'
    bridge=$(menu 'Step 4 · Network bridge' "${bridges[@]}")
    ipmode=$(menu 'IPv4 configuration' dhcp 'DHCP' static 'Static address and gateway' manual 'No automatic IPv4 configuration')
    case "$ipmode" in
        dhcp) ip=dhcp;; manual) ip=manual;;
        static) ip=$(ask 'Static IPv4 address/prefix' ''); gateway=$(ask 'IPv4 gateway (blank for none)' '');;
    esac
    ip6mode=$(menu 'IPv6 configuration' manual 'No automatic IPv6 configuration' auto 'SLAAC' dhcp 'DHCPv6' static 'Static IPv6 address and gateway')
    case "$ip6mode" in
        manual|auto|dhcp) ip6=$ip6mode;;
        static) ip6=$(ask 'Static IPv6 address/prefix' ''); gateway6=$(ask 'IPv6 gateway (blank for none)' '');;
    esac
    vlan=$(ask 'VLAN tag (blank for untagged)' '')
    mtu=$(ask 'Network MTU' 1500)
    mac=$(ask 'MAC address (blank lets Proxmox generate one)' '')
    rate=$(ask 'Network rate limit in MB/s (blank for unlimited)' '')
    firewall=$(menu 'Enable Proxmox firewall flag on this interface?' 1 'Enabled (rules still depend on your PVE firewall configuration)' 0 'Disabled')
    dns=$(ask 'DNS server IP (blank inherits host)' '')
    search=$(ask 'DNS search domain (blank inherits host)' '')
    cores=$(ask 'Step 5 · CPU cores' 2)
    cpulimit=$(ask 'CPU limit in cores (0 means unlimited)' 0)
    cpuunits=$(ask 'CPU weight (cgroup v2: 100 is normal)' 100)
    memory=$(ask 'Memory in MiB' 1024)
    swap=$(ask 'Swap in MiB (0 disables)' 512)
    disk=$(ask 'Root disk in GiB' 8)
    root_store=$(choose_storage rootdir)
    tz=$(ask 'Timezone' America/New_York)
    unpriv=$(menu 'Step 6 · Container type' 1 'Unprivileged (recommended)' 0 'Privileged (greater host exposure)')
    keyfile=$(ask 'SSH public key file on the host (blank to skip)' '')
    if [[ -n "$keyfile" ]]; then [[ -f "$keyfile" && -r "$keyfile" ]] || die 'Public key file is unreadable.'; fi
    if yesno 'Set a root console password? No leaves password login locked; pct enter still works.'; then
        password=$(whiptail --passwordbox 'Root console password (not logged)' 10 "$DIALOG_WIDTH" 3>&1 1>&2 2>&3)
        password2=$(whiptail --passwordbox 'Confirm root console password' 10 "$DIALOG_WIDTH" 3>&1 1>&2 2>&3)
        [[ -n "$password" && "$password" == "$password2" && "$password" != *$'\n'* && "$password" != *$'\r'* ]] || die 'Passwords are empty, differ, or contain a newline.'
        unset password2
    fi
    yesno 'Step 7 · Refresh the Proxmox template catalog? This downloads metadata only.' && pveam update
    release=$(menu 'Debian release' 13 'Debian 13 (Trixie)' 12 'Debian 12 (Bookworm)')
    arch=$(dpkg --print-architecture)
    [[ "$arch" == amd64 || "$arch" == arm64 ]] || die "Unsupported host architecture: $arch"
    while read -r item; do
        [[ -n "$item" ]] && templates+=("$item" 'Official Proxmox template')
    done < <(pveam available --section system | awk -v r="$release" -v a="$arch" '$2 ~ ("^debian-" r "-standard_.*_" a "\\.tar\\.") {print $2}')
    ((${#templates[@]})) || die 'No matching template. Refresh the catalog and try again.'
    template=$(menu 'Select the exact Debian template' "${templates[@]}")
    template_store=$(choose_storage vztmpl)
    number "$cores" 1 "$(nproc)" || die 'Invalid core count.'
    number "$memory" 256 1048576 || die 'Invalid memory.'
    [[ "$swap" == 0 ]] || number "$swap" 1 1048576 || die 'Invalid swap.'
    number "$disk" 2 1048576 || die 'Invalid disk size.'
    number "$mtu" 576 9000 || die 'Invalid MTU.'
    [[ -z "$vlan" ]] || number "$vlan" 1 4094 || die 'Invalid VLAN.'
    [[ "$bridge" =~ ^[a-zA-Z0-9_.:-]+$ && -d "/sys/class/net/$bridge/bridge" ]] || die 'Select an existing Linux bridge.'
    [[ -z "$mac" || "$mac" =~ ^([a-fA-F0-9]{2}:){5}[a-fA-F0-9]{2}$ ]] || die 'Invalid MAC address.'
    python3 - "$ip" "$gateway" "$dns" "$ip6" "$gateway6" "$rate" "$cpulimit" "$cpuunits" <<'PY'
import ipaddress, sys
ip, gw, dns, ip6, gw6, rate, limit, weight = sys.argv[1:]
if ip not in ('dhcp', 'manual'): ipaddress.IPv4Interface(ip)
if gw: ipaddress.IPv4Address(gw)
if dns: ipaddress.ip_address(dns)
if ip6 not in ('manual', 'auto', 'dhcp'): ipaddress.IPv6Interface(ip6)
if gw6: ipaddress.IPv6Address(gw6)
import decimal
for value in (rate, limit):
    if value:
        n = decimal.Decimal(value)
        assert n.is_finite() and n >= 0 and n <= 8192, 'Invalid rate/CPU limit'
assert weight.isdecimal() and 1 <= int(weight) <= 10000, 'Invalid CPU weight'
PY
    [[ -z "$search" || "$search" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die 'Invalid search domain.'
    [[ "$tz" != *..* && "$tz" =~ ^[a-zA-Z0-9_+/-]+$ && -f "/usr/share/zoneinfo/$tz" ]] || die 'Invalid timezone.'
    selected=$(whiptail --separate-output --checklist 'Step 8 · Select tools. Compose includes Docker Engine. Space toggles; Enter continues.' "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" \
        git 'Git version control' OFF curl 'curl downloads' OFF wget 'wget downloads' OFF \
        tailscale 'Tailscale VPN (manual sign-in after install)' OFF \
        docker 'Docker Engine and Buildx' OFF compose 'Docker Compose plugin + Engine' OFF \
        nano 'Simple text editor' OFF vim-tiny 'Compact Vim editor' OFF htop 'Process viewer' OFF \
        jq 'JSON tools' OFF tmux 'Persistent terminal sessions' OFF rsync 'File synchronization' OFF \
        unzip 'ZIP extraction' OFF dnsutils 'DNS diagnostics' OFF \
        iputils-ping 'Ping' OFF openssh-server 'SSH server (key login recommended)' OFF \
        sudo 'sudo (does not create users)' OFF 3>&1 1>&2 2>&3)
    local -a tools=()
    while IFS= read -r item; do [[ -z "$item" ]] || tools+=("$item"); done <<< "$selected"
    local docker=0 tailscale=0
    for item in ${tools[@]+"${tools[@]}"}; do
        case "$item" in docker|compose) docker=1;; tailscale) tailscale=1;; esac
    done
    nesting=$(menu 'Step 9 · Enable nesting? Docker requires Yes.' 0 'No' 1 'Yes (exposes additional host procfs/sysfs information)')
    if (( unpriv )); then
        keyctl=$(menu 'Enable keyctl? Required for Docker in an unprivileged CT.' 0 'No' 1 'Yes')
    fi
    while (( docker && nesting == 0 )); do
        nesting=$(menu 'Docker was selected and requires nesting. Confirm Yes, or press Esc to cancel.' 1 'Yes: enable nesting' 0 'Review requirement again')
    done
    while (( docker && unpriv && keyctl == 0 )); do
        keyctl=$(menu 'Unprivileged Docker requires keyctl. Confirm Yes, or press Esc to cancel.' 1 'Yes: enable keyctl' 0 'Review requirement again')
    done
    fuse=$(menu 'Enable FUSE? Only enable for workloads that need it.' 0 'No' 1 'Yes (can interact with container freezing/backups)')
    tun=$(menu 'Pass through /dev/net/tun? Required for selected Tailscale installation.' 0 'No' 1 'Yes')
    while (( tailscale && tun == 0 )); do
        tun=$(menu 'Tailscale requires TUN passthrough. Confirm Yes, or press Esc to cancel.' 1 'Yes: enable TUN' 0 'Review requirement again')
    done
    if (( tun )); then
        [[ -c /dev/net/tun ]] || die 'TUN is missing on the host. Configure it first.'
        devices+=(/dev/net/tun)
    fi
    if yesno 'Step 10 · Configure GPU passthrough? Select individual /dev/dri devices. Host drivers must already work.'; then
        local -a gpu_choices=()
        for item in /dev/dri/card* /dev/dri/renderD*; do
            [[ ! -c "$item" ]] || gpu_choices+=("$item" 'GPU device' OFF)
        done
        ((${#gpu_choices[@]})) || die 'No /dev/dri GPU devices found. Host GPU drivers are required.'
        selected=$(whiptail --separate-output --checklist 'Select GPU devices to pass through' "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" "${gpu_choices[@]}" 3>&1 1>&2 2>&3)
        while IFS= read -r item; do [[ -z "$item" ]] || devices+=("$item"); done <<< "$selected"
    fi
    if yesno 'Pass through another character device, such as a USB serial adapter? Block devices are excluded.'; then
        device=$(ask 'Host character device path under /dev (one device)' '')
        [[ "$device" =~ ^/dev/[a-zA-Z0-9_./-]+$ && "$device" != *..* && -c "$device" ]] || die 'Invalid character device.'
        for item in ${devices[@]+"${devices[@]}"}; do [[ "$device" != "$item" ]] || die 'Device already selected.'; done
        devices+=("$device")
    fi
    if ((${#devices[@]})); then
        pct_help=$(pct help create 2>&1)
        [[ "$pct_help" == *'--dev[n]'* || "$pct_help" == *'--dev0'* ]] ||
            die 'This PVE version does not advertise device passthrough. Upgrade PVE or omit devices.'
        for device in ${devices[@]+"${devices[@]}"}; do
            [[ -c "$device" ]] || die "Device disappeared: $device"
            gid=$(ask "Guest numeric group ID for $device (0 = root; choose video/render GID for GPU access by non-root users)" 0)
            [[ "$gid" == 0 ]] || number "$gid" 1 2147483647 || die 'Invalid device group ID.'
            device_options+=("--dev$device_index" "path=$device,gid=$gid,uid=0,mode=0660")
            device_index=$((device_index + 1))
        done
    fi
    onboot=$(menu 'Step 11 · Start at host boot?' 0 'No' 1 'Yes')
    startup=$(ask 'Startup order (0–9999; lower starts earlier)' 0)
    [[ "$startup" == 0 ]] || number "$startup" 1 9999 || die 'Invalid startup order.'
    protection=$(menu 'Protect this container against accidental removal?' 1 'Yes' 0 'No')
    if yesno 'Step 12 · Upgrade Debian packages inside the new container?'; then upgrade=1; fi
    net="name=eth0,bridge=$bridge,ip=$ip,ip6=$ip6,firewall=$firewall,mtu=$mtu"
    [[ -z "$gateway" ]] || net+=",gw=$gateway"
    [[ -z "$gateway6" ]] || net+=",gw6=$gateway6"
    [[ -z "$vlan" ]] || net+=",tag=$vlan"
    [[ -z "$mac" ]] || net+=",hwaddr=$mac"
    [[ -z "$rate" ]] || net+=",rate=$rate"
    features="nesting=$nesting,fuse=$fuse"
    (( unpriv == 0 )) || features+=",keyctl=$keyctl"
    local plan
    printf -v plan 'Create CT %s (%s)\nTemplate: %s\nTemplate storage: %s\nRoot storage: %s (%s GiB)\nCPU: %s; RAM: %s MiB; swap: %s MiB\nUnprivileged: %s; features: %s\nNetwork: %s\nDNS: %s; search: %s\nBoot: %s; timezone: %s; locale: en_US.UTF-8\nSSH key: %s\nTools: %s\nUpgrade packages: %s; TUN device: %s\n\nThe container will start now. No existing guest will be modified.\nDocker in LXC shares the host kernel; a VM provides stronger isolation.\nDownload template if needed, create and install?' \
        "$CTID" "$hostname" "$template" "$template_store" "$root_store" "$disk" "$cores" "$memory" "$swap" "$unpriv" "$features" "$net" "${dns:-inherit}" "${search:-inherit}" "$onboot" "$tz" "${keyfile:-none}" "${tools[*]:-none}" "$upgrade" "$tun"
    plan+=$'\n'
    plan+="Tags: ${tags:-none}; CPU limit: $cpulimit; weight: $cpuunits; startup order: $startup; protection: $protection"
    plan+=$'\n'
    plan+="Device options: ${device_options[*]:-none}; root password: $([[ -n "$password" ]] && echo set || echo locked)"
    whiptail --scrolltext --defaultno --yesno "$plan" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" || exit 0
    umask 077
    mkdir -p /var/log/sweenlab-debian-lxc
    LOG="/var/log/sweenlab-debian-lxc/$(date +%Y%m%d-%H%M%S)-$$.log"
    exec > >(tee -a "$LOG") 2>&1
    printf '%s\n' "$plan"
    sha256sum "$INSTALLER"
    # Recheck after review; pct create also enforces ID allocation atomically.
    pvesh get /cluster/nextid --vmid "$CTID" >/dev/null
    local volume="$template_store:vztmpl/$template"
    if ! pveam list "$template_store" | awk '{print $1}' | grep -Fxq "$volume"; then
        pveam download "$template_store" "$template"
    fi
    local -a args=("$CTID" "$volume" --ostype debian --arch "$arch" --hostname "$hostname"
        --cores "$cores" --cpulimit "$cpulimit" --cpuunits "$cpuunits" --memory "$memory" --swap "$swap" --rootfs "$root_store:$disk"
        --unprivileged "$unpriv" --features "$features" --net0 "$net" --onboot "$onboot"
        --protection "$protection" --startup "order=$startup"
        --description "SweenLab Debian LXC; wizard $SCRIPT_VERSION")
    [[ -z "$dns" ]] || args+=(--nameserver "$dns")
    [[ -z "$search" ]] || args+=(--searchdomain "$search")
    [[ -z "$keyfile" ]] || args+=(--ssh-public-keys "$keyfile")
    [[ -z "$tags" ]] || args+=(--tags "$tags")
    if (( device_index > 0 )); then args+=("${device_options[@]}"); fi
    pct create "${args[@]}"
    CREATED=1
    pct start "$CTID"
    local ready=0 attempt
    for attempt in {1..60}; do
        if pct exec "$CTID" -- test -d /run/systemd/system; then ready=1; break; fi
        sleep 2
    done
    (( ready )) || die 'Container did not become ready within 120 seconds.'
    if [[ -n "$password" ]]; then
        printf 'root:%s\n' "$password" | pct exec "$CTID" -- chpasswd
        unset password
    fi
    TMP=$(mktemp)
    cp -- "$INSTALLER" "$TMP"
    # Use a fixed owned path inside this newly created CT; never run remote code.
    pct push "$CTID" "$TMP" /root/sweenlab-debian-tools.sh --perms 0700
    pct exec "$CTID" -- bash /root/sweenlab-debian-tools.sh --timezone "$tz" --upgrade "$upgrade" ${tools[@]+"${tools[@]}"}
    printf '\n[OK] CT %s created. Log: %s\n' "$CTID" "$LOG"
    pct exec "$CTID" -- hostname -I
    printf 'Console: pct enter %s\n' "$CTID"
    (( tailscale == 0 )) || printf 'Sign in: pct exec %s -- tailscale up\n' "$CTID"
    printf 'Installer remains in /root/sweenlab-debian-tools.sh for reviewed retries.\n'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
