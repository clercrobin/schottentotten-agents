#!/bin/bash
# ============================================================
# AI Agent Factory — Setup Script
# Creates the GitHub repo, enables Discussions, queries categories
# ============================================================
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

echo "🏗️  Setting up AI Agent Factory..."
echo ""

# Check prerequisites
command -v gh >/dev/null 2>&1 || { echo "❌ gh CLI not found. Install: brew install gh"; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "❌ claude CLI not found. Install Claude Code first."; exit 1; }

# Check gh auth
gh auth status || { echo "❌ Not logged in to GitHub. Run: gh auth login"; exit 1; }

echo ""
echo "1/4 — Creating GitHub repository..."
if gh repo view "$GITHUB_REPO_FULL" &>/dev/null; then
    echo "   ✅ Repo already exists: $GITHUB_REPO_FULL"
else
    gh repo create "$GITHUB_REPO" --public --description "AI Agent Factory — Multi-agent dev pipeline powered by Claude Code" --clone=false
    echo "   ✅ Created repo: $GITHUB_REPO_FULL"
fi

echo ""
echo "2/4 — Enabling GitHub Discussions..."
REPO_ID=$(gh api "repos/$GITHUB_REPO_FULL" --jq .node_id)
gh api graphql -f query='
mutation($repoId: ID!) {
  updateRepository(input: {
    repositoryId: $repoId
    hasDiscussionsEnabled: true
  }) {
    repository { hasDiscussionsEnabled }
  }
}' -f repoId="$REPO_ID" 2>/dev/null && echo "   ✅ Discussions enabled" || echo "   ⚠️  Enable Discussions manually: Settings → Features → Discussions"

echo ""
echo "3/4 — Checking Discussion categories..."

# GitHub API does NOT support creating Discussion categories.
# They must be created via the web UI. Query what exists and report.
REQUIRED_CATS=("Triage" "Engineering" "Code Review" "Daily Standup" "Incidents")

existing_cats=$(gh api graphql -f query='
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    discussionCategories(first: 25) {
      nodes { id name }
    }
  }
}' -f owner="$GITHUB_OWNER" -f name="$GITHUB_REPO" --jq '.data.repository.discussionCategories.nodes[].name' 2>/dev/null || echo "")

missing_cats=()
for cat in "${REQUIRED_CATS[@]}"; do
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
    echo "   👉  https://github.com/$GITHUB_REPO_FULL/discussions/categories/new"
    echo ""
    echo "   Categories to create (use 'Open-ended' format for all):"
    for cat in "${missing_cats[@]}"; do
        echo "     • $cat"
    done
    echo ""
    read -rp "   Press Enter once you've created all categories (or Ctrl-C to abort)... "
    echo ""
    echo "   Re-checking categories..."
    existing_cats=$(gh api graphql -f query='
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        discussionCategories(first: 25) {
          nodes { id name }
        }
      }
    }' -f owner="$GITHUB_OWNER" -f name="$GITHUB_REPO" --jq '.data.repository.discussionCategories.nodes[].name' 2>/dev/null || echo "")

    still_missing=()
    for cat in "${REQUIRED_CATS[@]}"; do
        if echo "$existing_cats" | grep -qx "$cat"; then
            echo "   ✅ $cat"
        else
            still_missing+=("$cat")
            echo "   ❌ Still missing: $cat"
        fi
    done

    if [ ${#still_missing[@]} -gt 0 ]; then
        echo ""
        echo "   ⚠️  Some categories still missing. The agents will only use categories that exist."
        echo "   You can create them later and restart the agents."
    fi
fi

echo ""
echo "4/4 — Posting welcome message..."

# Find a valid category for the welcome post (prefer Daily Standup, fall back to General/Announcements)
welcome_cat_id=""
for try_cat in "Daily Standup" "General" "Announcements"; do
    welcome_cat_id=$(gh api graphql -f query='
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        discussionCategories(first: 25) {
          nodes { id name }
        }
      }
    }' -f owner="$GITHUB_OWNER" -f name="$GITHUB_REPO" \
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
    }' -f repoId="$REPO_ID" \
       -f catId="$welcome_cat_id" \
       -f title="🏭 Agent Factory Online" \
       -f body="The AI Agent Factory is now operational.

**Active Agents:**
- 🎯 CTO Agent — triages issues, assigns work, decides deploys
- 👷 Senior Engineer Agent — implements features, fixes bugs, writes tests
- 🔎 Code Reviewer Agent — reviews PRs, checks quality

**Target Project:** \`$TARGET_PROJECT\`

All agents communicate here via Discussions. The orchestrator polls every ${POLL_INTERVAL} seconds." \
    && echo "   ✅ Welcome message posted" || echo "   ⚠️  Could not post welcome message"
else
    echo "   ⚠️  No valid category found for welcome message. Create categories first."
fi

echo ""
echo "============================================"
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Create any missing Discussion categories (links above)"
echo "  2. Run: ./install.sh   (to set up launchd daemon)"
echo "  3. Or:  ./kick.sh cto scan   (to test a single run)"
echo "============================================"
