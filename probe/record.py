#!/usr/bin/env python3
"""Write one JSON fragment: record.py OUT_DIR NAME KEY=VALUE ...

VALUE is parsed as JSON when possible, otherwise kept as a string.
"""
import json
import os
import sys

out_dir, name, *pairs = sys.argv[1:]
data = {}
for pair in pairs:
    key, _, raw = pair.partition("=")
    try:
        data[key] = json.loads(raw)
    except ValueError:
        data[key] = raw
os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, name + ".json"), "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
