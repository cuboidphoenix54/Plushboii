#!/usr/bin/env python3
"""Deterministic training-row extraction from sewing-pattern PDFs.

Usage: ingest_pattern_pdfs.py OUT_DIR PDF_DIR [PDF_DIR ...]
Needs PyMuPDF (`import pymupdf`). Writes OUT_DIR/train.jsonl and OUT_DIR/manifest.json.
No LLM is used; every answer is quoted from the PDF's own text. Patterns are
third-party works: rows are for local personal training only.
"""
import glob, hashlib, json, os, re, sys
import pymupdf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pattern_quality import assess

GUIDES = ("pipeline", "anatomical", "masterclass", "research", "making guide",
          "basics", "starter", "obibook", "printinginstructions")
SKIP = ("jacket", "halter", "pantalon", "cowl", "aviator", "collar", "headband",
        "hair-clip", "kimono", "winterberry", "scarf", "shrug", "lgpattern", "chinese")
DISCLAIMER = "(Details come from the pattern's own text; check the original pattern before cutting.)"


def clean(t):
    return re.sub(r"[ \t]+", " ", re.sub(r"\n{2,}", "\n", t)).strip()


def section(text, head, stops):
    m = re.search(head + r"\s*:?\s*\n(.*?)(?=\n(?:%s)\s*:?\s*\n|\Z)" % "|".join(stops), text, re.S | re.I)
    if not m:
        return ""
    keep = []
    for ln in m.group(1).split("\n"):
        if re.match(r"^(\w ){3,}", ln.strip()) or re.fullmatch(r"\s*\d+\s*", ln) or "sew desu ne" in ln.lower():
            break
        keep.append(ln)
    return clean("\n".join(keep))


def row(q, a):
    return {"images": [], "messages": [{"role": "user", "content": q},
                                         {"role": "assistant", "content": a}]}


def plush_rows(name, text):
    out = []
    title = re.sub(r"[-_]", " ", name).replace("Sewing Pattern", "").replace("Plush", "").replace("plush", "").strip()
    makes = section(text, "makes", ["materials", "difficulty", "skills used"])
    mats = section(text, r"materials & tools", ["pattern", "notes", "cutting", "instructions", "seam"])
    skills = section(text, "skills used", ["makes", "materials"])
    if makes:
        out.append(row(f"How big is the finished {title} plush made from this pattern?", f"{makes[:400]}\n{DISCLAIMER}"))
    if mats:
        out.append(row(f"What materials does the {title} pattern call for?", f"{mats[:900]}\n{DISCLAIMER}"))
    if skills:
        out.append(row(f"What sewing skills does the {title} plush use?", f"{skills[:500]}\n{DISCLAIMER}"))
    return out


def guide_rows(name, text):
    out, paras, buf = [], [], ""
    for line in text.split("\n"):
        buf += " " + line
        if len(buf) > 700 and line.rstrip().endswith((".", ":")):
            paras.append(clean(buf)); buf = ""
    for i, p in enumerate(paras[:60]):
        out.append(row(f"From the guide \"{name}\", summarise section {i + 1}.", p))
    return out


def main():
    out_dir, dirs = sys.argv[1], sys.argv[2:]
    os.makedirs(out_dir, exist_ok=True)
    rows, seen, stats = [], set(), {"plush": 0, "guide": 0, "skipped": 0, "failed": 0, "quality_rejected": 0}
    rejected = {}
    files = sorted(f for d in dirs for f in glob.glob(os.path.join(d, "*.pdf")))
    for f in files:
        name = re.sub(r"^[0-9a-f-]{36}-", "", os.path.splitext(os.path.basename(f))[0])
        low = name.lower()
        try:
            doc = pymupdf.open(f)
            text = "\n".join(doc[i].get_text() for i in range(min(6, doc.page_count)))
        except Exception as e:
            stats["failed"] += 1; print("fail", name, e, file=sys.stderr); continue
        passed, quality = assess(doc)
        if not passed:
            stats["quality_rejected"] += 1; rejected[name] = quality["reasons"]; continue
        if any(k in low for k in GUIDES):
            new = guide_rows(name, "\n".join(doc[i].get_text() for i in range(doc.page_count)))
            stats["guide"] += 1
        elif any(k in low for k in SKIP) or "plush" not in (low + text.lower()[:3000]):
            stats["skipped"] += 1; continue
        else:
            new = plush_rows(name, text); stats["plush"] += 1
        for r in new:
            h = hashlib.sha1(json.dumps(r, sort_keys=True).encode()).hexdigest()
            if h not in seen:
                seen.add(h); rows.append(r)
    with open(os.path.join(out_dir, "train.jsonl"), "w") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    json.dump({"rows": len(rows), **stats, "rejected": rejected}, open(os.path.join(out_dir, "manifest.json"), "w"), indent=1)
    print(len(rows), stats)


main()
