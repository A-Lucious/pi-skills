#!/usr/bin/env python3
"""Runnable demo of every element in ``figstyle``.

Run it after changing the style module and eyeball ``demo_figstyle.png``: the
figure exercises the palette, the panel layout, the metric block, the dashed R2
overlay, the percentage callout arrow, the shaded highlight band, the grouped
axis label and the inset colour bar in one shot. The data are synthetic; only
the styling matters here.

    python scripts/demo_figstyle.py --out demo_figstyle
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import figstyle as fx


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path(__file__).with_name("demo_figstyle"))
    parser.add_argument("--family", default="sans", choices=["sans", "serif"])
    parser.add_argument("--dpi", type=int, default=300)
    return parser.parse_args()


def panel_a(ax, rng) -> None:
    """Full-width banner: several trajectories coloured by a continuous variable."""
    x = np.linspace(0, 2400, 240)
    for index, colour in enumerate(fx.BLUE_RAMP + fx.RED_RAMP):
        y = 2.3 - (index + 1) * 0.05 * (x / 2400) ** 0.6 + rng.normal(0, 0.004, x.size)
        ax.plot(x, y, color=colour, lw=0.7, alpha=0.9)
    fx.highlight_band(ax, 0, 60, color=fx.RED["wash"], alpha=0.9)
    fx.dashed_guides(ax, [60, 2300])
    ax.set_ylim(1.72, 2.36)
    fx.span_arrow(ax, 60, 2300, 1.78, "lifespan > 2000 Ah")
    ax.text(0.5, 0.94, "Second-life phase of 96 retired batteries", transform=ax.transAxes, ha="center", fontweight="bold")
    ax.set_xlabel("EFC: Ah-throughput (Ah)")
    ax.set_ylabel("Max capacity (Ah)")
    fx.panel_label(ax, "a")


def panel_b(ax, rng) -> None:
    """Histogram with an offset tag and an arrow pointing at the mode."""
    data = rng.gamma(1.6, 0.045, 4000)
    ax.hist(data, bins=60, range=(0, 0.6), color=fx.BLUE["deep"], edgecolor="white", linewidth=0.2)
    ax.set_xlabel("|Error| (Ah)")
    ax.set_ylabel("Count")
    ax.set_xlim(0, 0.6)
    fx.offset_text(ax, r"$\times10^{3}$")
    fx.metric_block(ax, ["Modelling using the", "recovered dataset", "(3 known points)"], loc="upper right",
                    fontweight="bold", linespacing=1.4)
    fx.point_arrow(ax, "", xy=(0.13, 290), xytext=(0.30, 300))
    fx.panel_label(ax, "b")


def panel_c(ax) -> None:
    """Grouped bars with the dashed R2 overlay and a percentage callout."""
    models = ["EN-CNN", "RE-CNN", "EXP"]
    model_colors = [fx.BLUE["deep"], fx.BLUE["mid"], fx.RED["deep"]]
    mae = np.array([0.015, 0.023, 0.021])
    rmse = np.array([0.028, 0.040, 0.037])
    x = np.arange(len(models))
    # MAE keeps the model colour, RMSE is always the salmon ramp entry: the
    # pairing used by the reference article for every bar panel.
    for centre, colour, m, r in zip(x, model_colors, mae, rmse):
        ax.bar(centre - 0.20, m, 0.38, color=colour)
        ax.bar(centre + 0.20, r, 0.38, color=fx.RED["pale"])
    ax.set_ylim(0, 0.075)
    fx.r2_overlay(ax, x, [98.91, 96.75, 96.96], band=(0.80, 0.97))
    fx.value_arrow(ax, "40%", xy_text=(0.16, 0.022), xy_point=(0.30, 0.040), rad=0.35)
    fx.group_axis_label(ax, -0.4, 0.4, "[10,50,100]", y=-0.16)
    fx.group_axis_label(ax, 0.6, 1.4, "[30,50,100]", y=-0.16)
    ax.set_xticks(x)
    ax.set_xticklabels(models)
    ax.set_ylabel("MAE / RMSE (Ah)")
    fx.offset_text(ax, r"$\times10^{-3}$")
    fx.panel_label(ax, "c")


def panel_d(ax, rng) -> None:
    """Density scatter versus the identity line with an inset colour bar."""
    x = rng.uniform(1.2, 2.4, 9000)
    y = x + rng.normal(0, 0.045, x.size)
    error = np.abs(y - x)
    handle = ax.scatter(x, y, c=error, s=1.4, cmap=fx.SEQ_RED, linewidths=0, vmin=0.0, vmax=0.6)
    ax.set_xlim(1.2, 2.4)
    ax.set_ylim(1.2, 2.4)
    fx.identity_line(ax)
    ax.set_xlabel(r"Real $Q_{\max}$ (Ah)")
    ax.set_ylabel(r"Estimated $Q_{\max}$ (Ah)")
    ax.text(0.5, 0.93, "Subset-B (with 24)", transform=ax.transAxes, ha="center", fontweight="bold")
    ax.text(0.30, 0.14, "CNN-1", transform=ax.transAxes, ha="center", fontweight="bold")
    fx.inset_colorbar(ax, handle, "|Error| (Ah)", ticks=[0.0, 0.3, 0.6], loc=(0.46, 0.20), width=0.40)
    fx.panel_label(ax, "d", dx=-0.14)


def main() -> None:
    args = parse_args()
    fx.apply_style(family=args.family)
    rng = np.random.default_rng(0)

    # Composition: one full-width banner panel for the overall story, a 2x2
    # grid whose four panels are exactly the same size, and a reserved strip at
    # the bottom for the single figure-level legend.
    layout = fx.compose_grid(
        width="full",
        nrows=2,
        ncols=2,
        panel_ratio=1.30,
        banner_ratio=0.85,
        hspace_in=0.52,
        banner_gap_in=0.62,
        strip_in=0.30,
    )
    fig = layout.fig

    panel_a(layout.banner, rng)
    panel_b(layout.axes[0, 0], rng)
    panel_c(layout.axes[0, 1])
    panel_d(layout.axes[1, 0], rng)

    info = layout.axes[1, 1]
    info.axis("off")
    info.text(
        0.0,
        0.94,
        "Palette\n"
        f"  blue ramp  {' '.join(fx.BLUE_RAMP)}\n"
        f"  red ramp   {' '.join(fx.RED_RAMP)}\n"
        f"  grey ramp  {' '.join(fx.GREY_RAMP)}",
        va="top",
        ha="left",
        family="monospace",
        fontsize=6.0,
    )
    fx.panel_label(info, "e", dx=-0.02)

    handles = [
        fx.line_handle(fx.BLUE["deep"], "EN-CNN"),
        fx.line_handle(fx.BLUE["mid"], "RE-CNN"),
        fx.line_handle(fx.RED["deep"], "EXP"),
        fx.line_handle(fx.TEXT, r"$R^2$", ls=(0, (5, 3))),
    ]
    fx.figure_legend(fig, handles, loc="bottom", ncol=4, y=0.055)

    fig.savefig(args.out.with_suffix(".png"), dpi=args.dpi)
    fig.savefig(args.out.with_suffix(".pdf"))
    panel_w = layout.axes[0, 0].get_position().width * fig.get_figwidth()
    print(f"panel size: {panel_w:.2f} x {panel_w / 1.30:.2f} in (all five panels identical)")
    print(f"written: {args.out.with_suffix('.png')}")


if __name__ == "__main__":
    main()
