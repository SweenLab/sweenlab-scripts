import pathlib
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

    def test_install_requires_explicit_projects(self):
        self.assertNotEqual(self.run_script("--install").returncode, 0)


if __name__ == "__main__":
    unittest.main()
