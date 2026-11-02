"""Deterministic quality gate for pattern sources before they become training rows.

assess(doc) inspects the first pages of an open PyMuPDF document and returns (passed, report).
Hard rejects (the text cannot be trusted as a source of facts):
  - garbled        : replacement/private-use characters or long vowel-less letter runs
  - too_little_text: no extractable instructional text at all (scan-only or image-only)
Soft signals (recorded in the report, never rejected on their own because many genuine
patterns legitimately lack them):
  - has_measurements, has_instruction_words, page_count
A seam-line versus photo consistency check needs image understanding and is intentionally
not attempted here.
"""
import re

MAX_PAGES = 8
GARBLED_CHAR_RATIO = 0.02
VOWELLESS_WORD_RATIO = 0.12
MIN_WORDS = 40

WORD = re.compile(r"[A-Za-z]{5,}")
MEASURE = re.compile(r"\d+(?:\.\d+)?\s*(?:cm|mm|in\b|inch|inches|\")", re.I)
INSTRUCTION = re.compile(r"\b(cut|sew|stitch|seam|fabric|stuff|trace|pin|turn|baste|dart|notch)\w*", re.I)


def _is_private_or_replacement(ch):
    o = ord(ch)
    return o == 0xFFFD or 0xE000 <= o <= 0xF8FF


def assess(doc):
    pages = min(doc.page_count, MAX_PAGES)
    text = "\n".join(doc[i].get_text() for i in range(pages))
    chars = [c for c in text if not c.isspace()]
    words = WORD.findall(text)
    report = {"page_count": doc.page_count, "words": len(text.split())}
    reasons = []

    if len(text.split()) < MIN_WORDS:
        reasons.append("too_little_text")
    if chars:
        bad = sum(1 for c in chars if _is_private_or_replacement(c))
        report["garbled_char_ratio"] = round(bad / len(chars), 4)
        if bad / len(chars) > GARBLED_CHAR_RATIO:
            reasons.append("garbled")
    if words:
        vowelless = sum(1 for w in words if not re.search(r"[aeiouyAEIOUY]", w))
        report["vowelless_word_ratio"] = round(vowelless / len(words), 4)
        if vowelless / len(words) > VOWELLESS_WORD_RATIO and "garbled" not in reasons:
            reasons.append("garbled")

    report["has_measurements"] = bool(MEASURE.search(text))
    report["has_instruction_words"] = len(INSTRUCTION.findall(text)) >= 5
    report["reasons"] = reasons
    return not reasons, report
