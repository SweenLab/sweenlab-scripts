"""Verify directory creation with Proxmox's File::Path mechanism."""
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/proxmox-debian-lxc-create.sh'

class UmaskTests(unittest.TestCase):
    def test_proxmox_directory_modes_and_private_files(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['bash', '-c', '''
source "$1"
trap - EXIT
cd "$2"
pct() { perl -MFile::Path=make_path -e 'make_path($ARGV[0])' "$1/rootfs"; }
umask 077
pct broken
proxmox_pct fixed
[[ $(umask) == 0077 ]]
: > private-log
pct() { return 42; }
rc=0; proxmox_pct failure || rc=$?
[[ $rc == 42 ]]
''', 'test', str(SCRIPT), directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            root = pathlib.Path(directory)
            for name in ['broken', 'broken/rootfs']:
                self.assertEqual((root / name).stat().st_mode & 0o777, 0o700)
            for name in ['fixed', 'fixed/rootfs']:
                self.assertEqual((root / name).stat().st_mode & 0o777, 0o755)
            self.assertEqual((root / 'private-log').stat().st_mode & 0o777, 0o600)

    def test_progress_modes_preserve_output_and_failure_status(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['bash', '-c', '''
source "$1"
trap - EXIT
UI_DIR=$2; LOG=$2/full.log; verbose=0
command_fixture() { echo PACKAGE-DETAIL; return "$1"; }
install_stage Quiet command_fixture 0
verbose=1
install_stage Verbose command_fixture 0
verbose=0
rc=0; install_stage Failure command_fixture 42 || rc=$?
[[ $rc == 42 ]]
''', 'test', str(SCRIPT), directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.count('PACKAGE-DETAIL'), 2)
            self.assertEqual((pathlib.Path(directory) / 'full.log').read_text().count('PACKAGE-DETAIL'), 2)
            self.assertIn('✅ Quiet', result.stdout)
            self.assertNotIn('✅ Failure', result.stdout)
