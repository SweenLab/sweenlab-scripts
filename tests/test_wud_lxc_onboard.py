import os
import pathlib
import pty
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts/wud-lxc-onboard.sh"


class OnboardPlanTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name).resolve()
        self.projects = [self.project("one"), self.project("two")]

    def project(self, name):
        path = self.root / name
        path.mkdir()
        (path / "docker-compose.yml").write_text("services: {}\n")
        return path

    def run_script(self, *args):
        return subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, text=True)

    def test_plan_preserves_projects_and_uses_one_scheduled_compose_trigger(self):
        result = self.run_script(*self.projects)
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in self.projects:
            self.assertIn(f"{path}:{path}", result.stdout)
            self.assertEqual((path / "docker-compose.yml").read_text(), "services: {}\n")
        self.assertIn("OnCalendar=*-*-* 09:00:00 America/New_York", result.stdout)
        self.assertIn("Persistent=false", result.stdout)
        self.assertIn("WUD_RUN_MODE: oneshot", result.stdout)
        self.assertIn('WUD_TRIGGER_DOCKERCOMPOSE_LXC_INCLUDEBYDEFAULT: "false"', result.stdout)
        self.assertNotIn("WUD_TRIGGER_DOCKER_", result.stdout)
        self.assertNotIn("ports:", result.stdout)

    def test_proxy_default_denies_and_binds_loopback(self):
        result = self.run_script(*self.projects)
        self.assertIn("bind 127.0.0.1:23750", result.stdout)
        self.assertIn("allowed_method method GET HEAD", result.stdout)
        self.assertIn("deny unless allowed_method allowed_path", result.stdout)
        self.assertIn("deny if encoded_path or unsafe_path or dot_segment or upgrade", result.stdout)
        self.assertNotIn("/archive", result.stdout)

    def test_rejects_missing_overlapping_and_symlinked_projects(self):
        nested = self.project("one/nested")
        link = self.root / "link"
        link.symlink_to(self.projects[0], target_is_directory=True)
        for args in [(self.root,), (self.projects[0], nested), (link,), ("relative",)]:
            with self.subTest(args=args):
                self.assertNotEqual(self.run_script(*args).returncode, 0)

    def test_rejects_symlinked_compose_file(self):
        path = self.projects[0] / "docker-compose.yml"
        path.unlink()
        path.symlink_to(self.projects[1] / path.name)
        self.assertNotEqual(self.run_script(self.projects[0]).returncode, 0)

    def test_discovers_unique_running_single_file_projects(self):
        docker = self.root / "docker"
        docker.write_text(
            '#!/bin/sh\n'
            'test "$1 $2 $3" = "--host unix:///var/run/docker.sock ps" || exit 1\n'
            f"printf '%s\\n' '{self.projects[0]}/docker-compose.yml' "
            f"'{self.projects[0]}/docker-compose.yml' "
            f"'{self.projects[1]}/docker-compose.yml' "
            "'/opt/skipped/docker-compose.yml,/opt/skipped/override.yml'\n"
        )
        docker.chmod(0o755)
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            env={**os.environ, "PATH": f"{self.root}:{os.environ['PATH']}"},
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in self.projects:
            self.assertEqual(result.stdout.count(f"{path}:{path}"), 1)
        self.assertIn("Skipping multi-file project", result.stderr)
        self.assertNotIn("/opt/skipped", result.stdout)

    def test_interactive_wizard_reviews_then_defaults_to_cancel(self):
        docker = self.root / "docker"
        docker.write_text(f"#!/bin/sh\necho '{self.projects[0]}/docker-compose.yml'\n")
        docker.chmod(0o755)
        calls = self.root / "dialog-calls"
        whiptail = self.root / "whiptail"
        whiptail.write_text(
            '#!/bin/sh\n'
            f'printf "%s\\n" "$*" >> "{calls}"\n'
            'case "$*" in *--yesno*) exit 1;; esac\n'
        )
        whiptail.chmod(0o755)
        master, terminal = pty.openpty()
        try:
            result = subprocess.run(
                ["bash", str(SCRIPT)],
                env={**os.environ, "PATH": f"{self.root}:{os.environ['PATH']}"},
                stdin=terminal, stderr=terminal, stdout=subprocess.PIPE,
                timeout=10,
            )
        finally:
            os.close(terminal)
            os.close(master)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn("--textbox", calls.read_text())
        self.assertIn("--defaultno --yesno", calls.read_text())
        self.assertNotIn("--infobox", calls.read_text())


if __name__ == "__main__":
    unittest.main()
