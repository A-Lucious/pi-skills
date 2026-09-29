# Editable figure and input contract

## Draw.io source

Use an uncompressed, editable `mxGraphModel` with a `root`, cell `id="0"`, and
a layer cell `id="1"` with `parent="0"`. Every cell ID is unique. Every
`parent`, `source`, and `target` points to an existing cell. Shapes and text use
`vertex="1"`; connectors use `edge="1"` and real source/target references.
Geometry is explicit and containment-safe. Labels remain text values in cells.
Do not include DTDs, entities, external file references, or flattened images as
a substitute for editable structure.

Use a content-derived canvas rather than a fixed template. Prefer a clean white
background, high-contrast text, readable typography at the target size, and at
least 24 px of useful clearance where the plan permits it. Keep containers
behind their contents. Route connectors through open space with explicit
waypoints when needed; avoid crossings, text collisions, boundary overflow,
and ambiguous arrow direction. Native rectangles, text, arrows, containers,
matrices, and other simple shapes do not need a stencil search.

For a device or specialized object, search the project’s actual draw.io index,
inspect the selected source, and record its asset ID, local path, origin, and
license information. If no suitable asset exists, report the gap or use an
explicit placeholder only when the user accepts it.

## Chart source

Use the real input paths and confirmed algorithm or statistical method. Read
the data schema, column names, units, missing values, and relevant analysis
code before writing the chart. The chart source should expose a reproducible
figure object (for Python/Matplotlib workflows, assign it to `fig`) and should
not install packages, call a shell, access undeclared files, modify raw data,
or use the network. Save code, parameters, input snapshots or hashes, and
execution logs with the artifact.

Do not invent samples, fit parameters, uncertainty, significance, units, or
columns. If data or method evidence is missing, keep the task blocked in the
plan instead of guessing. A conceptual trend belongs to a diagram and must be
labelled as illustrative when it is not measured data.

## Shared layout rules

Choose a layout from semantic relationships and text density. Do not impose a
three-column, equal-panel, or fixed-row template. Keep labels, legends, axes,
color bars, panel markers, and cross-panel relationships readable and editable
where the format allows. Measure actual panel dimensions before assembly and
preserve stable source identities when arranging or revising them.
