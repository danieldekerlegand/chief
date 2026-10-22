import json
import tempfile
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from collect import external_runs, gauntlet_compendium, link_gauntlet_runs, loop_run_manifests, roadmap_items, research_sources, tracker_runs
from collectors.gauntlet.validate_observation import validate

class CollectorTests(unittest.TestCase):
    def test_roadmap_statuses(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "ROADMAP.md").write_text("| Status | Milestone |\n|---|---|\n| ✅ | Shipped |\n| 🚧 | Building |\n| ⬜ | Later |\n")
            items, _ = roadmap_items(root, "demo", ["ROADMAP.md"])
            self.assertEqual([x["status"] for x in items], ["complete", "active", "planned"])

    def test_tracker_is_optional_and_computes_milestones(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); loop = root / "loop"; loop.mkdir()
            (loop / "state.json").write_text(json.dumps({"title":"Loop","status":"running","milestones":[{"status":"done"},{"status":"queued"}]}))
            runs = tracker_runs(root)
            self.assertEqual(runs[0]["progress"], 50)
            self.assertEqual(runs[0]["status"], "active")

    def test_private_run_and_research_manifests(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); (root / "runs").mkdir(); (root / "sources").mkdir()
            (root / "runs" / "one.json").write_text(json.dumps({"updated":"now","runs":[{"id":"r","title":"Run","status":"paused","source":"x"}]}))
            (root / "sources" / "one.json").write_text(json.dumps({"id":"s","coverage":{"discovered":3,"analyzed":1},"items":[{"id":"v","title":"Video","analysis":{"status":"reviewed","lessons":["L"],"actions":["A"]}}]}))
            self.assertIsNone(external_runs(root, "runs/*.json")[0]["progress"])
            sources, research = research_sources(root, "sources/*.json")
            self.assertIn("discovered=3", sources[0]["message"])
            self.assertEqual(research[0]["actions"], ["A"])

    def test_gauntlet_compendium_keeps_proposals_unscheduled(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); path = root / "README.md"
            path.write_text("### demo\n| Loop | What it does | Completed? |\n|---|---|---|\n| [Do it](demo.md#do-it)<br>*proposed* | Fix it. | Not started (shrunk, priority now) |\n")
            loops = gauntlet_compendium(path)
            self.assertEqual(len(loops), 1)
            self.assertEqual(loops[0]["status"], "proposed")
            self.assertTrue(loops[0]["approvalRequired"])
            self.assertEqual(loops[0]["priority"], "now")

    def test_gauntlet_status_does_not_call_not_completed_complete(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "README.md"
            path.write_text("### demo\n| Loop | What it does | Completed? |\n|---|---|---|\n| [Stopped](existing.md#stopped)<br>*existing* | Tried. | Not completed (stopped) |\n")
            self.assertEqual(gauntlet_compendium(path)[0]["status"], "incomplete")

    def test_gauntlet_links_matching_live_run(self):
        loops=[{"id":"x","project":"insimul","title":"Insimul Unreal Round"}]
        runs=[{"id":"run:x","project":"insimul","title":"Insimul Unreal Round","status":"active","progress":40,"source":"tracker"}]
        link_gauntlet_runs(loops, runs)
        self.assertEqual(loops[0]["linkedRuns"], ["run:x"])
        self.assertEqual(loops[0]["live"]["progress"], 40)

    def test_loop_run_manifest(self):
        with tempfile.TemporaryDirectory() as d:
            source=Path(__file__).resolve().parents[3]/'packages/contracts/fixtures/insimul-current-lanes.json'
            root=Path(d); (root/'runs').mkdir(); (root/'runs'/'x.json').write_text(source.read_text())
            imported=loop_run_manifests(root,'runs/*.json')[0]
            self.assertEqual(imported['id'],'insimul:dual-native-lanes-2026-10-17')
            self.assertEqual(validate(imported), [])

    def test_invalid_canonical_loop_run_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); (root/'runs').mkdir(); (root/'runs'/'x.json').write_text(json.dumps({"schemaVersion":"chief.loop-run/v1","id":"x","lanes":[]}))
            self.assertEqual(loop_run_manifests(root,'runs/*.json'),[])

if __name__ == "__main__": unittest.main()
