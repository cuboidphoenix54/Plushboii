#!/usr/bin/env python3
"""Evaluate one MLX anatomy adapter against a versioned Plushboii JSONL dataset."""

import base64
import json
import sys
import urllib.request
from pathlib import Path


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(2)


if len(sys.argv) not in (3, 4):
    fail("usage: evaluate_mlx_anatomy.py <dataset-directory> <adapter-path|none> [limit]")

dataset = Path(sys.argv[1])
adapter = sys.argv[2]
limit = int(sys.argv[3]) if len(sys.argv) == 4 else 10**9
rows = [
    json.loads(line)
    for line in (dataset / "valid.jsonl").read_text(encoding="utf-8").splitlines()[:limit]
]
if not rows:
    fail(f"no validation examples found in {dataset}")


def ask(row):
    parts = [{"type": "text", "text": row["messages"][0]["content"]}]
    for image_path in row["images"]:
        encoded = base64.b64encode((dataset / image_path).read_bytes()).decode()
        parts.append({"type": "image_url", "image_url": {"url": "data:image/png;base64," + encoded}})
    body = {
        "model": "mlx-community/gemma-4-e4b-it-4bit",
        "messages": [{"role": "user", "content": parts}],
        "max_tokens": 1024,
        "temperature": 0,
    }
    if adapter != "none":
        body["adapter_path"] = adapter
    request = urllib.request.Request(
        "http://127.0.0.1:8080/v1/chat/completions",
        json.dumps(body).encode(),
        {"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=600) as response:
        return json.load(response)["choices"][0]["message"]["content"]


def normalize(cuts):
    ordered = sorted(cuts, key=lambda cut: (cut["axis"], cut["normalizedPosition"]))
    groups = []
    for cut in ordered:
        if (
            groups
            and groups[-1][0]["axis"] == cut["axis"]
            and cut["normalizedPosition"]
            - sum(item["normalizedPosition"] for item in groups[-1]) / len(groups[-1])
            < 0.03
        ):
            groups[-1].append(cut)
        else:
            groups.append([cut])

    normalized = []
    for group in groups:
        def joined(key):
            return " / ".join(dict.fromkeys(cut[key] for cut in group))

        normalized.append(
            {
                "axis": group[0]["axis"],
                "normalizedPosition": sum(cut["normalizedPosition"] for cut in group) / len(group),
                "boundary": joined("boundary"),
                "negativeRegion": joined("negativeRegion"),
                "positiveRegion": joined("positiveRegion"),
                "confidence": min(cut["confidence"] for cut in group),
            }
        )
    return normalized


def app_valid(plan):
    if not isinstance(plan, dict) or set(plan) != {"summary", "cuts"}:
        return False
    if not isinstance(plan["summary"], str) or not 0 < len(plan["summary"]) <= 300:
        return False
    cuts = plan["cuts"]
    if not isinstance(cuts, list) or not 1 <= len(cuts) <= 9:
        return False
    expected = {
        "axis",
        "normalizedPosition",
        "boundary",
        "negativeRegion",
        "positiveRegion",
        "confidence",
    }
    for cut in cuts:
        if not isinstance(cut, dict) or set(cut) != expected:
            return False
        if cut["axis"] not in ("x", "y", "z"):
            return False
        position = cut["normalizedPosition"]
        confidence = cut["confidence"]
        if not isinstance(position, (int, float)) or not 0.1 <= position <= 0.9:
            return False
        if not isinstance(confidence, (int, float)) or not 0.55 <= confidence <= 1:
            return False
        if not all(
            isinstance(cut[key], str) and 0 < len(cut[key]) <= maximum
            for key, maximum in (
                ("boundary", 120),
                ("negativeRegion", 48),
                ("positiveRegion", 48),
            )
        ):
            return False
    merged = normalize(cuts)
    if len(merged) > 8:
        return False
    if not all(
        0 < len(cut[key]) <= maximum
        for cut in merged
        for key, maximum in (
            ("boundary", 120),
            ("negativeRegion", 48),
            ("positiveRegion", 48),
        )
    ):
        return False
    for axis in ("x", "y", "z"):
        positions = sorted(cut["normalizedPosition"] for cut in merged if cut["axis"] == axis)
        if any(right - left < 0.03 for left, right in zip(positions, positions[1:])):
            return False
    return True


def match(predicted, gold, tolerance=0.05):
    used = set()
    hits = 0
    for expected in gold:
        for index, proposed in enumerate(predicted):
            if index in used:
                continue
            if (
                proposed["axis"] == expected["axis"]
                and abs(proposed["normalizedPosition"] - expected["normalizedPosition"]) <= tolerance
            ):
                used.add(index)
                hits += 1
                break
    return hits


json_valid = app_valid_count = true_positives = predicted_count = gold_count = exact = 0
excluded_gold = 0
for index, row in enumerate(rows):
    gold = json.loads(row["messages"][1]["content"])["cuts"]
    eligible = [cut for cut in gold if 0.1 <= cut["normalizedPosition"] <= 0.9]
    excluded_gold += len(gold) - len(eligible)
    gold = normalize(eligible)
    gold_count += len(gold)
    try:
        prediction = json.loads(ask(row))
        json_valid += 1
        if not app_valid(prediction):
            print(index, "INVALID APP PLAN", flush=True)
            continue
        app_valid_count += 1
        predicted = normalize(prediction["cuts"])
    except Exception as error:
        print(index, "FAIL", repr(error)[:160], flush=True)
        continue

    hits = match(predicted, gold)
    true_positives += hits
    predicted_count += len(predicted)
    exact += int(hits == len(gold) == len(predicted))
    print(index, f"gold={len(gold)} pred={len(predicted)} hit={hits}", flush=True)

print(
    f"valid JSON {json_valid}/{len(rows)}; app-valid plans {app_valid_count}/{len(rows)}; "
    f"recall {true_positives}/{gold_count}; precision {true_positives}/{predicted_count}; "
    f"fully correct {exact}/{len(rows)}; excluded out-of-range gold cuts {excluded_gold}"
)
