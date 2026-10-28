"""Check the embedded terminal UI's actual rendering and key handling."""
import curses
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/proxmox-debian-lxc-create.sh'


class Screen:
    def __init__(self, keys):
        self.keys = iter(keys)
        self.drawn = []
    def keypad(self, value): pass
    def erase(self): pass
    def getmaxyx(self): return 24, 93
    def derwin(self, *args): return self
    def box(self): pass
    def addnstr(self, y, x, value, n, *args): self.drawn.append(value[:n])
    def move(self, *args): pass
    def refresh(self): pass
    def get_wch(self): return next(self.keys)


class TerminalUiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        code = subprocess.run(['bash', '-c', 'source "$1"; write_ui', '--', str(SCRIPT)],
                              text=True, capture_output=True, check=True).stdout
        cls.folder = tempfile.TemporaryDirectory()
        path = Path(cls.folder.name) / 'ui.py'
        path.write_text(code)
        spec = importlib.util.spec_from_file_location('sweenlab_terminal_ui', path)
        cls.ui = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.ui)

    @classmethod
    def tearDownClass(cls): cls.folder.cleanup()

    def drive(self, kind, keys, seed='', options=()):
        screen = Screen(keys)
        with patch.object(curses, 'curs_set'):
            result = self.ui.run(screen, kind, 'Test', 'Question', seed, options)
        return result, '\n'.join(screen.drawn)

    def test_horizontal_yes_no_and_default_yes(self):
        result, drawn = self.drive('yesno', ['\n'], '1')
        self.assertEqual(result, ('next', '1'))
        self.assertEqual([item[0] for item in self.ui.button_set('yesno')], ['Back', 'Yes', 'No', 'Abort'])
        for label in ('< Back >', '< Yes >', '< No >', '< Abort >'):
            self.assertIn(label, drawn)

    def test_yes_no_back_and_no_keys(self):
        self.assertEqual(self.drive('yesno', [curses.KEY_LEFT, '\n'], '1')[0], ('back', ''))
        self.assertEqual(self.drive('yesno', [curses.KEY_RIGHT, '\n'], '1')[0], ('next', '0'))

    def test_input_back_and_abort(self):
        self.assertEqual(self.drive('input', ['\t', curses.KEY_LEFT, '\n'], 'kept')[0], ('back', ''))
        self.assertEqual(self.drive('input', ['\x1b'])[0], ('abort', ''))

    def test_password_is_masked(self):
        result, drawn = self.drive('password', ['\n'], 'fixture-secret')
        self.assertEqual(result, ('next', 'fixture-secret'))
        self.assertNotIn('fixture-secret', drawn)
        self.assertIn('**************', drawn)

    def test_bridge_and_storage_names_have_no_descriptions(self):
        result, drawn = self.drive('menu', [curses.KEY_DOWN, '\n'], '', [('vmbr0', ''), ('vmbr1', '')])
        self.assertEqual(result, ('next', 'vmbr1'))
        self.assertIn('vmbr0', drawn)
        self.assertNotIn('Configured', drawn)
        self.assertNotIn('rootdir storage', drawn)

    def test_review_uses_create_with_back_and_abort(self):
        self.assertEqual([item[0] for item in self.ui.button_set('review')], ['Back', 'Create', 'Abort'])
        self.assertEqual(self.drive('review', [curses.KEY_DOWN, '\n'])[0], ('next', ''))

    def test_checkbox_preserves_initial_selections(self):
        result, _ = self.drive('check', [' ', '\n'], 'ssh\nignore-dns', [('ssh', 'SSH'), ('ignore-dns', 'Keep DNS')])
        self.assertEqual(result, ('next', 'ignore-dns'))


if __name__ == '__main__': unittest.main()
