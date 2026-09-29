# Workflow and state model

## Context routing

The project context is role-scoped:

- Boss receives the user request, design rules, project inventory, relevant
  data/method files, draw.io asset index, and the planning skills.
- Diagram Implementer receives the confirmed plan, diagram task, relevant
  design rules, selected assets, and the diagram skill.
- Data Figure Implementer receives the confirmed plan, declared data and
  algorithm inputs, and the chart skill.
- Orchestrators receive actual task sources, artifact dimensions, stable IDs,
  and the assembly constraints.
- Font/Visual Checker receives `checkrole`, confirmed style and content
  constraints, the exact current image, image hash, source, code, and change
  history.

Each read records a canonical project-relative path and SHA256 hash. Apply
private-file, hidden-file, generated-output, size, and symlink-boundary rules to
both the requested and resolved path. Search results also carry the searched
index hash. Invalid tool arguments are returned as bounded tool errors; do not
expose private file contents in error messages or traces.

## Graph stages

The workflow can be represented by these logical nodes and edges:

```text
intake/context
  -> boss_plan
  -> user_confirmation
  -> schedule_tasks
  -> implement_task (diagram | chart)
  -> assemble_panel
  -> panel_visual_check
  -> assemble_figure
  -> figure_visual_check
  -> deliver
```

`user_confirmation` loops back to `boss_plan` after revision. A failed model,
tool, renderer, executor, or checker step persists its error and resumes at the
failed stage. A changed dependency invalidates downstream artifacts and checks;
it never silently reuses an old pass.

Recommended durable states are:

- `planning`
- `awaiting_plan_confirmation`
- `running`
- `awaiting_user`
- `needs_review`
- `complete`
- `stopped`

The implementation may use stage-specific next actions such as `retry_plan`,
`retry_execute`, `render_sources`, or `review_panel`, but these are routing
details rather than user-visible success states.

## Conflicts and confirmation

Design rules, check rules, role skills, source evidence, and user instructions
can disagree. The Boss describes the conflict and its consequence. The user
chooses the applicable decision and scope. Persist the decision with the plan
version and pass the same decision to every downstream role. A changed rule
after confirmation requires a new plan decision; do not let each Agent resolve
it differently.

## Dependency-aware recovery

Before resuming, compare hashes for plan context, task inputs, selected assets,
generated sources, and any current rendered image. If an input or rule changed,
preserve the prior version, mark dependent outputs stale, and route to the
affected stage. If a generated source was manually edited, use it as the new
candidate only after the user explicitly chooses how to proceed; never overwrite
it automatically with a previously generated source.

Keep run, panel, task, artifact, and review IDs stable across process restarts.
Persist the confirmed plan, decisions, context hashes, source versions,
artifact hashes, errors, checker rounds, and user interventions. Credentials
and temporary permission grants do not belong in durable state.
