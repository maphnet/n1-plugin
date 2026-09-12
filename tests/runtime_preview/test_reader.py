import os
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from lib.runtime_review.reader import read_file, search_files


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

    def test_script_accepts_only_bound_operation_root_and_one_value(self):
        script = Path(__file__).resolve().parents[2] / 'lib/runtime_review/reader.py'
        result = subprocess.run(['python3', str(script), 'read', str(self.root), 'real.txt'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), 'literal .*\nsecond literal .*\n')
        for args in (['read', str(self.root), '../secret'], ['read', str(self.root), 'real.txt', 'extra'],
                     ['exec', str(self.root), 'real.txt']):
            with self.subTest(args=args):
                result = subprocess.run(['python3', str(script), *args], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, '')
