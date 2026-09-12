import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class LegacyFenceTests(unittest.TestCase):
    def test_production_bytes_unchanged(self):
        expected = json.loads((Path(__file__).with_name("legacy.json")).read_text())
        for relative, digest in expected["sha256"].items():
            with self.subTest(path=relative):
                self.assertEqual(
                    hashlib.sha256((ROOT / relative).read_bytes()).hexdigest(), digest
                )

    def test_advisory_semantics(self):
        text = (ROOT / "skills/n1-review/SKILL.md").read_text()
        self.assertIn("code-reviewer + security-reviewer", text)
        self.assertIn("Wait for ALL agents", text)
        self.assertIn("not the original reasoning", text)
        self.assertIn("Do NOT apply any fixes", text)

    def test_manifest_versions_are_paired(self):
        plugin = json.loads((ROOT / ".claude-plugin/plugin.json").read_text())
        marketplace = json.loads((ROOT / ".claude-plugin/marketplace.json").read_text())
        self.assertEqual(plugin["version"], marketplace["plugins"][0]["version"])

    def test_manifest_structure_unchanged(self):
        expected = json.loads((Path(__file__).with_name("legacy.json")).read_text())
        plugin = json.loads((ROOT / ".claude-plugin/plugin.json").read_text())
        marketplace = json.loads((ROOT / ".claude-plugin/marketplace.json").read_text())
        plugin.pop("version", None)
        marketplace["plugins"][0].pop("version", None)
        self.assertEqual(plugin, expected["manifests"]["plugin"])
        self.assertEqual(marketplace, expected["manifests"]["marketplace"])


if __name__ == "__main__":
    unittest.main()
