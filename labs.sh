#!/bin/bash
# ============================================================
# 🧪 labs.sh — Dashboard for all projects × environments
#
# Shows every project's environments with health, branch,
# last commit, and deploy URL.
#
# Usage:
#   ./labs.sh              Show all environments
#   ./labs.sh --watch      Refresh every 30s
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

do_labs() {
    echo "🧪 Agent Factory — Labs"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo ""
    printf "  %-18s %-10s %-10s %-8s %-35s %s\n" "PROJECT" "ENV" "BRANCH" "HEALTH" "LAST COMMIT" "URL"
    printf "  %-18s %-10s %-10s %-8s %-35s %s\n" "───────" "───" "──────" "──────" "───────────" "───"

    local projects_dir="$SCRIPT_DIR/projects"

    for proj_dir in "$projects_dir"/*/; do
        [ -d "$proj_dir" ] || continue
        local project_name
        project_name=$(basename "$proj_dir")

        # Load project config to get TARGET_PROJECT
        local target_project=""
        if [ -f "$proj_dir/config.sh" ]; then
            target_project=$(grep -m1 'TARGET_PROJECT=' "$proj_dir/config.sh" 2>/dev/null | sed 's/.*="\(.*\)"/\1/' | sed "s|\$HOME|$HOME|g" || echo "")
        fi

        # If no envs/ directory, show project with defaults
        if [ ! -d "$proj_dir/envs" ] || [ -z "$(ls -A "$proj_dir/envs" 2>/dev/null)" ]; then
            local health="—"
            local last_commit="—"
            printf "  %-18s %-10s %-10s %-8s %-35s %s\n" \
                "$project_name" "prod" "main" "$health" "$last_commit" "(no envs configured)"
            continue
        fi

        for env_file in "$proj_dir/envs"/*.sh; do
            [ -f "$env_file" ] || continue
            local env_name deploy_branch deploy_url

            env_name=$(basename "$env_file" .sh)
            deploy_branch=$(grep -m1 'DEPLOY_BRANCH=' "$env_file" 2>/dev/null | sed 's/.*="\(.*\)"/\1/' || echo "main")
            deploy_url=$(grep -m1 'DEPLOY_URL=' "$env_file" 2>/dev/null | sed 's/.*="\(.*\)"/\1/' || echo "")

            # Health check
            local health="—"
            if [ -n "$deploy_url" ]; then
                local status
                status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "$deploy_url" 2>/dev/null || echo "000")
                if [ "$status" = "200" ] || [ "$status" = "301" ] || [ "$status" = "302" ]; then
                    health="✅ $status"
                elif [ "$status" = "000" ]; then
                    health="⏳ timeout"
                else
                    health="❌ $status"
                fi
            fi

            # Last commit on the deploy branch
            local last_commit="—"
            if [ -n "$target_project" ] && [ -d "$target_project/.git" ]; then
                last_commit=$(cd "$target_project" && git log -1 --format='%h %s' "origin/$deploy_branch" 2>/dev/null | head -c 35 || echo "—")
            fi

            # Truncate URL for display
            local display_url="$deploy_url"
            if [ ${#display_url} -gt 55 ]; then
                display_url="${display_url:0:52}..."
            fi

            printf "  %-18s %-10s %-10s %-8s %-35s %s\n" \
                "$project_name" "$env_name" "$deploy_branch" "$health" "$last_commit" "$display_url"
        done
    done

    echo ""
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

case "${1:-show}" in
    --watch)
        while true; do
            clear
            do_labs
            sleep 30
        done
        ;;
    show|*)
        do_labs
        ;;
esac
