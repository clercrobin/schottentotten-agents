#!/bin/bash
# ============================================================
# 🚀 spawn.sh — Create a new project instance
#
# Usage:
#   ./spawn.sh <project-name> <target-repo-path> [--owner <github-owner>]
#   ./spawn.sh list                    # List all projects
#
# Example:
#   ./spawn.sh my-app ~/Workspace/my-app
#   ./spawn.sh my-app ~/Workspace/my-app --owner myorg
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ────────────────────────────────────────────
# LIST — Show all projects
# ────────────────────────────────────────────
do_list() {
    local projects_dir="$SCRIPT_DIR/projects"

    if [ ! -d "$projects_dir" ] || [ -z "$(ls -A "$projects_dir" 2>/dev/null)" ]; then
        echo "No projects configured yet."
        echo ""
        echo "Create one with: ./spawn.sh <project-name> <target-repo-path>"
        return 0
    fi

    echo "🏭 Agent Factory — Projects"
    echo "═══════════════════════════"
    echo ""
    printf "  %-20s %-40s %s\n" "PROJECT" "TARGET" "REPO"
    printf "  %-20s %-40s %s\n" "───────" "──────" "────"

    for proj_dir in "$projects_dir"/*/; do
        [ -d "$proj_dir" ] || continue
        local name
        name=$(basename "$proj_dir")
        local target_project="(not set)"
        local github_repo="(not set)"
        local github_owner=""

        if [ -f "$proj_dir/config.sh" ]; then
            # Extract values without executing the full config
            target_project=$(grep -m1 'TARGET_PROJECT=' "$proj_dir/config.sh" 2>/dev/null | sed 's/.*="\(.*\)"/\1/' | sed "s|\$HOME|$HOME|g" || echo "(not set)")
            github_repo=$(grep -m1 'GITHUB_REPO=' "$proj_dir/config.sh" 2>/dev/null | sed 's/.*="\(.*\)"/\1/' || echo "(not set)")
            github_owner=$(grep -m1 'GITHUB_OWNER=' "$proj_dir/config.sh" 2>/dev/null | sed 's/.*="\(.*\)"/\1/' || echo "")
        fi

        local repo_full="${github_owner:+$github_owner/}${github_repo}"
        printf "  %-20s %-40s %s\n" "$name" "$target_project" "$repo_full"
    done

    echo ""
}

# ────────────────────────────────────────────
# SPAWN — Create a new project
# ────────────────────────────────────────────
do_spawn() {
    local project_name="$1"
    local target_path="$2"
    shift 2

    # Parse optional flags
    local owner="${GITHUB_OWNER:-clercrobin}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --owner)
                owner="${2:-}"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    local repo_name="${project_name}-agents"
    local project_dir="$SCRIPT_DIR/projects/$project_name"

    echo "🚀 Spawning project: $project_name"
    echo "   Target:  $target_path"
    echo "   Repo:    $owner/$repo_name"
    echo ""

    # ── Validations ──
    if [ -z "$project_name" ]; then
        echo "❌ Project name is required."
        exit 1
    fi

    # Validate project name (alphanumeric + hyphens only)
    if ! echo "$project_name" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
        echo "❌ Project name must be lowercase alphanumeric with hyphens (e.g., 'my-project')."
        exit 1
    fi

    if [ ! -d "$target_path" ]; then
        echo "❌ Target path does not exist: $target_path"
        exit 1
    fi

    if [ ! -d "$target_path/.git" ]; then
        echo "❌ Target path is not a git repository: $target_path"
        exit 1
    fi

    if [ -d "$project_dir" ]; then
        echo "❌ Project '$project_name' already exists at: $project_dir"
        echo "   Delete it first if you want to recreate: rm -rf $project_dir"
        exit 1
    fi

    # Check prerequisites
    command -v gh >/dev/null 2>&1 || { echo "❌ gh CLI not found. Install: brew install gh"; exit 1; }
    gh auth status &>/dev/null || { echo "❌ Not logged in to GitHub. Run: gh auth login"; exit 1; }

    # ── Step 1: Create GitHub repo ──
    echo "1/5 — Creating GitHub repository: $owner/$repo_name..."
    if gh repo view "$owner/$repo_name" &>/dev/null; then
        echo "   ✅ Repo already exists"
    else
        gh repo create "$repo_name" --public \
            --description "AI Agent Factory — agents for $project_name" \
            --clone=false || {
            echo "❌ Failed to create repo. Check your permissions."
            exit 1
        }
        echo "   ✅ Created repo: $owner/$repo_name"
    fi

    # ── Step 2: Enable Discussions ──
    echo "2/5 — Enabling GitHub Discussions..."
    local repo_id
    repo_id=$(gh api "repos/$owner/$repo_name" --jq .node_id 2>/dev/null) || {
        echo "   ⚠️  Cannot get repo ID — enable Discussions manually"
        repo_id=""
    }

    if [ -n "$repo_id" ]; then
        gh api graphql -f query='
        mutation($repoId: ID!) {
          updateRepository(input: {
            repositoryId: $repoId
            hasDiscussionsEnabled: true
          }) {
            repository { hasDiscussionsEnabled }
          }
        }' -f repoId="$repo_id" &>/dev/null && echo "   ✅ Discussions enabled" || echo "   ⚠️  Enable Discussions manually in repo settings"
    fi

    # ── Step 3: Check Discussion categories ──
    echo "3/5 — Checking Discussion categories..."
    local required_cats=("Triage" "Engineering" "Code Review" "Daily Standup")
    local existing_cats
    existing_cats=$(gh api graphql -f query='
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        discussionCategories(first: 25) {
          nodes { id name }
        }
      }
    }' -f owner="$owner" -f name="$repo_name" --jq '.data.repository.discussionCategories.nodes[].name' 2>/dev/null || echo "")

    local missing_cats=()
    for cat in "${required_cats[@]}"; do
        if echo "$existing_cats" | grep -qx "$cat"; then
            echo "   ✅ Category exists: $cat"
        else
            missing_cats+=("$cat")
            echo "   ❌ Missing category: $cat"
        fi
    done

    if [ ${#missing_cats[@]} -gt 0 ]; then
        echo ""
        echo "   ⚠️  GitHub doesn't allow creating categories via API."
        echo "   Please create them manually at:"
        echo "   👉  https://github.com/$owner/$repo_name/discussions/categories/new"
        echo ""
        echo "   Categories to create (use 'Open-ended' format for all):"
        for cat in "${missing_cats[@]}"; do
            echo "     • $cat"
        done
        echo ""
        read -rp "   Press Enter once you've created the categories (or Ctrl-C to abort)... "
    fi

    # ── Step 4: Create project directory structure ──
    echo "4/5 — Creating project structure..."
    mkdir -p "$project_dir"/{state,logs,prompts,agents}
    mkdir -p "$project_dir/state"/{locks,category_cache}

    # Resolve target path to absolute
    local abs_target
    abs_target=$(cd "$target_path" && pwd)

    # Generate project config
    cat > "$project_dir/config.sh" << PROJEOF
#!/bin/bash
# ============================================================
# Project: $project_name
# Generated by spawn.sh on $(date '+%Y-%m-%d %H:%M')
# ============================================================

export GITHUB_REPO="$repo_name"
export GITHUB_OWNER="$owner"
export TARGET_PROJECT="$abs_target"

# Customize below as needed:
# export CLAUDE_MODEL="opus"
# export CLAUDE_MAX_BUDGET="10.00"
# export POLL_INTERVAL="120"
PROJEOF

    echo "   ✅ Created: $project_dir/"
    echo "   ✅ Generated: $project_dir/config.sh"

    # ── Step 5: Post welcome discussion ──
    echo "5/5 — Posting welcome message..."
    if [ -n "$repo_id" ]; then
        # Find a valid category for welcome post
        local welcome_cat_id=""
        for try_cat in "Daily Standup" "General" "Announcements"; do
            welcome_cat_id=$(gh api graphql -f query='
            query($owner: String!, $name: String!) {
              repository(owner: $owner, name: $name) {
                discussionCategories(first: 25) {
                  nodes { id name }
                }
              }
            }' -f owner="$owner" -f name="$repo_name" \
               --jq ".data.repository.discussionCategories.nodes[] | select(.name==\"$try_cat\") | .id" 2>/dev/null || echo "")
            if [ -n "$welcome_cat_id" ]; then
                break
            fi
        done

        if [ -n "$welcome_cat_id" ]; then
            gh api graphql -f query='
            mutation($repoId: ID!, $catId: ID!, $title: String!, $body: String!) {
              createDiscussion(input: {
                repositoryId: $repoId
                categoryId: $catId
                title: $title
                body: $body
              }) {
                discussion { url }
              }
            }' -f repoId="$repo_id" \
               -f catId="$welcome_cat_id" \
               -f title="🏭 Agent Factory Online — $project_name" \
               -f body="The AI Agent Factory is now operational for **$project_name**.

**Active Agents:**
- 🎯 CTO Agent — triages issues, assigns work, decides deploys
- 👷 Senior Engineer Agent — implements features, fixes bugs, writes tests
- 🔎 Code Reviewer Agent — reviews PRs, checks quality

**Target Project:** \`$abs_target\`

All agents communicate here via Discussions." \
            &>/dev/null && echo "   ✅ Welcome message posted" || echo "   ⚠️  Could not post welcome message"
        else
            echo "   ⚠️  No valid category for welcome message — create categories first"
        fi
    fi

    echo ""
    echo "════════════════════════════════════════════════"
    echo "✅ Project '$project_name' spawned!"
    echo ""
    echo "Usage:"
    echo "  ./kick.sh --project $project_name cto scan"
    echo "  ./orchestrator.sh --project $project_name --once"
    echo "  ./factory.sh --project $project_name start"
    echo ""
    echo "Or set default project:"
    echo "  echo '$project_name' > .current-project"
    echo "  export AI_AGENT_PROJECT=$project_name"
    echo ""
    echo "Customize:"
    echo "  Edit:   projects/$project_name/config.sh"
    echo "  Prompts: projects/$project_name/prompts/   (override any base prompt)"
    echo "  Agents:  projects/$project_name/agents/    (override or add agents)"
    echo ""
    echo "Forum: https://github.com/$owner/$repo_name/discussions"
    echo "════════════════════════════════════════════════"
}

# ────────────────────────────────────────────
# MAIN
# ────────────────────────────────────────────
case "${1:-help}" in
    list)
        do_list
        ;;
    help|-h|--help)
        echo "🚀 spawn.sh — Create a new project instance"
        echo ""
        echo "Usage:"
        echo "  ./spawn.sh <project-name> <target-repo-path> [--owner <github-owner>]"
        echo "  ./spawn.sh list"
        echo ""
        echo "Examples:"
        echo "  ./spawn.sh my-app ~/Workspace/my-app"
        echo "  ./spawn.sh my-app ~/Workspace/my-app --owner myorg"
        echo "  ./spawn.sh list"
        ;;
    *)
        if [ $# -lt 2 ]; then
            echo "❌ Usage: ./spawn.sh <project-name> <target-repo-path>"
            exit 1
        fi
        do_spawn "$@"
        ;;
esac
