#!/usr/bin/env bash
# SWEENLAB SCRIPTS — Hawser Agent Setup 0.1.0
# Run inside the Docker LXC, not on the Proxmox host.
set -euo pipefail
if [[ ${1:-} == --version ]]; then echo 'Sweenlab Hawser Agent Setup 0.1.0'; exit 0; fi
[[ $EUID == 0 ]] || { echo 'Run this wizard as root inside the Docker LXC.'; exit 1; }
[[ -t 1 && -r /dev/tty ]] || { echo 'An interactive terminal is required.'; exit 1; }
[[ $(uname -s) == Linux && -d /run/systemd/system && ! -d /etc/pve ]] || { echo 'Run inside a Linux Docker LXC with systemd, not the Proxmox node.'; exit 1; }
if ! command -v python3 >/dev/null; then
    command -v apt-get >/dev/null || { echo 'Python 3 is required on this system.'; exit 1; }
    echo 'Installing Python 3 for the setup menus...'
    apt-get update
    apt-get install -y python3 ca-certificates
fi
exec python3 - <<'PY'
import curses, hashlib, io, json, os, pathlib, platform, re, secrets, shutil
import socket, subprocess, sys, tarfile, tempfile, textwrap, time, urllib.request
VERSION = '0.1.0'
CONFIG = pathlib.Path('/etc/hawser/config')
UNIT = pathlib.Path('/etc/systemd/system/hawser.service')
BINARY = pathlib.Path('/usr/local/bin/hawser')
LOGROOT = pathlib.Path('/var/log/sweenlab-hawser')
BACKUPROOT = pathlib.Path('/var/backups/sweenlab-hawser')


def validate_token(value):
    return bool(re.fullmatch(r'[A-Za-z0-9_.~+/=-]{16,512}', value)) and value != 'change-me-before-starting'


def validate_name(value):
    return bool(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,62}', value))


def validate_path(value):
    return bool(re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+', value)) and '..' not in value.split('/') and value != '/'


def config_values(content):
    result = {}
    for line in content.splitlines():
        if re.match(r'^[A-Z_]+=', line):
            key, value = line.split('=', 1)
            result[key] = value.strip().strip('\"\'')
    return result


def render_config(content, name, token, stacks):
    managed = {'TOKEN': token, 'AGENT_NAME': name, 'STACKS_DIR': stacks,
               'PORT': '2376', 'DOCKER_SOCKET': '/var/run/docker.sock'}
    lines = [line for line in content.splitlines()
             if line.split('=', 1)[0] not in managed]
    return '\n'.join(lines + ['# Managed by Sweenlab Hawser Setup ' + VERSION] +
                     [key + '=' + value for key, value in managed.items()]) + '\n'


def service_text(stacks):
    return f'''[Unit]
Description=Hawser - Remote Docker Agent for Dockhand
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/hawser
EnvironmentFile=/etc/hawser/config
Restart=always
RestartSec=10
NoNewPrivileges=false
ProtectSystem=strict
ProtectHome=true
RuntimeDirectory=hawser
Environment=DOCKER_CONFIG=/run/hawser TMPDIR=/run/hawser
ReadWritePaths=/var/run/docker.sock -{stacks}

[Install]
WantedBy=multi-user.target
'''


def fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'Sweenlab-Hawser-Setup/' + VERSION})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def verified_binary(archive, checksums, filename):
    expected = next((line.split()[0] for line in checksums.splitlines()
                     if len(line.split()) == 2 and line.split()[1].lstrip('*') == filename), None)
    if not expected or hashlib.sha256(archive).hexdigest() != expected:
        raise RuntimeError('Hawser download checksum verification failed.')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        members = [m for m in tar.getmembers() if m.name in ('hawser', './hawser') and m.isfile()]
        if len(members) != 1:
            raise RuntimeError('Expected one regular Hawser executable in the download.')
        return tar.extractfile(members[0]).read()


class Abort(Exception):
    pass


class Wizard:
    def __init__(self, screen):
        self.s = screen
        curses.start_color()
        curses.use_default_colors()
        orange = 208 if curses.COLORS >= 256 else curses.COLOR_YELLOW
        green = 114 if curses.COLORS >= 256 else curses.COLOR_GREEN
        curses.init_pair(1, orange, -1)
        curses.init_pair(2, green, -1)
        curses.init_pair(3, curses.COLOR_BLACK, green)
        curses.init_pair(4, curses.COLOR_WHITE, curses.COLOR_BLUE)
        self.s.keypad(True)
        curses.curs_set(0)

    def put(self, y, text, attr=0):
        h, w = self.s.getmaxyx()
        text = text[:max(0, w - 6)]
        if 0 <= y < h - 1:
            self.s.addstr(y, max(2, (w - len(text)) // 2), text, attr)

    def page(self, title, prompt, value='', kind='input', choices=None, required=True, secret=False, final=False):
        focus, cursor, selected, error = (2 if final else 0), len(value), None, ''
        if choices and value in choices:
            cursor = choices.index(value)
        elif choices:
            cursor = 0
        while True:
            self.s.erase()
            h, w = self.s.getmaxyx()
            if h < 22 or w < 74:
                self.put(1, 'Enlarge the terminal to at least 74 columns by 22 rows.')
                self.put(3, 'Esc: abort')
                self.s.refresh()
                if self.s.getch() == 27:
                    raise Abort()
                continue
            self.s.border()
            self.put(1, 'SWEENLAB SCRIPTS | Hawser ' + VERSION, curses.color_pair(1) | curses.A_BOLD)
            self.put(3, title, curses.color_pair(1) | curses.A_BOLD)
            lines = prompt.split('\n')
            for n, line in enumerate(lines):
                self.put(5 + n, line, curses.color_pair(2) | (curses.A_BOLD if required else 0))
            row = 7 + len(lines)
            if kind == 'input':
                width = min(54, w - 12)
                left = (w - width) // 2
                self.s.addstr(row, left, '[' + ' ' * (width - 2) + ']', curses.A_DIM)
                display = ('*' * len(value) if secret else value)[-(width - 4):]
                self.s.addstr(row, left + 2, display, curses.A_NORMAL)
                if focus == 0:
                    curses.curs_set(1)
                    self.s.move(row, min(left + 2 + len(display), left + width - 2))
                else:
                    curses.curs_set(0)
                if secret:
                    self.put(row + 2, 'F2: generate a token here instead', curses.A_DIM)
            elif choices:
                curses.curs_set(0)
                labels = [('(●) ' if item == selected else '( ) ') + item for item in choices]
                x = (w - sum(map(len, labels)) - 6 * (len(labels) - 1)) // 2
                for n, label in enumerate(labels):
                    attr = curses.color_pair(3) if focus == 0 and cursor == n else curses.color_pair(2)
                    self.s.addstr(row, x, label, attr)
                    x += len(label) + 6
            else:
                curses.curs_set(0)
            if error:
                self.put(h - 7, error, curses.color_pair(1) | curses.A_BOLD)
            buttons = ['Back', 'Install' if final else 'Next', 'Abort']
            labels = ['< ' + b + ' >' for b in buttons]
            start = (w - sum(map(len, labels)) - 8) // 2
            for n, label in enumerate(labels):
                self.s.addstr(h - 5, start, label, curses.color_pair(3 if focus == n + 1 else 1))
                start += len(label) + 4
            self.put(h - 3, 'Tab / Shift+Tab: focus | Arrows: navigate | Enter: confirm | Esc: abort', curses.A_DIM)
            if kind == 'input' and focus == 0:
                self.s.move(row, min(left + 2 + len(display), left + width - 2))
            self.s.refresh()
            key = self.s.get_wch()
            if key == '\x1b':
                raise Abort()
            if key == '\t':
                focus = (focus + 1) % 4
            elif key == curses.KEY_BTAB:
                focus = (focus - 1) % 4
            elif key == curses.KEY_UP:
                if focus:
                    focus = 0
                elif choices:
                    cursor = (cursor - 1) % len(choices)
            elif key == curses.KEY_DOWN:
                if focus == 0 and choices and cursor < len(choices) - 1:
                    cursor += 1
                else:
                    focus = 2
            elif key in (curses.KEY_LEFT, curses.KEY_RIGHT) and focus == 0 and choices:
                cursor = (cursor + (1 if key == curses.KEY_RIGHT else -1)) % len(choices)
            elif key in (curses.KEY_LEFT, curses.KEY_RIGHT) and focus:
                focus = 1 + ((focus - 1 + (1 if key == curses.KEY_RIGHT else -1)) % 3)
            elif key == curses.KEY_F2 and secret and focus == 0:
                value = secrets.token_hex(32)
                error = 'Token generated. It will be shown privately after installation.'
                focus = 2
            elif key in ('\n', '\r', curses.KEY_ENTER) or (key == ' ' and choices and focus == 0):
                if focus == 3:
                    raise Abort()
                if focus == 1:
                    return 'back', value
                if choices and focus == 0:
                    selected = choices[cursor]
                    value = selected
                    focus = 2
                elif focus == 2 or kind == 'input':
                    if choices and selected is None:
                        error = 'Select an option with Space or Enter first.'
                        focus = 0
                    elif required and not value and kind == 'input':
                        error = 'This field is required.'
                        focus = 0
                    else:
                        return 'next', value
            elif focus == 0 and kind == 'input':
                if key in (curses.KEY_BACKSPACE, '\x7f', '\b'):
                    value = value[:-1]
                elif key == '\x15':
                    value = ''
                elif isinstance(key, str) and key.isprintable() and len(value) < 512:
                    value += key


def collect(screen, existing):
    ui = Wizard(screen)
    state = {'name': existing.get('AGENT_NAME', socket.gethostname().split('.')[0]),
             'token': '', 'stacks': existing.get('STACKS_DIR', '/data/stacks'), 'verbose': 'No'}
    steps = ['name', 'token', 'stacks', 'verbose', 'review']
    step = 0
    warning = ''
    while True:
        key = steps[step]
        if key == 'name':
            args = ('Agent name (required)', 'Name this Docker LXC in Dockhand.' + warning, state[key])
        elif key == 'token':
            args = ('Agent token (required)', 'Paste the token generated in Dockhand.\nOr press F2 to generate one here.' + warning, state[key])
        elif key == 'stacks':
            args = ('New stack directory (required)', 'Folder for new stacks managed through the agent.\nExisting application files are not moved.' + warning, state[key])
        elif key == 'verbose':
            args = ('Installation output', 'Show detailed installation output?', state[key])
        else:
            prompt = '\n'.join(['Agent: ' + state['name'], 'Mode: Standard | Protocol: HTTP | Port: 2376',
                                'Token: configured (hidden)', 'New stacks: ' + state['stacks'],
                                'Verbose: ' + state['verbose'], 'Install native service and enable startup on boot.',
                                'Existing Hawser config/service will be backed up and replaced.' if CONFIG.exists() or UNIT.exists()
                                else 'Ready to install Hawser on this Docker LXC.'])
            args = ('Review and install', prompt, 'ready')
        action, value = ui.page(*args, secret=key == 'token', kind='choice' if key == 'verbose' else ('review' if key == 'review' else 'input'),
                                choices=['Yes', 'No'] if key == 'verbose' else None, final=key == 'review')
        warning = ''
        if action == 'back':
            step = max(0, step - 1)
            continue
        if key != 'review':
            valid = {'name': validate_name, 'token': validate_token, 'stacks': validate_path, 'verbose': lambda _: True}[key](value)
            state[key] = value
            if not valid:
                warning = '\n' + {'name': 'Use letters, numbers, dots, underscores or hyphens.',
                                   'token': 'Use a 16–512 character token without spaces.',
                                   'stacks': 'Use an absolute path without spaces or parent traversal.'}[key]
                continue
            step += 1
        else:
            return state


def write_atomic(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.sweenlab-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(data if isinstance(data, bytes) else data.encode())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def install(state, old_content):
    os.umask(0o077)
    stamp = time.strftime('%Y%m%d-%H%M%S') + '-' + str(os.getpid())
    logpath = LOGROOT / (stamp + '.log')
    logpath.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    logpath.touch(mode=0o600)
    completed = []
    orange, green, reset = '\033[38;5;208m', '\033[38;5;114m', '\033[0m'
    def stage(label, function):
        print(orange + '  ⏳ ' + label + reset, flush=True)
        function()
        completed.append(label)
        print(green + '  ✅ ' + label + reset, flush=True)
    def run(*args):
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        # Never write the token or config contents into installation logs.
        output = result.stdout.replace(state['token'], '[REDACTED]')
        with logpath.open('a') as log:
            log.write(output)
        if state['verbose'] == 'Yes':
            print(output, end='', flush=True)
        if result.returncode:
            raise RuntimeError('Command failed: ' + args[0] + '. See ' + str(logpath))
        return result.stdout
    release = json.loads(fetch('https://api.github.com/repos/Finsys/hawser/releases/latest'))
    tag = release['tag_name']
    version = tag.removeprefix('v')
    arch = {'x86_64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64', 'armv7l': 'arm'}[platform.machine()]
    filename = f'hawser_{version}_linux_{arch}.tar.gz'
    assets = {item['name']: item['browser_download_url'] for item in release['assets']}
    payload = None
    def download():
        nonlocal payload
        payload = verified_binary(fetch(assets[filename]), fetch(assets['checksums.txt']).decode(), filename)
    stage('📥 Download and checksum-verify Hawser ' + version, download)
    backup = BACKUPROOT / stamp
    def backup_files():
        backup.mkdir(parents=True, mode=0o700)
        for name, path in [('config', CONFIG), ('hawser.service', UNIT), ('hawser', BINARY)]:
            if path.exists():
                shutil.copy2(path, backup / name)
        for path in backup.iterdir():
            path.chmod(0o600)
    stage('💾 Back up existing agent files', backup_files)
    def configure():
        # Stop only Hawser, never Docker or any application container.
        if subprocess.run(['systemctl', 'is-active', '--quiet', 'hawser']).returncode == 0:
            run('systemctl', 'stop', 'hawser')
        pathlib.Path(state['stacks']).mkdir(parents=True, exist_ok=True)
        write_atomic(BINARY, payload, 0o755)
        write_atomic(CONFIG, render_config(old_content, state['name'], state['token'], state['stacks']), 0o600)
        write_atomic(UNIT, service_text(state['stacks']), 0o644)
    was_active = subprocess.run(['systemctl', 'is-active', '--quiet', 'hawser']).returncode == 0
    was_enabled = subprocess.run(['systemctl', 'is-enabled', '--quiet', 'hawser']).returncode == 0
    try:
        stage('⚙️ Install agent and private configuration', configure)
        stage('🚀 Enable Hawser at boot and start service', lambda: (run('systemctl', 'daemon-reload'), run('systemctl', 'enable', '--now', 'hawser')))
        def verify():
            for _ in range(15):
                try:
                    health = json.loads(fetch('http://127.0.0.1:2376/_hawser/health'))
                    if health.get('status') == 'healthy':
                        run('systemctl', 'is-active', '--quiet', 'hawser')
                        run('systemctl', 'is-enabled', '--quiet', 'hawser')
                        return
                except Exception:
                    pass
                time.sleep(1)
            raise RuntimeError('Hawser did not become healthy. Check: journalctl -u hawser -n 40')
        stage('🩺 Verify service, boot startup and Docker connectivity', verify)
    except BaseException:
        print('Restoring the previous Hawser installation...', flush=True)
        subprocess.run(['systemctl', 'stop', 'hawser'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['systemctl', 'disable', 'hawser'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for name, path, mode in [('config', CONFIG, 0o600), ('hawser.service', UNIT, 0o644), ('hawser', BINARY, 0o755)]:
            saved = backup / name
            if saved.exists():
                write_atomic(path, saved.read_bytes(), mode)
            elif path.exists():
                path.unlink()
        subprocess.run(['systemctl', 'daemon-reload'])
        if was_enabled:
            subprocess.run(['systemctl', 'enable', 'hawser'])
        if was_active:
            subprocess.run(['systemctl', 'start', 'hawser'])
        print('Previous files restored. Backup: ' + str(backup))
        raise
    print('\n' + green + 'Installation checklist' + reset)
    for label in completed:
        print('  ✅ ' + label)
    addresses = subprocess.run(['hostname', '-I'], capture_output=True, text=True).stdout.strip()
    print('\nAdd environment in Dockhand:')
    print('  Name: ' + state['name'] + '\n  Type: Hawser agent (standard)\n  Protocol: HTTP\n  Port: 2376')
    print('  Host IPs (choose the LXC address reachable from Dockhand): ' + addresses)
    print('  Agent token: ' + state['token'])
    print('  Remote stack path: ' + state['stacks'])
    print('Then click Test connection and Add. Existing stacks need separate import.')
    print('Keep this HTTP agent on your trusted LAN or Tailscale; do not forward port 2376 to the internet.')
    print('Backup: ' + str(backup) + '\nLog (token excluded): ' + str(logpath))


def main():
    if platform.system() != 'Linux' or not pathlib.Path('/run/systemd/system').exists():
        raise RuntimeError('This wizard requires Linux with systemd inside a Docker LXC/host.')
    if pathlib.Path('/etc/pve').is_dir():
        raise RuntimeError('Run inside the Docker LXC, not on the Proxmox node.')
    if platform.machine() not in ('x86_64', 'aarch64', 'arm64', 'armv7l'):
        raise RuntimeError('Unsupported CPU architecture.')
    for command in ('docker', 'systemctl', 'hostname'):
        if not shutil.which(command):
            raise RuntimeError('Required command missing: ' + command)
    if subprocess.run(['docker', 'info'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise RuntimeError('Docker must be installed and running before this setup.')
    if subprocess.run(['docker', 'ps', '-aq', '--filter', 'name=^/hawser$'], capture_output=True, text=True).stdout.strip():
        raise RuntimeError('A Docker Hawser container already exists. Remove that deployment before installing the native service.')
    old = CONFIG.read_text() if CONFIG.exists() else ''
    existing = config_values(old)
    if any(existing.get(key) for key in ('DOCKHAND_SERVER_URL', 'TLS_CERT', 'TLS_KEY')):
        raise RuntimeError('Existing Hawser uses Edge/TLS. This Standard HTTP wizard will not replace it.')
    if existing.get('BIND_ADDRESS', '0.0.0.0') != '0.0.0.0' or existing.get('DOCKER_SOCKET', '/var/run/docker.sock') != '/var/run/docker.sock':
        raise RuntimeError('Existing Hawser has a custom bind address/socket. Keep its configuration and manage it manually.')
    # Python's program arrives on stdin; curses must read keyboard input from tty.
    with open('/dev/tty', 'rb', buffering=0) as tty:
        os.dup2(tty.fileno(), 0)
    state = curses.wrapper(lambda screen: collect(screen, existing))
    install(state, old)


if __name__ == '__main__':
    try:
        main()
    except (Abort, KeyboardInterrupt):
        print('\nAborted. No further changes made.')
        sys.exit(130)
    except Exception as error:
        print('\nSetup stopped: ' + str(error), file=sys.stderr)
        print('Existing Docker application containers were not stopped or recreated.', file=sys.stderr)
        sys.exit(1)
PY
