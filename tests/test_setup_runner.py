"""Runner tests use local Git and fake SSH/id; no server or package operations."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.home = self.base / 'account'
        self.home.mkdir()
        self.competition = self.base / 'competition'
        self.competition.mkdir()
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home), GIT_CONFIG_GLOBAL=str(self.base / 'gitconfig'),
                        GIT_CONFIG_NOSYSTEM='1', PATH=str(self.bin) + ':' + self.env['PATH'])
        for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR'):
            self.env.pop(key, None)
        self.write_executable(self.bin / 'id', '#!/bin/bash\necho isucon\n')
        self.calls = self.base / 'calls.jsonl'
        self.env['RUNNER_CALLS'] = str(self.calls)

    def write_executable(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def run_cmd(self, *args, check=True, **kwargs):
        result = subprocess.run(args, env=self.env, text=True, capture_output=True, **kwargs)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def git(self, path, *args):
        return self.run_cmd('git', '-C', str(path), *args)

    def init_fixture(self, path):
        path.mkdir(parents=True, exist_ok=True)
        self.git(path, 'init')
        self.git(path, 'symbolic-ref', 'HEAD', 'refs/heads/main')
        self.git(path, 'config', 'user.email', 'test@example.com')
        self.git(path, 'config', 'user.name', 'test')

    def commit_fixture(self, path):
        self.git(path, 'add', '-A')
        self.git(path, 'commit', '-m', 'fixture')

    def setup_source(self):
        source = self.base / 'setup-source'
        self.init_fixture(source)
        self.write_executable(source / 'setup-server.sh', '''#!/usr/bin/env bash
python3 - "$@" <<'PYTHON'
import json, os, sys
with open(os.environ['RUNNER_CALLS'], 'a') as out:
    out.write(json.dumps(sys.argv[1:]) + '\\n')
PYTHON
''')
        self.commit_fixture(source)
        return source

    def fake_ssh(self):
        # Execute only the quoted remote command locally; all fixtures are under
        # TemporaryDirectory and id is stubbed to avoid the sudo branch.
        self.write_executable(self.bin / 'ssh', '#!/bin/bash\nexec /bin/sh -c "${@: -1}"\n')

    def local_args(self, source):
        return ['/bin/bash', str(ROOT / 'setup.sh'), '--mode', 'first', '--server', 'isu1:s1',
                '--home', str(self.competition), '--setup-repo', str(source),
                '--setup-clone-dir', str(self.base / 'server-setup'), '--skip-backup']

    def test_plan_performs_no_ssh_or_file_changes(self):
        self.write_executable(self.bin / 'ssh', '#!/bin/bash\necho unexpected >&2; exit 91\n')
        result = self.run_cmd('/bin/bash', str(ROOT / 'setup.sh'), '--mode', 'join',
                              '--server', 'isu2:s2', '--server', 'isu3:s3',
                              '--skip-deploy-key', '--plan')
        self.assertIn('isu2', result.stdout)
        self.assertIn('isu3', result.stdout)
        self.assertFalse((self.home / '.ssh').exists())
        self.assertFalse((ROOT / 'backup').exists())

    def test_first_rejects_multiple_servers_and_credential_urls(self):
        result = self.run_cmd('/bin/bash', str(ROOT / 'setup.sh'), '--mode', 'first',
                              '--server', 'isu1:s1', '--server', 'isu2:s2',
                              '--skip-deploy-key', '--plan', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('one server', result.stderr)
        result = self.run_cmd('/bin/bash', str(ROOT / 'setup.sh'), '--mode', 'first',
                              '--server', 'isu1:s1', '--skip-deploy-key', '--plan',
                              '--setup-repo', 'https://token@example.com/repo', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('token@example', result.stdout + result.stderr)

    def test_config_precedence_and_relative_key_path(self):
        source = self.setup_source()
        self.fake_ssh()
        config_dir = self.base / 'config with spaces'
        config_dir.mkdir()
        key = config_dir / 'deploy key'
        key.write_text('fixture-key\n')
        config = config_dir / 'setup.conf'
        config.write_text("DEPLOY_KEY_FILE='./deploy key'\nISUCON_HOME=/wrong-home\n"
                          "ENV_REF=from-config\nAPP_DIR=from-config\nEXTRA_IGNORES=(old/)\n")
        for config_first in (True, False):
            with self.subTest(config_first=config_first):
                args = self.local_args(source) + ['--env-ref', 'main', '--app-dir', 'src/go',
                                                  '--ignore', 'tools/', '--ignore', 'cache/']
                if config_first:
                    args[2:2] = ['--config', str(config)]
                else:
                    args += ['--config', str(config)]
                result = self.run_cmd(*args)
                call = json.loads(self.calls.read_text().splitlines()[-1])
                self.assertEqual(call[call.index('--home') + 1], str(self.competition))
                self.assertEqual(call[call.index('--env-ref') + 1], 'main')
                self.assertEqual(call[call.index('--app-dir') + 1], 'src/go')
                self.assertEqual(call[-4:], ['--ignore', 'tools/', '--ignore', 'cache/'])
                self.assertNotIn('old/', call)
                self.assertNotIn('fixture-key', result.stdout + result.stderr)
        self.assertEqual((self.home / '.ssh/id_ed25519').read_text(), 'fixture-key\n')

    def test_shared_config_uses_first_settings_only_for_first_mode(self):
        source = self.setup_source()
        self.fake_ssh()
        config = self.base / 'setup.conf'
        config.write_text('APP_DIR=src/go\nAPP_SERVICE=app.service\nAPP_BIN=app\n'
                          'EXTRA_IGNORES=(vendor/ tools/)\nSKIP_DEPLOY_KEY=1\n'
                          'SKIP_KEYS=1\nSKIP_TOOLS=1\nSKIP_CONFIG=1\n'
                          'ARCHIVE_DIR=/home/backup\nSKIP_ARCHIVE=1\n')
        for mode in ('first', 'join', 'existing'):
            with self.subTest(mode=mode):
                args = self.local_args(source)
                args[args.index('--mode') + 1] = mode
                self.run_cmd(*args, '--config', str(config))
                call = json.loads(self.calls.read_text().splitlines()[-1])
                for switch in ('--skip-keys', '--skip-tools', '--skip-config'):
                    self.assertIn(switch, call)
                self.assertEqual('--app-dir' in call, mode == 'first')
                self.assertEqual('--ignore' in call, mode == 'first')
                self.assertEqual('--archive-dir' in call, mode != 'existing')
                self.assertEqual('--skip-archive' in call, mode != 'existing')
                if mode == 'first':
                    self.assertEqual(call[call.index('--ignore'):call.index('--archive-dir')],
                                     ['--ignore', 'vendor/', '--ignore', 'tools/'])

    def test_flat_and_legacy_options_preserve_literal_arguments(self):
        source = self.setup_source()
        self.fake_ssh()
        marker = self.base / 'INJECTED'
        payload = "o'neil/$(touch " + str(marker) + ')/'
        options = ['--env-ref', 'main', '--skip-tools']
        helper = ['--app-dir', 'src/go', '--ignore', payload, '--skip-archive']
        for tail in (options + helper, ['--'] + options + ['--'] + helper):
            self.run_cmd(*self.local_args(source), '--skip-deploy-key', *tail)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(calls[0], calls[1])
        self.assertIn(payload, calls[0])
        self.assertFalse(marker.exists())

    def test_cli_key_switches_override_config(self):
        source = self.setup_source()
        self.fake_ssh()
        config = self.base / 'setup.conf'
        config.write_text('DEPLOY_KEY_FILE=missing-key\n')
        self.run_cmd(*self.local_args(source), '--skip-deploy-key', '--config', str(config))
        self.assertFalse((self.home / '.ssh').exists())
        config.write_text('SKIP_DEPLOY_KEY=1\n')
        key = self.base / 'deploy_key'
        key.write_text('fixture-key\n')
        self.run_cmd(*self.local_args(source), '--deploy-key', str(key), '--config', str(config))
        self.assertEqual((self.home / '.ssh/id_ed25519').read_text(), 'fixture-key\n')

    def test_invalid_config_or_mode_options_stop_before_ssh(self):
        self.write_executable(self.bin / 'ssh', '#!/bin/bash\necho UNEXPECTED_SSH >&2; exit 91\n')
        config = self.base / 'setup.conf'
        config.write_text('SKIP_TOOLS=invalid\n')
        base = ['/bin/bash', str(ROOT / 'setup.sh'), '--server', 'isu1:s1', '--skip-deploy-key']
        cases = [
            (['--mode', 'first', '--config', str(self.base / 'missing')], 'cannot read configuration'),
            (['--mode', 'first', '--config', str(config)], 'must be 0 or 1'),
            (['--mode', 'first', '--config', str(config), '--config', str(config)], 'only one --config'),
            (['--mode', 'join', '--app-dir', 'src/go'], 'only supported in first mode'),
            (['--mode', 'existing', '--skip-archive'], 'no helper backup options'),
        ]
        for tail, message in cases:
            with self.subTest(tail=tail):
                result = self.run_cmd(*base, *tail, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertNotIn('UNEXPECTED_SSH', result.stderr)
                self.assertEqual(result.stdout, '')

    def test_make_plan_with_shared_config_does_not_execute_ssh(self):
        self.write_executable(self.bin / 'ssh', '#!/bin/bash\necho unexpected >&2; exit 91\n')
        config = self.base / 'setup with spaces.conf'
        config.write_text('SKIP_DEPLOY_KEY=1\nAPP_DIR=src/go\nEXTRA_IGNORES=(tools/)\nBACKUP_DIR=./copies\n')
        result = self.run_cmd('make', '-C', str(ROOT), 'plan', 'MODE=first',
                              'SERVER=isu1:s1', 'CONFIG=' + str(config))
        self.assertIn('src/go', result.stdout)
        backup_arg = next(arg for arg in shlex.split(result.stdout.splitlines()[0])
                          if arg.startswith('OUT_DIR='))
        self.assertEqual(Path(backup_arg.split('=', 1)[1]).resolve(), self.base / 'copies')
        result = self.run_cmd('make', '-C', str(ROOT), 'plan', 'MODE=join',
                              'SERVERS=isu2:s2 isu3:s3', 'CONFIG=' + str(config))
        self.assertIn('isu2', result.stdout)
        self.assertIn('isu3', result.stdout)
        self.assertNotIn('src/go', result.stdout)
        self.assertFalse((self.home / '.ssh').exists())
        self.assertFalse((self.base / 'copies').exists())
        self.assertFalse(self.calls.exists())

    def test_key_install_preserves_existing_key_and_argument_boundaries(self):
        source = self.setup_source()
        self.fake_ssh()
        key = self.base / 'private key'
        secret = 'fixture-private-key-content-do-not-display\n'
        key.write_text(secret)
        marker = self.base / 'INJECTED'
        payload = "tools/o'neil/$(touch " + str(marker) + ')/'
        args = self.local_args(source) + ['--deploy-key', str(key), '--',
                '--env-ref', 'main', '--', '--ignore', payload]
        result = self.run_cmd(*args)
        destination = self.home / '.ssh/id_ed25519'
        self.assertEqual(destination.read_text(), secret)
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
        self.assertEqual(destination.parent.stat().st_mode & 0o777, 0o700)
        self.assertNotIn(secret.strip(), result.stdout + result.stderr)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(calls[-1][-2:], ['--ignore', payload])
        self.assertFalse(marker.exists())
        self.run_cmd(*args)  # Same existing key is accepted without replacement.
        key.write_text('different secret\n')
        result = self.run_cmd(*args, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not overwritten', result.stderr)
        self.assertEqual(destination.read_text(), secret)
        self.assertNotIn('different secret', result.stdout + result.stderr)

    def test_backup_failure_is_nonfatal_and_receives_custom_home(self):
        source = self.setup_source()
        self.fake_ssh()
        runner = self.base / 'runner'
        runner.mkdir()
        shutil.copy2(ROOT / 'setup.sh', runner / 'setup.sh')
        backup_log = self.base / 'backup-home'
        self.write_executable(runner / '00-local-backup.sh',
                              '#!/bin/bash\nprintf "%s" "$REMOTE_HOME" > "' + str(backup_log) + '"\nexit 2\n')
        args = self.local_args(source)
        args[1] = str(runner / 'setup.sh')
        args.remove('--skip-backup')
        result = self.run_cmd(*args, '--skip-deploy-key')
        self.assertEqual(backup_log.read_text(), str(self.competition))
        self.assertIn('WARN: local backup failed', result.stderr)
        self.assertTrue(self.calls.exists())

    def test_existing_setup_clone_origin_mismatch_stops(self):
        source = self.setup_source()
        self.fake_ssh()
        clone = self.base / 'server-setup'
        self.run_cmd('git', 'clone', str(source), str(clone))
        self.git(clone, 'remote', 'set-url', 'origin', '/wrong-repo')
        result = self.run_cmd(*self.local_args(source), '--skip-deploy-key', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('origin differs', result.stderr)
        self.assertFalse(self.calls.exists())

    def test_first_clone_has_noninteractive_first_use_ssh_policy(self):
        source = self.setup_source()
        self.fake_ssh()
        real_git = shutil.which('git', path=os.environ['PATH'])
        policy = self.base / 'ssh-policy'
        self.write_executable(self.bin / 'git', '#!/bin/bash\n'
            'if [[ "$1" = clone ]]; then\n'
            '  [[ "$GIT_SSH_COMMAND" = *StrictHostKeyChecking=accept-new* && "$GIT_SSH_COMMAND" = *BatchMode=yes* ]] || exit 93\n'
            '  printf "%s" "$GIT_SSH_COMMAND" > "' + str(policy) + '"\n'
            'fi\nexec "' + real_git + '" "$@"\n')
        self.env.pop('GIT_SSH_COMMAND', None)
        self.run_cmd(*self.local_args(source), '--skip-deploy-key')
        self.assertIn('StrictHostKeyChecking=accept-new', policy.read_text())

    def test_existing_resolves_log_paths_and_runs_config_steps(self):
        self.init_fixture(self.competition)
        (self.competition / 'scripts').mkdir()
        (self.competition / 'scripts/init-repo.sh').write_text('# fixture marker\n')
        nginx = str(self.base / 'custom-nginx/access.log')
        mysql = str(self.base / 'custom-mysql/slow.log')
        (self.competition / 'config.mk').write_text(
            'NGINX_ACCESS_LOG := ' + nginx + '\nMYSQL_SLOW_LOG := ' + mysql + '\n')
        (self.competition / 'Makefile').write_text(
            'include config.mk\nset-as-s2:\n\t@echo SERVER_ID=s2 > env.sh\n'
            'get-conf:\n\t@echo copied > config-copied\n')
        runner = self.competition / 'a-different-setup-name'
        runner.mkdir()
        shutil.copy2(ROOT / 'setup-server.sh', runner / 'setup-server.sh')
        self.write_executable(runner / '30-install-tools.sh',
            '#!/bin/bash\nprintf "%s\\n" "$ISUCON_HOME" "$NGINX_ACCESS_LOG" "$MYSQL_SLOW_LOG" > "' + str(self.base / 'tool-env') + '"\n')
        self.run_cmd('bash', str(runner / 'setup-server.sh'), '--mode', 'existing',
                     '--server-id', 's2', '--home', str(self.competition), '--skip-keys')
        self.assertEqual((self.base / 'tool-env').read_text().splitlines(),
                         [str(self.competition), nginx, mysql])
        self.assertEqual((self.competition / 'env.sh').read_text(), 'SERVER_ID=s2\n')
        self.assertEqual((self.competition / 'config-copied').read_text(), 'copied\n')
        self.assertIn('/a-different-setup-name/',
                      (self.competition / '.git/info/exclude').read_text())

    def test_server_rejects_existing_git_and_unsupported_flags_before_keys(self):
        self.init_fixture(self.competition)
        result = self.run_cmd('bash', str(ROOT / 'setup-server.sh'), '--mode', 'first',
                              '--server-id', 's1', '--home', str(self.competition), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already has .git', result.stderr)
        result = self.run_cmd('bash', str(ROOT / 'setup-server.sh'), '--mode', 'join',
                              '--server-id', 's2', '--home', str(self.competition),
                              '--', '--app-dir', '.', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('only supported in first', result.stderr)
        result = self.run_cmd('bash', str(ROOT / 'setup-server.sh'), '--mode', 'first',
                              '--server-id', 's1', '--home', str(self.competition),
                              '--', '--app-bin', 'x;touch', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ASCII', result.stderr)

    @unittest.skipUnless(os.environ.get('ISUCON_ENV_TEST_SOURCE'),
                         'set ISUCON_ENV_TEST_SOURCE to a committed isucon-env clone for integration')
    def test_server_calls_real_env_init_and_join(self):
        source = Path(os.environ['ISUCON_ENV_TEST_SOURCE']).resolve()
        setup_source = self.setup_source()
        shutil.copy2(ROOT / 'setup-server.sh', setup_source / 'setup-server.sh')
        self.commit_fixture(setup_source)
        self.fake_ssh()
        clone = self.base / 'env-clone'
        self.run_cmd('git', 'clone', str(source), str(clone))
        ref = self.git(clone, 'symbolic-ref', '--short', 'HEAD').stdout.strip()
        remote = self.base / 'competition.git'
        self.run_cmd('git', 'init', '--bare', str(remote))
        (self.competition / 'go.mod').write_text('module example.test/competition\n')
        (self.competition / 'main.go').write_text('package main\n')
        config_file = self.base / 'setup.conf'
        settings = dict(ISUCON_HOME=str(self.competition), SETUP_REPO=str(setup_source),
                        SETUP_CLONE_DIR=str(self.base / 'server-setup'),
                        CLONE_DIR=str(clone), ENV_REPO=str(source), ENV_REF=ref,
                        BRANCH='competition', REMOTE=str(remote), APP_DIR='.', APP_BIN='game',
                        SKIP_DEPLOY_KEY='1', SKIP_BACKUP='1', SKIP_KEYS='1', SKIP_TOOLS='1',
                        SKIP_CONFIG='1', SKIP_ARCHIVE='1')
        config_file.write_text(''.join(f'{name}={shlex.quote(value)}\n'
                                       for name, value in settings.items()) +
                               'EXTRA_IGNORES=(extra-tool/)\n')
        args = ['bash', str(ROOT / 'setup.sh'), '--config', str(config_file),
                '--mode', 'first', '--server', 'isu1:s1']
        result = self.run_cmd(*args)
        self.assertIn('Initialized:', result.stdout)
        tracked = self.git(self.competition, 'ls-files').stdout.splitlines()
        self.assertIn('main.go', tracked)
        config = (self.competition / 'config.mk').read_text()
        self.assertIn('APP_DIR := ' + str(self.competition), config)
        self.assertIn('APP_BIN := game', config)
        self.assertIn('/extra-tool/', (self.competition / '.gitignore').read_text())
        self.assertEqual(self.git(self.competition, 'symbolic-ref', '--short', 'HEAD').stdout.strip(), 'competition')
        self.assertEqual(self.git(self.competition, 'config', '--get', 'remote.origin.url').stdout.strip(), str(remote))
        self.git(self.competition, 'push', 'origin', 'competition')  # Local fixture transport only.
        if not (clone / 'scripts/join-repo.sh').exists():
            self.fail('the integration source must contain the committed join helper')
        second = self.base / 'second'
        second.mkdir()
        (second / 'unique-data').write_text('preserve me\n')
        result = self.run_cmd('bash', str(ROOT / 'setup.sh'), '--mode', 'join',
                              '--server', 'isu2:s2', '--home', str(second),
                              '--config', str(config_file))
        self.assertTrue((second / 'main.go').exists())
        self.assertEqual((second / 'unique-data').read_text(), 'preserve me\n')
        self.assertEqual(self.git(second, 'rev-parse', 'competition').stdout,
                         self.git(self.competition, 'rev-parse', 'competition').stdout)


if __name__ == '__main__':
    unittest.main()
