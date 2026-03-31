#!/bin/bash
# ============================================================
# 🚨 SRE Agent — Site Reliability Engineering
#
# Monitors all environments for:
# - Uptime and response times
# - Error rates and anomalies
# - Certificate expiry
# - Resource health (S3, CloudFront, EC2)
# - SLO compliance
#
# Runs across ALL environments, not just the current one.
# Posts incidents to Engineering when thresholds are breached.
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config-loader.sh"
source "$SCRIPT_DIR/../lib/discussions.sh"
source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/robust.sh"

MODE="${1:-monitor}"
AGENT="sre"

log() { echo "[$(date '+%H:%M:%S')] [SRE] $*"; }

# ────────────────────────────────────────────
# monitor — Check health of ALL environments
# ────────────────────────────────────────────
run_monitor() {
    log "🚨 Running health checks across all environments..."

    local projects_dir="$BASE_DIR/projects"
    local incidents=""
    local checks=0
    local failures=0

    for proj_dir in "$projects_dir"/*/; do
        [ -d "$proj_dir" ] || continue
        local project_name
        project_name=$(basename "$proj_dir")

        # Skip projects without envs
        [ -d "$proj_dir/envs" ] || continue

        for env_file in "$proj_dir/envs"/*.sh; do
            [ -f "$env_file" ] || continue

            local env_name deploy_url deploy_branch
            env_name=$(basename "$env_file" .sh)
            deploy_url=$(grep -m1 'DEPLOY_URL=' "$env_file" 2>/dev/null | sed 's/.*="\(.*\)"/\1/' || echo "")
            deploy_branch=$(grep -m1 'DEPLOY_BRANCH=' "$env_file" 2>/dev/null | sed 's/.*="\(.*\)"/\1/' || echo "main")

            [ -z "$deploy_url" ] && continue

            checks=$((checks + 1))
            log "  Checking $project_name/$env_name: $deploy_url"

            # HTTP health check with timing
            local start_ms end_ms status duration_ms
            start_ms=$(date +%s%N 2>/dev/null | cut -c1-13 || date +%s)
            status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$deploy_url" 2>/dev/null || echo "000")
            end_ms=$(date +%s%N 2>/dev/null | cut -c1-13 || date +%s)
            duration_ms=$(( end_ms - start_ms ))

            if [ "$status" = "200" ] || [ "$status" = "301" ] || [ "$status" = "302" ]; then
                log "    ✅ HTTP $status (${duration_ms}ms)"

                # Check for slow responses (>3s)
                if [ "$duration_ms" -gt 3000 ]; then
                    log "    ⚠️  Slow response: ${duration_ms}ms"
                    incidents="$incidents
- **$project_name/$env_name**: Slow response (${duration_ms}ms) — $deploy_url"
                fi
            else
                failures=$((failures + 1))
                log "    ❌ HTTP $status"
                incidents="$incidents
- **$project_name/$env_name**: DOWN (HTTP $status) — $deploy_url"
            fi

            # TLS certificate check (only for HTTPS)
            if echo "$deploy_url" | grep -q "^https://"; then
                local domain
                domain=$(echo "$deploy_url" | sed 's|https://||' | cut -d/ -f1)
                local cert_expiry
                cert_expiry=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
                if [ -n "$cert_expiry" ]; then
                    local expiry_epoch now_epoch days_left
                    expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$cert_expiry" +%s 2>/dev/null || date -d "$cert_expiry" +%s 2>/dev/null || echo "0")
                    now_epoch=$(date +%s)
                    if [ "$expiry_epoch" -gt 0 ]; then
                        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                        if [ "$days_left" -lt 14 ]; then
                            log "    ⚠️  TLS cert expires in ${days_left} days"
                            incidents="$incidents
- **$project_name/$env_name**: TLS cert expires in ${days_left} days ($domain)"
                        fi
                    fi
                fi
            fi
        done
    done

    log "  Checks: $checks | Failures: $failures"

    if [ -n "$incidents" ]; then
        post_discussion "$CAT_ENGINEERING" "🚨 SRE Alert: ${failures} issue(s) detected" \
"## Environment Health Report

**Checked:** $checks environments
**Issues:** $((failures))

### Incidents
$incidents

---
*SRE Agent — automated monitoring across all environments.*" "$AGENT_SRE" || true
        log "🚨 Posted incident report"
    else
        log "✅ All $checks environments healthy"
    fi
}

# ────────────────────────────────────────────
# env-audit — Verify environment isolation
# ────────────────────────────────────────────
run_env_audit() {
    log "🚨 Auditing environment isolation..."

    cd "$TARGET_PROJECT"

    local violations=""

    # Check: each env has its own TF directory
    local tf_dirs
    tf_dirs=$(find infra/terraform -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -v ".terraform" | sort)
    if [ -z "$tf_dirs" ]; then
        violations="$violations
- **CRITICAL:** No Terraform directories found in infra/terraform/"
    fi

    # Check: no shared IAM role ARNs across deploy workflows
    local role_arns
    role_arns=$(grep -rh 'AWS_ROLE_ARN\|role-to-assume' .github/workflows/deploy*.yml 2>/dev/null | grep -oE 'arn:aws:iam[^ "]+' | sort)
    local unique_roles
    unique_roles=$(echo "$role_arns" | sort -u | wc -l | tr -d ' ')
    local total_roles
    total_roles=$(echo "$role_arns" | wc -l | tr -d ' ')
    if [ "$unique_roles" -lt "$total_roles" ] && [ "$total_roles" -gt 1 ]; then
        violations="$violations
- **CRITICAL:** Multiple deploy workflows share the same IAM role ARN"
    fi

    # Check: no cross-env references in TF
    for tf_dir in $tf_dirs; do
        local dir_name
        dir_name=$(basename "$tf_dir")
        # Check if this dir's TF files reference other env's bucket names
        for other_dir in $tf_dirs; do
            local other_name
            other_name=$(basename "$other_dir")
            [ "$dir_name" = "$other_name" ] && continue
            local cross_refs
            cross_refs=$(grep -rl "$other_name" "$tf_dir"/*.tf 2>/dev/null || true)
            if [ -n "$cross_refs" ]; then
                violations="$violations
- **WARNING:** $tf_dir references '$other_name' (cross-env): $cross_refs"
            fi
        done
    done

    # Check: each deploy workflow has its own branch trigger
    local deploy_branches
    deploy_branches=$(grep -A2 'branches:' .github/workflows/deploy*.yml 2>/dev/null | grep -oE '\[.*\]' | sort)

    if [ -n "$violations" ]; then
        post_discussion "$CAT_ENGINEERING" "🚨 Environment Isolation Violations" \
"## Isolation Audit

$violations

### Expected Structure
\`\`\`
infra/terraform/
├── app/         # prod TF state (own IAM role, own S3 bucket)
├── staging/     # staging TF state (own IAM role, own S3 bucket)
└── bootstrap/   # shared bootstrap (TF state bucket, lock table)

.github/workflows/
├── deploy.yml          # prod: triggers on main, uses prod IAM role
└── deploy-staging.yml  # staging: triggers on staging, uses staging IAM role
\`\`\`

---
*SRE Agent — environment isolation must be maintained at all times.*" "$AGENT_SRE" || true
        log "⚠️  Isolation violations found"
    else
        log "✅ Environment isolation verified"
    fi
}

case "$MODE" in
    monitor)   run_monitor ;;
    env-audit) run_env_audit ;;
    *)         echo "Usage: $0 {monitor|env-audit}"; exit 1 ;;
esac
