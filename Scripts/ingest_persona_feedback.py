#!/usr/bin/env python3
"""Copy thumbs-up persona answers from the app into an MLX training dataset folder.

Usage: ingest_persona_feedback.py [--source DIR] [--dest DIR]

The app writes persona_training.jsonl (rows shaped {"images":[],"messages":[...]}) under Application Support.
This merges any new rows into DEST/train.jsonl and DEST/valid.jsonl (about 1 in 10 rows to valid, chosen by
content hash so a row never moves between splits) and skips rows already present. It never trains anything.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

APP_SUPPORT = "Library/Application Support/Plushboii/Personas"
CANDIDATES = [
    Path.home() / "Library/Containers/com.example.Plushboii/Data" / APP_SUPPORT,
    Path.home() / APP_SUPPORT,
]
DEFAULT_DEST = Path("/Volumes/AMITA/PlushboiiTraining/persona")


def read_rows(path: Path):
    if not path.exists():
        return []
    rows = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line:
            rows.append(json.loads(line))
    return rows


def key(row) -> str:
    return hashlib.sha256(json.dumps(row, sort_keys=True).encode()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path)
    parser.add_argument("--dest", type=Path, default=DEFAULT_DEST)
    args = parser.parse_args()

    source = args.source or next((c for c in CANDIDATES if (c / "persona_training.jsonl").exists()), None)
    if source is None:
        print("No persona_training.jsonl found; rate some answers with thumbs-up first.", file=sys.stderr)
        return 1

    incoming = read_rows(source / "persona_training.jsonl")
    args.dest.mkdir(parents=True, exist_ok=True)
    train_path, valid_path = args.dest / "train.jsonl", args.dest / "valid.jsonl"
    existing = {key(r) for r in read_rows(train_path) + read_rows(valid_path)}

    new_train, new_valid = [], []
    for row in incoming:
        k = key(row)
        if k in existing:
            continue
        existing.add(k)
        (new_valid if int(k[:8], 16) % 10 == 0 else new_train).append(row)

    for path, rows in ((train_path, new_train), (valid_path, new_valid)):
        if rows:
            with path.open("a") as handle:
                for row in rows:
                    handle.write(json.dumps(row) + "\n")

    print(f"source={source} added train={len(new_train)} valid={len(new_valid)} skipped={len(incoming) - len(new_train) - len(new_valid)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
