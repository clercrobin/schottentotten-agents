#!/bin/bash
# ============================================================
# GitHub Discussions API wrapper
# All agent communication goes through these functions
#
# NOTE: Compatible with bash 3.2 (macOS default).
# No associative arrays, no bash 4+ features.
# ============================================================

# Config is expected to be already loaded by the entry-point script via config-loader.sh.
# Only load config.sh as fallback if BASE_DIR is not set (direct invocation).
if [ -z "${BASE_DIR:-}" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
fi
source "$(dirname "${BASH_SOURCE[0]}")/state.sh"

# File-based category cache (works on bash 3.2, persists across subshells)
_CAT_CACHE_DIR="${STATE_DIR}/category_cache"
mkdir -p "$_CAT_CACHE_DIR"

# ────────────────────────────────────────────
# Internal: check a GraphQL response for errors.
# GitHub returns HTTP 200 + {"errors": [...]} on failures like
# Discussions disabled, auth issues, etc.
# Usage: _check_graphql_response "$json"
# Returns 0 if OK, 1 if errors found (prints error to stderr)
# ────────────────────────────────────────────
_check_graphql_response() {
    local json="$1"
    echo "$json" | python3 -c "
import sys, json, re
try:
    raw = sys.stdin.read()
    raw = re.sub(r'[\x00-\x1f\x7f]', lambda m: ' ' if m.group() not in '\n\r\t' else m.group(), raw)
    data = json.loads(raw)
    if 'errors' in data:
        msgs = [e.get('message', '?') for e in data['errors']]
        print('GraphQL errors: ' + '; '.join(msgs), file=sys.stderr)
        sys.exit(1)
    if data.get('data') is None:
        print('GraphQL returned null data', file=sys.stderr)
        sys.exit(1)
except json.JSONDecodeError as e:
    print(f'Invalid JSON from GitHub API: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1 >&2
}

# ────────────────────────────────────────────
# Resolve a category name to its node ID (cached to file)
# ────────────────────────────────────────────
_resolve_category_id() {
    local category_name="$1"

    # Check file cache first
    local cache_key
    cache_key=$(echo "$category_name" | tr ' /' '__')
    local cache_file="$_CAT_CACHE_DIR/$cache_key"
    if [ -f "$cache_file" ]; then
        cat "$cache_file"
        return 0
    fi

    local all_cats
    all_cats=$(gh api graphql \
        -F owner="$GITHUB_OWNER" \
        -F repo="$GITHUB_REPO" \
        -f query='
        query($owner: String!, $repo: String!) {
          repository(owner: $owner, name: $repo) {
            discussionCategories(first: 20) {
              nodes { id name }
            }
          }
        }') || { echo "ERROR: Cannot fetch categories from GitHub" >&2; return 1; }

    # Check for GraphQL-level errors
    _check_graphql_response "$all_cats" || return 1

    local cat_id
    cat_id=$(echo "$all_cats" | MATCH_NAME="$category_name" python3 -c "
import sys, json, os
target = os.environ['MATCH_NAME']
try:
    data = json.load(sys.stdin)
    cats = data['data']['repository']['discussionCategories']['nodes']
    for c in cats:
        if c['name'] == target:
            print(c['id'])
            break
    else:
        print(f'Category not found: {target}', file=sys.stderr)
        sys.exit(1)
except (KeyError, TypeError, json.JSONDecodeError) as e:
    print(f'ERROR parsing categories: {e}', file=sys.stderr)
    sys.exit(1)
") || { echo "ERROR: category '$category_name' not found" >&2; return 1; }

    if [ -n "$cat_id" ]; then
        # Atomic write: write to temp, then mv (prevents races)
        local tmp_cache
        tmp_cache=$(mktemp "$_CAT_CACHE_DIR/.tmp.XXXXXX")
        echo "$cat_id" > "$tmp_cache"
        mv "$tmp_cache" "$cache_file"
        echo "$cat_id"
    else
        return 1
    fi
}

# ────────────────────────────────────────────
# Get repo node ID
# ────────────────────────────────────────────
_repo_id() {
    gh api "repos/$GITHUB_REPO_FULL" --jq '.node_id'
}

# ────────────────────────────────────────────
# Post a new discussion
# Usage: post_discussion "Category" "Title" "Body" "agent-label"
# Returns: discussion number
# ────────────────────────────────────────────
post_discussion() {
    local category_name="$1"
    local title="$2"
    local body="$3"
    local agent_label="${4:-system}"

    # Env-tag: prefix title so discussions are filterable by environment
    local env_tag="${ENV_NAME:-prod}"
    title="[$env_tag] $title"

    local repo_id cat_id
    repo_id=$(_repo_id) || { echo "ERROR: cannot get repo ID" >&2; return 1; }
    cat_id=$(_resolve_category_id "$category_name") || return 1

    local signed_body
    signed_body="**[$agent_label]** · \`$env_tag\` — $(date -u '+%Y-%m-%d %H:%M UTC')

$body"

    local result
    result=$(gh api graphql \
        -F repoId="$repo_id" \
        -F catId="$cat_id" \
        -F title="$title" \
        -F body="$signed_body" \
        -f query='
        mutation($repoId: ID!, $catId: ID!, $title: String!, $body: String!) {
          createDiscussion(input: {
            repositoryId: $repoId
            categoryId: $catId
            title: $title
            body: $body
          }) {
            discussion { id number url }
          }
        }') || { echo "ERROR: createDiscussion API call failed" >&2; return 1; }

    _check_graphql_response "$result" || return 1

    echo "$result" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['data']['createDiscussion']['discussion']['number'])
except (KeyError, TypeError, json.JSONDecodeError) as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
"
}

# ────────────────────────────────────────────
# Reply to an existing discussion
# Usage: reply_to_discussion <discussion_number> "Body" "agent-label"
# ────────────────────────────────────────────
reply_to_discussion() {
    local discussion_number="$1"
    local body="$2"
    local agent_label="${3:-system}"

    local disc_id
    disc_id=$(gh api graphql \
        -F owner="$GITHUB_OWNER" \
        -F repo="$GITHUB_REPO" \
        -F num="$discussion_number" \
        -f query='
        query($owner: String!, $repo: String!, $num: Int!) {
          repository(owner: $owner, name: $repo) {
            discussion(number: $num) { id }
          }
        }' --jq '.data.repository.discussion.id') || {
        echo "ERROR: cannot resolve discussion #$discussion_number" >&2
        return 1
    }

    # Guard: don't call mutation with empty ID
    if [ -z "$disc_id" ] || [ "$disc_id" = "null" ]; then
        echo "ERROR: discussion #$discussion_number returned empty/null ID" >&2
        return 1
    fi

    local env_tag="${ENV_NAME:-prod}"
    local signed_body="**[$agent_label]** · \`$env_tag\` — $(date -u '+%Y-%m-%d %H:%M UTC')

$body"

    local mutation_result
    mutation_result=$(gh api graphql \
        -F discId="$disc_id" \
        -F body="$signed_body" \
        -f query='
        mutation($discId: ID!, $body: String!) {
          addDiscussionComment(input: {
            discussionId: $discId
            body: $body
          }) {
            comment { id }
          }
        }') || {
        echo "ERROR: reply to #$discussion_number failed" >&2
        return 1
    }

    _check_graphql_response "$mutation_result" || return 1
    return 0
}

# ────────────────────────────────────────────
# Get recent discussions from a category (server-side filtered)
# Usage: get_discussions "Category" [limit]
# Returns JSON array (empty [] on error)
# ────────────────────────────────────────────
get_discussions() {
    local category_name="$1"
    local limit="${2:-10}"

    local cat_id
    cat_id=$(_resolve_category_id "$category_name") || return 1

    local raw
    raw=$(gh api graphql \
        -F owner="$GITHUB_OWNER" \
        -F repo="$GITHUB_REPO" \
        -F catId="$cat_id" \
        -F limit="$limit" \
        -f query='
        query($owner: String!, $repo: String!, $catId: ID!, $limit: Int!) {
          repository(owner: $owner, name: $repo) {
            discussions(first: $limit, categoryId: $catId, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number
                title
                body
                createdAt
                category { name }
                comments(first: 10) {
                  nodes { body createdAt }
                }
              }
            }
          }
        }') || { echo "[]"; return 1; }

    # Sanitize control characters from discussion bodies before JSON parsing
    raw=$(printf '%s' "$raw" | python3 -c "import sys,re; sys.stdout.write(re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', '', sys.stdin.read()))" 2>/dev/null || echo "$raw")

    _check_graphql_response "$raw" || { echo "[]"; return 1; }

    local env_tag="${ENV_NAME:-prod}"

    echo "$raw" | ENV_TAG="$env_tag" python3 -c "
import sys, json, os
env_tag = os.environ.get('ENV_TAG', 'prod')
try:
    data = json.load(sys.stdin)
    discussions = data['data']['repository']['discussions']['nodes']
    # Filter by env tag
    discussions = [d for d in discussions if d.get('title', '').startswith(f'[{env_tag}]')]
    for d in discussions:
        d['comment_count'] = len(d['comments']['nodes'])
        d['last_comments'] = [c['body'] for c in d['comments']['nodes']]
    print(json.dumps(discussions, indent=2))
except (KeyError, TypeError, json.JSONDecodeError) as e:
    print(f'ERROR: {e}', file=sys.stderr)
    print('[]')
"
}

# ────────────────────────────────────────────
# Get unprocessed discussions (no reply from a specific agent)
# Usage: get_unprocessed "Category" "agent-label"
# Returns JSON array (empty [] on error)
# ────────────────────────────────────────────
get_unprocessed() {
    local category_name="$1"
    local agent_label="$2"

    local cat_id
    cat_id=$(_resolve_category_id "$category_name") || return 1

    local raw
    raw=$(gh api graphql \
        -F owner="$GITHUB_OWNER" \
        -F repo="$GITHUB_REPO" \
        -F catId="$cat_id" \
        -f query='
        query($owner: String!, $repo: String!, $catId: ID!) {
          repository(owner: $owner, name: $repo) {
            discussions(first: 20, categoryId: $catId, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number
                title
                body
                createdAt
                category { name }
                comments(first: 20) {
                  nodes { body }
                }
              }
            }
          }
        }') || { echo "[]"; return 1; }

    # Sanitize control characters from discussion bodies before JSON parsing
    raw=$(printf '%s' "$raw" | python3 -c "import sys,re; sys.stdout.write(re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', '', sys.stdin.read()))" 2>/dev/null || echo "$raw")

    _check_graphql_response "$raw" || { echo "[]"; return 1; }

    local env_tag="${ENV_NAME:-prod}"

    echo "$raw" | AGENT_LABEL="$agent_label" ENV_TAG="$env_tag" python3 -c "
import sys, json, os
agent_label = os.environ['AGENT_LABEL']
env_tag = os.environ['ENV_TAG']
try:
    data = json.load(sys.stdin)
    discussions = data['data']['repository']['discussions']['nodes']
    filtered = []
    for d in discussions:
        # Filter by env tag — only process discussions for this environment
        title = d.get('title', '')
        if not title.startswith(f'[{env_tag}]'):
            continue
        agent_replied = any(f'[{agent_label}]' in c['body'] for c in d['comments']['nodes'])
        if not agent_replied:
            filtered.append({
                'number': d['number'],
                'title': d['title'],
                'body': d['body'],
                'comments': [c['body'] for c in d['comments']['nodes']]
            })
    print(json.dumps(filtered, indent=2))
except (KeyError, TypeError, json.JSONDecodeError) as e:
    print(f'ERROR: {e}', file=sys.stderr)
    print('[]')
"
}

# ────────────────────────────────────────────
# Mark a discussion with a comment tag (replaces labels — Discussions
# don't support GitHub labels via the API)
# Usage: tag_discussion <discussion_number> <tag>
# ────────────────────────────────────────────
tag_discussion() {
    local discussion_number="$1"
    local tag="$2"
    reply_to_discussion "$discussion_number" "**Status:** \`$tag\`" "system"
}

# ────────────────────────────────────────────
# Update a discussion's title (for lifecycle status tracking)
# Usage: update_discussion_title <discussion_number> "New Title"
# ────────────────────────────────────────────
update_discussion_title() {
    local discussion_number="$1"
    local new_title="$2"

    local disc_id
    disc_id=$(gh api graphql \
        -F owner="$GITHUB_OWNER" \
        -F repo="$GITHUB_REPO" \
        -F num="$discussion_number" \
        -f query='
        query($owner: String!, $repo: String!, $num: Int!) {
          repository(owner: $owner, name: $repo) {
            discussion(number: $num) { id }
          }
        }' --jq '.data.repository.discussion.id' 2>/dev/null) || return 1

    [ -z "$disc_id" ] || [ "$disc_id" = "null" ] && return 1

    gh api graphql \
        -F id="$disc_id" \
        -F title="$new_title" \
        -f query='
        mutation($id: ID!, $title: String!) {
          updateDiscussion(input: {
            discussionId: $id
            title: $title
          }) {
            discussion { title }
          }
        }' &>/dev/null || return 1
}

# ────────────────────────────────────────────
# Update lifecycle status in a discussion title
# Replaces [STATUS] prefix while keeping the topic
# Usage: update_status <discussion_number> "NEW_STATUS" "topic title"
#
# Example: update_status 42 "REVIEW" "applyMove exception"
# Result:  "[staging] [REVIEW] applyMove exception"
# ────────────────────────────────────────────
update_status() {
    local discussion_number="$1"
    local new_status="$2"
    local topic="$3"

    local env_tag="${ENV_NAME:-prod}"
    local new_title="[$env_tag] [$new_status] $topic"

    update_discussion_title "$discussion_number" "$new_title"
}

# ────────────────────────────────────────────
# Post or update a "pinned" discussion — reuses an existing
# discussion with the same title prefix instead of creating a new one.
# Use for recurring reports (quality gate, security, staging status).
#
# Usage: post_or_update "Category" "Title Prefix" "Body" "agent-label"
# Returns: discussion number
# ────────────────────────────────────────────
post_or_update() {
    local category_name="$1"
    local title_prefix="$2"
    local body="$3"
    local agent_label="${4:-system}"

    local env_tag="${ENV_NAME:-prod}"

    # Search for existing discussion with this prefix
    local existing_num
    existing_num=$(get_discussions "$category_name" 20 2>/dev/null | ENV_TAG="$env_tag" TITLE_PREFIX="$title_prefix" python3 -c "
import sys, json, os
env_tag = os.environ.get('ENV_TAG', 'prod')
prefix = os.environ.get('TITLE_PREFIX', '')
try:
    for d in json.load(sys.stdin):
        title = d.get('title', '')
        if prefix in title:
            print(d['number'])
            break
except (json.JSONDecodeError, KeyError):
    pass
" 2>/dev/null)

    if [ -n "$existing_num" ]; then
        # Update: reply to existing discussion
        reply_to_discussion "$existing_num" "$body" "$agent_label" || return 1
        echo "$existing_num"
    else
        # Create new discussion
        post_discussion "$category_name" "$title_prefix" "$body" "$agent_label"
    fi
}
