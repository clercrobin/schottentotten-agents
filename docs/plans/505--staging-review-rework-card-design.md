I can't write the plan file without permission — here's the complete plan directly:

---

## Research Findings

**What the reference branch (`agent/-staging-building-rework-card-design`) actually does:**

The +179 line commit to `src/styles.css` has four parts:
1. **Default game cards** — adds a 4px left inset color stripe (`box-shadow: inset 4px 0 0 rgba(...)`) to `.card--green/blue/red/yellow/purple/pink`, bringing them in parity with themed variants (which already have this at `styles.css:4144–4190`)
2. **Hero preview cards** — colors the 4 bottom-row mini-cards in the landing hero board with clan gradients
3. **Landing feature cards** — adds a colored top stripe (`::before`) + numbered badge "01/02/03" (`::after`)
4. **Landing mode cards** — adds a left gradient accent stripe (`::before`)

**Key issue with the implementation:** It uses an append-only CSS pattern, creating duplicate `.card--green` etc. blocks at the end of a ~6500-line file. The originals at line 1727 become dead code. Also includes an unused CSS counter (`counter-reset: mode-counter`) that serves no purpose.

---

## Plan: feat: Rework card design — color accents and landing page polish

**File:** `docs/plans/2026-04-01-001-feat-rework-card-design-plan.md`

### Summary

The rework has four targeted CSS changes. An existing implementation on branch `agent/-staging-building-rework-card-design` achieves the correct visual outcome but uses append-only overrides that create dead code. This plan specifies the same changes as in-place edits.

### Requirements

- **R1.** Default-theme game cards get `inset 4px 0 0` left stripe (themed variants already have this at `styles.css:4144`)
- **R2.** Landing hero bottom-row cards get clan-color gradients
- **R3.** Landing feature cards get a colored top stripe + numbered badge
- **R4.** Landing mode cards get a left gradient accent stripe
- **R5.** All edits are in-place (no appended duplicate selectors)

### Key Technical Decisions

| Decision | Rationale |
|---|---|
| `box-shadow: inset 4px 0 0` over `border-left` | Avoids adding width to card; matches existing themed variant pattern |
| In-place edits over append-only | Prevents dead code at original locations in a 6500-line stylesheet |
| `var(--accent)` for mode stripe | Picks up active theme accent automatically |
| No CSS counter for mode cards | Reference branch defines `counter-reset/counter-increment` for modes but never uses `counter()` — pure dead code |

### Implementation Units

**Unit 1 — Default game cards: add left inset stripe**
- Modify `src/styles.css:1727–1762` in-place
- Each `.card--[color]` gets `box-shadow` with `inset 4px 0 0 rgba(color, 0.45)` + updated `border: 1.5px solid rgba(color, 0.62)`
- Reference exact rgba values from branch diff
- Test: none (visual-only) — verify in default/no-theme mode

**Unit 2 — Hero preview cards: clan-color gradients**
- Add `.hero-row--bottom .hero-card:nth-child(1/2/3/4)` rules after `.hero-card--accent` block (~line 205)
- Red/blue/green/yellow matching existing `--card-accent` theme values
- Test: none — verify landing page hero board

**Unit 3 — Landing feature cards: top stripe + badge**
- In-place: add `position: relative; counter-increment: landing-feature` to `.landing-card` (~line 244)
- In-place: add `counter-reset: landing-feature` to `.landing-grid` (~line 238)
- Add `.landing-card::before` (top stripe, 3px, `border-top-left-radius: 18px`) immediately after parent rule
- Add `.landing-card::after` (badge with CSS counter "01/02/03") immediately after
- Add `.landing-grid .landing-card:nth-child(1/2/3)::before` color variants
- Test: none — verify 3 feature cards show stripe + badge

**Unit 4 — Landing mode cards: left accent stripe**
- In-place: add `position: relative` to `.landing-mode` (~line 274)
- Add `.landing-mode::before` (3px left stripe, `var(--accent)`, `border-top/bottom-left-radius: 16px`)
- **Do NOT** add `counter-reset/counter-increment` — not needed, was dead code in reference branch

### Risks

| Risk | Mitigation |
|---|---|
| In-place edit removes an existing property | Read full rule before editing; test all 3 themes |
| `border-top-left-radius` mismatch clips top stripe | Match parent `18px` exactly |
| Counter "0" prefix produces "010" if features > 9 | Fixed array of 3 — add comment near rule |

### No infrastructure impact. No new files. No JS changes.

---

**Options:**
1. **Start `/ce:work`** to implement this plan on branch `agent/-staging-building-rework-card-design` (replace append-only CSS with in-place edits)
2. **Merge the reference branch as-is** — the visual outcome is correct; the append-only pattern is a code quality concern but not a blocker
3. **Open plan file** — grant write permission so I can save to `docs/plans/`
