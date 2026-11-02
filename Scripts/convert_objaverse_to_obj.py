#!/usr/bin/env python3
"""Convert downloaded Objaverse .glb files to OBJ, dropping meshes the pipeline cannot use.

usage: convert_objaverse_to_obj.py DATASET_DIR [--min-faces N] [--max-faces N]
Reads DATASET_DIR/glb and manifest.jsonl; writes DATASET_DIR/obj/<uid>.obj and
DATASET_DIR/converted.jsonl (uid, status, faces, license). Resumable.
"""
import argparse, json, math, os
import numpy as np
import trimesh


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset")
    ap.add_argument("--min-faces", type=int, default=1000)
    ap.add_argument("--max-faces", type=int, default=400_000)
    a = ap.parse_args()
    obj_dir = os.path.join(a.dataset, "obj")
    os.makedirs(obj_dir, exist_ok=True)
    log_path = os.path.join(a.dataset, "converted.jsonl")
    seen = set()
    if os.path.exists(log_path):
        seen = {json.loads(l)["uid"] for l in open(log_path)}
    licenses = {}
    for line in open(os.path.join(a.dataset, "manifest.jsonl")):
        r = json.loads(line)
        if r.get("status") == "ok":
            licenses[r["uid"]] = r["license"]

    with open(log_path, "a") as log:
        for uid, lic in licenses.items():
            if uid in seen:
                continue
            rec = {"uid": uid, "license": lic}
            try:
                m = trimesh.load(os.path.join(a.dataset, "glb", uid + ".glb"), force="mesh")
                v = np.asarray(m.vertices, dtype=float)
                faces = len(m.faces)
                extent = v.max(axis=0) - v.min(axis=0) if len(v) else np.zeros(3)
                if not np.isfinite(v).all():
                    rec["status"] = "non_finite"
                elif faces < a.min_faces:
                    rec["status"] = "too_few_faces"
                elif faces > a.max_faces:
                    rec["status"] = "too_many_faces"
                elif extent.min() <= 1e-6 * max(extent.max(), 1e-12):
                    rec["status"] = "flat_or_degenerate"
                else:
                    m.export(os.path.join(obj_dir, uid + ".obj"))
                    rec["status"] = "ok"
                rec["faces"] = faces
            except Exception as e:
                rec["status"] = f"error:{type(e).__name__}"
            log.write(json.dumps(rec) + "\n")
            log.flush()
    counts = {}
    for l in open(log_path):
        s = json.loads(l)["status"]
        counts[s] = counts.get(s, 0) + 1
    print(counts)


if __name__ == "__main__":
    main()
