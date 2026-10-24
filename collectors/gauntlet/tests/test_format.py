import importlib.util, json, tempfile, unittest
from pathlib import Path
P = Path(__file__).resolve().parents[1] / "format.py"
S = importlib.util.spec_from_file_location("gauntlet_format", P); M = importlib.util.module_from_spec(S); S.loader.exec_module(M)

class FormatTests(unittest.TestCase):
    def definition(self):
        return {"schemaVersion":"chief.gauntlet/v1","id":"demo","project":"demo","goal":"Ship",
            "approval":"granted","modules":[{"id":"m1","title":"Build","description":"Build it","acceptance":["Tests pass"],"harness":{"provider":"codex"}}],
            "critics":[{"id":"code","rubric":"Correct","freshContext":True}],"stopRule":{"cleanWaves":2,"maxWaves":5,"stallWaves":3}}
    def test_renders_existing_chief_gen_contract(self):
        data=self.definition(); self.assertEqual(M.validate(data), [])
        item=M.render(data)["phases"][0]["items"][0]
        self.assertIn("Tests pass", item["description"]); self.assertIn("codex", item["description"])
    def test_refuses_unapproved_definition(self):
        data=self.definition(); data["approval"]="required"
        self.assertTrue(any("approval" in e for e in M.validate(data)))

if __name__ == "__main__": unittest.main()
