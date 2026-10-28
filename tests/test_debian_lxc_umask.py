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

    def test_leftover_directory_and_dangling_symlink_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = SCRIPT.read_text().replace('/var/lib/lxc/', directory + '/')
            script = root / 'wizard.sh'
            script.write_text(source)
            (root / '204').mkdir()
            (root / '205').symlink_to(root / 'missing')
            for ctid in ['204', '205']:
                result = subprocess.run(['bash', '-c', 'source "$1"; CTID=$2; assert_new_ct_path', 'test', str(script), ctid], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('leftover', result.stderr)
            self.assertTrue((root / '204').is_dir())
            self.assertTrue((root / '205').is_symlink())
