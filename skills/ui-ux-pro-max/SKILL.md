---
name: ui-ux-pro-max
description: AI-powered design intelligence — 67 UI styles, 161 color palettes, 57 font pairings, 99 UX guidelines, 25 chart types, and design system generation across 16 tech stacks. Use when the user asks to build, design, review, or improve any UI/UX (landing pages, dashboards, mobile apps, components, color schemes, typography, accessibility).
---

# UI UX Pro Max

Design intelligence toolkit with searchable databases of UI styles, color palettes, font pairings, chart types, UX guidelines, and a design system reasoning engine.

**Prerequisites:** Python 3.x (no extra deps).

## Quick Start

When a user requests any UI/UX task, always start with the design system generator:

```bash
python3 ~/.pi/agent/skills/ui-ux-pro-max/scripts/search.py "<product_type> <keywords>" --design-system -p "Project Name"
```

This runs 5 parallel searches (product, style, color, landing, typography) and applies 161 reasoning rules to output a complete design system: pattern, style, colors, typography, effects, anti-patterns, and a pre-delivery checklist.

## Domain Searches

Supplement with detailed searches as needed:

```bash
python3 ~/.pi/agent/skills/ui-ux-pro-max/scripts/search.py "<keyword>" --domain <domain> [-n <max>]
```

| Domain | Use For |
|--------|---------|
| `product` | Product type recommendations |
| `style` | UI styles, colors, effects, AI prompts |
| `typography` | Font pairings with Google Fonts imports |
| `color` | Color palettes by product type |
| `landing` | Page structure and CTA strategies |
| `chart` | Chart types and library recommendations |
| `ux` | UX best practices and anti-patterns |
| `prompt` | AI prompt keywords and CSS keywords for a style |

## Stack Guidelines

```bash
python3 ~/.pi/agent/skills/ui-ux-pro-max/scripts/search.py "<keyword>" --stack <stack>
```

Available stacks: `html-tailwind`, `react`, `nextjs`, `astro`, `vue`, `nuxtjs`, `nuxt-ui`, `svelte`, `swiftui`, `react-native`, `flutter`, `shadcn`, `jetpack-compose`, `angular`, `laravel`, `javafx`

## Persist Design System

Save for hierarchical retrieval across sessions:

```bash
python3 ~/.pi/agent/skills/ui-ux-pro-max/scripts/search.py "<query>" --design-system --persist -p "Project"
python3 ~/.pi/agent/skills/ui-ux-pro-max/scripts/search.py "<query>" --design-system --persist -p "Project" --page "dashboard"
```

Creates `design-system/MASTER.md` + optional `design-system/pages/<name>.md` overrides.

## Output Format

```bash
# Markdown (for documentation)
python3 ~/.pi/agent/skills/ui-ux-pro-max/scripts/search.py "<query>" --design-system -f markdown
```

## Pre-Delivery Checklist

Always run before delivering UI code:

- `--domain ux "animation accessibility"` for UX validation
- No emojis as icons (use SVG: Phosphor/Heroicons/Lucide)
- Touch targets ≥44pt, hover/press feedback 150-300ms
- Light + dark mode contrast verified (4.5:1 body, 3:1 secondary)
- Safe areas respected, scroll content not hidden behind fixed bars
- Tested on 375px / 768px / 1024px / 1440px
- `prefers-reduced-motion` respected
