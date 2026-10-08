# Plan contract

The Boss plan is a validated object. It may include additional provenance
metadata, but the following scientific fields must remain explicit:

```json
{
  "title": "Concise figure title",
  "objective": "What the reader should learn",
  "style": "Canvas, typography, palette, and target-size requirements",
  "panels": [
    {"id": "panel-method", "purpose": "Meaning of this panel"}
  ],
  "tasks": [
    {
      "id": "task-method-diagram",
      "panel_id": "panel-method",
      "kind": "diagram",
      "objective": "Specific editable result",
      "inputs": [],
      "method": "Confirmed construction method",
      "depends_on": []
    }
  ],
  "questions": [],
  "conflicts": []
}
```

`kind` is `diagram` or `chart`. `inputs` contains only project-relative files
that exist and have been read through the approved project tools. A conceptual
diagram without source data uses `inputs: []`; node labels, output paths,
missing files, and assumptions do not belong there. Chart tasks require actual
input files or an explicit unresolved question that blocks execution.

Panel and task IDs are unique and stable. Tasks are listed in dependency order;
each dependency refers to an earlier task. The plan records the source paths and
hashes used to make it. If those dependencies change before execution or
confirmation, revise and reconfirm the plan.

Questions identify information the user must provide or decide. Conflicts name
the competing rules, their effect, and the decision needed. An empty list means
the plan is confirmable; it does not mean the scientific assumptions are true.
