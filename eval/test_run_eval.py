import csv
import json
import tempfile
import unittest
from pathlib import Path

import run_eval


class ParseSse(unittest.TestCase):
    def test_content_delta(self):
        line = 'data: {"choices":[{"delta":{"content":"안녕"}}]}'
        self.assertEqual(run_eval.parse_sse_line(line), "안녕")

    def test_done_and_blank(self):
        self.assertIsNone(run_eval.parse_sse_line("data: [DONE]"))
        self.assertIsNone(run_eval.parse_sse_line(""))

    def test_role_only_and_usage_chunks(self):
        self.assertIsNone(run_eval.parse_sse_line('data: {"choices":[{"delta":{"role":"assistant"}}]}'))
        self.assertIsNone(run_eval.parse_sse_line('data: {"choices":[],"usage":{"completion_tokens":5}}'))


class Blind(unittest.TestCase):
    def test_blind_hides_labels_and_keeps_rows(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            for label, text in [("gemma31", "g"), ("qwen27", "q")]:
                (d / f"{label}.jsonl").write_text(
                    json.dumps({"id": "v1", "task": "draft", "output": text}, ensure_ascii=False) + "\n", encoding="utf-8")
            run_eval.blind(sorted(d.glob("*.jsonl")), d, seed=1)
            key = json.loads((d / "blind_key.json").read_text(encoding="utf-8"))
            self.assertEqual(sorted(key.values()), ["gemma31", "qwen27"])
            rows = list(csv.DictReader((d / "blind.csv").open(encoding="utf-8-sig")))
            self.assertEqual(len(rows), 1)
            self.assertEqual({rows[0][k] for k in key}, {"g", "q"})
            self.assertNotIn("gemma31", (d / "blind.csv").read_text(encoding="utf-8-sig"))


if __name__ == "__main__":
    unittest.main()
