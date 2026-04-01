# Project Rules — auto-generated from past work
# Last updated: 2026-04-02

## Must-follow rules (from past P1/critical findings)

- **Snapshot-rollback all engine mutations.** Every call to `applyMove`, `applyPass`, `applyClaim`, `declineClaim`, `applyDrawChoice` in `server/index.js` must be wrapped in `const snapshot = structuredClone(game.state); try { ... } catch (err) { game.state = snapshot; ... }`. No polyfill — Node >= 17 is already required. From: `docs/solutions/2026-03-30-snapshot-rollback-engine-mutation-handlers.md`

- **Idempotency guard before side effects.** Any function callable from multiple game-end paths (timeout, disconnect, normal end) must set `game.completed = true` synchronously *before* any `await` or side effect. A guard placed after an `await` is a race condition in disguise. From: `docs/solutions/2026-03-31-tactic-card-coverage-and-engine-fixes.md`

- **Bounds-check array indices against `.length`, not magic numbers.** Use `index >= array.length`, not `index > 8`. Magic numbers diverge silently when data shapes change and are off-by-one bugs waiting to happen. Pair with a boundary-valid and boundary-invalid test. From: `docs/solutions/2026-03-31-bounds-check-off-by-one-stone-index.md`

- **Null + type guard before accessing discriminated union fields.** When `pendingAction` is a union, always guard: `if (!pendingAction || pendingAction.type !== "<expected-type>") return;`. See `handleRecruiterDrawChoice` in `src/App.jsx` as the canonical reference. From: `docs/solutions/2026-03-30-null-guard-pending-action.md`

## Should-follow rules (from past P2 findings)

- **Handlers must delegate to exported helpers — never duplicate.** When business logic is extracted to a pure function and exported, the live handler must call the export. Exporting without refactoring the handler creates a parallel implementation that diverges silently. From: `docs/solutions/2026-03-31-pure-function-extraction-for-component-testing.md`

- **Add `now = Date.now()` to any extracted function with a time dependency.** This costs nothing, avoids fake-timer complexity in tests, and keeps tests fully deterministic. From: same

- **Use `ws.ip` (attached at connection time) in close handlers — not the closure variable.** Variables in scope at connection setup may be undefined when the close handler fires. Pattern: `ws.ip = ip` at connection time; use `ws.ip` in close handler. From: `docs/solutions/2026-03-31-tactic-card-coverage-and-engine-fixes.md`

- **Memoization caches use FIFO size caps; security/state Maps use TTL cleanup.** Two distinct Map patterns: (1) computation caches (`_formationCache`) use a FIFO size cap (`FORMATION_CACHE_MAX`) with `_cache.delete(_cache.keys().next().value)` on overflow, plus an exported `clearXCache()` for test isolation; (2) security/connection tracking Maps (`ipStrikes`, `connectionsByIp`) use interval-based TTL eviction in the 30s `setInterval` cleanup loop — never a fixed size cap. From: `docs/solutions/2026-03-31-tactic-card-coverage-and-engine-fixes.md` and `server/index.js` commit #35.

- **Ban check is the first gate at connection time.** In `wss.on("connection")`, `isIpBanned(ip)` must run before `MAX_CONN_PER_IP`, before any message handling. A ban that only fires after the connection count check can be bypassed by clients that hit the limit and rotate. From: `server/index.js` commit #35.

- **Card-move tests must assert specific IDs, not just counts.** `hand.length === N` passes even if the wrong cards moved. Assert that expected IDs are absent from hand and present in destination. From: `docs/solutions/2026-03-31-tactic-card-coverage-and-engine-fixes.md`

- **Do not trust `X-Forwarded-For` without a proxy allowlist.** Per-IP rate limits can be bypassed with spoofed headers. Use `req.socket.remoteAddress` when not behind a known proxy, or validate against a configured trusted-proxy list. From: same

- **Pin Node.js version to prevent platform regressions.** Add an `engines` field in `package.json` and an `.nvmrc` file. Node.js 25 introduced a native `localStorage` global (`--experimental-webstorage`) that overrides jsdom's stub and omits `clear()`, breaking 14+ tests without any code change. Pinning catches this in CI before it hits contributors. From: `docs/solutions/2026-03-31-localstorage-mock-node25-jsdom.md`

## Conventions (from codebase analysis)

- **Test global setup is in `tests/setup.js`.** It installs a full `localStorage` mock via `Object.defineProperty` with `configurable: true`. All new test files benefit automatically — no per-file setup needed.

- **Engine mutations are in `shared/engine.js`; server wires them via `server/index.js`.** Client game display lives in `src/App.jsx`. Keep mutation logic in `shared/`, not in server or client.

- **Tactics variant state must be drained before `applyMove` in tests.** Call `declineClaim(state)` after `createGame({ variant: "tactics" })` — the variant always initialises with `pendingClaim: { player: 0 }` that blocks moves. Use a `makeTacticsState()` helper and document the drain.

- **Replica test files require an explicit sync warning.** When a server function can't be exported (e.g. `connectionsByIp` tracking), a test can replicate the logic in-process — but the file must open with: "Replicates X from server/index.js. If you change that logic, update this replica accordingly." From: `tests/server-ws-ip.test.js`. Prefer exporting the function directly when feasible.

- **Clean up temp/scratch files before merging.** Files like `vitest.config.tmp.js` created during debugging must be deleted before a PR is opened. From: `docs/solutions/2026-03-31-bounds-check-off-by-one-stone-index.md`

- **One PR per correctness fix.** Multiple agents solving the same bug independently causes review overhead and merge conflicts. Coordinate before opening a PR for a known-open function. From: `docs/solutions/2026-03-30-snapshot-rollback-engine-mutation-handlers.md`

- **No environment-coupled guards for logging concerns.** Do not use `process.env.NODE_ENV` to suppress `stack` in error logs. That belongs in the log aggregator/shipper, not application code. From: same

- **Staging merges first, then prod.** PRs merge to `staging` branch, tested, then to `main`. Never push untested code directly to `main`. (Environment rule.)

- **Each environment has its own Terraform directory.** `infra/terraform/staging/`, `infra/terraform/app/`, etc. Never add staging resources to prod Terraform state or vice versa. (Environment rule.)

- **`vi.mock` all heavy deps when testing exported functions from `App.jsx`.** App.jsx imports React, mcts, ai-policy, engine, Landing, and i18n — none of which should execute in unit tests. Always mock: `vi.mock("../shared/mcts.js", ...)`, `vi.mock("../shared/ai-policy.js", ...)`, `vi.mock("../shared/engine.js", ...)`, `vi.mock("../src/Landing.jsx", ...)`, `vi.mock("../src/i18n.js", ...)`. See `tests/app-utils.test.js` as the canonical reference. From: `tests/app-utils.test.js` codebase pattern.
