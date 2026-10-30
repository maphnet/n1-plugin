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

class TranscriptCountTest(unittest.TestCase):
    def test_record_counts_match_transcript(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript, row = build(Path(tmp))
            # Independent count from the fixture file: one API call per message id,
            # one tool call per non-Agent tool_use block id (streamed copies collapse).
            recs = [json.loads(line) for line in transcript.read_text().splitlines()]
            asst = [r for r in recs if r.get('type') == 'assistant']
            ids = {r['message']['id'] for r in asst}
            tools = {b['id'] for r in asst for b in r['message']['content']
                     if b.get('type') == 'tool_use' and b['name'] != 'Agent'}
            late = {r['message']['id'] for r in asst if r['timestamp'][:19] > CLOSE[:19]}
            orch = row['orchestrator']
            self.assertEqual(orch['totals']['api_calls'], len(ids))
            self.assertEqual(orch['totals']['tool_calls'], len(tools))
            parts = orch['steps'] + [orch['unattributed']]
            self.assertEqual(sum(p['api_calls'] for p in parts), orch['totals']['api_calls'])
            self.assertEqual(sum(p['tool_calls'] for p in parts), orch['totals']['tool_calls'])
            # The tail is a named subset of the finish step and of totals, never additive.
            self.assertEqual(orch['tail']['api_calls'], len(late))
            finish = next(s for s in orch['steps'] if s['step'] == 'finish')
            self.assertEqual(finish['api_calls'], len(late))
            self.assertEqual(orch['model'], 'claude-opus-5-5')
            self.assertEqual(orch['context_window'], 1000000)
            self.assertEqual(orch['transcript_path'], str(transcript))

    def test_unknown_model_has_no_context_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            _, row = build(Path(tmp), model='claude-haiku-9')
            self.assertEqual(row['orchestrator']['model'], 'claude-haiku-9')
            self.assertIsNone(row['orchestrator']['context_window'])


if __name__ == '__main__':
    unittest.main()
