import copy
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "collectors" / "gauntlet" / "validate_observation.py"
SPEC = importlib.util.spec_from_file_location("validate_observation", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
FIXTURE = ROOT / "packages" / "contracts" / "fixtures" / "insimul-current-lanes.json"


class ObservationContractTests(unittest.TestCase):
    def fixture(self):
        return json.loads(FIXTURE.read_text())

    def test_every_contract_is_parseable_and_versioned(self):
        expected = {
            "loop-run.schema.json": "chief.loop-run/v1",
            "lane.schema.json": "chief.lane/v1",
            "stage.schema.json": "chief.stage/v1",
            "round.schema.json": "chief.round/v1",
            "native-session.schema.json": "chief.native-session/v1",
            "finding.schema.json": "chief.finding/v1",
            "operator-decision.schema.json": "chief.operator-decision/v1",
            "evidence.schema.json": "chief.evidence/v1",
            "normalized-event.schema.json": "chief.normalized-event/v1",
        }
        for name, version in expected.items():
            schema = json.loads((ROOT / "packages" / "contracts" / name).read_text())
            self.assertEqual(schema["properties"]["schemaVersion"]["const"], version, name)
            self.assertEqual(schema["$schema"], "https://json-schema.org/draft/2020-12/schema")

    def test_reference_fixture_validates(self):
        self.assertEqual(MODULE.validate(self.fixture()), [])

    def test_reference_fixture_preserves_reported_state(self):
        data = self.fixture()
        lanes = {lane["id"]: lane for lane in data["lanes"]}
        asset_stages = {stage["id"]: stage for stage in lanes["assets"]["stages"]}
        ui_stages = {stage["id"]: stage for stage in lanes["unreal-ui"]["stages"]}
        self.assertEqual(list(asset_stages), ["B0", "B1", "B2", "B3", "B4", "B5", "B7", "B8"])
        self.assertEqual(list(ui_stages), ["E0", "E1", "E3", "E2", "E4", "E4b", "E5", "E6", "E7", "E3b", "acceptance-games", "D1"])
        self.assertEqual((lanes["assets"]["progress"]["completed"], lanes["assets"]["progress"]["total"]), (6, 8))
        self.assertEqual((lanes["unreal-ui"]["progress"]["completed"], lanes["unreal-ui"]["progress"]["total"]), (4, 12))
        self.assertEqual(asset_stages["B7"]["roundSummary"], {"observed": 4, "void": 0, "current": 5, "cap": 5})
        self.assertEqual(ui_stages["E4"]["roundSummary"], {"observed": 3, "void": 0, "current": 4, "cap": 5})
        self.assertEqual(ui_stages["E2"]["status"], "capped")
        self.assertEqual(ui_stages["E5"]["dependsOn"], [{"laneId": "assets", "stageId": "B8"}])
        self.assertFalse(data["runtime"]["pausedSecondsKnown"])
        self.assertEqual(data["operatorDecisions"][0]["status"], "pending")

    def test_bad_progress_and_broken_dependency_are_rejected(self):
        data = copy.deepcopy(self.fixture())
        data["lanes"][0]["progress"]["completed"] = 8
        data["lanes"][1]["stages"][6]["dependsOn"][0]["stageId"] = "missing"
        errors = MODULE.validate(data)
        self.assertTrue(any("completed count" in error for error in errors), errors)
        self.assertTrue(any("unknown stage" in error for error in errors), errors)

    def test_unknown_contract_field_is_rejected(self):
        data = self.fixture()
        data["nativeSessions"][0]["madeUpState"] = True
        self.assertTrue(any("unknown property madeUpState" in error for error in MODULE.validate(data)))


if __name__ == "__main__":
    unittest.main()
