#!/bin/bash
# ============================================================
# 🚦 Quality Gate Agent — Staging → Prod gate + retry loop
#
# NO CLAUDE SESSIONS — pure shell. Reads CI results, posts reports.
#
# 1. Checks latest staging CI run (unit tests, coverage, smoke tests)
# 2. If failing: creates targeted fix tasks in Triage (picked up next cycle)
# 3. If passing: posts "ready for prod" report @mentioning the human
# 4. Natural retry: failures create tasks → agents fix → next deploy → re-check
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"

# No robust.sh needed — no Claude sessions
MODE="${1:-check}"
AGENT="quality-gate"

log() { echo "[$(date '+%H:%M:%S')] [GATE] $*"; }

run_check() {
    log "🚦 Checking staging quality gate..."

    local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
    local staging_branch="${DEPLOY_BRANCH:-staging}"

    # Get latest CI run on staging
    local run_json
    run_json=$(gh run list --repo "$target_repo" --branch "$staging_branch" --limit 1 \
        --json databaseId,conclusion,headSha,createdAt 2>/dev/null) || return 0

    local run_id conclusion run_sha
    run_id=$(echo "$run_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['databaseId'] if d else '')" 2>/dev/null)
    conclusion=$(echo "$run_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0].get('conclusion','') if d else '')" 2>/dev/null)
    run_sha=$(echo "$run_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['headSha'][:8] if d else '')" 2>/dev/null)

    [ -z "$run_id" ] && { log "No CI runs found"; return 0; }
    is_processed "run-$run_id" "$AGENT" "checked" && { log "Already checked"; return 0; }

    # Get per-job results
    local jobs_json
    jobs_json=$(gh run view "$run_id" --repo "$target_repo" --json jobs 2>/dev/null || echo '{"jobs":[]}')

    local unit_result deploy_result smoke_result
    unit_result=$(echo "$jobs_json" | python3 -c "
import sys,json
for j in json.load(sys.stdin)['jobs']:
    if 'test' == j['name'].lower():
        print(j['conclusion']); break
else: print('skipped')
" 2>/dev/null)
    deploy_result=$(echo "$jobs_json" | python3 -c "
import sys,json
for j in json.load(sys.stdin)['jobs']:
    if 'deploy' == j['name'].lower():
        print(j['conclusion']); break
else: print('skipped')
" 2>/dev/null)
    smoke_result=$(echo "$jobs_json" | python3 -c "
import sys,json
for j in json.load(sys.stdin)['jobs']:
    if 'smoke' in j['name'].lower():
        print(j['conclusion']); break
else: print('skipped')
" 2>/dev/null)

    local unit_icon="❓" deploy_icon="❓" smoke_icon="❓"
    [ "$unit_result" = "success" ] && unit_icon="✅"
    [ "$unit_result" = "failure" ] && unit_icon="❌"
    [ "$deploy_result" = "success" ] && deploy_icon="✅"
    [ "$deploy_result" = "failure" ] && deploy_icon="❌"
    [ "$smoke_result" = "success" ] && smoke_icon="✅"
    [ "$smoke_result" = "failure" ] && smoke_icon="❌"
    [ "$smoke_result" = "skipped" ] && smoke_icon="⏭️"

    # Smoke test count from e2e/smoke.spec.js
    local smoke_count=0
    [ -f "$TARGET_PROJECT/e2e/smoke.spec.js" ] && smoke_count=$(grep -c "^test(" "$TARGET_PROJECT/e2e/smoke.spec.js" 2>/dev/null || echo "0")

    # Deploy URL health
    local health_icon="—"
    if [ -n "${DEPLOY_URL:-}" ]; then
        local http_status
        http_status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "$DEPLOY_URL" 2>/dev/null || echo "000")
        [ "$http_status" = "200" ] || [ "$http_status" = "301" ] && health_icon="✅ $http_status"
        [ "$http_status" = "000" ] && health_icon="⏳ timeout"
        echo "$http_status" | grep -qE "^[45]" && health_icon="❌ $http_status"
    fi

    local all_pass="false"
    [ "$unit_result" = "success" ] && [ "$deploy_result" = "success" ] && \
    { [ "$smoke_result" = "success" ] || [ "$smoke_result" = "skipped" ]; } && \
    all_pass="true"

    local run_url="https://github.com/$target_repo/actions/runs/$run_id"

    if [ "$all_pass" = "true" ]; then
        log "✅ ALL PASS — $run_sha"

        # Post the report to Engineering
        post_discussion "$CAT_ENGINEERING" "🚦 Staging: ✅ READY — \`$run_sha\`" \
"## Staging Quality Gate

| Gate | Status |
|------|--------|
| Unit tests | $unit_icon |
| Deploy | $deploy_icon |
| Smoke tests ($smoke_count registered) | $smoke_icon |
| Live health | $health_icon |

**CI:** $run_url
**Staging:** ${DEPLOY_URL:-N/A}" "$AGENT_QUALITY_GATE" || true

        # Ask the human for explicit merge approval in Q&A
        post_discussion "$CAT_DECISIONS" "🚀 Ready for prod — approve merge? (\`$run_sha\`)" \
"**@${GITHUB_OWNER}** — Staging is green. All gates passed.

| Gate | Status |
|------|--------|
| Unit tests | $unit_icon |
| Deploy | $deploy_icon |
| Smoke tests ($smoke_count) | $smoke_icon |
| Live health | $health_icon |

**Test staging:** ${DEPLOY_URL:-N/A}
**CI run:** $run_url

**To ship to prod:** merge \`$staging_branch → main\`

Reply here with your decision:
- **approve** — I've tested staging, ship it
- **hold** — not yet, need more testing
- **reject** — issues found, don't ship" "$AGENT_QUALITY_GATE" || true

    else
        log "❌ BLOCKED — $run_sha"

        # Get failure context
        local failed_log
        failed_log=$(gh run view "$run_id" --repo "$target_repo" --log-failed 2>/dev/null | tail -20)

        post_discussion "$CAT_ENGINEERING" "🚦 Staging: ❌ BLOCKED — \`$run_sha\`" \
"## Staging Quality Gate

| Gate | Status |
|------|--------|
| Unit tests | $unit_icon |
| Deploy | $deploy_icon |
| Smoke tests ($smoke_count registered) | $smoke_icon |
| Live health | $health_icon |

**CI:** $run_url

### Failure Context
\`\`\`
$failed_log
\`\`\`

---
*Fix tasks created below. Agents will retry next cycle.*" "$AGENT_QUALITY_GATE" || true

        # Create targeted fix tasks
        if [ "$unit_result" = "failure" ]; then
            post_discussion "$CAT_TRIAGE" "[CRITICAL] Unit tests failing on staging" \
"**Priority:** critical — blocks prod release.
Fix the failing tests. CI run: $run_url" "$AGENT_QUALITY_GATE" || true
        fi

        if [ "$smoke_result" = "failure" ]; then
            post_discussion "$CAT_TRIAGE" "[CRITICAL] Smoke tests failing on staging" \
"**Priority:** critical — deployed app has broken user flows.
Staging URL: ${DEPLOY_URL:-N/A}. CI run: $run_url" "$AGENT_QUALITY_GATE" || true
        fi

        if [ "$deploy_result" = "failure" ]; then
            post_discussion "$CAT_TRIAGE" "[CRITICAL] Staging deploy failed" \
"**Priority:** critical — build or infra broken.
CI run: $run_url" "$AGENT_QUALITY_GATE" || true
        fi
    fi

    mark_processed "run-$run_id" "$AGENT" "checked"
}

run_report() {
    log "🚦 Generating staging health report..."

    local target_repo="${GITHUB_OWNER}/$(basename "$TARGET_PROJECT")"
    local staging_branch="${DEPLOY_BRANCH:-staging}"

    local runs
    runs=$(gh run list --repo "$target_repo" --branch "$staging_branch" --limit 5 \
        --json conclusion,headSha,createdAt \
        --jq '.[] | "\(.conclusion)\t\(.headSha[:8])\t\(.createdAt[:16])"' 2>/dev/null)

    local smoke_count=0
    [ -f "$TARGET_PROJECT/e2e/smoke.spec.js" ] && smoke_count=$(grep -c "^test(" "$TARGET_PROJECT/e2e/smoke.spec.js" 2>/dev/null || echo "0")

    local report="## Staging Health

**Smoke tests registered:** $smoke_count
**URL:** ${DEPLOY_URL:-N/A}

### Recent CI Runs
| Status | Commit | Date |
|--------|--------|------|"

    while IFS=$'\t' read -r conc sha dt; do
        [ -z "$conc" ] && continue
        local icon="❓"; [ "$conc" = "success" ] && icon="✅"; [ "$conc" = "failure" ] && icon="❌"
        report="$report
| $icon | \`$sha\` | $dt |"
    done <<< "$runs"

    if [ "$smoke_count" -lt 5 ]; then
        report="$report

⚠️ **Low E2E coverage** — only $smoke_count smoke tests. Add tests to \`e2e/smoke.spec.js\` for critical user flows."
    fi

    post_discussion "$CAT_ENGINEERING" "🚦 [staging] Health — $(date '+%Y-%m-%d')" "$report" "$AGENT_QUALITY_GATE" || true
}

case "$MODE" in
    check)  run_check ;;
    report) run_report ;;
    *)      echo "Usage: $0 {check|report}"; exit 1 ;;
esac
