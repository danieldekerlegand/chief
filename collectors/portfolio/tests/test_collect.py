import json
import tempfile
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from collect import external_runs, roadmap_items, research_sources, tracker_runs

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
            (root / "sources" / "one.json").write_text(json.dumps({"id":"s","coverage":{"discovered":3,"analyzed":1}}))
            self.assertIsNone(external_runs(root, "runs/*.json")[0]["progress"])
            self.assertIn("discovered=3", research_sources(root, "sources/*.json")[0]["message"])

if __name__ == "__main__": unittest.main()
