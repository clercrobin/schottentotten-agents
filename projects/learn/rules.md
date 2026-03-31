# Project Rules — auto-generated from past work
# Last updated: 2026-03-31 (rev 4)

## Must-follow rules (from past P1 findings)

- **Snapshot-rollback every engine mutation call.** Any server-side handler that calls an engine function mutating `game.state` must take a `structuredClone(game.state)` snapshot before the call and restore it on exception. Partial mutations that throw otherwise corrupt state permanently.
  _From: docs/solutions/2026-03-30-snapshot-rollback-engine-mutation-handlers.md_

- **Guard against `"unknown"` IP on every per-IP write path.** `getIp()` returns `"unknown"` when `socket.remoteAddress` is undefined. Every function writing to a per-IP map (`strikes`, `connectionCounts`, etc.) must return early: `if (ip === "unknown") return;`. Without this, all unresolvable IPs share one key and can collectively ban each other.
  _From: docs/solutions/2026-03-31-rate-limit-strike-enforcement.md_

- **Never import `server/index.js` directly in unit tests.** The module binds a port on import. Extract or inline the pure logic under test instead. Reference: `tests/server-ip.test.js`, `tests/server-rate-limit.test.js`.
  _From: docs/solutions/2026-03-31-rate-limit-strike-enforcement.md_

- **Idempotency guard before side effects on any multi-path game-end function.** Any function reachable from multiple game-end paths (timeout, disconnect, normal end) must guard with `if (entity.completed) return;` and set `entity.completed = true` synchronously *before* any side effects. For `async` functions this means before the **first `await`** — Node.js's single-threaded event loop makes a synchronous assignment before the first `await` a reliable mutex. Add a comment (`// must be set before first await — acts as mutex in single-threaded JS`) so future devs don't remove it thinking it's redundant.
  _From: docs/solutions/2026-03-31-tactic-card-coverage-and-engine-fixes.md, docs/solutions/2026-03-31-websocket-close-handler-ip-race-condition-cache.md_

- **Attach closure variables to `ws` at connection time for close handlers.** Variables needed in `ws.on('close')` must be attached to the socket object (`ws.ip = ip`) at connection time, not relied upon from the outer closure. Transpiler quirks and conditional handler registration can leave closure references undefined when the handler fires.
  _From: docs/solutions/2026-03-31-tactic-card-coverage-and-engine-fixes.md, docs/solutions/2026-03-31-websocket-close-handler-ip-race-condition-cache.md_

- **`X-Forwarded-For` is spoofable — deferred security fix tracked.** `getIp()` at `server/index.js:641` reads `X-Forwarded-For` and trusts the first IP unconditionally. Per-IP rate limits and connection caps can be bypassed by setting a fake header. Fix: validate against a configured trusted-proxy allowlist, or use `req.socket.remoteAddress` exclusively when not behind a known proxy. This was identified and deferred — do not implement per-IP security features on top of the current `getIp()` without fixing this first.
  _From: docs/solutions/2026-03-31-websocket-close-handler-ip-race-condition-cache.md_

## Should-follow rules (from past P2 findings)

- **Type-narrow before accessing discriminated union fields.** When `pendingAction` (or any discriminated union) may be null or a different type, guard with `if (!pendingAction || pendingAction.type !== "<expected-type>") return;` before accessing type-specific fields. Reference: `handleRecruiterDrawChoice` in `src/App.jsx`.
  _From: docs/solutions/2026-03-30-null-guard-pending-action.md_

- **Handlers must delegate to exported helpers — never duplicate, never test replicas.** When a pure function is extracted from a handler and exported for testing, the original handler must be refactored to call that export. Exporting without refactoring creates a parallel implementation that silently diverges. Corollary: if `server-finalize.test.js` tests a copy of `finalizeGame`, export and test the real function — test replicas provide no regression coverage.
  _From: docs/solutions/2026-03-31-pure-function-extraction-for-component-testing.md, docs/solutions/2026-03-31-tactic-card-coverage-and-engine-fixes.md_

- **Add `now = Date.now()` as an optional parameter to any function using `Date.now()` internally.** This costs nothing and enables fully deterministic unit tests without fake timers.
  _From: docs/solutions/2026-03-31-pure-function-extraction-for-component-testing.md_

- **One PR per well-defined correctness fix — no new abstractions inside.** Multiple agents opening PRs for the same function creates review overhead and merge conflicts. Helpers like `withRollback(game, fn)` are worth extracting, but as a follow-up refactor, not inside the fix PR.
  _From: docs/solutions/2026-03-30-snapshot-rollback-engine-mutation-handlers.md_

- **Log `err.stack` server-side without environment-coupling.** Include `stack: err.stack` unconditionally. Noise concerns belong in the log aggregator as a field filter, not as `process.env.NODE_ENV` guards in application code.
  _From: docs/solutions/2026-03-30-snapshot-rollback-engine-mutation-handlers.md_

- **Remove dead parameters in the same PR as the semantic change.** When a function's scope is widened (e.g., per-player → global), any parameter that scoped the old behavior becomes dead immediately. Remove it and update all call sites in the same commit. Never leave it as a "documentation artifact" — callers will pass it silently with no effect.
  _From: docs/solutions/2026-03-31-dead-parameter-removal-getUnknownFormationCards.md_

- **Use analytical O(1) helpers for formation evaluation — never recursive enumeration.** For formation evaluation with joker/wildcard cards, implement one function per formation type (`flexColorRun`, `flexThreeKind`, etc.) rather than recursively walking variant combinations. 3 jokers × 54 variants = 157,464 recursive paths vs. O(1) per helper. This is the established pattern in `shared/engine.js` since commit `829944b`.
  _From: docs/solutions/2026-03-31-dead-parameter-removal-getUnknownFormationCards.md_

- **Module-level caches must have a size cap and a `clearXCache()` export.** Module-level `Map` caches grow forever in long-running servers. Cap at a named constant (`CACHE_MAX = 10_000`) and use FIFO eviction: `_cache.delete(_cache.keys().next().value)` before writing (not bulk `_cache.clear()` — that discards all warm entries). Export a `clearXCache()` function so tests can call it in `afterEach` for isolation.
  _From: docs/solutions/2026-03-31-tactic-card-coverage-and-engine-fixes.md, docs/solutions/2026-03-31-websocket-close-handler-ip-race-condition-cache.md_

- **Assert specific card IDs in card-move tests — never count-only.** `hand.length === N` after a card move doesn't prove the right cards moved. Assert that `move.returnCardIds` contains specific expected IDs, and that those IDs are absent from hand and present at the expected destination.
  _From: docs/solutions/2026-03-31-tactic-card-coverage-and-engine-fixes.md_

- **Never double-clone before `postMessage`.** `postMessage` invokes the browser's structured clone algorithm synchronously. Calling `cloneState(game)` or `structuredClone(...)` immediately before `worker.postMessage({ state: ... })` is a redundant full deep-copy. Pass the value directly.
  _From: docs/solutions/2026-03-31-tactic-card-coverage-and-engine-fixes.md_

## Conventions (from codebase analysis)

- **Test framework: Vitest.** All tests use `vitest` with `describe`/`it`/`expect`. No Jest. Test files live in `tests/` at project root. Known pre-existing failures: `tests/app-utils.test.js` has 14 failing tests (`localStorage.clear is not a function`) — do not treat as regressions from unrelated changes.

- **Architecture boundaries.** Shared game logic in `shared/` (`engine.js`, `mcts.js`, `ai-policy.js`) — used by both client and server, no React or Node APIs. Server is a single file at `server/index.js`. Frontend is a monolithic `src/App.jsx` with hooks extracted to `src/hooks/`.

- **Per-environment Terraform with isolated state.** Each environment (`staging`, `app`, `bootstrap`, `pwa`) has its own directory in `infra/terraform/<env>/` with its own state backend and IAM role. Never add resources for one env inside another env's TF directory.

- **Test drain helper for game variants with blocking initial state.** When a game variant (e.g., `"tactics"`) initializes with pending state (`pendingClaim: { player: 0 }`) that blocks `applyMove`, create a `makeXState()` helper that drains it and documents why: `// tactics always starts with pendingClaim — drain before any applyMove`.

- **Deploy flow: staging before prod.** `staging` branch → staging environment. `main` branch → prod. CI in `.github/workflows/ci.yml`; deploy in `.github/workflows/deploy.yml`.
