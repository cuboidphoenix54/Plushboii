#!/usr/bin/env python3
"""Label converted Objaverse meshes with the pipeline's own joint plan (one isolated, time-limited process each).

usage: build_objaverse_rows.py DATASET_DIR OUT_DIR [--timeout S] [--max-faces N] [--plushdata PATH]
Writes OUT_DIR/train.jsonl, OUT_DIR/images/, OUT_DIR/results.jsonl (uid, license, status). Resumable.
"""
import argparse, json, os, shutil, subprocess

ap = argparse.ArgumentParser()
ap.add_argument("dataset")
ap.add_argument("out")
ap.add_argument("--timeout", type=int, default=150)
ap.add_argument("--max-faces", type=int, default=60000)
ap.add_argument("--plushdata", default=".build/release/plushdata")
a = ap.parse_args()
os.makedirs(os.path.join(a.out, "images"), exist_ok=True)
results = os.path.join(a.out, "results.jsonl")
done = set()
if os.path.exists(results):
    done = {json.loads(l)["uid"] for l in open(results)}
items = [json.loads(l) for l in open(os.path.join(a.dataset, "converted.jsonl"))]
items = [r for r in items if r["status"] == "ok" and r.get("faces", 1 << 60) <= a.max_faces]
kept = 0
with open(results, "a") as rf, open(os.path.join(a.out, "train.jsonl"), "a") as tf:
    for i, r in enumerate(items):
        uid = r["uid"]
        if uid in done:
            continue
        try:
            p = subprocess.run(["nice", "-n", "19", a.plushdata, "objaverse-one", a.dataset, a.out, uid],
                               capture_output=True, text=True, timeout=a.timeout)
            if p.returncode == 0 and p.stdout.strip():
                tf.write(p.stdout.strip() + "\n"); tf.flush()
                status = "kept"; kept += 1
            else:
                status = (p.stderr.strip().splitlines() or [f"exit_{p.returncode}"])[-1][:120]
        except subprocess.TimeoutExpired:
            status = "timeout"
            shutil.rmtree(os.path.join(a.out, "images", uid), ignore_errors=True)
        rf.write(json.dumps({"uid": uid, "license": r["license"], "status": status}) + "\n"); rf.flush()
        if i % 25 == 0:
            print(i, len(items), "kept this run:", kept, flush=True)
