import hashlib
import io
import pathlib
import subprocess
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/hawser-agent-setup.sh'
source = SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY\n', 1)[0]
h = types.ModuleType('hawser_setup')
exec(compile(source, str(SCRIPT), 'exec'), h.__dict__)


def archive():
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as tar:
        member = tarfile.TarInfo('hawser')
        member.size = 5
        tar.addfile(member, io.BytesIO(b'agent'))
    return output.getvalue()


class HawserTests(unittest.TestCase):
    def test_validation(self):
        self.assertTrue(h.validate_token('a' * 64))
        for token in ('', 'short', 'change-me-before-starting', 'a' * 20 + '\nPORT=1', 'space token' * 3):
            self.assertFalse(h.validate_token(token))
        self.assertTrue(h.validate_name('homarr'))
        self.assertFalse(h.validate_name('host\nTOKEN=bad'))
        self.assertTrue(h.validate_path('/data/stacks'))
        for path in ('/', 'relative', '/opt/../etc', '/two words', '/tmp/%n'):
            self.assertFalse(h.validate_path(path))

    def test_configuration_preserves_unmanaged_options_and_replaces_duplicates(self):
        old = 'TOKEN=old\nTOKEN=duplicate\nLOG_LEVEL=debug\nPORT=9999\n'
        result = h.render_config(old, 'homarr', 'a' * 64, '/data/stacks')
        self.assertEqual(result.count('TOKEN='), 1)
        self.assertIn('LOG_LEVEL=debug\n', result)
        self.assertIn('PORT=2376\n', result)
        self.assertNotIn('old', result)
        self.assertEqual(h.config_values(result)['TOKEN'], 'a' * 64)

    def test_checksum_and_archive(self):
        data = archive()
        checksums = hashlib.sha256(data).hexdigest() + '  hawser.tar.gz\n'
        self.assertEqual(h.verified_binary(data, checksums, 'hawser.tar.gz'), b'agent')
        with self.assertRaises(RuntimeError):
            h.verified_binary(data + b'x', checksums, 'hawser.tar.gz')
        with self.assertRaises(RuntimeError):
            h.verified_binary(data, checksums, 'missing.tar.gz')

    def test_atomic_private_config(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / 'config'
            h.write_atomic(path, 'private', 0o600)
            self.assertEqual(path.read_text(), 'private')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_install_uses_verified_binary_and_never_logs_token(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            data = archive()
            token = 'a' * 64
            state = dict(name='homarr', token=token, stacks=str(root / 'stacks'), verbose='No')
            release = {'tag_name': 'v0.2.52', 'assets': [
                {'name': 'hawser_0.2.52_linux_amd64.tar.gz', 'browser_download_url': 'archive'},
                {'name': 'checksums.txt', 'browser_download_url': 'checksums'}]}
            def fetch(url):
                if url == 'archive': return data
                if url == 'checksums': return (hashlib.sha256(data).hexdigest() + '  hawser_0.2.52_linux_amd64.tar.gz').encode()
                return h.json.dumps({'status': 'healthy'} if 'health' in url else release).encode()
            calls = []
            def run(args, **kwargs):
                calls.append(args)
                return subprocess.CompletedProcess(args, 0, stdout=token if args[0] == 'systemctl' else '10.10.10.220')
            with patch.multiple(h, CONFIG=root/'config', UNIT=root/'hawser.service', BINARY=root/'hawser', LOGROOT=root/'logs', BACKUPROOT=root/'backups'), patch.object(h, 'fetch', fetch), patch.object(h.platform, 'machine', return_value='x86_64'), patch.object(h.subprocess, 'run', run), patch('sys.stdout', new_callable=io.StringIO):
                h.CONFIG.write_text('TOKEN=previous\n')
                h.install(state, 'TOKEN=previous\n')
                self.assertEqual(h.BINARY.read_bytes(), b'agent')
                self.assertEqual(h.config_values(h.CONFIG.read_text())['TOKEN'], token)
                self.assertIn('ReadWritePaths=/var/run/docker.sock -' + state['stacks'], h.UNIT.read_text())
                self.assertNotIn(token, next((root/'logs').iterdir()).read_text())
                self.assertEqual(next((root/'backups').glob('*/config')).read_text(), 'TOKEN=previous\n')
            self.assertIn(('systemctl', 'enable', '--now', 'hawser'), calls)
            self.assertFalse(any('docker' in call for call in calls))

    def test_failed_service_start_restores_previous_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            data = archive()
            release = {'tag_name': 'v0.2.52', 'assets': [
                {'name': 'hawser_0.2.52_linux_amd64.tar.gz', 'browser_download_url': 'archive'},
                {'name': 'checksums.txt', 'browser_download_url': 'checksums'}]}
            def fetch(url):
                if url == 'archive': return data
                if url == 'checksums': return (hashlib.sha256(data).hexdigest() + '  hawser_0.2.52_linux_amd64.tar.gz').encode()
                return h.json.dumps(release).encode()
            calls = []
            def run(args, **kwargs):
                calls.append(tuple(args))
                failed = tuple(args) == ('systemctl', 'enable', '--now', 'hawser')
                return subprocess.CompletedProcess(args, int(failed), stdout='start failed' if failed else '')
            with patch.multiple(h, CONFIG=root/'config', UNIT=root/'hawser.service', BINARY=root/'hawser', LOGROOT=root/'logs', BACKUPROOT=root/'backups'), patch.object(h, 'fetch', fetch), patch.object(h.platform, 'machine', return_value='x86_64'), patch.object(h.subprocess, 'run', run), patch('sys.stdout', new_callable=io.StringIO):
                for path in (h.CONFIG, h.UNIT, h.BINARY):
                    path.write_text('previous')
                with self.assertRaises(RuntimeError):
                    h.install(dict(name='test', token='a'*64, stacks=str(root/'stacks'), verbose='No'), '')
                for path in (h.CONFIG, h.UNIT, h.BINARY):
                    self.assertEqual(path.read_text(), 'previous')
                self.assertIn(('systemctl', 'start', 'hawser'), calls)


class NavigationTests(unittest.TestCase):
    def screen(self, keys):
        class Screen:
            def __init__(self): self.keys = iter(keys); self.text = []
            def getmaxyx(self): return (28, 100)
            def erase(self): pass
            def border(self): pass
            def addstr(self, *args): self.text.append(args[2])
            def move(self, *args): pass
            def refresh(self): pass
            def get_wch(self): return next(self.keys)
        return Screen()

    def page(self, keys, **kwargs):
        ui = object.__new__(h.Wizard)
        ui.s = self.screen(keys)
        with patch.object(h.curses, 'color_pair', return_value=0), patch.object(h.curses, 'curs_set'):
            return ui.page('Title', 'Prompt', **kwargs), ui.s.text

    def test_tab_reaches_back(self):
        result, _ = self.page(['\t', '\n'], value='homarr')
        self.assertEqual(result, ('back', 'homarr'))

    def test_required_radio_blocks_next_then_selection_focuses_next(self):
        result, text = self.page(['\t', '\t', '\n', ' ', '\n'], kind='choice', value='No', choices=['Yes', 'No'])
        self.assertEqual(result, ('next', 'No'))
        self.assertTrue(any('Select an option' in line for line in text))

    def test_empty_token_blocks_and_generate_works(self):
        result, text = self.page(['\n', h.curses.KEY_F2, '\n'], secret=True)
        self.assertTrue(h.validate_token(result[1]))
        self.assertTrue(any('This field is required' in line for line in text))
        self.assertFalse(any(result[1] in line for line in text))

    def test_review_install_and_abort(self):
        result, _ = self.page(['\n'], value='ready', kind='review', final=True)
        self.assertEqual(result, ('next', 'ready'))
        with self.assertRaises(h.Abort):
            self.page(['\x1b'])

    def test_final_buttons_order_default_create_abort_and_back(self):
        result, text = self.page(['\n'], value='ready', kind='review', final=True)
        labels = [x for x in text if x in ('< Create >', '< Abort >', '< Back >')]
        self.assertEqual(labels[:3], ['< Create >', '< Abort >', '< Back >'])
        self.assertEqual(result[0], 'next')
        with self.assertRaises(h.Abort):
            self.page(['\t', '\n'], value='ready', kind='review', final=True)
        result, _ = self.page(['\t', '\t', '\n'], value='ready', kind='review', final=True)
        self.assertEqual(result[0], 'back')
        result, _ = self.page([h.curses.KEY_LEFT, '\n'], value='ready', kind='review', final=True)
        self.assertEqual(result[0], 'back')

    def test_collect_skips_verbose_prompt(self):
        prompts = []
        values = iter(['homarr', 'a'*64, '/data/stacks', 'ready'])
        def page(*args, **kwargs):
            prompts.append(args[0])
            return 'next', next(values)
        with patch.object(h, 'Wizard') as wizard:
            wizard.return_value.page.side_effect = page
            result = h.collect(None, {})
        self.assertEqual(prompts, ['Agent name (required)', 'Agent token (required)', 'New stack directory (required)', 'Review and create'])
        self.assertNotIn('verbose', result)


if __name__ == '__main__':
    unittest.main()
