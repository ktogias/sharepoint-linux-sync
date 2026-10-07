# SPDX-License-Identifier: Apache-2.0

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts" / "validate-config.py"
EXAMPLE = ROOT / "config" / "projects.example.json"


class ConfigTests(unittest.TestCase):
    def test_example_is_valid_json(self) -> None:
        data = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        self.assertIsInstance(data, list)
        self.assertGreaterEqual(len(data), 1)

    def test_example_passes_validator(self) -> None:
        result = subprocess.run(
            [sys.executable, str(VALIDATOR), str(EXAMPLE)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_skip_forbidden_must_be_boolean(self) -> None:
        data = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        data[0]["skipForbidden"] = "yes"
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "projects.json"
            path.write_text(json.dumps(data), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(VALIDATOR), str(path)],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("skipForbidden must be boolean", result.stderr)

    def test_example_has_no_credential_keys(self) -> None:
        data = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        serialized = json.dumps(data).lower()
        for word in ("password", "secret", "access_token", "refresh_token", "private_key"):
            self.assertNotIn(word, serialized)


if __name__ == "__main__":
    unittest.main()
