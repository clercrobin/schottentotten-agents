#!/usr/bin/env python3
"""Feature state management — called from feature-state.sh via env vars."""
import json, glob, sys, os
from datetime import datetime, timezone

FEATURE_DIR = os.environ.get("_FEATURE_DIR", "state/features")
PLANS_DIR = os.environ.get("_PLANS_DIR", "docs/plans")

def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def load(fid):
    path = os.path.join(FEATURE_DIR, f"{fid}.json")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)

def save(fid, data):
    path = os.path.join(FEATURE_DIR, f"{fid}.json")
    data["updated"] = now()
    with open(path, "w") as f:
        json.dump(data, f, indent=2)

cmd = sys.argv[1] if len(sys.argv) > 1 else ""

if cmd == "create":
    fid = os.environ["FID"]
    topic = os.environ["TOPIC"]
    priority = os.environ.get("PRIORITY", "medium")
    discussion = os.environ.get("DISCUSSION", "")
    slug = "".join(c if c.isalnum() or c == "-" else "-" for c in topic.lower())[:40].strip("-")
    data = {
        "id": fid,
        "topic": topic,
        "status": "triage",
        "priority": priority,
        "discussion": int(discussion) if discussion.isdigit() else None,
        "plan": f"{PLANS_DIR}/{fid}-{slug}.md",
        "branch": None,
        "pr": None,
        "created": now(),
        "updated": now(),
        "feedback": []
    }
    save(fid, data)
    print(os.path.join(FEATURE_DIR, f"{fid}.json"))

elif cmd == "get":
    fid = os.environ["FID"]
    d = load(fid)
    print(json.dumps(d, indent=2) if d else "{}")

elif cmd == "field":
    fid = os.environ["FID"]
    field = os.environ["FIELD"]
    d = load(fid)
    print(d.get(field, "") if d else "")

elif cmd == "set-status":
    fid = os.environ["FID"]
    status = os.environ["STATUS"]
    d = load(fid)
    if d:
        d["status"] = status
        save(fid, d)

elif cmd == "set":
    fid = os.environ["FID"]
    field = os.environ["FIELD"]
    value = os.environ["VALUE"]
    d = load(fid)
    if d:
        d[field] = value
        save(fid, d)

elif cmd == "add-feedback":
    fid = os.environ["FID"]
    by = os.environ["BY"]
    verdict = os.environ["VERDICT"]
    note = os.environ["NOTE"]
    d = load(fid)
    if d:
        d["feedback"].append({"by": by, "at": now(), "verdict": verdict, "note": note})
        save(fid, d)

elif cmd == "find-by-status":
    statuses = set(sys.argv[2:])
    # Pick most advanced first (finish what's started), then by priority
    status_advancement = {
        "reviewed": 0, "review": 1, "building": 2,
        "approved": 3, "planning": 4, "triage": 5
    }
    priority_order = {"critical": 0, "high": 1, "medium": 2, "low": 3}

    best, best_adv, best_pri = None, 99, 99
    for f in glob.glob(os.path.join(FEATURE_DIR, "*.json")):
        try:
            with open(f) as fh:
                d = json.load(fh)
            if d.get("status") in statuses:
                adv = status_advancement.get(d.get("status"), 9)
                pri = priority_order.get(d.get("priority", "low"), 9)
                if (adv, pri) < (best_adv, best_pri):
                    best, best_adv, best_pri = d["id"], adv, pri
        except: pass
    if best:
        print(best)

elif cmd == "count":
    status = os.environ.get("STATUS", "")
    count = 0
    for f in glob.glob(os.path.join(FEATURE_DIR, "*.json")):
        try:
            with open(f) as fh:
                d = json.load(fh)
            if d.get("status") == status:
                count += 1
        except: pass
    print(count)

elif cmd == "list":
    for f in sorted(glob.glob(os.path.join(FEATURE_DIR, "*.json"))):
        try:
            with open(f) as fh:
                d = json.load(fh)
            pr = f"PR#{d['pr']}" if d.get("pr") else ""
            print(f"{d['id']:>5} [{d['status']:>10}] {d.get('priority','?'):>8} {pr:>6}  {d['topic'][:50]}")
        except: pass
