#!/usr/bin/env bash
# SWEENLAB SCRIPTS — Arcane Agent Setup 0.1.0 (MIT)
# https://github.com/SweenLab/sweenlab-scripts
set +x
set -euo pipefail

readonly version=0.1.0
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

orange='' green='' reset=''
if [[ ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
    orange=$'\e[1;38;5;208m'
    green=$'\e[1;32m'
    reset=$'\e[0m'
fi
heading() { printf '\n%s%s%s\n' "$orange" "$1" "$reset" >&3; }
prompt() { printf '%s%s%s' "$green" "$1" "$reset" >&3; }

heading "SWEENLAB SCRIPTS | Arcane Agent $version"
manager=$default_manager
unset enrollment_token
while true; do
    heading 'Manager'
    prompt "Manager URL [$manager] (or type Abort) "
    IFS= read -r answer <&3 || die 'Setup cancelled.'
    case $answer in [Aa]bort) exit 0 ;; esac
    manager=${answer:-$manager}
    if [[ ! $manager =~ ^https?://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:[0-9]{1,5})?(/[A-Za-z0-9._~/%-]*)?$ ]]; then
        printf 'Enter an HTTP or HTTPS manager URL.\n' >&3
        manager=$default_manager
        continue
    fi

    heading 'Enrollment'
    printf 'In Arcane, open Agents > Add Agent and generate a token for this LXC.\n' >&3
    printf 'Press Enter to go back. Press Ctrl+C to abort.\n' >&3
    while true; do
        prompt 'Paste enrollment token (hidden) '
        if ! IFS= read -rs enrollment_token <&3; then
            printf '\n' >&3
            die 'Setup cancelled.'
        fi
        printf '\n' >&3
        [[ -n $enrollment_token ]] || break
        if [[ $enrollment_token =~ ^arc_etkn_[A-Za-z0-9_-]+$ ]]; then
            break
        fi
        printf 'Expected an enrollment token starting with arc_etkn_.\n' >&3
    done
    [[ -n $enrollment_token ]] || continue

    heading 'Review'
    printf '  Manager     %s\n  Compose     %s/docker-compose.yml\n' "$manager" "$install_dir" >&3
    while true; do
        prompt '[Install / Back / Abort] (default Abort) '
        IFS= read -r answer <&3 || die 'Setup cancelled.'
        case $answer in
            [Ii]nstall|[Ii]) break 2 ;;
            [Bb]ack|[Bb]) unset enrollment_token; break ;;
            [Aa]bort|[Aa]|'') exit 0 ;;
        esac
    done
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

heading 'Starting Arcane Agent'
if ! docker_local compose --project-name arcane-agent --file docker-compose.yml up -d; then
    die "Startup failed. Configuration is saved. To retry, run cd $install_dir && docker compose -p arcane-agent -f docker-compose.yml up -d"
fi
heading 'Docker Compose started the agent'
printf 'Check that the agent shows Online under Agents in %s.\n' "$manager" >&3
