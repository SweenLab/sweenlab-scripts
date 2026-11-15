# SweenLab WUD LXC onboarding

Version **0.3.1**. Start with a disposable Compose service. The first intended pilot from the handoff is Entertainment (CT 211), after confirming its current project paths. ChaosGremlin CT 103 remains the central WUD dashboard.

## 1. Prepare the Docker LXC

Use a Debian LXC with systemd, Docker Engine on `/var/run/docker.sock`, Docker Compose 2.30 or later, curl, Tailscale, whiptail or dialog, and current timezone data. Use a current patched Docker Engine. Join the existing tailnet if needed with `tailscale up` and complete the browser login on the URL it prints. Verify the LXC with `tailscale ip -4`.

The installer reads Compose metadata from running containers on the local Docker socket and deduplicates project directories. It accepts projects deployed from a single regular `docker-compose.yml` and reports skipped overrides and other filenames. Review generated files, interpolated image references, build-only services and manager-controlled stacks before opting services in. Use root-controlled directories. The updater mounts the discovered directories at their original paths with write access for YAML changes and backups, and has full access to the local Docker socket.

## 2. Preview and install

As root **inside the Docker LXC**, run this one command.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/71d1044714a7dad2d029f61bc33d95d6e53d2961/scripts/wud-lxc-onboard.sh)
```

Review the detected projects, then choose **Yes** in the confirmation dialog to install the local proxy and write the updater configuration. The wizard shows progress and the result in dialog boxes. Outside an interactive terminal the command previews and exits. To limit onboarding to selected projects, you can pass their absolute directories for preview and add `--install` before the paths to install. If HAProxy is missing, the wizard installs it through Debian APT after confirmation. The timer starts disabled. Installation does not change application Compose files or recreate application containers.

## 3. Connect CT 103

In your tailnet policy, allow TCP 23750 from CT 103's Tailscale identity to the onboarded LXC's identity. Check overlapping grants and broad allow rules. Docker metadata can contain environment variables, labels and other sensitive configuration. Verify the port is inaccessible from a tailnet node outside the intended grant. The proxy permits only a narrow set of Docker metadata reads and binds to loopback. WUD does not need Docker events for this setup.

Check `tailscale serve status` and `tailscale funnel status` and choose a free Serve port before applying the command below. The examples assume 23750 is free and dedicated to WUD. The forwarding path is encrypted between Tailscale peers.

```bash
tailscale serve --bg --tcp=23750 tcp://127.0.0.1:23750
tailscale serve status
```

From CT 103, substitute the remote LXC's Tailscale IPv4. Expect HTTP 200 for container listing and HTTP 403 for the archive request. Also verify access from the network namespace used by central WUD and denial from an unauthorized tailnet peer.

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' http://REMOTE_TAILSCALE_IPV4:23750/containers/json
curl -sS -o /dev/null -w '%{http_code}\n' 'http://REMOTE_TAILSCALE_IPV4:23750/containers/000000000000/archive?path=/'
```

Review CT 103's current Compose definition and effective environment first. Back up its Compose file. Ensure it has no Docker or Docker Compose update triggers for these remote workloads. Confirm the existing service key and use `nano` to create a dedicated `docker-compose.wud-watchers.yml` override beside its existing file. This is a complete override for one watcher. Replace `wud` with the actual service key, `entertainment` with your unique watcher name (letters/digits), and the sample address with the actual Tailscale IPv4.

```yaml
services:
  wud:
    environment:
      TZ: America/New_York
      WUD_WATCHER_ENTERTAINMENT_HOST: "REMOTE_TAILSCALE_IPV4"
      WUD_WATCHER_ENTERTAINMENT_PORT: "23750"
      WUD_WATCHER_ENTERTAINMENT_CRON: "0 9 * * *"
      WUD_WATCHER_ENTERTAINMENT_JITTER: "0"
      WUD_WATCHER_ENTERTAINMENT_WATCHEVENTS: "false"
      WUD_WATCHER_ENTERTAINMENT_WATCHATSTART: "false"
      WUD_WATCHER_ENTERTAINMENT_WATCHBYDEFAULT: "true"
```

Validate from the existing project's directory with `docker compose -f docker-compose.yml -f docker-compose.wud-watchers.yml config --quiet`. Deploy with the same files and existing project name, targeting only the WUD service. Retain those `-f` arguments for subsequent redeploys. Repeat the environment entries with distinct watcher names per LXC. Check the dashboard and watcher logs after a scan. CT 103 may sample a container before its local update finishes, so a manual dashboard refresh or the next poll may be needed.

## 4. Opt in and schedule updates

Choose one disposable service first. Back up its Compose file and persistent data, then use `nano` to add these labels under the selected service's existing `labels` mapping. Preserve all existing service settings and inspect any existing `wud.trigger.*` labels for conflicts. Apply the change through the project's usual Compose deployment command. Docker container labels take effect when the service is recreated.

```yaml
labels:
  wud.watch: "true"
  wud.trigger.dockercompose.lxc.enabled: "true"
```

Optional protected ntfy notifications go in `/etc/sweenlab-wud/notifications.env` (root-only). Notifications use the local updater's lifecycle events. Configure the endpoint and credential through `nano` before running the updater.

```dotenv
WUD_TRIGGER_NTFY_ALERTS_URL=https://ntfy.example.com
WUD_TRIGGER_NTFY_ALERTS_TOPIC=sweenlab-updates
WUD_TRIGGER_NTFY_ALERTS_AUTH_TOKEN=REPLACE_WITH_TOKEN
WUD_TRIGGER_NTFY_ALERTS_EVENTS=success,failure,rollback
```

On the disposable project, verify a known update, its Compose image entry or running digest, the backup for YAML changes, and the notification. A manual test via `systemctl start sweenlab-wud-update.service` performs real updates on all opted-in services. Review `journalctl -u sweenlab-wud-update.service`. Test health rollback with a disposable image that fails its health check before enabling production projects.

```bash
systemctl enable --now sweenlab-wud-update.timer
systemctl list-timers sweenlab-wud-update.timer
```

The timer runs one local WUD scan per day at 9:00 a.m. New York time, including DST. Missed runs are skipped. WUD pulls and recreates eligible services through Docker Engine and writes changed image references to the mounted Compose file. Floating tags can change digest while their YAML tag stays the same. Tag/digest eligibility still follows WUD registry rules. Configure a meaningful health check for each production service. Rollback covers the container swap where supported. Database migrations, named volumes and bind-mounted app data need their own backup and restore plan. Compose `.back` files are rolling backups, so keep independent copies.

## Pause or remove

Pause scheduled updates with `systemctl disable --now sweenlab-wud-update.timer`. A run already underway can finish. If recovering an app, check the WUD journal and current Compose file before restoring your known-good file and image reference. Redeploy with the original Compose command. A floating tag can point at the new image, so use the verified previous digest or archived image when rolling it back manually.

To remove this onboarding, remove the corresponding CT 103 watcher and stop serving the port with `tailscale serve --tcp=23750 off`. Disable and stop `sweenlab-wud-proxy.service`. Back up `/etc/sweenlab-wud` before removing it and the three `sweenlab-wud-*` unit files from `/etc/systemd/system`, then run `systemctl daemon-reload`. Use the same cleanup if installation stops partway, and review the proxy journal before retrying.

## References

[WUD one-shot mode](https://getwud.app/docs/configuration/oneshot/) · [WUD Compose trigger](https://getwud.app/docs/configuration/triggers/docker-compose/) · [WUD trigger options](https://getwud.app/docs/configuration/triggers/) · [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve)
