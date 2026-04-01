#!/usr/bin/env python3
"""Parse review items and output tab-separated number/title/body."""
import sys, json

raw = sys.stdin.read().translate({i: None for i in range(32) if i not in (9, 10, 13)})
try:
    items = json.loads(raw)
    if not isinstance(items, list):
        items = [items]
    for d in items:
        num = d.get('number', '')
        title = d.get('title', '').replace('\t', ' ')
        body = d.get('body', '').replace('\t', ' ')[:2000]
        print(f"{num}\t{title}\t{body}")
except Exception:
    pass
