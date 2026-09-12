import json
import multiprocessing
import os
from pathlib import Path
import stat
from tempfile import TemporaryDirectory
import unittest
from uuid import UUID

from lib.runtime_review import store


def race_writer(run, ready, go, outcome):
    ready.put(True)
    go.wait(10)
    try:
        store.save_state(Path(run), {"generation": 2, "status": "reviewing", "eventIds": ["e1", "e2"]}, 1)
        outcome.put("saved")
    except ValueError:
        outcome.put("stale")


class StoreTests(unittest.TestCase):
    def test_runs_are_private_unique_uuid_directories_under_resolved_home(self):
        with TemporaryDirectory() as temp:
            home = Path(temp) / "home"
            home.mkdir()
            alias = Path(temp) / "alias"
            alias.symlink_to(home, target_is_directory=True)
            first, second = store.create_run(alias), store.create_run(alias)
            self.assertNotEqual(first, second)
            self.assertEqual(first.parent, home / "scratch" / "reviews")
            self.assertEqual(UUID(first.name).version, 4)
            self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o700)
            self.assertTrue((first / "requests").is_dir())
            self.assertTrue((first / "results").is_dir())

    def test_stale_writer_fails(self):
        with TemporaryDirectory() as temp:
            run = store.create_run(Path(temp))
            store.save_state(run, {"generation": 1, "status": "pending"}, expected_generation=0)
            with self.assertRaisesRegex(ValueError, "generation"):
                store.save_state(run, {"generation": 1, "status": "completed"}, expected_generation=0)
            self.assertEqual(json.loads((run / "state.json").read_text()), {"generation": 1, "status": "pending"})

    def test_concurrent_writers_accept_exactly_one_event(self):
        with TemporaryDirectory() as temp:
            run = store.create_run(Path(temp))
            store.save_state(run, {"generation": 1, "status": "reviewing", "eventIds": ["e1"]}, 0)
            ctx = multiprocessing.get_context("fork")
            ready, outcome, go = ctx.Queue(), ctx.Queue(), ctx.Event()
            workers = [ctx.Process(target=race_writer, args=(str(run), ready, go, outcome)) for _ in range(2)]
            for worker in workers:
                worker.start()
            for _ in workers:
                self.assertTrue(ready.get(timeout=10))
            go.set()
            results = [outcome.get(timeout=10) for _ in workers]
            for worker in workers:
                worker.join(10)
                self.assertEqual(worker.exitcode, 0)
            self.assertEqual(sorted(results), ["saved", "stale"])
            self.assertEqual(json.loads((run / "state.json").read_text())["generation"], 2)

    def test_terminal_state_and_event_history_cannot_be_rewritten(self):
        with TemporaryDirectory() as temp:
            run = store.create_run(Path(temp))
            store.save_state(run, {"generation": 1, "status": "failed", "eventIds": ["e1"]}, 0)
            for state in [
                {"generation": 2, "status": "reviewing", "eventIds": ["e1", "e2"]},
                {"generation": 2, "status": "failed", "eventIds": ["e1", "e1"]},
                {"generation": 2, "status": "failed", "eventIds": ["replaced", "e2"]},
                {"generation": 3, "status": "failed", "eventIds": ["e1", "e2"]},
            ]:
                with self.subTest(state=state), self.assertRaises(ValueError):
                    store.save_state(run, state, 1)
            store.save_state(run, {"generation": 2, "status": "failed", "eventIds": ["e1", "e2"]}, 1)

    def test_run_resolution_rejects_foreign_paths_symlinks_and_state_symlinks(self):
        with TemporaryDirectory() as temp:
            home = Path(temp)
            run = store.create_run(home)
            self.assertEqual(store.resolve_run(home, run.name), run)
            for value in (str(run), "../outside", "run-1", "00000000-0000-4000-8000-000000000000"):
                with self.subTest(value=value), self.assertRaises(ValueError):
                    store.resolve_run(home, value)
            outside = home / "outside"
            outside.write_text("untouched")
            (run / "state.json").symlink_to(outside)
            with self.assertRaises((ValueError, OSError)):
                store.save_state(run, {"generation": 1, "status": "pending"}, 0)
            self.assertEqual(outside.read_text(), "untouched")

    def test_symlinked_scratch_root_is_rejected(self):
        with TemporaryDirectory() as temp:
            home = Path(temp) / "home"
            outside = Path(temp) / "outside"
            home.mkdir()
            outside.mkdir()
            (home / "scratch").symlink_to(outside, target_is_directory=True)
            with self.assertRaises((ValueError, OSError)):
                store.create_run(home)
            self.assertEqual(list(outside.iterdir()), [])
