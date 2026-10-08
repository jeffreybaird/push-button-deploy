# Rails accessibility review

Review every changed ERB template, partial, stylesheet and interactive behavior
against WCAG 2.1 AA. Accessibility defects are behavior defects: fix them through
the shared source/test ownership workflow and add meaningful regression coverage.
Automated assertions supplement keyboard and visual review; they do not establish
full WCAG compliance.

- Use semantic landmarks and one main region, ordered headings, lists for lists,
  and table captions and header cells for tabular data.
- Navigation uses links. State changes use Rails forms or `button_to`, with real
  buttons and Rails CSRF protection. Never attach the sole action to a div or span.
- Every input has a visible linked label. Required inputs expose that requirement;
  invalid fields link to their errors with `aria-describedby` and indicate their
  invalid state. Form error summaries announce through `role="alert"`.
- Keyboard users can reach and operate each control. Focus remains visible and
  follows a logical order; repeated navigation has a skip link. Dialogs need an
  accessible name, Escape behavior and focus restoration when they are introduced.
- Give icon-only controls an accessible name. Images have meaningful `alt` text,
  or empty alternative text when decorative. Prefer native HTML over redundant ARIA.
- Normal text has at least 4.5:1 contrast; large text at least 3:1. Large means
  24 CSS pixels or roughly 18.7 CSS pixels when bold. Essential component edges
  and focus indicators need at least 3:1 contrast. Color never carries meaning alone.
- Target at least 44 by 44 CSS pixels for interactive controls as a project rule;
  this stronger target is not a claim that WCAG 2.1 AA requires that size.
- Announce success/status changes using an appropriate live region. Preserve
  entered form values after validation failures. Respect reduced motion, and
  provide controls for automatically changing content if it is added.

Exercise the empty state, successful submission, validation failure and archived
state in request/acceptance tests. Assert labels, linked errors and visible
outcomes using stable selectors. Check keyboard reachability and focus visibility
in a real browser before claiming those behaviors work.

Reference: https://www.w3.org/WAI/WCAG21/quickref/
