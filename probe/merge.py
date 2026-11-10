#!/usr/bin/env python3
"""Merge fragments into one leg file: merge.py OUT_DIR LEG_NAME OUTPUT.json"""
import glob
import json
import os
import platform
import sys

out_dir, leg, output = sys.argv[1:4]
doc = {
    "leg": leg,
    "machine": platform.machine(),
    "system": platform.system(),
    "release": platform.release(),
    "probes": {},
}
for path in sorted(glob.glob(os.path.join(out_dir, "*.json"))):
    name = os.path.splitext(os.path.basename(path))[0]
    try:
        with open(path, encoding="utf-8-sig") as fh:
            doc["probes"][name] = json.load(fh)
    except ValueError as exc:
        doc["probes"][name] = {"unparseable": str(exc)}
with open(output, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
print(json.dumps(doc, indent=2, sort_keys=True))
