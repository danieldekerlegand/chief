import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from collectors.observers.base import CommandResult
from collectors.observers.chief import ChiefAdapter
from collectors.observers.claude import ClaudeAdapter
from collectors.observers.codex import CodexAdapter
from collectors.observers.collect import collect
from collectors.observers.git import GitAdapter
from collectors.observers.tracker import TrackerAdapter

NOW = datetime(2026, 10, 21, 12, 0, tzinfo=timezone.utc)


class ClaudeAdapterTest(unittest.TestCase):
    def test_projects_native_inventory_without_mutating_it(self):
        calls = []

        def runner(argv):
            calls.append(tuple(argv))
            return CommandResult(0, json.dumps([
                {"sessionId": "abc", "name": "asset-builder", "cwd": "/work/assets",
                 "status": "busy", "kind": "background", "pid": 42,
                 "startedAt": 1792570280649},
                {"sessionId": "done", "status": "completed"},
            ]))

        batch = ClaudeAdapter(runner).collect(NOW)
        self.assertEqual(calls, [("claude", "agents", "--json", "--all")])
        self.assertEqual(batch.status, "ok")
        self.assertEqual([x.status for x in batch.observations], ["active", "complete"])
        record = batch.observations[0].to_dict()
        self.assertEqual(record["projectPath"], "/work/assets")
        self.assertEqual(record["attributes"]["pid"], 42)
        self.assertEqual(record["freshness"]["state"], "fresh")

    def test_bad_json_is_degraded_not_empty_success(self):
        batch = ClaudeAdapter(lambda _: CommandResult(0, "not json")).collect(NOW)
        self.assertEqual(batch.status, "degraded")
        self.assertEqual(batch.observations, [])

    def test_stopped_session_is_not_reported_complete(self):
        batch = ClaudeAdapter(lambda _: CommandResult(0, json.dumps([
            {"sessionId": "stopped", "status": "stopped"}
        ]))).collect(NOW)
        self.assertEqual(batch.observations[0].status, "gone")
        self.assertEqual(batch.observations[0].to_native_session()["status"], "stopped")


class CodexAdapterTest(unittest.TestCase):
    def test_index_is_discoverable_but_never_claimed_live(self):
        with tempfile.TemporaryDirectory() as raw:
            home = Path(raw)
            (home / "thread-writer-locks").mkdir()
            (home / "thread-writer-locks" / "c1.lock").write_text("")
            (home / "session_index.jsonl").write_text(
                '{"id":"c1","thread_name":"migration","updated_at":"2026-10-21T11:59:30Z"}\n'
                'malformed\n'
            )
            batch = CodexAdapter(home, stale_seconds=60).collect(NOW)
        self.assertEqual(batch.status, "degraded")
        self.assertFalse(batch.capabilities["liveness"])
        self.assertEqual(len(batch.observations), 1)
        record = batch.observations[0].to_dict()
        self.assertEqual(record["status"], "unknown")
        self.assertTrue(record["attributes"]["writerLockObserved"])
        self.assertEqual(record["attributes"]["liveness"], "unknown")
        self.assertTrue(any("malformed JSON" in issue for issue in batch.issues))


class ChiefAdapterTest(unittest.TestCase):
    def test_reads_registry_and_events_and_cross_checks_liveness(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            events = root / "insimul-7.events.jsonl"
            events.write_text(
                json.dumps({"schema": "chief.event/1", "runId": "insimul-7", "ts": "2026-10-21T11:59:00Z",
                            "event": "run.started", "state": "running"}) + "\n" +
                json.dumps({"schema": "chief.event/1", "runId": "insimul-7", "ts": "2026-10-21T11:59:30Z",
                            "event": "tasklist.launched", "state": "running", "name": "ui"}) + "\n"
            )
            (root / "42.run").write_text(
                f"repo=/work/insimul\nprovider=claude\nstarted=1792583940\n"
                f"events={events}\nrunid=insimul-7\nnames=assets ui\nparallel=2\n"
            )
            batch = ChiefAdapter(root, alive=lambda pid: pid == 42).collect(NOW)
        run = next(item for item in batch.observations if item.kind == "legacy-run")
        self.assertEqual(run.status, "active")
        self.assertEqual(run.attributes["tasklists"], ["assets", "ui"])
        self.assertEqual(run.attributes["processAlive"], True)
        events_seen = [item for item in batch.observations if item.kind == "activity-event"]
        self.assertEqual(len(events_seen), 2)
        self.assertTrue(all(item.attributes["hasRegistryEntry"] for item in events_seen))

    def test_dead_registry_process_is_gone_without_terminal_event(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "99.run").write_text("repo=/work/x\nrunid=x-99\n")
            batch = ChiefAdapter(root, alive=lambda _: False).collect(NOW)
        self.assertEqual(batch.observations[0].status, "gone")


class TrackerAdapterTest(unittest.TestCase):
    def test_reads_json_and_leaves_markdown_status_unknown(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            run = root / "asset"
            run.mkdir()
            (run / "state.json").write_text(json.dumps({
                "id": "asset-lane", "title": "Assets", "status": "running", "progress": 75,
                "updatedAt": "2026-10-21T11:59:30Z", "stage": "B7", "round": 5,
            }))
            (run / "RUNNING.md").write_text("# Asset gauntlet\n\nCurrent details in prose.\n")
            batch = TrackerAdapter([root], stale_seconds=60).collect(NOW)
        states = {item.kind: item for item in batch.observations}
        self.assertEqual(states["tracker-state"].status, "active")
        self.assertEqual(states["tracker-state"].attributes["stage"], "B7")
        self.assertEqual(states["tracker-document"].status, "unknown")

    def test_human_status_requires_an_explicit_lifecycle_phrase(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            for name, status in {
                "done": "CLOSED 2026-10-14 by the operator",
                "live": "Unreal is priority; run resumed 2026-10-21",
                "decision": "One decision needed from the operator before the waves resume",
                "ambiguous": "Two stages passed; the other lanes are PAUSED",
            }.items():
                folder = root / name
                folder.mkdir()
                (folder / "state.json").write_text(json.dumps({"id": name, "status": status}))
            batch = TrackerAdapter([root]).collect(NOW)
        statuses = {item.title: item.status for item in batch.observations}
        self.assertEqual(statuses, {
            "ambiguous": "unknown", "decision": "blocked", "done": "complete", "live": "active",
        })


class GitAdapterTest(unittest.TestCase):
    def test_discovers_repo_and_worktrees_without_assigning_liveness(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            repo = root / "insimul"
            (repo / ".git").mkdir(parents=True)
            other = root / "wt-ui"
            other.mkdir()

            def runner(argv):
                args = tuple(argv[3:])
                cwd = argv[2]
                if args[:2] == ("log", "-1"):
                    return CommandResult(0, "2026-10-21T11:00:00+00:00\x00abc123\x00work")
                if args == ("branch", "--show-current"):
                    return CommandResult(0, "main\n")
                if args == ("status", "--short"):
                    return CommandResult(0, " M file\n" if cwd == str(other) else "")
                if args == ("worktree", "list", "--porcelain"):
                    return CommandResult(0, f"worktree {repo}\nHEAD abc123\nbranch refs/heads/main\n\n"
                                            f"worktree {other}\nHEAD def456\nbranch refs/heads/ui\n\n")
                return CommandResult(1, "", "unexpected")

            batch = GitAdapter([root], runner=runner).collect(NOW)
        self.assertEqual(batch.status, "ok")
        kinds = [item.kind for item in batch.observations]
        self.assertEqual(kinds.count("repository"), 1)
        self.assertEqual(kinds.count("worktree"), 2)
        ui = next(item for item in batch.observations if item.worktree_path == str(other))
        self.assertEqual(ui.status, "unknown")
        self.assertEqual(ui.attributes["dirtyFiles"], 1)


class CollectionTest(unittest.TestCase):
    def test_combines_batches_under_one_observation_time(self):
        class Fake:
            name = "fake"

            def collect(self, now=None):
                from collectors.observers.base import ObservationBatch
                return ObservationBatch(self.name, now)

        result = collect([Fake()])
        self.assertEqual(result["schema"], "chief.observation-collection/1")
        self.assertEqual(result["summary"], {"adapters": 1, "records": 0, "degraded": 0, "unavailable": 0})

    def test_emits_portable_session_contract_without_inventing_a_link(self):
        adapter = ClaudeAdapter(lambda _: CommandResult(0, json.dumps([
            {"sessionId": "native-1", "status": "busy", "cwd": "/work/project"}
        ])))
        result = collect([adapter])
        self.assertEqual(len(result["nativeSessions"]), 1)
        session = result["nativeSessions"][0]
        self.assertEqual(session["schemaVersion"], "chief.native-session/v1")
        self.assertEqual(session["provider"], "claude")
        self.assertEqual(session["status"], "active")
        self.assertEqual(session["links"], [])


if __name__ == "__main__":
    unittest.main()
