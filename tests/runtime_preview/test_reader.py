import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from lib.runtime_review.reader import read_file, reader_main, search_files


class ReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'real.txt').write_text('literal .*\nsecond literal .*\n')

    def test_reads_regular_utf8_and_searches_literals_with_line_numbers(self):
        self.assertEqual(read_file(self.root, 'real.txt'), 'literal .*\nsecond literal .*\n')
        self.assertEqual(search_files(self.root, '.*'), [
            {'file': 'real.txt', 'line': 1, 'text': 'literal .*'},
            {'file': 'real.txt', 'line': 2, 'text': 'second literal .*'},
        ])

    def test_rejects_escape_git_and_nonregular_files(self):
        (self.root / '.git').mkdir()
        (self.root / '.git/config').write_text('secret')
        os.mkfifo(self.root / 'fifo')
        for name in ('../secret', '/etc/passwd', '', '.', 'a/../real.txt',
                     '.git/config', 'missing', 'fifo', 'x\x00y'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                read_file(self.root, name)

    def test_rejects_leaf_and_parent_symlinks(self):
        (self.root / 'link').symlink_to(self.root / 'real.txt')
        (self.root / 'directory').symlink_to(self.root, target_is_directory=True)
        for name in ('link', 'directory/real.txt'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                read_file(self.root, name)

    def test_search_does_not_follow_symlinks_or_git(self):
        (self.root / 'link').symlink_to('/etc')
        (self.root / '.git').mkdir()
        (self.root / '.git/config').write_text('literal')
        (self.root / 'binary').write_bytes(b'\x00literal')
        self.assertEqual(len(search_files(self.root, 'literal')), 2)

    def test_explicit_file_search_byte_and_match_overflow(self):
        with patch('lib.runtime_review.reader.MAX_FILE_BYTES', 4):
            with self.assertRaisesRegex(ValueError, 'limit'):
                read_file(self.root, 'real.txt')
        with patch('lib.runtime_review.reader.MAX_TOTAL_BYTES', 4):
            with self.assertRaisesRegex(ValueError, 'limit'):
                search_files(self.root, 'absent')
        with patch('lib.runtime_review.reader.MAX_MATCHES', 1):
            with self.assertRaisesRegex(ValueError, 'limit'):
                search_files(self.root, 'literal')

    def test_binary_read_and_empty_search_are_explicit_errors(self):
        (self.root / 'binary').write_bytes(b'\x00abc')
        with self.assertRaisesRegex(ValueError, 'binary'):
            read_file(self.root, 'binary')
        with self.assertRaises(ValueError):
            search_files(self.root, '')

    def policy_environment(self):
        inputs = self.root / 'inputs'
        inputs.mkdir(exist_ok=True)
        artifact = inputs / 'diff'
        artifact.write_text('prepared diff')
        artifact.chmod(0o400)
        policy = self.root / 'worker-policy.json'
        payload = {'schemaVersion': 1, 'sourceRoot': str(self.root),
                   'allowedInputPaths': [str(artifact)]}
        raw = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
        policy.write_bytes(raw)
        policy.chmod(0o400)
        return {'N1_REVIEW_POLICY': str(policy),
                'N1_REVIEW_POLICY_DIGEST': hashlib.sha256(raw).hexdigest()}, policy

    def test_script_accepts_only_policy_bound_operation_and_one_value(self):
        """Would fail if workers could choose a root or read an input absent from controller policy."""
        script = Path(__file__).resolve().parents[2] / 'lib/runtime_review/reader.py'
        environment, _ = self.policy_environment()
        result = subprocess.run(['python3', str(script), 'read', 'real.txt'],
                                capture_output=True, text=True, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), 'literal .*\nsecond literal .*\n')
        result = subprocess.run(['python3', str(script), 'read', 'inputs/diff'],
                                capture_output=True, text=True, env=environment)
        self.assertEqual(json.loads(result.stdout), 'prepared diff')
        for args in (['read', '/etc/passwd'], ['read', 'worker-policy.json'],
                     ['read', 'real.txt', 'extra'],
                     ['exec', 'real.txt'], ['read', '../inputs/diff']):
            with self.subTest(args=args):
                result = subprocess.run(['python3', str(script), *args], capture_output=True,
                                        text=True, env=environment)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, '')

    def test_worker_reader_rejects_missing_malformed_or_altered_policy(self):
        """Would fail if an attacker could replace the controller's path policy."""
        environment, policy = self.policy_environment()
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(reader_main(['read', 'real.txt']), 2)
        with patch.dict(os.environ, {**environment, 'N1_REVIEW_POLICY_DIGEST': '0' * 64}, clear=True):
            self.assertEqual(reader_main(['read', 'real.txt']), 2)
        policy.chmod(0o600)
        malformed = b'{"sourceRoot":"/"}'
        policy.write_bytes(malformed)
        policy.chmod(0o400)
        malformed_environment = {**environment,
            'N1_REVIEW_POLICY_DIGEST': hashlib.sha256(malformed).hexdigest()}
        with patch.dict(os.environ, malformed_environment, clear=True):
            self.assertEqual(reader_main(['read', 'real.txt']), 2)

    def test_worker_search_never_discloses_policy_inside_source_root(self):
        """Would fail if bounded search treated the controller policy as review source."""
        script = Path(__file__).resolve().parents[2] / 'lib/runtime_review/reader.py'
        environment, _ = self.policy_environment()
        result = subprocess.run(
            ['python3', str(script), 'search', '"schemaVersion"'],
            capture_output=True, text=True, env=environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])
