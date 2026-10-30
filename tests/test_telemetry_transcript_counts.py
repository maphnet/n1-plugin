"""Run records bracket every step and match transcript call counts (N1-229)."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLOSE = '2026-01-01T00:04:01Z'


def _msg(mid, ts, tools=(), model='claude-opus-5-5'):
    content = [dict(type='tool_use', id=tid, name=name, input={}) for tid, name in tools]
    usage = dict(input_tokens=10, output_tokens=1, cache_read_input_tokens=100,
                 cache_creation_input_tokens=5)
    return dict(type='assistant', timestamp=ts,
                message=dict(id=mid, model=model, usage=usage, content=content))


def build(base, model='claude-opus-5-5'):
    """Fixture run: ticket begin lost, zero-width finish, two calls after the close."""
    transcript = base / 'session.jsonl'
    rows = [
        dict(type='user', timestamp='2026-01-01T00:00:10.000Z', message=dict(role='user', content='go')),
        _msg('m1', '2026-01-01T00:00:30.000Z', model=model),                      # streamed copy 1
        _msg('m1', '2026-01-01T00:00:30.000Z', [('t1', 'Bash')], model=model),    # streamed copy 2
        _msg('m2', '2026-01-01T00:00:45.000Z', [('t2', 'Read'), ('t3', 'Agent')], model=model),
        _msg('m3', '2026-01-01T00:01:30.000Z', model=model),                      # between windows
        _msg('m4', '2026-01-01T00:02:30.000Z', [('t4', 'Bash'), ('t5', 'Edit')], model=model),
        _msg('m5', '2026-01-01T00:04:30.000Z', [('t6', 'Bash')], model=model),    # Gate 3 / chain
        _msg('m6', '2026-01-01T00:05:00.000Z', model='<synthetic>'),
    ]
    transcript.write_text(''.join(json.dumps(r) + '\n' for r in rows))
    (base / 'raw/steps').mkdir(parents=True, exist_ok=True)
    events = [
        dict(layer='envelope', run_id='run', host='claude-code', session_id='s',
             session_transcript_path=str(transcript), started_at='2026-01-01T00:00:00Z'),
        dict(layer='step', step='ticket', step_number=1,
             completed_at='2026-01-01T00:01:00Z', outcome='success'),               # begin lost
        dict(layer='step', step='plan', step_number=4, started_at='2026-01-01T00:02:00Z'),
        dict(layer='step', step='plan', step_number=4,
             completed_at='2026-01-01T00:03:00Z', outcome='success'),
        dict(layer='step', step='finish', step_number=14, started_at='2026-01-01T00:04:00Z'),
        dict(layer='step', step='finish', step_number=14,
             completed_at='2026-01-01T00:04:00Z', outcome='success'),
        dict(layer='envelope_close', run_id='run', completed_at=CLOSE, final_outcome='pr_created'),
    ]
    (base / 'raw/steps/run.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in events))
    subprocess.run(['python3', str(ROOT / 'hooks/telemetry-merge.py'), 'run', str(base)], check=True)
    return transcript, json.loads((base / 'runs/run.jsonl').read_text())


class StepWindowTest(unittest.TestCase):
    def test_missing_begin_and_zero_width_finish_are_bracketed(self):
        with tempfile.TemporaryDirectory() as tmp:
            _, row = build(Path(tmp))
            steps = {s['step']: s for s in row['steps']}
            self.assertEqual(steps['ticket']['started_at'], '2026-01-01T00:00:00Z')
            self.assertTrue(steps['ticket']['window_inferred'])
            self.assertEqual(steps['ticket']['duration_s'], 60)
            self.assertNotIn('window_inferred', steps['plan'])
            self.assertEqual(steps['finish']['completed_at'], '2026-01-01T00:05:00.000Z')
            self.assertTrue(steps['finish']['window_extended'])
            self.assertEqual(steps['finish']['duration_s'], 60)
            orch = {s['step']: s for s in row['orchestrator']['steps']}
            self.assertEqual(orch['ticket']['api_calls'], 2)
            self.assertEqual(orch['finish']['api_calls'], 2)
            self.assertEqual(row['orchestrator']['unattributed']['api_calls'], 1)


if __name__ == '__main__':
    unittest.main()
