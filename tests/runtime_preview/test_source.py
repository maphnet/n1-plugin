import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from lib.runtime_review.source import parse_target, prepare_source


ROOT = Path(__file__).resolve().parents[2]
BASE = 'a' * 40
HEAD = 'b' * 40
OID = 'c' * 40
META = {'number': 123, 'title': 'Title', 'body': 'Requirements',
        'baseRefOid': BASE, 'headRefOid': HEAD,
        'url': 'https://github.com/owner/repo/pull/123'}
DIFF = b'diff --git a/app.py b/app.py\n--- a/app.py\n+++ b/app.py\n@@ -1 +1 @@\n-old\n+new\n'
REAL_SUBPROCESS_RUN = subprocess.run


class SourceTests(unittest.TestCase):
    def test_only_explicit_github_targets(self):
        for value in ('owner/repo#123', 'https://github.com/owner/repo/pull/123'):
            self.assertEqual(parse_target(value), ('owner/repo', 123))
        for value in ('', '123', '--help', 'owner/repo#0', 'owner/repo#01',
                      'https://evil.test/a/b/pull/1', 'a/../b#1', 'a/b#1\n',
                      'https://github.com/a/b/pull/1?x=y', '-a/b#1'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse_target(value)

    def test_github_dot_repository_is_a_valid_explicit_target(self):
        self.assertEqual(parse_target('owner/.github#1'), ('owner/.github', 1))
        with self.assertRaises(ValueError):
            parse_target('owner/..#1')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.workspace = Path(self.temp.name)
        self.run = self.workspace / 'run'
        self.calls = []
        self.metadata = [dict(META), dict(META)]
        self.diff = DIFF
        self.entries = [('100644', 'blob', OID, 'app.py')]
        self.blobs = {OID: b'new\n'}

    def controller(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        if argv[:3] == ['gh', 'pr', 'view']:
            data = json.dumps(self.metadata.pop(0)).encode()
        elif argv[:3] == ['gh', 'pr', 'diff']:
            data = self.diff
        elif 'apply' in argv:
            # Keep Git's read-only patch parser real; only acquisition is fake.
            return REAL_SUBPROCESS_RUN(['git', 'apply', '--numstat', '-z'],
                                       input=kwargs['input'], check=True, capture_output=True,
                                       env=kwargs['env'], cwd=self.workspace)
        elif 'ls-tree' in argv:
            data = b''.join(f'{mode} {kind} {oid}\t{name}\0'.encode()
                            for mode, kind, oid, name in self.entries)
        elif 'cat-file' in argv:
            blob = self.blobs[argv[-1]]
            data = str(len(blob)).encode() if argv[-2] == '-s' else blob
        else:
            data = b''
        return subprocess.CompletedProcess(argv, 0, data, b'')

    def prepare(self):
        with patch('lib.runtime_review.source.subprocess.run', side_effect=self.controller):
            return prepare_source('owner/repo#123', self.run)

    def test_materializes_pinned_blob_and_strict_contract_inputs(self):
        result = self.prepare()
        self.assertEqual(result['revision'], {'repository': 'owner/repo', 'baseSha': BASE, 'headSha': HEAD})
        self.assertEqual((result['prNumber'], result['prTitle']), (123, 'Title'))
        source = Path(result['cwd'])
        self.assertEqual((source / 'app.py').read_bytes(), b'new\n')
        self.assertFalse((source / '.git').exists())
        self.assertEqual({item['name'] for item in result['inputs']}, {'diff', 'requirements', 'conventions'})
        artifacts = {item['name']: Path(item['path']).read_text() for item in result['inputs']}
        self.assertEqual(artifacts['diff'], DIFF.decode())
        self.assertIn('Requirements', artifacts['requirements'])
        self.assertTrue(all(item['required'] for item in result['inputs']))

    def test_controller_arguments_and_git_environment_are_isolated(self):
        with patch.dict(os.environ, {'GIT_DIR': '/untrusted', 'GIT_CONFIG_COUNT': '1',
                                     'GIT_CONFIG_KEY_0': 'core.sshCommand', 'GIT_CONFIG_VALUE_0': 'evil'}):
            self.prepare()
        views = [argv for argv, _ in self.calls if argv[:3] == ['gh', 'pr', 'view']]
        self.assertEqual(views, [['gh', 'pr', 'view', '123', '--repo', 'owner/repo', '--json',
                                 'number,title,body,baseRefOid,headRefOid,url']] * 2)
        self.assertIn(['gh', 'pr', 'diff', '123', '--repo', 'owner/repo', '--patch'], [x[0] for x in self.calls])
        for argv, kwargs in self.calls:
            self.assertIs(kwargs['shell'], False)
            self.assertTrue(kwargs['check'])
            self.assertTrue(kwargs['capture_output'])
            self.assertEqual(kwargs['timeout'], 60)
            self.assertTrue(set(argv).isdisjoint({'checkout', 'reset', 'clean', 'submodule'}))
            if argv[0] == 'git':
                self.assertIn('core.hooksPath=/dev/null', argv)
                self.assertIn('protocol.file.allow=never', argv)
                self.assertIn('protocol.ext.allow=never', argv)
                self.assertEqual(kwargs['env']['GIT_CONFIG_GLOBAL'], '/dev/null')
                self.assertEqual(kwargs['env']['GIT_CONFIG_NOSYSTEM'], '1')
                self.assertNotIn('GIT_DIR', kwargs['env'])
                self.assertNotIn('GIT_CONFIG_COUNT', kwargs['env'])
        fetch = next(argv for argv, _ in self.calls if 'fetch' in argv)
        self.assertEqual(fetch[-2:], ['https://github.com/owner/repo.git', HEAD])
        self.assertIn('--no-recurse-submodules', fetch)

    def test_moving_base_or_head_fails_before_fetch(self):
        for field in ('baseRefOid', 'headRefOid'):
            with self.subTest(field=field):
                self.metadata = [dict(META), dict(META, **{field: 'd' * 40})]
                self.calls = []
                with self.assertRaisesRegex(RuntimeError, 'changed'):
                    self.prepare()
                self.assertFalse(any(argv[0] == 'git' for argv, _ in self.calls))

    def test_fetch_failure_is_concrete_incomplete_error(self):
        original = self.controller
        def fail(argv, **kwargs):
            if 'fetch' in argv:
                raise subprocess.CalledProcessError(128, argv, stderr=b'not our ref')
            return original(argv, **kwargs)
        with patch('lib.runtime_review.source.subprocess.run', side_effect=fail):
            with self.assertRaisesRegex(RuntimeError, 'fetch.*not our ref'):
                prepare_source('owner/repo#123', self.run)

    def test_fetch_authentication_failure_cannot_inherit_ssh_askpass(self):
        original = self.controller
        def authenticate(argv, **kwargs):
            if 'fetch' in argv:
                self.assertTrue('SSH_ASKPASS' not in kwargs['env'], 'untrusted askpass was inherited')
                raise subprocess.CalledProcessError(128, argv, stderr=b'authentication failed; prompts disabled')
            if argv[0] == 'gh':
                self.assertNotIn('env', kwargs)
            return original(argv, **kwargs)
        with patch.dict(os.environ, {'SSH_ASKPASS': '/untrusted/askpass'}):
            with patch('lib.runtime_review.source.subprocess.run', side_effect=authenticate):
                with self.assertRaisesRegex(RuntimeError, 'fetch.*authentication failed'):
                    prepare_source('owner/repo#123', self.run)
            self.assertEqual(os.environ['SSH_ASKPASS'], '/untrusted/askpass')

    def test_tree_escape_git_and_collisions_are_denied(self):
        for names in (['../escape'], ['/escape'], ['.git/config'], ['a', 'a/b']):
            with self.subTest(names=names):
                self.metadata = [dict(META), dict(META)]
                self.run = self.workspace / str(len(self.calls))
                self.entries = [('100644', 'blob', OID, name) for name in names]
                with self.assertRaisesRegex(RuntimeError, 'coverage'):
                    self.prepare()

    def test_unchanged_boundaries_and_host_config_are_preserved_as_data(self):
        self.entries += [('120000', 'blob', 'd' * 40, 'link'),
                         ('160000', 'commit', 'e' * 40, 'vendor'),
                         ('100644', 'blob', 'f' * 40, '.claude/settings.json'),
                         ('100644', 'blob', '1' * 40, 'AGENTS.md'),
                         ('100644', 'blob', '2' * 40, 'nested/CLAUDE.md')]
        self.blobs.update({'f' * 40: b'{"hooks":{"run":"evil"}}',
                           '1' * 40: b'Root convention', '2' * 40: b'Nested convention'})
        result = self.prepare()
        source = Path(result['cwd'])
        self.assertEqual((source / '.claude/settings.json').read_text(), '{"hooks":{"run":"evil"}}')
        self.assertFalse((source / 'link').exists())
        self.assertFalse((source / 'vendor').exists())
        conventions = json.loads(Path(next(x['path'] for x in result['inputs'] if x['name'] == 'conventions')).read_text())
        self.assertEqual(conventions['projectConfigFiles'], ['.claude/settings.json'])
        self.assertEqual([b['path'] for b in conventions['inaccessibleBoundaries']], ['link', 'vendor'])
        pinned = [x for x in conventions['instructions'] if x['trust'] == 'pinned-repository-data']
        self.assertEqual([x['path'] for x in pinned], ['AGENTS.md', 'nested/CLAUDE.md'])
        self.assertEqual([x['scope'] for x in pinned], ['.', 'nested'])

    def test_changed_binary_symlink_and_gitlink_fail_coverage(self):
        for marker in (b'Binary files a/x and b/x differ\n', b'GIT binary patch\n',
                       b'new file mode 120000\n', b'old mode 160000\n'):
            with self.subTest(marker=marker):
                self.metadata = [dict(META), dict(META)]
                self.diff = DIFF + marker
                with self.assertRaisesRegex(RuntimeError, 'coverage'):
                    self.prepare()

    def test_pure_boundary_renames_fail_coverage_without_mode_headers(self):
        for mode, kind in [('120000', 'blob'), ('160000', 'commit')]:
            with self.subTest(mode=mode):
                self.metadata = [dict(META), dict(META)]
                self.run = self.workspace / mode
                self.diff = b'diff --git a/old b/app.py\nsimilarity index 100%\nrename from old\nrename to app.py\n'
                self.entries = [(mode, kind, OID, 'app.py')]
                with self.assertRaisesRegex(RuntimeError, 'coverage.*boundary'):
                    self.prepare()

    def test_changed_blob_with_unsupported_bytes_outside_hunks_fails_coverage(self):
        for value in (b'\x00', b'\xff'):
            with self.subTest(value=value):
                self.metadata = [dict(META), dict(META)]
                self.run = self.workspace / value.hex()
                self.blobs[OID] = b'new\n' + b'unchanged\n' * 50 + value
                with self.assertRaisesRegex(RuntimeError, 'coverage.*(?:binary|UTF-8)'):
                    self.prepare()

    def test_git_quoted_rename_path_is_correlated_with_pinned_blob(self):
        self.diff = (b'diff --git a/old "b/new\\tname.py"\nsimilarity index 100%\n'
                     b'rename from old\nrename to "new\\tname.py"\n')
        self.entries = [('100644', 'blob', OID, 'new\tname.py')]
        result = self.prepare()
        self.assertEqual((Path(result['cwd']) / 'new\tname.py').read_bytes(), b'new\n')

    def test_unestablished_or_missing_changed_paths_fail_coverage(self):
        for diff in (b'not a patch\n', DIFF):
            with self.subTest(diff=diff):
                self.metadata = [dict(META), dict(META)]
                self.run = self.workspace / str(len(self.calls))
                self.diff = diff
                self.entries = []
                with self.assertRaisesRegex(RuntimeError, 'coverage.*(?:changed paths|absent)'):
                    self.prepare()

    def test_size_limit_fails_without_reading_oversize_blob(self):
        self.blobs[OID] = b'x' * 1025
        with patch('lib.runtime_review.source.MAX_FILE_BYTES', 1024):
            with self.assertRaisesRegex(RuntimeError, 'coverage.*limit'):
                self.prepare()
        self.assertFalse(any('blob' in argv and 'cat-file' in argv for argv, _ in self.calls))

    def test_total_limit_includes_serialized_artifacts(self):
        previous = Path.cwd()
        try:
            os.chdir(self.workspace)
            with patch('lib.runtime_review.source.MAX_TOTAL_BYTES', 500):
                with self.assertRaisesRegex(RuntimeError, 'coverage.*limit'):
                    self.prepare()
        finally:
            os.chdir(previous)

    def test_real_git_tree_materialization_keeps_executable_blobs_nonexecutable(self):
        fixture = self.workspace / 'fixture'
        fixture.mkdir()
        def fixture_git(*args):
            return subprocess.run(['git', '-C', str(fixture), *args], check=True, capture_output=True).stdout
        fixture_git('init', '-q')
        fixture_git('config', 'user.email', 'fixture@example.test')
        fixture_git('config', 'user.name', 'Fixture')
        (fixture / 'script.sh').write_text('#!/bin/sh\necho never-run\n')
        (fixture / 'script.sh').chmod(0o755)
        fixture_git('add', 'script.sh')
        fixture_git('update-index', '--chmod=+x', 'script.sh')
        fixture_git('commit', '-qm', 'fixture')
        head = fixture_git('rev-parse', 'HEAD').decode().strip()
        self.diff = fixture_git('show', '--format=', 'HEAD')
        self.metadata = [dict(META, headRefOid=head), dict(META, headRefOid=head)]
        real_run = subprocess.run
        def transport(argv, **kwargs):
            if argv[0] == 'gh':
                return self.controller(argv, **kwargs)
            if 'fetch' in argv:
                destination = Path(next(x.removeprefix('--git-dir=') for x in argv if x.startswith('--git-dir=')))
                shutil.copytree(fixture / '.git/objects', destination / 'objects', dirs_exist_ok=True)
                return subprocess.CompletedProcess(argv, 0, b'', b'')
            return real_run(argv, **kwargs)
        with patch('lib.runtime_review.source.subprocess.run', side_effect=transport):
            result = prepare_source('owner/repo#123', self.run)
        materialized = Path(result['cwd']) / 'script.sh'
        self.assertEqual(materialized.read_text(), '#!/bin/sh\necho never-run\n')
        self.assertEqual(materialized.stat().st_mode & 0o222, 0)
        self.assertEqual(materialized.stat().st_mode & 0o111, 0)

    def test_run_directory_escape_is_rejected_before_creation(self):
        outside = self.workspace / 'outside'
        outside.mkdir()
        (self.workspace / 'alias').symlink_to(outside, target_is_directory=True)
        self.run = self.workspace / 'alias/new-run'
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            self.prepare()
        self.assertFalse((outside / 'new-run').exists())

    def test_trusted_parent_instruction_hierarchy_is_captured(self):
        project = self.workspace / 'project'
        project.mkdir()
        (self.workspace / 'AGENTS.md').write_text('Parent convention')
        (project / 'CLAUDE.md').write_text('Project convention')
        previous = Path.cwd()
        try:
            os.chdir(project)
            result = self.prepare()
        finally:
            os.chdir(previous)
        conventions = json.loads(Path(next(x['path'] for x in result['inputs'] if x['name'] == 'conventions')).read_text())
        captured = [x for x in conventions['instructions'] if x['text'] in ('Parent convention', 'Project convention')]
        self.assertEqual([x['text'] for x in captured], ['Parent convention', 'Project convention'])
        self.assertTrue(all(x['trust'] == 'trusted-parent-context' for x in captured))
        self.assertLess(captured[0]['order'], captured[1]['order'])

    def test_user_checkout_fingerprint_is_preserved(self):
        checkout = self.workspace / 'checkout'
        checkout.mkdir()
        subprocess.run(['git', 'init', '-q', str(checkout)], check=True)
        (checkout / 'tracked').write_text('original')
        subprocess.run(['git', '-C', str(checkout), 'add', 'tracked'], check=True)
        (checkout / 'tracked').write_text('dirty')
        (checkout / 'untracked').write_text('untracked')
        (checkout / 'link').symlink_to('tracked')
        def fingerprint():
            return {str(path.relative_to(checkout)): ('link', os.readlink(path)) if path.is_symlink()
                    else ('file', path.read_bytes()) for path in checkout.rglob('*')
                    if path.is_symlink() or path.is_file()}
        before = fingerprint()
        previous = Path.cwd()
        try:
            os.chdir(checkout)
            self.prepare()
        finally:
            os.chdir(previous)
        self.assertEqual(fingerprint(), before)


class BridgeTests(unittest.TestCase):
    def test_bridge_resolves_relocated_package_and_original_relative_home(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            package = root / 'relocated package'
            (package / 'lib/runtime_review').mkdir(parents=True)
            shutil.copyfile(ROOT / 'lib/runtime-review.sh', package / 'lib/runtime-review.sh')
            shutil.copyfile(ROOT / 'lib/config.sh', package / 'lib/config.sh')
            # T4 supplies the real CLI. This stub checks the T3 Bash boundary only.
            (package / 'lib/runtime_review/cli.py').write_text('import json,sys; print(json.dumps(sys.argv[1:]))')
            invocation = root / 'invocation'
            invocation.mkdir()
            user_home = root / 'user'
            user_home.mkdir()
            env = {key: value for key, value in os.environ.items() if not key.startswith(('N1_', 'GIT_', 'PYTHON'))}
            env.update(HOME=str(user_home), CLAUDE_PLUGIN_ROOT='/wrong/root', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
            command = ['bash', str(package / 'lib/runtime-review.sh'), 'prepare', '--target', 'owner/repo#123']
            missing = subprocess.run(command, cwd=invocation, env=env, capture_output=True, text=True)
            self.assertEqual(missing.returncode, 2)
            self.assertIn('N1 home is not configured', missing.stderr)
            for home, filename, override in [('.n1', 'n1.config.json', False), ('relative space', 'config.json', True),
                                              (str(root / 'absolute home'), 'config.json', True)]:
                location = invocation / home
                location.mkdir(exist_ok=True)
                (location / filename).write_text('{}')
                current = dict(env)
                if override:
                    current['N1_HOME'] = home
                result = subprocess.run(command, cwd=invocation, env=current, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), ['--home', str(location), '--config-file',
                                  str(location / filename), 'prepare', '--target', 'owner/repo#123'])
            # An invocation checkout must not shadow the trusted bridge package.
            (invocation / 'lib').mkdir()
            (invocation / 'lib/__init__.py').write_text('raise RuntimeError("untrusted import executed")')
            result = subprocess.run(command, cwd=invocation, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_bridge_resolves_legacy_git_home_without_disabling_resolver_config(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            package = root / 'package'
            (package / 'lib/runtime_review').mkdir(parents=True)
            shutil.copyfile(ROOT / 'lib/runtime-review.sh', package / 'lib/runtime-review.sh')
            shutil.copyfile(ROOT / 'lib/config.sh', package / 'lib/config.sh')
            (package / 'lib/runtime_review/cli.py').write_text('import json,sys; print(json.dumps(sys.argv[1:]))')
            checkout = root / 'checkout'
            checkout.mkdir()
            subprocess.run(['git', 'init', '-q', str(checkout)], check=True)
            subprocess.run(['git', '-C', str(checkout), 'config', 'n1.home', 'legacy state'], check=True)
            env = {key: value for key, value in os.environ.items() if not key.startswith(('N1_', 'GIT_', 'PYTHON'))}
            env.update(HOME=str(root), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
            result = subprocess.run(['bash', str(package / 'lib/runtime-review.sh'), 'prepare'],
                                    cwd=checkout, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), ['--home', str(checkout / 'legacy state'),
                              '--config-file', str(checkout / 'legacy state/config.json'), 'prepare'])
