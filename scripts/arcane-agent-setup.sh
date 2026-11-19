#!/usr/bin/env bash
# SWEENLAB SCRIPTS — Arcane Agent Setup 0.2.0 (MIT)
# https://github.com/SweenLab/sweenlab-scripts
set +x
set -euo pipefail

readonly version=0.2.0
readonly install_dir=/opt/arcane-agent
readonly default_manager=http://10.10.10.103:3552

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

case ${1:-} in
    --version) printf 'SweenLab Arcane Agent Setup %s\n' "$version"; exit ;;
    --help|-h) printf 'Run as root inside the Docker LXC. Generate a token in Arcane under Agents > Add Agent.\n'; exit ;;
    '') ;;
    *) die 'Unknown argument. Use --help.' ;;
esac

[[ $EUID == 0 && $(uname -s) == Linux && ! -d /etc/pve ]] ||
    die 'Run as root inside the Docker LXC.'
[[ ! -e $install_dir && ! -L $install_dir ]] ||
    die "$install_dir already exists. Existing files were preserved."
docker compose version >/dev/null 2>&1 || die 'Docker Compose is required.'
[[ -S /var/run/docker.sock ]] || die 'The local Docker socket is missing.'
docker_local() { docker --host unix:///var/run/docker.sock "$@"; }
existing=$(docker_local container ls -a --format '{{.Names}}') ||
    die 'Could not contact the local Docker engine.'
if [[ $'\n'$existing$'\n' == *$'\narcane-agent\n'* ]]; then
    die 'An arcane-agent container already exists.'
fi
existing_project=$(docker_local container ls -aq --filter label=com.docker.compose.project=arcane-agent) ||
    die 'Could not check for an existing Arcane Agent Compose project.'
existing_data=$(docker_local volume ls -q --filter name=arcane-agent_arcane-data) ||
    die 'Could not check for existing Arcane Agent data.'
if [[ -n $existing_project || $'\n'$existing_data$'\n' == *$'\narcane-agent_arcane-data\n'* ]]; then
    die 'An Arcane Agent Compose project or data volume already exists.'
fi
{ exec 3<>/dev/tty; } 2>/dev/null || die 'Open an interactive terminal inside the LXC.'
trap 'exit 130' INT
trap 'exit 143' TERM

if ! command -v dialog >/dev/null; then
    command -v apt-get >/dev/null || die 'The dialog package is required.'
    printf 'Installing dialog for the SweenLab setup wizard.\n' >&3
    apt-get update <&3 >&3 2>&3 &&
        apt-get install -y --no-install-recommends dialog <&3 >&3 2>&3 ||
        die 'Could not install the dialog package.'
fi

theme=$(mktemp)
trap 'rm -f -- "$theme"' EXIT
cat > "$theme" <<'THEME'
use_colors = ON
use_shadow = OFF
screen_color = (WHITE,BLACK,OFF)
dialog_color = (BLACK,WHITE,OFF)
title_color = (YELLOW,BLACK,ON)
border_color = (BLACK,WHITE,OFF)
button_active_color = (BLACK,GREEN,ON)
button_inactive_color = (YELLOW,BLACK,ON)
button_key_active_color = (BLACK,GREEN,ON)
button_key_inactive_color = (YELLOW,BLACK,ON)
button_label_active_color = (BLACK,GREEN,ON)
button_label_inactive_color = (YELLOW,BLACK,ON)
inputbox_color = (BLACK,WHITE,OFF)
THEME

box() {
    # Keep the screen and keyboard on the terminal, with answers on a private pipe.
    DIALOGRC="$theme" DIALOGOPTS='' dialog --output-fd 4 \
        --backtitle "SWEENLAB SCRIPTS | Arcane Agent $version" "$@" \
        4>&1 <&3 >&3 2>&3
}

manager=$default_manager
unset enrollment_token
while true; do
    if ! answer=$(box --title 'Manager' --ok-label Next --cancel-label Abort \
        --inputbox 'Enter the Arcane Manager URL.' 9 64 "$manager"); then
        exit 0
    fi
    manager=${answer:-$default_manager}
    if [[ ! $manager =~ ^https?://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:[0-9]{1,5})?(/[A-Za-z0-9._~/%-]*)?$ ]]; then
        box --title 'Manager URL' --msgbox 'Enter an HTTP or HTTPS manager URL.' 7 60
        manager=$default_manager
        continue
    fi

    while true; do
        if enrollment_token=$(box --title 'Enrollment' --ok-label Next --cancel-label Back \
            --insecure --passwordbox \
            'Paste the per-agent token from Arcane > Agents > Add Agent. The field displays asterisks as you paste.' 10 64); then
            if [[ $enrollment_token =~ ^arc_etkn_[A-Za-z0-9_-]+$ ]]; then
                break
            fi
            unset enrollment_token
            box --title 'Enrollment token' --msgbox 'Paste a token beginning with arc_etkn_.' 7 60
        else
            selection=$?
            [[ $selection == 1 ]] && continue 2
            exit 0
        fi
    done

    if box --title 'Review' --yes-label Install --no-label Abort --defaultno \
        --extra-button --extra-label Back --yesno \
        "Manager: $manager\nCompose: $install_dir/docker-compose.yml\n\nStart the Arcane Agent with Docker Compose?" 11 68; then
        break
    else
        selection=$?
        unset enrollment_token
        [[ $selection == 3 ]] || exit 0
    fi
done

# mkdir is the claim on this path. An existing directory or symlink makes it fail.
umask 077
mkdir -- "$install_dir" || die "Could not create $install_dir. Existing files were preserved."
cd -- "$install_dir"
set -o noclobber
printf 'ARCANE_AGENT_TOKEN=%s\n' "$enrollment_token" > agent.env
unset enrollment_token
cat > docker-compose.yml <<EOF
services:
  arcane-agent:
    image: ghcr.io/getarcaneapp/agent:latest
    container_name: arcane-agent
    restart: unless-stopped
    env_file:
      - agent.env
    environment:
      ARCANE_AGENT: "true"
      ARCANE_AGENT_TRANSPORT: "auto"
      ARCANE_MANAGER_API_URL: "$manager"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - arcane-data:/app/data

volumes:
  arcane-data:
EOF

box --title 'Starting Arcane Agent' --infobox 'Docker Compose is starting the agent.' 6 58
if ! docker_local compose --project-name arcane-agent --file docker-compose.yml up -d; then
    box --title 'Startup failed' --msgbox \
        "Configuration is saved. To retry, run:\n\ncd $install_dir && docker compose up -d" 10 66 || true
    exit 1
fi
box --title 'Arcane Agent started' --msgbox \
    "Check that the agent shows Online under Agents in $manager." 8 64 || true
