"""Local backup tests: SSH and sudo are stubs; tar only reads fixture files."""
import os
from pathlib import Path
import stat
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "00-local-backup.sh"


class LocalBackupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="isucon-local-backup-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.home = self.base / "competition"
        self.home.mkdir()
        (self.home / "original.txt").write_text("competition source\n")
        self.etc = self.base / "etc-fixture"
        self.etc.mkdir()
        (self.etc / "nginx.conf").write_text("fixture\n")
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        OUT_DIR=str(self.base / "output"), REMOTE_HOME=str(self.home),
                        CASE_DIR=str(self.base), FIXTURE_HOME=str(self.home),
                        FIXTURE_ETC=str(self.etc), EXECUTE_HOME="1")
        self.stub("sudo", '[[ "$1" = -n ]] && shift\n'
                  'case "$1" in true|tar) exec "$@";; *) exit 99;; esac\n')
        self.stub("ssh", 'while [[ "$1" = -o ]]; do shift 2; done\n'
                  'host=$1; shift; command=$1\n'
                  'printf "%s\\t%s\\n" "$host" "$command" >> "$CASE_DIR/ssh-calls"\n'
                  'case "$command" in\n'
                  ' true|"sudo -n true") exit 0;;\n'
                  ' requested_home=*)\n'
                  '   if [[ "$EXECUTE_HOME" = 1 ]]; then exec bash -c "$command"; fi\n'
                  '   exec tar -czf - -C "$FIXTURE_HOME" .;;\n'
                  ' p=*) exec tar -czf - -C "$FIXTURE_ETC" .;;\n'
                  ' *) echo "unexpected SSH command" >&2; exit 99;;\n'
                  'esac\n')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -eu\n" + body)
        path.chmod(0o755)

    def run_backup(self, host="isu1", **changes):
        return subprocess.run(["bash", str(SCRIPT), host], env=dict(self.env, **changes),
                              text=True, capture_output=True, timeout=10)

    def test_custom_home_archive_contains_only_selected_fixture(self):
        for name in ("competition", "-competition"):
            with self.subTest(name=name):
                selected = self.base / name
                if selected != self.home:
                    self.home.rename(selected)
                    self.home = selected
                    self.env["REMOTE_HOME"] = self.env["FIXTURE_HOME"] = str(selected)
                result = self.run_backup()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                archive = next((self.base / "output").glob("*-home-isucon.tar.gz"))
                self.assertEqual(stat.S_IMODE(archive.stat().st_mode), 0o600)
                with tarfile.open(archive) as handle:
                    self.assertIn(f"{name}/original.txt", handle.getnames())
                    self.assertEqual(handle.extractfile(f"{name}/original.txt").read(), b"competition source\n")
                calls = (self.base / "ssh-calls").read_text()
                self.assertIn(f"requested_home='{self.home}'", calls)

    def test_default_home_is_preserved(self):
        self.env.pop("REMOTE_HOME")
        result = self.run_backup(EXECUTE_HOME="0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("requested_home='/home/isucon'", (self.base / "ssh-calls").read_text())

    def test_filesystem_root_alias_is_rejected_remotely(self):
        result = self.run_backup(REMOTE_HOME="/./")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not be the filesystem root", result.stderr)
        self.assertFalse(list((self.base / "output").glob("*-home-isucon.tar.gz")))

    def test_invalid_host_and_home_are_rejected_before_ssh(self):
        for host, home in (("../escape", str(self.home)), ("-oProxyCommand=bad", str(self.home)),
                           ("isu1", "relative/home"), ("isu1", "/tmp/$(false)")):
            with self.subTest(host=host, home=home):
                result = self.run_backup(host=host, REMOTE_HOME=home)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertFalse((self.base / "ssh-calls").exists())


if __name__ == "__main__":
    unittest.main()
