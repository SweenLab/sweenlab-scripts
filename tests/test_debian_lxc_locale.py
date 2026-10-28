"""Host detection and guest locale/upgrade ordering without host changes."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/proxmox-debian-lxc-create.sh'

class LocaleTests(unittest.TestCase):
    def test_host_config_precedence_normalization_and_fallback(self):
        cases = [(None, None, 'C.UTF-8'), ('LANG="en_GB.utf8"\n', 'LANG=en_US.UTF-8\n', 'en_GB.UTF-8'),
                 (None, 'LANG=de_DE.UTF-8\n', 'de_DE.UTF-8'), ('LANG=C\n', None, 'C.UTF-8'),
                 ('LANG=C.UTF-8\n', None, 'C.UTF-8')]
        for primary, legacy, expected in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = SCRIPT.read_text().replace('/etc/locale.conf', str(root / 'locale.conf')).replace('/etc/default/locale', str(root / 'locale'))
                script = root / 'wizard.sh'; script.write_text(source)
                if primary is not None: (root / 'locale.conf').write_text(primary)
                if legacy is not None: (root / 'locale').write_text(legacy)
                result = subprocess.run(['bash', '-c', 'source "$1"; host_locale', 'test', str(script)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_guest_locale_activation_precedes_full_upgrade(self):
        guest = subprocess.run(['bash', '-c', 'source "$1"; write_guest_installer', 'test', str(SCRIPT)], capture_output=True, text=True, check=True).stdout
        start = guest.index('    [[ $locale_name == C.UTF-8')
        end = guest.index('    ln -snf', start)
        block = guest[start:end]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'en_GB').touch()
            block = block.replace('/usr/share/i18n/locales/', directory + '/').replace('/etc/locale.gen', str(root / 'locale.gen')).replace('/etc/default/locale', str(root / 'legacy')).replace('/etc/locale.conf', str(root / 'modern'))
            code = '''set -euo pipefail
locale_name=en_GB.UTF-8; upgrade=1
LC_ALL=C; LC_TIME=C; LANGUAGE=wrong
fail() { echo "$*" >&2; exit 1; }
locale-gen() { echo GENERATED; }
update-locale() { printf 'SET %s\\n' "$*"; }
locale() { [[ $LANG == en_GB.UTF-8 && ! ${LC_ALL+x} && ! ${LC_TIME+x} && ! ${LANGUAGE+x} ]]; echo UTF-8; }
apt-get() { printf 'APT %s\\n' "$*"; }
run() {
''' + block + '\n}\nrun\n'
            result = subprocess.run(['bash', '-c', code], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('LANG=en_GB.UTF-8', result.stdout)
            self.assertIn(str(root / 'legacy'), result.stdout)
            self.assertIn(str(root / 'modern'), result.stdout)
            self.assertLess(result.stdout.index('Locale configured and verified'), result.stdout.index('APT'))
            self.assertIn('-y dist-upgrade', result.stdout)
