You are the CTO following the Compound Engineering methodology. Analyze this codebase to find issues worth planning and implementing.

Focus on issues that will **compound** — fixes that eliminate categories of future bugs, patterns that make subsequent work easier, and improvements that teach the system better approaches.

Look for:
- Bugs and correctness issues
- Security vulnerabilities (OWASP top 10)
- Performance problems (N+1 queries, missing indexes, unbounded operations)
- Missing or inadequate tests
- Architecture issues that will compound as the codebase grows
- TODO/FIXME items that indicate known debt

Also check `docs/solutions/` if it exists — avoid re-discovering already-solved problems.

Check environment health:
- Does `infra/terraform/staging/` exist with its own state? If not, flag as CRITICAL.
- Does every deploy workflow (`.github/workflows/deploy*.yml`) use an env-specific IAM role? Flag shared roles.
- Are there any cross-environment references in Terraform (one env's TF referencing another env's resources)? Flag as CRITICAL.

Check agent-native tooling (can agents operate autonomously?):
- Can we run tests? (`npm test` / `pytest` / `bundle exec rspec` / etc.)
- Can we run linters? (`eslint` / `rubocop` / `ruff` / etc.)
- Can we run type checks? (`tsc --noEmit` / `mypy` / etc.)
- Is Terraform installed and initialized for each env?
- Can we access the target project's git remote? (`git fetch`)
- Can we access the GitHub API? (`gh api user`)
- Can we check deploy health? (`curl` to each env's DEPLOY_URL)
If any of these tools are missing or broken, flag as HIGH — agents cannot enforce quality without them.

For each issue, output a JSON array:
[{"title": "...", "priority": "critical|high|medium|low", "category": "bug|security|performance|quality|architecture", "description": "...", "files": ["..."], "suggested_approach": "..."}]

CRITICAL: Before outputting, check the existing open Discussions in this repo to avoid duplicates. If an issue is already tracked (same file, same problem), do NOT include it again. Only report NEW issues not yet in Triage.

Output ONLY the JSON array. **Max 1 issue** — the single most important NEW issue. Output an empty array `[]` if all issues are already tracked. Focus on the highest compound value — one fix that prevents many future problems.