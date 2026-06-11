---
description: Audit UI changes for WCAG 2.1 AA accessibility compliance and fix all violations.
---

# Accessibility Audit

Every UI addition or modification in this project MUST fully comply with WCAG 2.1 AA. This is not optional — accessibility violations are bugs.

Audit all UI changes in the current diff (or the files specified below). For every violation found, fix it directly — do not just report it.

$ARGUMENTS

## Requirements

All of the following apply to every template, component, CSS rule, and JS hook that touches the UI.

### Semantic HTML
- Interactive elements MUST use `<button>`, `<a>`, `<input>`, `<select>` — never `<div>` or `<span>` with click handlers
- Headings (`<h1>`–`<h6>`) MUST follow a logical hierarchy with no skipped levels
- Landmark regions (`<nav>`, `<main>`, `<header>`, `<footer>`, `<section>`) MUST be used correctly
- Lists MUST use `<ul>`/`<ol>`/`<li>`
- Data tables MUST use `<th>` with `scope`

### Keyboard Navigation
- All interactive elements MUST be reachable via Tab
- Custom widgets (modals, dropdowns, menus, dialogs) MUST support arrow keys, Escape, Enter/Space as appropriate
- Focus order MUST match visual order
- No keyboard traps — Escape MUST close modals/overlays and return focus to the trigger
- Every focusable element MUST have a visible focus indicator (never `outline: none` without a replacement)
- Skip links MUST exist for repeated navigation blocks

### ARIA
- Elements that lack visible text (icon buttons, image links) MUST have `aria-label` or `aria-labelledby`
- Disclosure/toggle controls MUST have `aria-expanded`, `aria-controls`, `aria-haspopup`
- The active nav link MUST have `aria-current="page"`
- Dynamic content updates (flash messages, loading states) MUST use `aria-live` regions
- Use `role` attributes only when native semantics are insufficient — prefer semantic HTML over ARIA
- Never add redundant ARIA (e.g. `role="button"` on a `<button>`)

### Color & Contrast
- Text contrast ratio MUST be >= 4.5:1 for normal text, >= 3:1 for large text (18px+ or 14px+ bold)
- UI component boundaries (buttons, inputs, focus rings) MUST have >= 3:1 contrast against adjacent colors
- Information MUST NOT be conveyed by color alone — always pair with text, icon, or pattern
- All themes (light, dark, or custom) MUST meet contrast requirements

### Images & Media
- Every `<img>` MUST have a meaningful `alt` (or `alt=""` if purely decorative)
- Icon-only buttons MUST have `aria-label`
- Decorative inline SVGs MUST have `aria-hidden="true"`
- Video/audio MUST have captions or transcript (flag if missing)

### Forms
- Every input MUST have a visible `<label>` linked via `for`/`id` (or wrapping)
- Required fields MUST be indicated both visually and with `aria-required="true"` or `required`
- Error messages MUST be linked to their input via `aria-describedby`
- Form-level error summaries MUST use `aria-live="assertive"` or `role="alert"`

### Motion & Animation
- Auto-advancing or animated content MUST respect `prefers-reduced-motion`
- Auto-playing content MUST have a visible pause/stop control
- No content may flash more than 3 times per second

### Touch & Pointer
- Touch targets MUST be at least 44x44 CSS pixels
- No functionality may require hover-only interaction (tooltips need keyboard/focus equivalents)

### Phoenix LiveView Specifics
- `phx-click` elements MUST be on `<button>` or `<a>`, not on `<div>`/`<span>`
- LiveView page navigations MUST announce route changes (`<.live_title>` and `aria-live` on flash)
- Modals MUST trap focus when open
- Async loading states MUST have `aria-busy` or a visible indicator

## Output

For each violation:
1. State the file, line, and element
2. State the WCAG criterion violated (e.g. "1.4.3 Contrast")
3. Fix it in place

After all fixes, list a summary of changes.
