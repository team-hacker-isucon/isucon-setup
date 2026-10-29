"""Regression checks; all privileged/network operations are isolated behind stubs."""
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallToolsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="isucon-tools-test-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.home = self.base / "home"
        self.home.mkdir()
        (self.home / ".bashrc").write_text("")
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        HOME=str(self.home), ISUCON_HOME=str(self.home),
                        CASE_DIR=str(self.base), APT_LOCK_WAIT_SECONDS="2", APT_LOCK_RETRY_SECONDS="1")
        self.stub("sudo", 'while [[ "$1" = *=* ]]; do export "$1"; shift; done\n'
                  'case "$1" in apt-get|du|tar) exec "$@";; install|chmod|test|update-alternatives) exit 0;; '
                  '*) echo "unexpected sudo command: $*" >&2; exit 99;; esac\n')
        self.stub("apt-get", 'echo "$*" >> "$CASE_DIR/apt-calls"\n'
                  '[[ "${LC_ALL:-}" = C ]] || exit 91\n'
                  'if [[ "$1" = update ]]; then echo updated; exit 0; fi\n'
                  'n=0; [[ ! -f "$CASE_DIR/count" ]] || read -r n < "$CASE_DIR/count"\n'
                  'n=$((n+1)); echo "$n" > "$CASE_DIR/count"\n'
                  'if [[ "$n" -le "${FAIL_COUNT:-1}" ]]; then\n'
                  '  printf "%s\\n" "${APT_ERROR:-E: Could not get lock /var/lib/dpkg/lock-frontend - open (11: Resource temporarily unavailable)}" >&2\n'
                  '  [[ -z "${EXTRA_ERROR:-}" ]] || echo "$EXTRA_ERROR" >&2\n'
                  '  exit 100\n'
                  'fi\necho installed\n')
        self.stub("du", 'printf "16\\t%s\\n" "${@: -1}"\n')
        self.stub("df", 'printf "Filesystem 1024-blocks Used Available Capacity Mounted\\nfixture 9000000 1 %s 1%% /\\n" "${FREE_KB:-8000000}"\n')
        self.real_tar = shlex.quote(shutil.which("tar"))
        self.stub("tar", 'if [[ "${TAR_FAIL:-0}" = 1 ]]; then touch "$2"; echo "injected tar failure" >&2; exit 1; fi\n'
                  'if [[ "${@: -1}" = . ]]; then exec ' + self.real_tar + ' "$@"; fi\ntouch "$2"\n')

    def stub(self, name, body):
        target = self.bin / name
        target.write_text("#!/bin/bash\nset -eu\n" + body)
        target.chmod(0o755)

    def run_shell(self, body, **changes):
        env = dict(self.env, **{k: str(v) for k, v in changes.items()})
        return subprocess.run(["bash", "-c", "set -euo pipefail\nsource " +
                               shlex.quote(str(ROOT / "lib/install-tools.sh")) + "\n" + body],
                              env=env, text=True, capture_output=True, timeout=15)

    def apt(self, **changes):
        return self.run_shell("apt_with_lock_retry install -y example", **changes)

    def backups(self, **changes):
        return self.run_shell('BACKUP_DIR="$ISUCON_HOME/local"; TIMESTAMP=fixture; backup_before_install', **changes)

    def test_old_apt_frontend_lock_retries_then_succeeds(self):
        result = self.apt()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("installed", result.stdout)
        self.assertIn("retrying", result.stderr)
        self.assertEqual((self.base / "count").read_text().strip(), "2")

    def test_lists_and_archives_locks_retry(self):
        for path in ("/var/lib/apt/lists/lock", "/var/cache/apt/archives/lock"):
            with self.subTest(path=path):
                (self.base / "count").unlink(missing_ok=True)
                result = self.apt(APT_ERROR=f"E: Could not get lock {path}. It is held by process 42 (apt-get)")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_lock_wait_is_bounded_and_zero_disables_retry(self):
        started = time.monotonic()
        result = self.apt(FAIL_COUNT=100, APT_LOCK_WAIT_SECONDS=1)
        self.assertEqual(result.returncode, 100)
        self.assertIn("timed out", result.stderr)
        self.assertLess(time.monotonic() - started, 5)
        (self.base / "count").unlink()
        result = self.apt(FAIL_COUNT=100, APT_LOCK_WAIT_SECONDS=0)
        self.assertEqual(result.returncode, 100)
        self.assertEqual((self.base / "count").read_text().strip(), "1")

    def test_non_lock_and_mixed_errors_return_without_retry(self):
        for message in ("E: Could not get lock /var/lib/dpkg/lock-frontend - open (13: Permission denied)",
                        "E: dpkg was interrupted, you must manually run dpkg --configure -a",
                        "E: Failed to fetch https://invalid.example/packages 404 Not Found"):
            with self.subTest(message=message):
                (self.base / "count").unlink(missing_ok=True)
                result = self.apt(APT_ERROR=message)
                self.assertEqual(result.returncode, 100)
                self.assertEqual((self.base / "count").read_text().strip(), "1")
        (self.base / "count").unlink()
        result = self.apt(EXTRA_ERROR="E: repository is not signed")
        self.assertEqual(result.returncode, 100)
        self.assertEqual((self.base / "count").read_text().strip(), "1")

    def test_home_without_webapp_is_archived_without_generated_paths(self):
        (self.home / "isucari").mkdir()
        (self.home / "isucari/main.go").write_text("package main\n")
        for directory in ("local", ".git", "isucon-setup-logs"):
            (self.home / directory).mkdir()
            (self.home / directory / "excluded").write_text("must not archive")
        result = self.backups()
        self.assertEqual(result.returncode, 0, result.stderr)
        archive_path = self.home / "local/backup-fixture-home-isucon.tar.gz"
        self.assertEqual(stat.S_IMODE(archive_path.stat().st_mode), 0o600)
        with tarfile.open(archive_path) as archive:
            members = archive.getnames()
        self.assertIn("./isucari/main.go", members)
        self.assertFalse(any(name.startswith(("./local", "./.git", "./isucon-setup-logs")) for name in members))
        self.assertIn("home-isucon\tsuccess", (self.home / "local/backup-fixture-report.txt").read_text())

    def test_failed_archives_are_partial_and_reported(self):
        result = self.backups(TAR_FAIL=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / "local/backup-fixture-home-isucon.tar.gz.partial").exists())
        self.assertEqual(stat.S_IMODE((self.home / "local/backup-fixture-home-isucon.tar.gz.partial").stat().st_mode), 0o600)
        self.assertFalse((self.home / "local/backup-fixture-home-isucon.tar.gz").exists())
        self.assertIn("home-isucon\tfailed", (self.home / "local/backup-fixture-report.txt").read_text())

    def test_low_space_skips_archives(self):
        result = self.backups(FREE_KB=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(list((self.home / "local").glob("*.tar.gz*")))
        self.assertIn("home-isucon\tskipped", (self.home / "local/backup-fixture-report.txt").read_text())

    def test_existing_dangling_archive_symlink_is_not_followed(self):
        (self.home / "local").mkdir()
        target = self.base / "outside"
        (self.home / "local/backup-fixture-home-isucon.tar.gz").symlink_to(target)
        result = self.backups()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(target.exists())
        self.assertIn("destination-exists", (self.home / "local/backup-fixture-report.txt").read_text())

    def test_existing_archive_and_partial_are_not_overwritten(self):
        (self.home / "local").mkdir()
        for suffix, symlink in ((".tar.gz", False), (".tar.gz.partial", False), (".tar.gz.partial", True)):
            with self.subTest(suffix=suffix, symlink=symlink):
                path = self.home / ("local/backup-fixture-home-isucon" + suffix)
                target = self.base / "untouched"
                if symlink:
                    path.symlink_to(target)
                else:
                    path.write_bytes(b"original backup")
                result = self.backups()
                self.assertEqual(result.returncode, 0, result.stderr)
                if symlink:
                    self.assertTrue(path.is_symlink())
                    self.assertFalse(target.exists())
                else:
                    self.assertEqual(path.read_bytes(), b"original backup")
                self.assertIn("destination-exists", (self.home / "local/backup-fixture-report.txt").read_text())
                path.unlink()

    def test_full_script_continues_when_backup_directory_cannot_be_created(self):
        self.stub("mkdir", '[[ "${@: -1}" != "$ISUCON_HOME/local" ]] || exit 1\nexec ' + shlex.quote(shutil.which("mkdir")) + ' "$@"\n')
        for name, body in {"git": "exit 0\n", "dpkg": "echo amd64\n", "unzip": "exit 0\n",
                           "wget": '[[ "$*" != *slp* ]]\n'}.items():
            self.stub(name, body)
        result = subprocess.run(["bash", str(ROOT / "30-install-tools.sh")], env=self.env,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("backups skipped", result.stdout + result.stderr)
        self.assertIn("installed", result.stdout)
        self.assertIn("== done ==", result.stdout)

    def test_root_alias_is_rejected_and_retired_init_changes_nothing(self):
        result = subprocess.run(["bash", str(ROOT / "30-install-tools.sh")],
                                env=dict(self.env, ISUCON_HOME="/."), text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 1)
        self.assertIn("filesystem root", result.stdout + result.stderr)
        before = sorted(self.home.iterdir())
        result = subprocess.run(["bash", str(ROOT / "20-init-repo.sh"), "ignored/legacy-repo", "https"],
                                env=self.env, text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn("scripts/init-repo.sh", result.stderr)
        self.assertEqual(sorted(self.home.iterdir()), before)
        self.assertFalse((self.base / "apt-calls").exists())


if __name__ == "__main__":
    unittest.main()
