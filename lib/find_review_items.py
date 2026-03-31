#!/usr/bin/env python3
"""Find open discussions with [REVIEW] in title. Sanitizes control chars."""
import sys, json

raw = sys.stdin.read()
# Remove control chars except tab/newline/cr
raw = raw.translate({i: None for i in range(32) if i not in (9, 10, 13)})
try:
    items = json.loads(raw)
    found = [d for d in items if '[REVIEW]' in d.get('title', '')]
    for d in found:
        print(json.dumps(d))
except Exception:
    pass
