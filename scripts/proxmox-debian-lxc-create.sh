#!/usr/bin/env bash
# SweenLab Debian LXC Creation Wizard — MIT
# https://github.com/SweenLab/personal-proxmox-scripts
set -Eeuo pipefail
SCRIPT_VERSION=0.1.5
CTID='' CREATED=0 LOG='' TMP='' UI_DIR='' UI_ACTION='' UI_VALUE=''
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup() {
    local rc=$?
    [[ -z "$TMP" ]] || rm -f -- "$TMP"
    [[ -z "$UI_DIR" ]] || rm -rf -- "$UI_DIR"
    if (( rc != 0 )); then
        printf '\nStopped with status %s. Log: %s\n' "$rc" "${LOG:-not started}" >&2
        [[ -z "$CTID" ]] || printf 'Inspect CT %s and any partial storage before retrying. Nothing is automatically destroyed.\n' "$CTID" >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Keep private logs/UI files at 077, but do not pass that mask to Proxmox.
# File::Path::make_path in Proxmox respects the inherited process umask.
proxmox_pct() (
    umask 022
    pct "$@"
)
assert_new_ct_path() {
    if [[ -e "/var/lib/lxc/$CTID" || -L "/var/lib/lxc/$CTID" ]]; then
        die "CT $CTID has a leftover /var/lib/lxc/$CTID path. Choose a fresh ID or inspect the leftover state first. Nothing was changed."
    fi
}
number() { [[ "$1" =~ ^[1-9][0-9]{0,8}$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 )); }
contains_line() { local wanted=$1 line; while IFS= read -r line; do [[ "$line" != "$wanted" ]] || return 0; done <<< "$2"; return 1; }
ui() {
    local kind=$1 title=$2 prompt=$3 seed=$4; shift 4
    printf '%s' "$seed" > "$UI_DIR/seed"
    python3 "$UI_DIR/ui.py" "$kind" "SweenLab $SCRIPT_VERSION | $title" "$prompt" "$UI_DIR/seed" "$UI_DIR/result" "$@" </dev/tty >/dev/tty
    IFS= read -r UI_ACTION < "$UI_DIR/result"
    UI_VALUE=$(sed '1d' "$UI_DIR/result")
    # Passwords are never passed as command arguments or retained on disk.
    : > "$UI_DIR/seed"; : > "$UI_DIR/result"
}
host_timezone() {
    local zone=''
    zone=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
    if [[ -z "$zone" ]]; then
        zone=$(readlink -f /etc/localtime 2>/dev/null || true)
        zone=${zone#/usr/share/zoneinfo/}
    fi
    if [[ "$zone" =~ ^[a-zA-Z0-9_+/-]+$ && "$zone" != *..* && -f "/usr/share/zoneinfo/$zone" ]]; then
        printf '%s\n' "$zone"
    else
        printf 'UTC\n'
    fi
}
list_storage() {
    local data
    data=$(pvesm status --content "$1") || die 'Could not read storage inventory.'
    awk 'NR>1 && $3=="active" {print $1}' <<< "$data"
}
list_downloaded_templates() {
    local data
    data=$(pveam list "$1") || die 'Could not read downloaded templates.'
    python3 -c '
import re, sys
store, arch = sys.argv[1:]
for line in sys.stdin:
    fields = line.split()
    if not fields:
        continue
    volume = fields[0]
    if re.fullmatch(re.escape(store) + r":vztmpl/debian-(12|13)-standard_[A-Za-z0-9.+~_-]+_" + re.escape(arch) + r"\.tar\.(zst|xz|gz)", volume):
        print(volume)
' "$1" "$2" <<< "$data"
}
validate_ip() { python3 -c 'import ipaddress,sys; (ipaddress.IPv4Interface if sys.argv[1]=="4" else ipaddress.IPv6Interface)(sys.argv[2])' "$1" "$2" 2>/dev/null; }
validate_address() { python3 -c 'import ipaddress,sys; (ipaddress.IPv4Address if sys.argv[1]=="4" else ipaddress.IPv6Address)(sys.argv[2])' "$1" "$2" 2>/dev/null; }
validate_rate() { python3 -c 'import decimal,sys; n=decimal.Decimal(sys.argv[1]); sys.exit(0 if n.is_finite() and n>=0 and n<=8192 else 1)' "$1" 2>/dev/null; }
yes_word() { if [[ "$1" == 1 ]]; then printf Yes; else printf No; fi; }
# These probes are read-only and do not broaden host directory permissions.
check_extraction_access() {
    (( unpriv )) || return 0
    local parent
    for parent in /var /var/lib /var/lib/lxc; do
        if ! lxc-usernsexec -m u:0:100000:65536 -m g:0:100000:65536 -- test -x "$parent"; then
            printf 'Mapped container root (host UID 100000) cannot traverse %s.\n' "$parent" >&2
            command -v namei >/dev/null && namei -l "$parent" || true
            die 'Fix the host path/ACL problem before creation. No permissions were changed.'
        fi
    done
}
creation_diagnostics() {
    printf '\nProxmox failed before guest setup. Read-only path diagnostics follow.\n'
    command -v namei >/dev/null && namei -l "/var/lib/lxc/$CTID/rootfs" || true
    command -v findmnt >/dev/null && findmnt -T /var/lib/lxc -o TARGET,SOURCE,FSTYPE,OPTIONS || true
    printf 'Inspect the selected storage (%s), parent traversal permissions and ACLs.\n' "$root_store"
    printf 'Do not chmod recursively or switch to privileged mode as an automatic workaround.\n'
}
make_plan() {
    cat <<PLAN
CONTAINER
  ID / name       $CTID / $hostname
  Tags            ${tags:-none}
  Type            $([[ "$unpriv" == 1 ]] && printf Unprivileged || printf Privileged)

RESOURCES
  CPU / memory    $cores cores / $memory MiB
  Root disk       $root_store · $disk GiB
  Timezone        $tz
  Template        ${template##*/}
  Template store  $template_store

NETWORK
  Bridge          $bridge
  IPv4            $ip ${gateway:+(gateway $gateway)}
  IPv6            $ip6 ${gateway6:+(gateway $gateway6)}
  VLAN / MTU      ${vlan:-untagged} / $mtu
  MAC / rate      ${mac:-automatic} / ${rate:-unlimited}
  DNS / search    ${dns:-inherit host} / ${search:-inherit host}

SOFTWARE & FEATURES
  Packages        ${packages_display:-none}
  Nesting/keyctl  $(yes_word "$nesting") / $(yes_word "$keyctl")
  FUSE / TUN      $(yes_word "$fuse") / $(yes_word "$tun")
  GPU devices     ${gpu_display:-none}
  Host boot       $(yes_word "$onboot")
  Tailscale login $([[ "$tailscale" == 1 && "$ts_up" == 1 ]] && printf Yes || printf No)
  Tailscale flags ${ts_flags_display:-not selected}

AUTOMATIC SETTINGS
  Root password required (hidden); locale en_US.UTF-8
  Package upgrades enabled; firewall interface flag enabled
  CPU limit 0; CPU weight 100; swap 512 MiB
  PVE default startup order/delays; deletion protection off
  Passed devices use guest UID/GID 0 and mode 0660

Create starts this new CT and installs the selected software.
Tailscale login may require browser authentication after installation.
PLAN
}
configure() {
    ctid=$(pvesh get /cluster/nextid)
    hostname='' tags='' bridge='' ipmode=dhcp ip='' gateway='' ip6mode=manual ip6='' gateway6=''
    vlan='' mtu=1500 mac='' rate='' dns='' search='' cores=2 memory=1024 disk=8 root_store=''
    tz=$(host_timezone); unpriv=1 keyfile='' password='' password_confirm='' template_store='' template=''
    selected='' ts_up=1 ts_options=$'ssh\nignore-dns\nqr' nesting=1 keyctl=1 fuse=1 tun=1 gpu=1 gpu_selected='' onboot=1
    docker=0 tailscale=0 packages_display='' gpu_display='' ts_flags_display=''
    local -a steps=(ctid hostname tags bridge ipmode ip gateway ip6mode ip6 gateway6 vlan mtu mac rate dns search cores memory disk root_store tz unpriv keyfile password password_confirm template_store template selected ts_up ts_options nesting keyctl fuse tun gpu gpu_selected onboot review)
    local index=0 direction=1 key kind title prompt seed error='' names='' line old_password='' arch
    local -a options=()
    arch=$(dpkg --print-architecture)
    [[ "$arch" == amd64 || "$arch" == arm64 ]] || die 'This wizard supports amd64 and arm64 hosts.'
    while (( index < ${#steps[@]} )); do
        key=${steps[$index]}
        case "$key" in
            ip|gateway) [[ "$ipmode" == static ]] || { index=$((index + direction)); continue; };;
            ip6|gateway6) [[ "$ip6mode" == static ]] || { index=$((index + direction)); continue; };;
            ts_up|ts_options) (( tailscale )) || { index=$((index + direction)); continue; };;
            keyctl) (( unpriv )) || { index=$((index + direction)); continue; };;
            gpu|gpu_selected) [[ -n "$gpu_names" ]] || { index=$((index + direction)); continue; };;
        esac
        if [[ "$key" == gpu_selected ]] && (( gpu == 0 )); then index=$((index + direction)); continue; fi
        if [[ "$key" == ts_options ]] && (( ts_up == 0 )); then index=$((index + direction)); continue; fi
        options=(); kind=input; title='Container setup'; seed=${!key-}; prompt=''
        case "$key" in
            ctid) prompt='Container ID (unused across the cluster)' ;;
            hostname) prompt='Hostname (required; starts blank)' ;;
            tags) prompt='Tags separated by semicolons; leave blank for none' ;;
            bridge)
                kind=menu; title='Network bridge'; prompt='Choose the bridge for this container.'
                names=$(configured_linux_bridges)
                while IFS= read -r line; do [[ -z "$line" ]] || options+=("$line" ''); done <<< "$names"
                if ((${#options[@]} == 0)); then kind=notice; prompt='No active configured Proxmox Linux bridge is available. Apply its network configuration, then restart the wizard.'; fi;;
            ipmode) kind=menu; title='IPv4'; prompt='How should IPv4 be configured?'; options=(dhcp 'DHCP' static 'Static address' manual 'No automatic IPv4');;
            ip) title='IPv4 address'; prompt='IPv4 address/prefix, for example 10.10.10.204/24';;
            gateway) title='IPv4 gateway'; prompt='IPv4 gateway; leave blank for none';;
            ip6mode) kind=menu; title='IPv6'; prompt='How should IPv6 be configured?'; options=(manual 'No automatic IPv6' auto 'SLAAC' dhcp 'DHCPv6' static 'Static address');;
            ip6) title='IPv6 address'; prompt='IPv6 address/prefix';;
            gateway6) title='IPv6 gateway'; prompt='IPv6 gateway; leave blank for none';;
            vlan) title='VLAN'; prompt='VLAN tag; leave blank for untagged';;
            mtu) title='MTU'; prompt='Network MTU';;
            mac) title='MAC address'; prompt='Leave blank for Proxmox to generate a MAC address';;
            rate) title='Network rate'; prompt='Network limit in MB/s; leave blank for unlimited';;
            dns) title='DNS'; prompt='DNS server IP; leave blank to inherit the host configuration';;
            search) title='DNS search'; prompt='Search domain; leave blank to inherit the host configuration';;
            cores) title='CPU cores'; prompt='Number of CPU cores';;
            memory) title='Memory'; prompt=$'Memory in MiB\n\nQuick conversion:\n  512 MiB = 0.5 GiB    1024 MiB = 1 GiB\n  2048 MiB = 2 GiB     4096 MiB = 4 GiB\n  8192 MiB = 8 GiB    16384 MiB = 16 GiB';;
            disk) title='Root disk'; prompt='Root disk size in GiB';;
            root_store|template_store)
                kind=menu
                if [[ "$key" == root_store ]]; then title='Container storage'; prompt='Where should the container disk be stored?'; names=$(list_storage rootdir)
                else title='Template storage'; prompt='Where are your downloaded Debian templates stored?'; names=$(list_storage vztmpl); fi
                while IFS= read -r line; do [[ -z "$line" ]] || options+=("$line" ''); done <<< "$names"
                if ((${#options[@]} == 0)); then kind=notice; prompt='No active storage of the required content type is available. Configure storage in Proxmox before continuing.'; fi;;
            tz) title='Timezone'; prompt='Prefilled from the Proxmox host. Edit if needed.';;
            unpriv) kind=yesno; title='Container type'; prompt='Create an unprivileged container?';;
            keyfile) title='SSH key'; prompt='Optional host path to an SSH public key file; leave blank to skip';;
            password) kind=password; title='Root password'; prompt='Enter the required root console password (hidden).';;
            password_confirm) kind=password; title='Confirm password'; prompt='Re-enter the root password (hidden).';;
            template)
                kind=menu; title='Downloaded Debian template'; prompt='Choose a template already downloaded on this storage.'
                names=$(list_downloaded_templates "$template_store" "$arch")
                while IFS= read -r line; do [[ -z "$line" ]] || options+=("$line" "${line##*/}"); done <<< "$names"
                if ((${#options[@]} == 0)); then kind=notice; prompt='No downloaded Debian 12/13 template for this host architecture was found here. Back selects another storage; Abort lets you download a template in Proxmox first.'; fi;;
            selected)
                kind=check; title='Packages'; prompt='Space selects packages. Docker Compose includes Docker Engine.'
                options=(git 'Version control' curl 'Downloads' wget 'Downloads' tailscale 'VPN and optional guided sign-in'
                    docker 'Docker Engine + Buildx' compose 'Docker Compose + Engine' nano 'Text editor' jq 'JSON tools'
                    unzip 'ZIP extraction' iputils-ping 'Ping' openssh-server 'SSH server' sudo 'sudo; no users are created');;
            ts_up) kind=yesno; title='Tailscale sign-in'; prompt='Run tailscale up automatically after installation? The login URL/QR will appear for browser authentication.';;
            ts_options) kind=check; title='Tailscale options'; prompt='Choose options for tailscale up. SSH access still follows your tailnet policy.'; options=(ssh 'Enable Tailscale SSH' ignore-dns 'Keep existing DNS; ignore Tailscale DNS' accept-routes 'Accept advertised subnet routes' shields-up 'Block incoming Tailscale connections' qr 'Display a login QR code');;
            nesting) kind=yesno; title='Nesting'; prompt='Enable nesting? Required for Docker; exposes additional host procfs/sysfs information.';;
            keyctl) kind=yesno; title='Keyctl'; prompt='Enable keyctl? Required for Docker in an unprivileged container.';;
            fuse) kind=yesno; title='FUSE'; prompt='Enable FUSE? It can interact with container freezing and backups.';;
            tun) kind=yesno; title='TUN passthrough'; prompt='Pass through /dev/net/tun? Required for Tailscale. Guest UID/GID are configured automatically.';;
            gpu) kind=yesno; title='GPU passthrough'; prompt='Pass through GPU device nodes? Host GPU drivers must already work.';;
            gpu_selected)
                kind=check; title='GPU devices'; prompt='Select the GPU devices to pass through. Guest UID/GID are 0.'
                while IFS= read -r line; do [[ -z "$line" ]] || options+=("$line" ''); done <<< "$gpu_names";;
            onboot) kind=yesno; title='Start at host boot'; prompt='Start this container when Proxmox boots? Startup order and delays use Proxmox defaults.';;
            review) kind=review; title='Review and create'; seed=''; prompt=$(make_plan);;
        esac
        [[ -z "$error" ]] || prompt=$'Please correct: '"$error"$'\n\n'"$prompt"
        ui "$kind" "$title" "$prompt" "$seed" ${options[@]+"${options[@]}"}
        case "$UI_ACTION" in
            abort) printf 'Aborted. No container was created.\n'; exit 0;;
            back) direction=-1; index=$(( index > 0 ? index - 1 : 0 )); error=''; continue;;
            next) direction=1;;
            *) die 'Invalid dialog response.';;
        esac
        error=''
        if [[ "$key" == review ]]; then
            if (( docker && (!nesting || (unpriv && !keyctl)) )); then error='Docker requires nesting and keyctl in unprivileged mode. Use Back to change those settings.'; continue; fi
            if (( tailscale && !tun )); then error='Tailscale requires TUN. Use Back to enable it.'; continue; fi
            return 0
        fi
        old_password=$password
        printf -v "$key" '%s' "$UI_VALUE"
        case "$key" in
            ctid)
                if ! number "$ctid" 100 999999999; then error='Enter a valid CT ID.'
                elif ! pvesh get /cluster/nextid --vmid "$ctid" >/dev/null 2>&1; then error='That ID is already in use.'
                elif [[ -e "/var/lib/lxc/$ctid" || -L "/var/lib/lxc/$ctid" ]]; then error='That ID has leftover host directories. Choose a fresh ID; inspect the old state separately.'; fi
                CTID=$ctid;;
            hostname) [[ ${#hostname} -le 63 && "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || error='Hostname is required; use a single valid DNS label.';;
            tags) [[ -z "$tags" || "$tags" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.+-]*(\;[a-zA-Z0-9_][a-zA-Z0-9_.+-]*)*$ ]] || error='Use valid tags separated by semicolons.';;
            bridge|root_store|template_store|template) contains_line "${!key}" "$names" || error='Choose an item from the list.';;
            ip) validate_ip 4 "$ip" || error='Enter IPv4 with a prefix length.';;
            gateway) [[ -z "$gateway" ]] || validate_address 4 "$gateway" || error='Invalid IPv4 gateway.';;
            ip6) validate_ip 6 "$ip6" || error='Enter IPv6 with a prefix length.';;
            gateway6) [[ -z "$gateway6" ]] || validate_address 6 "$gateway6" || error='Invalid IPv6 gateway.';;
            vlan) [[ -z "$vlan" ]] || number "$vlan" 1 4094 || error='VLAN must be 1–4094.';;
            mtu) number "$mtu" 576 9000 || error='MTU must be 576–9000.';;
            mac) [[ -z "$mac" || "$mac" =~ ^([a-fA-F0-9]{2}:){5}[a-fA-F0-9]{2}$ ]] || error='Invalid MAC address.';;
            rate) [[ -z "$rate" ]] || validate_rate "$rate" || error='Invalid network rate.';;
            dns) [[ -z "$dns" ]] || python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$dns" 2>/dev/null || error='Invalid DNS server IP.';;
            search) [[ -z "$search" || "$search" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || error='Invalid search domain.';;
            cores) number "$cores" 1 "$(nproc)" || error='Enter a valid core count for this host.';;
            memory) number "$memory" 256 1048576 || error='Memory must be at least 256 MiB.';;
            disk) number "$disk" 2 1048576 || error='Disk must be at least 2 GiB.';;
            tz) [[ "$tz" != *..* && "$tz" =~ ^[a-zA-Z0-9_+/-]+$ && -f "/usr/share/zoneinfo/$tz" ]] || error='Unknown timezone.';;
            keyfile) [[ -z "$keyfile" || ( -f "$keyfile" && -r "$keyfile" ) ]] || error='SSH key file is unreadable.';;
            password) [[ -n "$password" && "$password" != *$'\n'* && "$password" != *$'\r'* ]] || error='A root password is required.'; [[ "$password" == "$old_password" ]] || password_confirm='';;
            password_confirm) [[ -n "$password_confirm" && "$password_confirm" == "$password" ]] || error='Passwords must match.';;
            selected)
                docker=0; tailscale=0; packages_display=${selected//$'\n'/, }
                contains_line docker "$selected" && docker=1
                contains_line compose "$selected" && docker=1
                contains_line tailscale "$selected" && tailscale=1;;
            ts_options) ts_flags_display=${ts_options//$'\n'/, };;
            nesting) (( docker == 0 || nesting == 1 )) || error='Docker was selected and requires nesting.';;
            keyctl) (( docker == 0 || keyctl == 1 )) || error='Unprivileged Docker requires keyctl.';;
            tun) if (( tun )); then [[ -c /dev/net/tun ]] || error='The host TUN device is missing.'; elif (( tailscale )); then error='Tailscale requires TUN.'; fi;;
            gpu_selected)
                gpu_display=${gpu_selected//$'\n'/, }
                while IFS= read -r line; do [[ -z "$line" ]] || contains_line "$line" "$gpu_names" || error='Unknown GPU device.'; done <<< "$gpu_selected";;
        esac
        [[ -z "$error" ]] || continue
        # Clear only values made irrelevant by an earlier choice.
        [[ "$ipmode" == static ]] || { ip=$ipmode; gateway=''; }
        [[ "$ip6mode" == static ]] || { ip6=$ip6mode; gateway6=''; }
        (( unpriv )) || keyctl=0
        (( gpu )) || { gpu_selected=''; gpu_display=''; }
        index=$((index + 1))
    done
}
execute_plan() {
    umask 077
    mkdir -p /var/log/sweenlab-debian-lxc
    LOG="/var/log/sweenlab-debian-lxc/$(date +%Y%m%d-%H%M%S)-$$.log"
    exec > >(tee -a "$LOG") 2>&1
    make_plan
    assert_new_ct_path
    check_extraction_access
    pvesh get /cluster/nextid --vmid "$CTID" >/dev/null
    [[ -d "/sys/class/net/$bridge/bridge" ]] || die 'The selected Linux bridge is no longer available.'
    local current_templates
    current_templates=$(list_downloaded_templates "$template_store" "$(dpkg --print-architecture)")
    contains_line "$template" "$current_templates" || die 'The selected template is no longer present.'
    local net="name=eth0,bridge=$bridge,ip=$ip,ip6=$ip6,firewall=1,mtu=$mtu"
    [[ -z "$gateway" ]] || net+=",gw=$gateway"
    [[ -z "$gateway6" ]] || net+=",gw6=$gateway6"
    [[ -z "$vlan" ]] || net+=",tag=$vlan"
    [[ -z "$mac" ]] || net+=",hwaddr=$mac"
    [[ -z "$rate" ]] || net+=",rate=$rate"
    local features="nesting=$nesting,fuse=$fuse"
    (( unpriv == 0 )) || features+=",keyctl=$keyctl"
    local -a args=("$CTID" "$template" --ostype debian --arch "$(dpkg --print-architecture)" --hostname "$hostname"
        --cores "$cores" --cpulimit 0 --cpuunits 100 --memory "$memory" --swap 512 --rootfs "$root_store:$disk"
        --unprivileged "$unpriv" --features "$features" --net0 "$net" --onboot "$onboot" --protection 0
        --description "SweenLab Debian LXC; wizard $SCRIPT_VERSION")
    [[ -z "$tags" ]] || args+=(--tags "$tags")
    [[ -z "$dns" ]] || args+=(--nameserver "$dns")
    [[ -z "$search" ]] || args+=(--searchdomain "$search")
    [[ -z "$keyfile" ]] || args+=(--ssh-public-keys "$keyfile")
    local device_index=0 device item pct_help
    local -a devices=() tools=()
    (( tun == 0 )) || devices+=(/dev/net/tun)
    if (( gpu )); then
        while IFS= read -r item; do [[ -z "$item" ]] || devices+=("$item"); done <<< "$gpu_selected"
    fi
    if ((${#devices[@]})); then
        pct_help=$(proxmox_pct help create 2>&1)
        [[ "$pct_help" == *'--dev[n]'* || "$pct_help" == *'--dev0'* ]] || die 'PVE device passthrough is unavailable on this host version.'
        for device in ${devices[@]+"${devices[@]}"}; do
            [[ -c "$device" ]] || die "Device is no longer available: $device"
            args+=("--dev$device_index" "path=$device,gid=0,uid=0,mode=0660")
            device_index=$((device_index + 1))
        done
    fi
    local rc=0
    proxmox_pct create "${args[@]}" || rc=$?
    if (( rc )); then creation_diagnostics; die "Container creation failed (status $rc). Inspect CT $CTID before retrying; no automatic cleanup was performed."; fi
    CREATED=1
    proxmox_pct start "$CTID"
    local ready=0 attempt
    for attempt in {1..60}; do
        if proxmox_pct exec "$CTID" -- test -d /run/systemd/system; then ready=1; break; fi
        sleep 2
    done
    (( ready )) || die 'Container was not ready within 120 seconds.'
    printf 'root:%s\n' "$password" | proxmox_pct exec "$CTID" -- chpasswd
    unset password password_confirm
    TMP=$(mktemp)
    write_guest_installer > "$TMP"
    bash -n "$TMP"; sha256sum "$TMP"
    proxmox_pct push "$CTID" "$TMP" /root/sweenlab-debian-tools.sh --perms 0700
    while IFS= read -r item; do [[ -z "$item" ]] || tools+=("$item"); done <<< "$selected"
    proxmox_pct exec "$CTID" -- bash /root/sweenlab-debian-tools.sh --timezone "$tz" --upgrade 1 ${tools[@]+"${tools[@]}"}
    if (( tailscale && ts_up )); then
        local ssh=false accept_dns=true routes=false shields=false qr=false login_rc=0
        contains_line ssh "$ts_options" && ssh=true
        contains_line ignore-dns "$ts_options" && accept_dns=false
        contains_line accept-routes "$ts_options" && routes=true
        contains_line shields-up "$ts_options" && shields=true
        contains_line qr "$ts_options" && qr=true
        printf '\nStarting Tailscale sign-in. Complete the URL/QR in your browser.\n'
        # Login URLs are sent only to the terminal, not the host run log.
        proxmox_pct exec "$CTID" -- tailscale up --timeout=120s "--ssh=$ssh" "--accept-dns=$accept_dns" "--accept-routes=$routes" "--shields-up=$shields" "--qr=$qr" >/dev/tty 2>/dev/tty || login_rc=$?
        if (( login_rc )); then
            printf '[ATTENTION] Tailscale sign-in is incomplete; CT and packages are preserved. Retry:\n'
            printf 'pct exec %s -- tailscale up --ssh=%s --accept-dns=%s --accept-routes=%s --shields-up=%s --qr=%s\n' "$CTID" "$ssh" "$accept_dns" "$routes" "$shields" "$qr"
        fi
    fi
    printf '\n[OK] CT %s created and selected packages installed. Log: %s\n' "$CTID" "$LOG"
    proxmox_pct exec "$CTID" -- hostname -I
    printf 'Enter the container: pct enter %s\n' "$CTID"
}
main() {
    if [[ ${1:-} == --help ]]; then printf 'Self-contained SweenLab wizard %s. Run as root on Proxmox VE.\n' "$SCRIPT_VERSION"; return; fi
    (($# == 0)) || die 'Unknown argument.'
    (( EUID == 0 )) || die 'Run on the Proxmox host as root.'
    [[ -d /etc/pve ]] || die 'A Proxmox VE host is required.'
    local cmd
    for cmd in pct pvesh pvesm pveam python3 flock sha256sum lxc-usernsexec; do command -v "$cmd" >/dev/null || die "Required command is missing: $cmd"; done
    python3 -c 'import curses' || die 'Python terminal support (curses) is required.'
    exec </dev/tty
    exec 9>/run/lock/sweenlab-debian-lxc.lock
    flock -n 9 || die 'Another SweenLab wizard is running.'
    umask 077
    UI_DIR=$(mktemp -d)
    write_ui > "$UI_DIR/ui.py"
    gpu_names=''
    local item
    for item in /dev/dri/card* /dev/dri/renderD*; do [[ ! -c "$item" ]] || gpu_names+="$item"$'\n'; done
    configure
    execute_plan
}

configured_linux_bridges() {
    local network_json
    network_json=$(pvesh get "/nodes/$(hostname -s)/network" --type bridge --output-format json) ||
        die 'Could not read Proxmox network configuration.'
    python3 -c '
import json, re, sys
networks = json.load(sys.stdin)
if not isinstance(networks, list):
    raise SystemExit("Invalid Proxmox network response.")
bridges = set()
for entry in networks:
    name = entry.get("iface", "")
    if entry.get("type") != "bridge" or entry.get("active") not in (1, True):
        continue
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", name):
        continue
    if re.fullmatch(r"docker[0-9]+|br-[0-9a-fA-F]+|fwbr[0-9]+i[0-9]+", name):
        continue
    bridges.add(name)
for name in sorted(bridges, key=lambda value: [int(part) if part.isdigit() else part for part in re.split(r"([0-9]+)", value)]):
    print(name)
' <<< "$network_json"
}


write_ui() {
    cat <<'SWEENLAB_UI'
import curses
import os
import sys
import textwrap


def button_set(kind):
    if kind == 'yesno':
        return [('Back', 'back', ''), ('Yes', 'next', '1'), ('No', 'next', '0'), ('Abort', 'abort', '')]
    if kind == 'notice':
        return [('Back', 'back', ''), ('Abort', 'abort', '')]
    return [('Back', 'back', ''), ('Create' if kind == 'review' else 'Next', 'next', None), ('Abort', 'abort', '')]


def run(screen, kind, title, prompt, seed, options):
    curses.curs_set(0)
    screen.keypad(True)
    text = seed
    cursor = len(text)
    tags = [tag for tag, _ in options]
    selected = set(seed.splitlines())
    row = tags.index(seed) if seed in tags else 0
    scroll = 0
    buttons = button_set(kind)
    button = 1 if kind != 'notice' else 0
    if kind == 'yesno' and seed == '0':
        button = 2
    focus = 'buttons' if kind in ('yesno', 'review', 'notice') else 'content'
    while True:
        screen.erase()
        h, w = screen.getmaxyx()
        if h < 24 or w < 80:
            screen.addnstr(0, 0, 'Enlarge this terminal to at least 80 columns x 24 rows. Esc aborts.', max(1, w - 1))
            screen.refresh()
            if screen.getch() == 27:
                return 'abort', ''
            continue
        width = min(w - 4, 100)
        left = (w - width) // 2
        top = 1
        height = h - 2
        box = screen.derwin(height, width, top, left)
        box.box()
        def write(y, x, value, attr=0):
            if 0 <= y < height - 1:
                box.addnstr(y, x, value, max(0, width - x - 2), attr)
        write(0, 3, ' ' + title + ' ', curses.A_BOLD)
        lines = []
        for paragraph in prompt.splitlines():
            lines.extend(textwrap.wrap(paragraph, width - 6) or [''])
        if kind == 'review':
            limit = height - 7
            scroll = max(0, min(scroll, max(0, len(lines) - limit)))
            for idx, line in enumerate(lines[scroll:scroll + limit]):
                write(2 + idx, 3, line)
        else:
            for idx, line in enumerate(lines[:8]):
                write(2 + idx, 3, line)
            content_y = 3 + min(len(lines), 8)
            if kind in ('input', 'password'):
                shown = '*' * len(text) if kind == 'password' else text
                field_width = width - 8
                offset = max(0, cursor - field_width + 1)
                write(content_y, 3, ' ' * field_width, curses.A_REVERSE if focus == 'content' else 0)
                write(content_y, 3, shown[offset:], curses.A_REVERSE if focus == 'content' else 0)
            elif kind in ('menu', 'check'):
                visible = max(1, height - content_y - 5)
                start = max(0, min(row - visible + 1, max(0, len(options) - visible)))
                for idx, (tag, label) in enumerate(options[start:start + visible], start):
                    mark = ('[x] ' if tag in selected else '[ ] ') if kind == 'check' else ''
                    label = (label or tag) if kind == 'menu' else (tag if not label else tag + '  ' + label)
                    write(content_y + idx - start, 3, mark + label,
                          curses.A_REVERSE if idx == row and focus == 'content' else 0)
        labels = ['< ' + value[0] + ' >' for value in buttons]
        total = sum(map(len, labels)) + 4 * (len(labels) - 1)
        x = max(2, (width - total) // 2)
        for idx, label in enumerate(labels):
            write(height - 4, x, label, curses.A_REVERSE | curses.A_BOLD if idx == button else curses.A_NORMAL)
            x += len(label) + 4
        hint = 'Tab: buttons | Shift+Tab: previous | Esc: abort'
        if kind == 'check':
            hint = 'Space: select | Tab: buttons | Esc: abort'
        if kind == 'review':
            hint = 'Up/Down: scroll | Left/Right: buttons | Esc: abort'
        write(height - 2, 3, hint, curses.A_DIM)
        curses.curs_set(1 if focus == 'content' and kind in ('input', 'password') else 0)
        if focus == 'content' and kind in ('input', 'password'):
            box.move(content_y, 3 + min(cursor, width - 9))
        box.refresh()
        key = screen.get_wch()
        if key == '\x1b' or key == '\x03':
            return 'abort', ''
        if key == curses.KEY_RESIZE:
            continue
        if key in ('\t', curses.KEY_BTAB):
            if focus == 'content':
                focus = 'buttons'
                button = len(buttons) - 1 if key == curses.KEY_BTAB else 1
            else:
                step = -1 if key == curses.KEY_BTAB else 1
                target = button + step
                if target < 0 or target >= len(buttons):
                    if kind in ('input', 'password', 'menu', 'check'):
                        focus = 'content'
                    else:
                        button = target % len(buttons)
                else:
                    button = target
            continue
        if kind == 'review' and key in (curses.KEY_UP, curses.KEY_DOWN, curses.KEY_NPAGE, curses.KEY_PPAGE):
            scroll += {curses.KEY_UP: -1, curses.KEY_DOWN: 1, curses.KEY_NPAGE: 8, curses.KEY_PPAGE: -8}[key]
            continue
        if focus == 'buttons' and key in (curses.KEY_LEFT, curses.KEY_RIGHT):
            button = (button + (1 if key == curses.KEY_RIGHT else -1)) % len(buttons)
            continue
        if focus == 'content':
            if kind in ('menu', 'check'):
                if key in (curses.KEY_UP, curses.KEY_DOWN):
                    row = (row + (1 if key == curses.KEY_DOWN else -1)) % max(1, len(options))
                    continue
                if key == ' ' and kind == 'check' and options:
                    tag = options[row][0]
                    selected.symmetric_difference_update([tag])
                    continue
            elif kind in ('input', 'password'):
                if key in (curses.KEY_BACKSPACE, '\x7f', '\b'):
                    if cursor:
                        text = text[:cursor - 1] + text[cursor:]
                        cursor -= 1
                    continue
                if key == curses.KEY_DC:
                    text = text[:cursor] + text[cursor + 1:]
                    continue
                if key in (curses.KEY_LEFT, curses.KEY_RIGHT, curses.KEY_HOME, curses.KEY_END):
                    cursor = {curses.KEY_LEFT: max(0, cursor - 1), curses.KEY_RIGHT: min(len(text), cursor + 1),
                              curses.KEY_HOME: 0, curses.KEY_END: len(text)}[key]
                    continue
                if key == '\x15':
                    text, cursor = '', 0
                    continue
                if isinstance(key, str) and key.isprintable():
                    text = text[:cursor] + key + text[cursor:]
                    cursor += 1
                    continue
        if key in ('\n', '\r', curses.KEY_ENTER):
            _, action, value = buttons[button if focus == 'buttons' else 1]
            if action != 'next' or value is not None:
                return action, value or ''
            if kind in ('input', 'password'):
                return action, text
            if kind == 'menu':
                return action, tags[row] if tags else ''
            if kind == 'check':
                return action, '\n'.join(tag for tag in tags if tag in selected)
            return action, ''


def main():
    kind, title, prompt, seed_path, result_path, *raw = sys.argv[1:]
    options = list(zip(raw[::2], raw[1::2]))
    with open(seed_path) as handle:
        seed = handle.read()
    try:
        action, value = curses.wrapper(run, kind, title, prompt, seed, options)
    except KeyboardInterrupt:
        action, value = 'abort', ''
    fd = os.open(result_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as handle:
        handle.write(action + '\n' + value)


if __name__ == '__main__':
    main()
SWEENLAB_UI
}

# Keep guest setup in this file so the launcher never fetches another script.
write_guest_installer() {
    cat <<'SWEENLAB_GUEST_INSTALLER'
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
            git|curl|wget|nano|jq|unzip|iputils-ping|openssh-server|sudo)
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
        printf 'Tailscale installed. The wizard will handle the selected sign-in options.\n'
    fi
    for item in ${tools[@]+"${tools[@]}"}; do
        [[ $(dpkg-query -W -f='${Status}' "$item") == 'install ok installed' ]] || fail "Verification failed: $item"
    done
    printf '[OK] Selected tools installed; locale en_US.UTF-8; timezone %s.\n' "$tz"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
SWEENLAB_GUEST_INSTALLER
}


if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then main "$@"; fi
