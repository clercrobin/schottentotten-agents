#!/bin/bash
# ============================================================
# Feature state management — thin shell wrappers around Python
#
# All data handling is in lib/feature-state.py (no inline Python,
# no shell variable interpolation in JSON, no quoting issues).
# ============================================================

export _FEATURE_DIR="${STATE_DIR:-state}/features"
export _PLANS_DIR="docs/plans"
_FS_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-state.py"

mkdir -p "$_FEATURE_DIR" "$_PLANS_DIR"

feature_create()          { FID="$1" TOPIC="$2" PRIORITY="${3:-medium}" DISCUSSION="${4:-}" python3 "$_FS_PY" create; }
feature_get()             { FID="$1" python3 "$_FS_PY" get; }
feature_field()           { FID="$1" FIELD="$2" python3 "$_FS_PY" field; }
feature_set_status()      { FID="$1" STATUS="$2" python3 "$_FS_PY" set-status; }
feature_set()             { FID="$1" FIELD="$2" VALUE="$3" python3 "$_FS_PY" set; }
feature_add_feedback()    { FID="$1" BY="$2" VERDICT="$3" NOTE="$4" python3 "$_FS_PY" add-feedback; }
feature_find_next()       { python3 "$_FS_PY" find-next "$@"; }
feature_find_by_status()  { python3 "$_FS_PY" find-next "$@"; }  # alias
feature_count()           { STATUS="$1" python3 "$_FS_PY" count; }
feature_list()            { python3 "$_FS_PY" list; }
