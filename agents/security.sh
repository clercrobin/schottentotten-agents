#!/bin/bash
# ============================================================
# 🛡️ Security Agent — Owns security end-to-end
#
# Runs at 4 points in the lifecycle:
#
# 1. SCAN (Discovery) — secret scanning, attack surface audit
# 2. REVIEW (Verify)  — security-focused review of PR diffs
# 3. DEPLOY (Ship)    — HTTP headers, TLS, exposed endpoints
# 4. AUDIT (Periodic) — dependency CVEs, license compliance,
#                        verify past findings were actually fixed
#
# This agent OWNS security. If a vulnerability ships to prod,
# this agent failed. It tracks findings, verifies fixes, and
# escalates unresolved issues.
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${1:-scan}"
AGENT="security"

log() { echo "[$(date '+%H:%M:%S')] [SEC] $*"; }

# ────────────────────────────────────────────
# scan — Proactive: secrets, attack surface, hardcoded creds
#   Runs in DISCOVERY phase
# ────────────────────────────────────────────
run_scan() {
    log "🛡️ Scanning for security issues..."

    local prompt_text
    prompt_text=$(load_prompt "security-scan") || { log "Cannot load prompt"; return 1; }

    local result
    result=$(safe_claude "$AGENT" "$prompt_text" \
    --allowedTools "Bash,Read,Glob,Grep") || {
        log "⚠️  Security scan failed"
        return 1
    }

    local result_len=${#result}
    if [ "$result_len" -lt 20 ]; then
        log "🛡️ No security issues found"
        return 0
    fi

    # Parse findings and post to Triage with SECURITY tag
    echo "$result" | python3 -c "
import sys, json
text = sys.stdin.read()
try:
    start = text.index('[')
    end = text.rindex(']') + 1
    issues = json.loads(text[start:end])
    for issue in issues[:5]:
        print(json.dumps(issue))
except (ValueError, json.JSONDecodeError):
    pass
" 2>/dev/null | while IFS= read -r line; do
        [ -z "$line" ] && continue
        local title body
        title=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'[SECURITY] {d[\"title\"]}')")
        body=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'**Priority:** {d[\"priority\"]}\n**Category:** security\n**Files:** {\", \".join(d.get(\"files\",[]))}\n\n{d[\"description\"]}\n\n**Remediation:** {d[\"remediation\"]}')")

        post_discussion "$CAT_TRIAGE" "$title" "$body" "$AGENT_SECURITY" || continue
        log "📤 Posted: $title"
    done
}

# ────────────────────────────────────────────
# review — Security-focused PR review
#   Runs in VERIFY phase, after the general reviewer
#   Dedicated pass because security findings MUST NOT be
#   deprioritized by mixing with style/perf concerns
# ────────────────────────────────────────────
run_review() {
    log "🛡️ Security review of open PRs..."

    local unprocessed
    unprocessed=$(get_unprocessed "$CAT_CODE_REVIEW" "$AGENT_SECURITY") || return 0

    echo "$unprocessed" | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    title = d['title'].replace('\t', ' ')
    body = d['body'][:2000].replace('\t', ' ')
    print(f\"{d['number']}\t{title}\t{body}\")
" 2>/dev/null | while IFS=$'\t' read -r num title body; do
        [ -z "$num" ] && continue
        is_processed "$num" "$AGENT" "sec-reviewed" && continue

        log "🛡️ Security reviewing #$num"

        # Get diff
        local branch_name diff_content=""
        branch_name=$(echo "$body" | sed -n 's/.*Branch:[[:space:]]*`\([^`]*\)`.*/\1/p' | head -1)
        if [ -n "$branch_name" ]; then
            cd "$TARGET_PROJECT"
            git fetch origin 2>/dev/null || true
            local base_branch
            base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || echo "main")
            diff_content=$(git diff "$base_branch"..."origin/$branch_name" 2>/dev/null | head -c 10000)
        fi

        local review_prompt
        review_prompt=$(load_prompt "security-review") || continue
        review_prompt=$(render_prompt "$review_prompt" \
            TITLE "$title" \
            DIFF_CONTENT "$diff_content")

        local result
        result=$(safe_claude "$AGENT" "$review_prompt" \
        --allowedTools "Read,Glob,Grep") || continue

        # Security findings are posted as a SEPARATE comment from the general review
        reply_to_discussion "$num" "$result" "$AGENT_SECURITY" || continue

        # If security BLOCKS, tag it — CTO merge gate checks this
        if echo "$result" | grep -qi "SECURITY BLOCK\|CRITICAL.*security\|P1.*injection\|P1.*auth"; then
            tag_discussion "$num" "security-blocked" || true
            log "🚫 SECURITY BLOCKED #$num"
        fi

        mark_processed "$num" "$AGENT" "sec-reviewed"
    done
}

# ────────────────────────────────────────────
# deploy-check — Verify deployed app security
#   Runs in SHIP phase, after deploy
#   Checks HTTP headers, TLS, exposed endpoints
# ────────────────────────────────────────────
run_deploy_check() {
    log "🛡️ Checking deployed security [${ENV_NAME:-prod}]..."

    local url="${DEPLOY_URL:-}"
    if [ -z "$url" ]; then
        log "  No DEPLOY_URL set, skipping"
        return 0
    fi

    local findings=""
    local has_issues=false

    # Check HTTP security headers
    local headers
    headers=$(curl -sI --connect-timeout 5 --max-time 10 "$url" 2>/dev/null)

    if [ -z "$headers" ]; then
        log "  ⚠️  Cannot reach $url"
        return 0
    fi

    # Required headers
    for header in "strict-transport-security" "x-frame-options" "x-content-type-options" "content-security-policy"; do
        if echo "$headers" | grep -qi "$header"; then
            log "  ✅ $header present"
        else
            findings="$findings\n- **Missing header:** \`$header\`"
            has_issues=true
        fi
    done

    # Check for server version disclosure
    if echo "$headers" | grep -qi "^server:.*[0-9]"; then
        local server_header
        server_header=$(echo "$headers" | grep -i "^server:" | head -1 | tr -d '\r')
        findings="$findings\n- **Server version exposed:** \`$server_header\`"
        has_issues=true
    fi

    # Check TLS (if HTTPS)
    if echo "$url" | grep -q "^https://"; then
        local domain
        domain=$(echo "$url" | sed 's|https://||' | cut -d/ -f1)
        local tls_info
        tls_info=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | openssl x509 -noout -dates -subject 2>/dev/null)
        if echo "$tls_info" | grep -q "notAfter"; then
            local expiry
            expiry=$(echo "$tls_info" | grep "notAfter" | cut -d= -f2)
            local days_left
            days_left=$(( ( $(date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2>/dev/null || date -d "$expiry" +%s 2>/dev/null || echo "0") - $(date +%s) ) / 86400 ))
            if [ "$days_left" -lt 14 ] && [ "$days_left" -gt 0 ]; then
                findings="$findings\n- **TLS cert expires in $days_left days**"
                has_issues=true
            fi
            log "  ✅ TLS cert valid ($days_left days)"
        fi
    fi

    if [ "$has_issues" = true ]; then
        post_or_update "$CAT_ENGINEERING" "🛡️ Security: deploy"  \
"**URL:** $url
$(echo -e "$findings")

---
*Security Agent — deploy-time check.*" "$AGENT_SECURITY" || true
        log "⚠️  Deploy security issues found"
    else
        log "✅ Deploy security checks passed"
    fi
}

# ────────────────────────────────────────────
# audit — Periodic: CVEs, verify past fixes, track open findings
#   Runs as periodic audit
# ────────────────────────────────────────────
run_audit() {
    log "🛡️ Security audit..."

    cd "$TARGET_PROJECT"

    local findings=""

    # 1. Dependency vulnerabilities
    if [ -f "package.json" ]; then
        local audit_out
        audit_out=$(npm audit --json 2>/dev/null || echo '{}')
        local vuln_count
        vuln_count=$(echo "$audit_out" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    v = d.get('metadata',{}).get('vulnerabilities',{})
    print(v.get('high',0) + v.get('critical',0))
except: print(0)
" 2>/dev/null)
        if [ "${vuln_count:-0}" -gt 0 ]; then
            findings="$findings\n### Dependency vulnerabilities: $vuln_count high/critical\n\`\`\`\n$(npm audit --omit=dev 2>/dev/null | head -20)\n\`\`\`"
        fi
    fi

    # 2. Secret scanning (quick grep for common patterns)
    local secrets_found
    secrets_found=$(grep -rn --include='*.js' --include='*.ts' --include='*.jsx' --include='*.tsx' --include='*.json' --include='*.yml' --include='*.yaml' \
        -E "(password|secret|api.?key|token|private.?key)\s*[:=]\s*['\"][^'\"]{8,}" \
        . --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist 2>/dev/null | grep -vi "test\|mock\|example\|placeholder\|TODO\|FIXME\|process\.env\|import\|require" | head -5)
    if [ -n "$secrets_found" ]; then
        findings="$findings\n### Possible hardcoded secrets\n\`\`\`\n$secrets_found\n\`\`\`"
    fi

    # 3. Check .env files committed
    local env_in_git
    env_in_git=$(git ls-files '*.env' '.env*' 2>/dev/null | grep -v '.env.example' | head -5)
    if [ -n "$env_in_git" ]; then
        findings="$findings\n### .env files tracked in git\n$env_in_git"
    fi

    # 4. Verify past security findings were fixed
    local open_sec_todos
    if [ -d "todos" ]; then
        open_sec_todos=$(grep -rl "security\|SECURITY" todos/*.md 2>/dev/null | wc -l | tr -d ' ')
        if [ "${open_sec_todos:-0}" -gt 0 ]; then
            findings="$findings\n### Open security todos: $open_sec_todos unresolved"
        fi
    fi

    if [ -n "$findings" ]; then
        post_discussion "$CAT_TRIAGE" "[SECURITY] Audit findings — $(date '+%Y-%m-%d')" \
"**Priority:** high
**Category:** security

$(echo -e "$findings")

---
*Security Agent — periodic audit.*" "$AGENT_SECURITY" || true
        log "⚠️  Security audit found issues"
    else
        log "✅ Security audit clean"
    fi
}

case "$MODE" in
    scan)         run_scan ;;
    review)       run_review ;;
    deploy-check) run_deploy_check ;;
    audit)        run_audit ;;
    *)            echo "Usage: $0 {scan|review|deploy-check|audit}"; exit 1 ;;
esac
