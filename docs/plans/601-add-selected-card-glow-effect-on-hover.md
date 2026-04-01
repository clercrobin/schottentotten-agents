I have enough context. Here's the plan.

---

## Summary

Add a color-aware glow to selected cards on hover using a single CSS rule. The existing `--card-accent` CSS variable is already set per color class (green/blue/red/yellow/purple/pink) and on tactic cards, so `color-mix()` can produce a correctly-colored outer glow without needing any new variables or JS changes. The `transform` (lift) already comes from the `button.card:hover:not(:disabled)` rule via cascade — only `box-shadow` needs to be overridden.

---

## Research Findings

**Card HTML structure** (`App.jsx:3344`): Hand cards are `<button>` elements with classes `card`, `card--{color}`, and optionally `card--selected`, `card--tactic`.

**CSS variables** (`styles.css:1486`): Each color class sets `--card-accent` (e.g. `.card--green { --card-accent: #00a651 }`). Tactic cards inherit `--card-accent: var(--accent)` (#c24a2e).

**Existing selected state** — two layers:
- Base (`styles.css:1663`): `outline: 3px solid var(--accent)` — simple outline, no glow
- Signature Visual Refresh (`styles.css:2565`): overrides with `box-shadow: 0 0 0 3px rgba(11, 106, 143, 0.32), 0 18px 26px ...` — a fixed-color blue ring, still no glow on hover

**Existing hover rule** (`styles.css:2558`): `button.card:hover:not(:disabled)` sets transform+box-shadow. A new `button.card--selected:hover:not(:disabled)` rule has higher specificity (4 classes vs 2), so it wins on `box-shadow` while leaving `transform` to cascade from the lower-specificity hover rule — meaning the theme-specific lift transforms (arena: `-4px`, arcade: `-2px`) still apply correctly without per-theme overrides.

**`color-mix()` support**: Chrome 111+ / Firefox 113+ / Safari 16.2+ (all 2023+). No polyfill needed.

**No JS changes needed**: `card--selected` is already toggled in `renderHand` at `App.jsx:3348`.

**Theme coverage**: The Signature Visual Refresh rules (lines 2216–2644) are bare selectors, not scoped to any theme, so one rule there covers the default, editorial, arena, and arcade themes.

---

## Implementation Steps

1. **`src/styles.css`, after line 2569** — Insert `button.card--selected:hover:not(:disabled)` rule with a color-aware glow using `color-mix()` against `var(--card-accent)`:

```css
button.card--selected:hover:not(:disabled) {
  box-shadow:
    0 0 0 3px color-mix(in srgb, var(--card-accent) 70%, transparent),
    0 0 18px 6px color-mix(in srgb, var(--card-accent) 40%, transparent),
    0 18px 26px rgba(29, 23, 17, 0.24);
}
```

That's the entire change. The `transform` (lift animation) continues to come from the existing `button.card:hover:not(:disabled)` rule.

---

## Files Affected

| File | Change |
|------|--------|
| `src/styles.css` | Add 1 CSS rule (6 lines) after line 2569 |

---

## Test Strategy

- **Unit tests**: None needed — purely visual CSS, no logic changed.
- **E2E smoke test**: No change to `e2e/smoke.spec.js` — the existing smoke tests don't assert visual hover states (they're currently `fixme` for gameplay selectors anyway). A CSS-only hover glow is not meaningful to test in Playwright without screenshot comparison, which this project doesn't use.
- **Verification**: Open the game in a browser, select a card in hand, hover over it — the card should lift (existing) AND show a colored outer glow matching the card's suit color.

---

## Infrastructure Impact

None. Pure client-side CSS change. No cloud resources, no env vars, no CI workflow changes.

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| `color-mix()` not supported in old browsers | Game targets modern browsers; all 2023+ evergreen browsers support it. No fallback needed. |
| Glow too strong/garish | The 70%/40% mix values produce a soft ring + diffuse outer glow. Can tune opacity if needed. |
| Arcade/arena theme inconsistency | Rule applies globally without theme scope; theme-specific transforms still cascade normally since `transform` isn't declared in the new rule. |

---

## Alternatives Considered

1. **Add `--card-glow` variable per color class** — more verbose, requires 7 variable additions; `color-mix()` achieves the same result in one line.
2. **Modify the base section (line ~1667) instead of refresh section** — refresh section overrides base, so base changes would be shadowed; refresh section is the correct place.
3. **JS-driven class on hover** — unnecessary complexity; CSS `:hover` handles this natively.
