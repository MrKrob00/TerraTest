#!/usr/bin/env python3
"""Rebuild fonts/NotoSans{JP,KR,SC}-subset.otf from the full Noto Sans CJK fonts.

Only the characters i18n/strings.json uses for ja / ko / zh_CN (plus the language names the
settings list shows) go in, which keeps each font a few hundred KB instead of 4-8 MB.
Run after adding or changing CJK text:

    pip install fonttools
    curl -LO https://github.com/notofonts/noto-cjk/raw/main/Sans/SubsetOTF/JP/NotoSansJP-Regular.otf
    (same for KR, SC)
    python3 tools/subset_cjk_fonts.py <dir with the three full .otf files>
"""
import json, os, sys
from fontTools import subset

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = sys.argv[1] if len(sys.argv) > 1 else "."
NAMES = "English Русский Українська Español Português (Brasil) Deutsch Français Türkçe 日本語 한국어 简体中文 Bahasa Indonesia"
BASE = "".join(chr(c) for c in range(0x20, 0x7F)) + "　、。・「」『』（）！？：；，．…—–～％＋×÷·“”‘’《》【】" + NAMES

data = json.load(open(os.path.join(ROOT, "i18n", "strings.json"), encoding="utf-8"))
for font, lang in (("JP", "ja"), ("KR", "ko"), ("SC", "zh_CN")):
    chars = set(BASE)
    for key, row in data.items():
        if isinstance(row, dict):
            chars.update(row.get(lang, ""))
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    opts.hinting = False
    opts.desubroutinize = False
    f = subset.load_font(os.path.join(SRC, f"NotoSans{font}-Regular.otf"), opts)
    s = subset.Subsetter(opts)
    s.populate(text="".join(sorted(chars)))
    s.subset(f)
    out = os.path.join(ROOT, "fonts", f"NotoSans{font}-subset.otf")
    subset.save_font(f, out, opts)
    print(out, len(chars), "chars", os.path.getsize(out) // 1024, "KB")
