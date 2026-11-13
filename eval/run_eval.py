"""VOC 샘플로 모델별 응답 품질/속도를 수집하고 블라인드 평가표를 만든다. stdlib 만 사용."""
import argparse
import csv
import json
import random
import string
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent


def parse_sse_line(line: str):
    line = line.strip()
    if not line.startswith("data:"):
        return None
    payload = line[5:].strip()
    if payload == "[DONE]":
        return None
    choices = json.loads(payload).get("choices") or []   # usage 전용 청크는 choices 가 비어 있다
    if not choices:
        return None
    return choices[0].get("delta", {}).get("content") or None


def call(base: str, key: str, messages: list, max_tokens: int):
    body = json.dumps({"model": "voc-llm", "messages": messages, "temperature": 0,
                       "max_tokens": max_tokens, "stream": True}).encode()
    req = urllib.request.Request(f"{base}/v1/chat/completions", data=body, method="POST", headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    t0 = time.monotonic()
    ttft, parts = None, []
    with urllib.request.urlopen(req, timeout=300) as resp:
        for raw in resp:
            piece = parse_sse_line(raw.decode("utf-8", "replace"))
            if piece:
                if ttft is None:
                    ttft = time.monotonic() - t0
                parts.append(piece)
    total = time.monotonic() - t0
    text = "".join(parts)
    gen = total - (ttft or 0)
    return {"output": text, "ttft_sec": round(ttft or total, 3), "total_sec": round(total, 3),
            "completion_chars": len(text), "chars_per_sec": round(len(text) / gen, 1) if gen > 0 else 0}


def run(label: str, base: str, key: str, samples: Path, max_tokens: int):
    out_dir = HERE / "results"
    out_dir.mkdir(exist_ok=True)
    out = out_dir / f"{label}.jsonl"
    with samples.open(encoding="utf-8") as f, out.open("w", encoding="utf-8") as w:
        for line in f:
            if not line.strip():
                continue
            s = json.loads(line)
            r = {"id": s["id"], "task": s.get("task", ""), **call(base, key, s["messages"], max_tokens)}
            w.write(json.dumps(r, ensure_ascii=False) + "\n")
            print(f'{r["id"]}\tttft={r["ttft_sec"]}s\ttotal={r["total_sec"]}s')
    print(f"saved {out}")


def blind(files, out_dir: Path, seed=None):
    files = list(files)
    labels = [Path(p).stem for p in files]
    rng = random.Random(seed)
    rng.shuffle(labels)
    letters = list(string.ascii_uppercase[:len(labels)])
    key = dict(zip(letters, labels))
    outputs = {}
    for p in files:
        for line in Path(p).read_text(encoding="utf-8").splitlines():
            if line.strip():
                r = json.loads(line)
                outputs.setdefault(r["id"], {"task": r.get("task", "")})[Path(p).stem] = r["output"]
    with (out_dir / "blind.csv").open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["id", "task", *letters])
        for sid, row in outputs.items():
            w.writerow([sid, row["task"], *[row.get(key[l], "") for l in letters]])
    (out_dir / "blind_key.json").write_text(json.dumps(key, ensure_ascii=False, indent=2), encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--label", required=True)
    r.add_argument("--base", required=True, help="https://<DOMAIN>")
    r.add_argument("--key", required=True)
    r.add_argument("--samples", type=Path, default=HERE / "samples.jsonl")
    r.add_argument("--max-tokens", type=int, default=800)
    b = sub.add_parser("blind")
    b.add_argument("files", nargs="+")
    a = ap.parse_args()
    if a.cmd == "run":
        run(a.label, a.base.rstrip("/"), a.key, a.samples, a.max_tokens)
    else:
        blind(a.files, HERE / "results")
        print(f"saved {HERE / 'results' / 'blind.csv'} (평가자에게 blind_key.json 은 공유하지 않는다)")


if __name__ == "__main__":
    main()
