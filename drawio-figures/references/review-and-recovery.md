# Rendering, visual review, and recovery

## Render and execute

The renderer or chart executor receives only the declared source and inputs.
Use an isolated execution boundary for arbitrary chart code, with project
writes and read access explicitly scoped. Save stdout/stderr, return status,
runtime parameters, input hashes, output dimensions, and output hashes. A
technical failure is a failure, not an empty or placeholder image presented as
success.

## Visual checker contract

Inspect the actual current PNG or SVG at the planned insertion or viewing size.
Check, as applicable:

- font family, size, symbols, subscripts, and missing glyphs;
- readability, contrast, wrapping, truncation, overlap, and whitespace;
- diagram boundaries, container padding, alignment, arrow direction, routing,
  occlusion, and connector labels;
- chart axes, units, ticks, legends, color bars, annotations, and panel scale;
- panel order, cross-panel relationships, overall hierarchy, cropping, and
  consistency after assembly.

Every issue has a severity, location (`panel_id`, `task_id`, element ID or code
location when known), image evidence, affected source, and proposed
presentation-only correction. The checker may fix layout or presentation. It
must not change raw data, statistical method, scientific relationship, or
conclusion without a new user decision.

After each correction, save a new source version, re-render, hash the new image,
and inspect that exact image again. Allow at most three automatic correction
rounds per checking stage. If the figure still fails, evidence is missing, or
the checker is unavailable, pause with `needs_review` or `awaiting_user` and
preserve the unresolved issues.

## Completion

`complete` requires the exact current rendered artifacts to exist, the required
visual checks to pass, no unresolved blocking issue, and a persisted review
record tied to the current source and image hashes. Source generation,
placeholder content, a model claim, an old image pass, or a user acceptance of
known issues is not equivalent to a clean completion; known accepted issues
remain recorded and the run remains `needs_review` when they are blocking.
