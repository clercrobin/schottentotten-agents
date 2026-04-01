#!/bin/bash
# ============================================================
# Feature state management — file-based, single source of truth
#
# Each feature is a JSON file: state/features/<id>.json
# Plans live on disk: docs/plans/<id>-<slug>.md
#
# Statuses: intake → triage → planning → approved → building → review → done
# ============================================================

_FEATURE_DIR="${STATE_DIR:-state}/features"
_PLANS_DIR="docs/plans"
mkdir -p "$_FEATURE_DIR" "$_PLANS_DIR"

# ────────────────────────────────────────────
# Create a new feature
# Usage: feature_create <id> <topic> <priority> [discussion_num]
# ────────────────────────────────────────────
feature_create() {
    local id="$1" topic="$2" priority="${3:-medium}" discussion="${4:-}"
    local slug
    slug=$(echo "$topic" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 40)
    local file="$_FEATURE_DIR/${id}.json"
    python3 -c "
import json, sys
f = {
    'id': '$id',
    'topic': '''$topic''',
    'status': 'triage',
    'priority': '$priority',
    'discussion': $( [ -n "$discussion" ] && echo "$discussion" || echo "null" ),
    'plan': '$_PLANS_DIR/${id}-${slug}.md',
    'branch': None,
    'pr': None,
    'created': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'updated': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'feedback': []
}
with open('$file', 'w') as fh:
    json.dump(f, fh, indent=2)
print('$file')
" 2>/dev/null
}

# ────────────────────────────────────────────
# Read a feature's state
# Usage: feature_get <id>
# Returns: full JSON on stdout
# ────────────────────────────────────────────
feature_get() {
    local id="$1"
    local file="$_FEATURE_DIR/${id}.json"
    [ -f "$file" ] && cat "$file" || echo "{}"
}

# ────────────────────────────────────────────
# Read a single field from a feature
# Usage: feature_field <id> <field>
# ────────────────────────────────────────────
feature_field() {
    local id="$1" field="$2"
    python3 -c "
import json
with open('$_FEATURE_DIR/${id}.json') as f:
    print(json.load(f).get('$field', ''))
" 2>/dev/null
}

# ────────────────────────────────────────────
# Update feature status
# Usage: feature_set_status <id> <new_status>
# ────────────────────────────────────────────
feature_set_status() {
    local id="$1" status="$2"
    local file="$_FEATURE_DIR/${id}.json"
    [ -f "$file" ] || return 1
    python3 -c "
import json
with open('$file') as f:
    d = json.load(f)
d['status'] = '$status'
d['updated'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
with open('$file', 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null
}

# ────────────────────────────────────────────
# Update a single field
# Usage: feature_set <id> <field> <value>
# ────────────────────────────────────────────
feature_set() {
    local id="$1" field="$2" value="$3"
    local file="$_FEATURE_DIR/${id}.json"
    [ -f "$file" ] || return 1
    python3 -c "
import json
with open('$file') as f:
    d = json.load(f)
d['$field'] = '$value'
d['updated'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
with open('$file', 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null
}

# ────────────────────────────────────────────
# Append feedback (CTO review notes)
# Usage: feature_add_feedback <id> <by> <verdict> <note>
# ────────────────────────────────────────────
feature_add_feedback() {
    local id="$1" by="$2" verdict="$3" note="$4"
    local file="$_FEATURE_DIR/${id}.json"
    [ -f "$file" ] || return 1
    python3 -c "
import json
with open('$file') as f:
    d = json.load(f)
d['feedback'].append({
    'by': '$by',
    'at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'verdict': '$verdict',
    'note': '''$note'''
})
d['updated'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
with open('$file', 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null
}

# ────────────────────────────────────────────
# Find the highest-priority feature in a given status
# Usage: feature_find_by_status <status> [status2...]
# Returns: feature ID (or empty)
# ────────────────────────────────────────────
feature_find_by_status() {
    python3 -c "
import json, glob, sys
priority_order = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
statuses = set(sys.argv[1:])
best = None
best_pri = 99
for f in glob.glob('$_FEATURE_DIR/*.json'):
    try:
        with open(f) as fh:
            d = json.load(fh)
        if d.get('status') in statuses:
            pri = priority_order.get(d.get('priority', 'low'), 9)
            if pri < best_pri:
                best = d['id']
                best_pri = pri
    except: pass
if best:
    print(best)
" "$@" 2>/dev/null
}

# ────────────────────────────────────────────
# Count features by status
# Usage: feature_count <status>
# ────────────────────────────────────────────
feature_count() {
    local status="$1"
    python3 -c "
import json, glob
count = 0
for f in glob.glob('$_FEATURE_DIR/*.json'):
    try:
        with open(f) as fh:
            d = json.load(fh)
        if d.get('status') == '$status':
            count += 1
    except: pass
print(count)
" 2>/dev/null
}

# ────────────────────────────────────────────
# List all features with status
# Usage: feature_list
# ────────────────────────────────────────────
feature_list() {
    python3 -c "
import json, glob
for f in sorted(glob.glob('$_FEATURE_DIR/*.json')):
    try:
        with open(f) as fh:
            d = json.load(fh)
        pr = f'PR#{d[\"pr\"]}' if d.get('pr') else ''
        print(f'{d[\"id\"]:>5} [{d[\"status\"]:>10}] {d.get(\"priority\",\"?\"):>8} {pr:>6}  {d[\"topic\"][:50]}')
    except: pass
" 2>/dev/null
}
