#!/usr/bin/env bash
set -euo pipefail
umask 077

version=0.2.0
directory=/etc/sweenlab-wud
mode=plan
case ${1:-} in
  --version) echo "$version"; exit ;;
  --help) echo "Usage: wud-lxc-onboard.sh [--install] [ /absolute/project-dir ... ]"; exit ;;
  --install) mode=install; shift ;;
esac
die() { printf '%s\n' "$*" >&2; exit 1; }
discover_projects() {
  local listing files
  listing=$(env -u DOCKER_CONTEXT -u DOCKER_HOST docker --host unix:///var/run/docker.sock ps \
    --filter label=com.docker.compose.project \
    --format '{{.Label "com.docker.compose.project.config_files"}}') ||
    die 'Unable to list running Compose projects on the local Docker socket.'
  while IFS= read -r files; do
    case "$files" in
      /etc/sweenlab-wud/*|'') ;;
      *,*) printf 'Skipping multi-file project: %s\n' "$files" >&2 ;;
      /*/docker-compose.yml) printf '%s\n' "${files%/docker-compose.yml}" ;;
      *) printf 'Skipping unsupported Compose file: %s\n' "$files" >&2 ;;
    esac
  done <<< "$listing"
}
automatic=false
if (( $# == 0 )); then
  detected=$(discover_projects | sort -u) || exit 1
  [[ -n $detected ]] || die 'No running projects with a single docker-compose.yml were found.'
  discovered=()
  while IFS= read -r project; do
    discovered+=("$project")
  done <<< "$detected"
  set -- "${discovered[@]}"
  automatic=true
  printf 'Discovered Compose project directories:\n'
  printf '  %s\n' "$@"
fi
projects=()
for project in "$@"; do
  [[ $project =~ ^(/[a-zA-Z0-9_.-]+)+$ ]] || die "Unsupported path: $project"
  [[ $(cd -P -- "$project" && pwd -P) == "$project" ]] || die "Use the physical project directory: $project"
  [[ -f $project/docker-compose.yml && ! -L $project/docker-compose.yml ]] ||
    die "Expected a regular docker-compose.yml in $project"
  case "$project" in
    /etc|/etc/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*|/var|/var/run|/var/run/*)
      die "Choose a dedicated application directory: $project" ;;
  esac
  for previous in ${projects[@]+"${projects[@]}"}; do
    [[ "$project/" != "$previous/"* && "$previous/" != "$project/"* ]] ||
      die "Duplicate or overlapping projects: $previous and $project"
  done
  projects+=("$project")
done

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cat > "$stage/docker-compose.yml" <<'YAML'
services:
  updater:
    image: getwud/wud:9.8.0
    command: ["watch"]
    environment:
      WUD_RUN_MODE: oneshot
      WUD_WATCHER_LOCAL_WATCHBYDEFAULT: "false"
      WUD_TRIGGER_DOCKERCOMPOSE_LXC_AUTO: "true"
      WUD_TRIGGER_DOCKERCOMPOSE_LXC_INCLUDEBYDEFAULT: "false"
      WUD_TRIGGER_DOCKERCOMPOSE_LXC_BACKUP: "true"
      WUD_TRIGGER_DOCKERCOMPOSE_LXC_ROLLBACK: "true"
      WUD_TRIGGER_DOCKERCOMPOSE_LXC_PRUNE: "false"
      WUD_TRIGGER_DOCKERCOMPOSE_LXC_STRICT_DIGEST: "true"
    env_file:
      - path: ./notifications.env
        format: raw
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
YAML
for project in "${projects[@]}"; do
  printf '      - %s:%s\n' "$project" "$project" >> "$stage/docker-compose.yml"
done
: > "$stage/notifications.env"

cat > "$stage/proxy.cfg" <<'CFG'
global
    maxconn 32
defaults
    mode http
    timeout connect 3s
    timeout client 15s
    timeout server 15s
    timeout http-request 5s
    option httpclose
frontend local
    bind 127.0.0.1:23750
    acl allowed_method method GET HEAD
    acl allowed_path path_reg ^(/v[0-9]+\.[0-9]+)?/(_ping|version|containers/json|containers/[0-9a-f]{12,64}/json|images/[a-zA-Z0-9_.:@/-]+/json)$
    acl encoded_path path_sub %
    acl unsafe_path path_sub .. //
    acl dot_segment path_sub /./
    acl upgrade hdr(Upgrade) -m found
    acl transfer_encoding hdr(Transfer-Encoding) -m found
    acl content_length hdr(Content-Length) -m found
    http-request deny unless allowed_method allowed_path
    http-request deny if encoded_path or unsafe_path or dot_segment or upgrade or transfer_encoding or content_length
    default_backend docker
backend docker
    server socket unix@/var/run/docker.sock
CFG
cat > "$stage/sweenlab-wud-proxy.service" <<'UNIT'
[Unit]
Description=SweenLab read-only Docker metadata proxy
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/sbin/haproxy -db -f /etc/sweenlab-wud/proxy.cfg
Restart=on-failure
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes

[Install]
WantedBy=multi-user.target
UNIT
cat > "$stage/sweenlab-wud-update.service" <<'UNIT'
[Unit]
Description=SweenLab local WUD Compose update
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/etc/sweenlab-wud
Environment=DOCKER_HOST=unix:///var/run/docker.sock
ExecStart=/usr/bin/docker compose --project-name sweenlab-wud --file docker-compose.yml run --rm --no-deps -T updater
UNIT
cat > "$stage/sweenlab-wud-update.timer" <<'UNIT'
[Unit]
Description=Run SweenLab WUD daily at 9 AM Eastern

[Timer]
OnCalendar=*-*-* 09:00:00 America/New_York
AccuracySec=1s
Persistent=false

[Install]
WantedBy=timers.target
UNIT

if [[ $mode == plan ]] || $automatic; then
  for file in "$stage"/*; do
    printf '\n# %s\n' "${file##*/}"
    cat "$file"
  done
  if ! $automatic || [[ ! -t 0 ]]; then
    exit
  fi
  read -r -p 'Install the local proxy and updater configuration? [y/N] ' answer
  [[ $answer == y || $answer == Y ]] || exit 0
fi

(( EUID == 0 )) || die 'Run installation as root inside the Docker LXC.'
for command in curl flock systemctl systemd-analyze tailscale; do
  command -v "$command" >/dev/null || die "Missing prerequisite: $command"
done
[[ -x /usr/sbin/haproxy && -x /usr/bin/docker && -S /var/run/docker.sock ]] ||
  die 'Install HAProxy and Docker Engine with the standard local socket first.'
exec 9>/run/sweenlab-wud-install.lock
flock -n 9 || die 'Another WUD install is active.'
for target in "$directory" /etc/systemd/system/sweenlab-wud-{proxy.service,update.service,update.timer}; do
  [[ ! -e $target && ! -L $target ]] || die "Already present: $target. See the guide for recovery."
done
tailscale ip -4 >/dev/null || die 'Join Tailscale first (tailscale up).'
unset DOCKER_CONTEXT DOCKER_HOST
export DOCKER_HOST=unix:///var/run/docker.sock
/usr/bin/docker info >/dev/null
for project in "${projects[@]}"; do
  /usr/bin/docker compose --project-directory "$project" -f "$project/docker-compose.yml" config --quiet
done
/usr/bin/docker compose -f "$stage/docker-compose.yml" config --quiet
/usr/sbin/haproxy -c -f "$stage/proxy.cfg"
systemd-analyze calendar '*-*-* 09:00:00 America/New_York' >/dev/null
/usr/bin/docker compose -f "$stage/docker-compose.yml" pull updater

install -d -m 0700 "$directory"
install -m 0600 "$stage"/{docker-compose.yml,notifications.env,proxy.cfg} "$directory/"
install -m 0644 "$stage"/sweenlab-wud-* /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now sweenlab-wud-proxy.service
proxy=http://127.0.0.1:23750
curl --noproxy '*' --max-time 5 -fsS "$proxy/containers/json" >/dev/null
for probe in 'POST /containers/create' 'GET /images/get' 'GET /containers/000000000000/archive?path=/'; do
  status=$(curl --noproxy '*' --max-time 5 -sS -o /dev/null -w '%{http_code}' -X "${probe%% *}" "$proxy/${probe#* /}")
  [[ $status == 403 ]] || die "Expected a proxy denial for $probe, got $status"
done
printf '%s\n' 'Local proxy installed and checked. Follow the guide to restrict and enable Serve, test CT 103, and enable the daily timer.'
