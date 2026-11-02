#!/usr/bin/env python3
"""Pattern-page image rows: render template pages and label them from the PDF's own text.

Usage: ingest_pattern_images.py OUT_DIR PDF_DIR [PDF_DIR ...]
Writes OUT_DIR/images/*.png and OUT_DIR/train.jsonl (image paths relative to OUT_DIR).
A page counts as a template page only if it has >= 3 "cut N ..." instructions and
almost no body text. Labels are the page's own cut lines, top-to-bottom; nothing is generated.
Local personal training only (third-party patterns).
"""
import glob, hashlib, json, os, re, sys
import pymupdf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pattern_quality import assess

CUT = re.compile(r"(?i)^(?:trace\s*&\s*)?cut\s+\d+\b.*")
# Labels must end on a complete word from this set so clipped text ("fabri") is dropped.
COMPLETE = re.compile(r"(?i)^(?:trace\s*&\s*)?cut\s+\d+(?:\s+each)?(?:\s+from\s+[a-z0-9 /-]+?)?\s*(?:fabric|felt|interfacing|fleece|fur|minky|batting|each|fold)?$")
SKIP = ("jacket", "halter", "pantalon", "cowl", "aviator", "collar", "headband", "hair-clip",
        "kimono", "winterberry", "scarf", "shrug", "lgpattern", "chinese")
MAX_SIDE = 1024


def page_labels(page):
    blocks = sorted(page.get_text("blocks"), key=lambda b: (round(b[1] / 8), b[0]))
    labels = []
    for b in blocks:
        t = re.sub(r"\s+", " ", b[4]).strip()
        if CUT.match(t) and len(t) <= 80 and COMPLETE.match(t) and re.search(r"(?i)(fabric|felt|interfacing|fleece|fur|minky|batting|each|fold)$", t):
            labels.append(t)
    return labels


def main():
    out, dirs = sys.argv[1], sys.argv[2:]
    os.makedirs(os.path.join(out, "images"), exist_ok=True)
    rows, pages = [], 0
    for f in sorted(p for d in dirs for p in glob.glob(os.path.join(d, "*.pdf"))):
        name = re.sub(r"^[0-9a-f-]{36}-", "", os.path.splitext(os.path.basename(f))[0])
        slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:40]
        if any(k in name.lower() for k in SKIP):
            continue
        try:
            doc = pymupdf.open(f)
        except Exception as e:
            print("fail", name, e, file=sys.stderr); continue
        passed, quality = assess(doc)
        if not passed:
            print("quality-rejected", name, quality["reasons"], file=sys.stderr); continue
        for i, page in enumerate(doc):
            labels = page_labels(page)
            body = len(page.get_text().split())
            if len(labels) < 3 or body > 220:
                continue
            scale = MAX_SIDE / max(page.rect.width, page.rect.height)
            rel = f"images/{slug}-p{i + 1}.png"
            page.get_pixmap(matrix=pymupdf.Matrix(scale, scale)).save(os.path.join(out, rel))
            answer = "\n".join(f"• {l}" for l in labels)
            rows.append({"images": [rel], "messages": [
                {"role": "user", "content": "This is a plush sewing-pattern template page. List the cutting instruction printed next to each pattern piece, top to bottom."},
                {"role": "assistant", "content": answer + "\n(Read from the printed labels; confirm against the page before cutting.)"}]})
            pages += 1
    with open(os.path.join(out, "train.jsonl"), "w") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    json.dump({"rows": len(rows), "pages": pages}, open(os.path.join(out, "manifest.json"), "w"))
    print(len(rows), "pages")


main()
