"""Run totals include parent exactly once, and never fabricate missing usage."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RunTotalsTest(unittest.TestCase):
    def test_parent_and_child_and_missing_usage(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / 'raw/steps').mkdir(parents=True)
            (base / 'raw/agents').mkdir()
            parent = base / 'parent.jsonl'
            child = base / 'parent/subagents/agent-a.jsonl'
            child.parent.mkdir(parents=True)
            def transcript(path, count):
                msg = dict(type='assistant', message=dict(id='message-1', usage=dict(
                    input_tokens=count, output_tokens=2, cache_read_input_tokens=4,
                    cache_creation_input_tokens=3), content=[]))
                path.write_text(json.dumps(msg) + '\n' + json.dumps(msg) + '\n')
            transcript(parent, 10)
            transcript(child, 20)
            # The last streamed copy owns usage; duplicated IDs still count once.
            records = [json.loads(line) for line in parent.read_text().splitlines()]
            records[0]['message']['usage']['input_tokens'] = 1
            parent.write_text(''.join(json.dumps(row)+'\n' for row in records))
            opening = dict(layer='envelope', host='claude-code', session_id='root',
                           session_transcript_path=str(parent))
            (base / 'raw/steps/run.jsonl').write_text(json.dumps(opening)+'\n')
            events = [dict(event='stop', agent_id='a', agent_type='n1:developer', transcript_path=str(child))]
            (base / 'raw/agents/run.jsonl').write_text(json.dumps(events[0])+'\n')
            def merge():
                subprocess.run(['python3', str(ROOT/'hooks/telemetry-merge.py'), 'run', str(base)], check=True)
                return json.loads((base/'runs/run.jsonl').read_text())
            row = merge()
            self.assertEqual(row['summary']['total_input_tokens'], 44)  # 30 fresh + 8 read + 6 write
            self.assertEqual(row['summary']['total_output_tokens'], 4)
            self.assertEqual(row['summary']['total_tokens'], 48)
            self.assertEqual(row['usage_scope'], 'session-tree')
            parent.write_text(json.dumps(dict(type='assistant', message=dict(id='missing-usage'))) + '\n')
            self.assertIsNone(merge()['summary']['total_input_tokens'])
            transcript(parent, 10)
            child.unlink()
            row = merge()
            self.assertEqual(row['usage_status'], 'partial')
            self.assertIsNone(row['summary']['total_input_tokens'])
            opening.update(host='codex', session_transcript_path=None)
            (base/'raw/steps/run.jsonl').write_text(json.dumps(opening)+'\n')
            row = merge()
            self.assertIsNone(row['summary']['total_input_tokens'])
            self.assertIsNone(row['summary']['cache_efficiency'])


if __name__ == '__main__':
    unittest.main()
