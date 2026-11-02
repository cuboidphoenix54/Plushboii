#!/usr/bin/env python3
"""Download a seeded random subset of Objaverse 1.0 (Sketchfab source of Objaverse-XL).

Annotations (uid, license, sha256) come from allenai/objaverse-xl; files come from
allenai/objaverse on Hugging Face, exactly as objaverse/xl/sketchfab.py does.
Resumable: existing files are skipped. Every file is sha256-verified.

usage: fetch_objaverse_subset.py OUT_DIR [--count N] [--seed S] [--workers W] [--max-mb M]
"""
import argparse, gzip, hashlib, json, os, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
import pandas as pd

ANN = "https://huggingface.co/datasets/allenai/objaverse-xl/resolve/main/sketchfab/sketchfab.parquet"
HF = "https://huggingface.co/datasets/allenai/objaverse/resolve/main/"


def fetch(url, dest, max_bytes):
    tmp = dest + ".tmp"
    with urllib.request.urlopen(url, timeout=120) as r:
        length = int(r.headers.get("Content-Length") or 0)
        if length > max_bytes:
            return "too_big"
        with open(tmp, "wb") as f:
            while chunk := r.read(1 << 20):
                f.write(chunk)
    os.rename(tmp, dest)
    return "ok"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--count", type=int, default=5000)
    ap.add_argument("--seed", type=int, default=420)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--max-mb", type=int, default=30)
    ap.add_argument("--uid-list", help="JSON list of uids to fetch instead of a random sample")
    a = ap.parse_args()
    glb_dir = os.path.join(a.out, "glb")
    os.makedirs(glb_dir, exist_ok=True)

    df = pd.read_parquet(ANN)
    df["uid"] = df.fileIdentifier.str.rsplit("/", n=1).str[-1]
    if a.uid_list:
        wanted = set(json.load(open(a.uid_list)))
        sample = df[df.uid.isin(wanted)].reset_index(drop=True)
    else:
        sample = df.sample(n=a.count, random_state=a.seed).reset_index(drop=True)

    paths_file = os.path.join(a.out, "object-paths.json.gz")
    if not os.path.exists(paths_file):
        urllib.request.urlretrieve(HF + "object-paths.json.gz", paths_file)
    with gzip.open(paths_file) as f:
        paths = json.load(f)

    manifest_path = os.path.join(a.out, "manifest.jsonl")
    done = {}
    if os.path.exists(manifest_path):
        for line in open(manifest_path):
            r = json.loads(line)
            done[r["uid"]] = r
    max_bytes = a.max_mb << 20

    def work(row):
        uid = row.uid
        if uid in done:
            return None
        rel = paths.get(uid)
        if rel is None:
            return {"uid": uid, "status": "no_path"}
        dest = os.path.join(glb_dir, uid + ".glb")
        for attempt in range(3):
            try:
                st = "ok" if os.path.exists(dest) else fetch(HF + rel, dest, max_bytes)
                break
            except Exception as e:
                st = f"error:{type(e).__name__}"
                time.sleep(2 * (attempt + 1))
        if st == "ok" and sha256(dest) != row.sha256:
            os.remove(dest)
            st = "sha_mismatch"
        return {"uid": uid, "status": st, "license": row.license, "source_url": row.fileIdentifier}

    n = 0
    with open(manifest_path, "a") as mf, ThreadPoolExecutor(a.workers) as ex:
        for res in ex.map(work, sample.itertuples()):
            if res is None:
                continue
            mf.write(json.dumps(res) + "\n")
            mf.flush()
            n += 1
            if n % 100 == 0:
                print(f"{n} processed", flush=True)
    print("done")


if __name__ == "__main__":
    sys.exit(main())
