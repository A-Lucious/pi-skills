#!/usr/bin/env python3
"""Pixel-level reproduction of the reference article's Fig. 6.

Source layout: Energy Storage Materials 86 (2026) 104947, Fig. 6 -- one
full-width boxplot banner (a) plus a 2 x 3 grid of bar panels (b)-(g), with one
framed legend strip at the bottom.

Numerical values below are transcribed by eye from the published figure. They
exist so the reproduction can be compared side by side with the original; they
are NOT measurements of this project's batteries and must never be reused as
results.

    python scripts/fig6_reproduction.py --out fig6_reproduction
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
from matplotlib.legend_handler import HandlerTuple

import figstyle as fx

MODELS = ["EN-CNN", "RE-CNN", "EXP"]
MODEL_COLORS = [fx.BLUE["deep"], fx.BLUE["mid"], fx.RED["deep"]]
RMSE_COLOR = fx.RED["pale"]
LOCATIONS = ["[10,50,100]", "[30,50,100]", "[0,30,100]", "[0,70,100]", "[0,50,70]", "[0,50,90]"]

# Bar values in 1e-3 Ah and R2 in %, recovered from the published raster with
# scripts/measure_figure.py (values are ~0.5 unit low because the colour match
# drops the anti-aliased top row of each bar).
BARS = {
    "[10,50,100]": {"mae": [14.5, 23.6, 22.2], "rmse": [22.0, 38.3, 37.1], "r2": [98.91, 96.75, 96.96], "callout": "40%", "ymax": 60},
    "[30,50,100]": {"mae": [15.9, 26.0, 22.2], "rmse": [23.6, 41.1, 36.0], "r2": [98.75, 96.25, 97.11], "callout": "40%", "ymax": 60},
    "[0,30,100]": {"mae": [21.6, 31.7, 35.0], "rmse": [33.0, 49.8, 53.9], "r2": [97.56, 94.48, 93.58], "callout": "32%", "ymax": 75},
    "[0,70,100]": {"mae": [16.3, 24.8, 27.8], "rmse": [22.0, 35.4, 36.2], "r2": [98.92, 97.21, 97.05], "callout": "35%", "ymax": 60},
    "[0,50,70]": {"mae": [15.3, 22.0, 18.7], "rmse": [30.0, 45.7, 40.5], "r2": [96.83, 92.92, 94.32], "callout": "31%", "ymax": 75},
    "[0,50,90]": {"mae": [13.8, 21.1, 17.1], "rmse": [21.1, 45.1, 31.2], "r2": [98.97, 95.46, 97.81], "callout": "44%", "ymax": 75},
}

# Bar geometry in x data units, measured from the raster: the axis spans exactly
# three x units, the MAE/RMSE pair is centred on each model position, and the two
# bars sit side by side with a hairline gap.
BAR_WIDTH = 0.317
# mpl.bar() takes the bar CENTRE, so these are centres, not left edges.
MAE_OFFSET = -0.156
RMSE_OFFSET = 0.170
X_LIMITS = (-0.50, 2.50)
PEACH_FROM = 0.62

# Upper whisker of each box in panel (a), in Ah, ordered as MODELS.
WHISKER_HIGH = [
    [0.135, 0.415, 0.215],
    [0.135, 0.230, 0.105],
    [0.135, 0.145, 0.600],
    [0.125, 0.345, 0.125],
    [0.145, 0.305, 0.140],
    [0.145, 0.240, 0.245],
]

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path(__file__).with_name("fig6_reproduction"))
    parser.add_argument("--family", default="sans", choices=["sans", "serif"])
    parser.add_argument("--dpi", type=int, default=400)
    parser.add_argument("--font-scale", type=float, default=1.0)
    return parser.parse_args()


def banner(ax) -> None:
    """(a) Boxplots of |Error| for the six known-point locations."""
    box_w = 0.17
    stats = []
    for group, high in enumerate(WHISKER_HIGH):
        for index, top in enumerate(high):
            stats.append(
                {
                    "med": 0.0075,
                    "q1": 0.0025,
                    "q3": max(top * 0.10, 0.006),
                    "whislo": 0.0005,
                    "whishi": top,
                    "fliers": [],
                    "position": group + (index - 1) * 0.30,
                }
            )
    for index, colour in enumerate(MODEL_COLORS):
        subset = [s for i, s in enumerate(stats) if i % 3 == index]
        ax.bxp(
            subset,
            positions=[s["position"] for s in subset],
            widths=box_w,
            showfliers=False,
            patch_artist=True,
            boxprops={"facecolor": colour, "edgecolor": fx.GREY["frame"], "linewidth": 0.5},
            medianprops={"color": fx.GOLD, "linewidth": 1.0},
            whiskerprops={"color": colour, "linewidth": 0.6},
            capprops={"color": colour, "linewidth": 0.6},
        )
    ax.set_xticks(range(len(LOCATIONS)))
    ax.set_xticklabels(LOCATIONS, fontweight="bold")
    ax.set_xlim(-0.55, len(LOCATIONS) - 0.45)
    ax.set_ylim(0.0, 0.66)
    ax.set_xlabel("Location (%)")
    ax.set_ylabel("|Error| (Ah)")
    ax.text(0.02, 0.95, "All batteries in Subset-A (with 72)", transform=ax.transAxes,
            ha="left", va="top", fontweight="bold")
    handles = [fx.patch_handle(c, m) for c, m in zip(MODEL_COLORS, MODELS)]
    ax.legend(handles=handles, loc="upper right", ncol=3, frameon=False)


def bar_panel(ax, location: str, letter: str) -> None:
    """One of (b)-(g): MAE/RMSE bars, dashed R2 overlay, percentage callout."""
    spec = BARS[location]
    x = np.arange(len(MODELS), dtype=float)

    # Peach wash behind the right two thirds, as in the original.
    fx.highlight_band(ax, PEACH_FROM, X_LIMITS[1], color=fx.RED["pale"], alpha=0.22, zorder=0)

    for centre, colour, mae, rmse in zip(x, MODEL_COLORS, spec["mae"], spec["rmse"]):
        ax.bar(centre + MAE_OFFSET, mae, BAR_WIDTH, color=colour, zorder=3)
        ax.bar(centre + RMSE_OFFSET, rmse, BAR_WIDTH, color=RMSE_COLOR, zorder=3)

    ax.set_ylim(0, spec["ymax"])
    ax.set_xlim(*X_LIMITS)
    ax.set_xticks(x)
    ax.set_xticklabels(MODELS, fontweight="bold")
    ax.set_yticks([0, 20, 40, 60] if spec["ymax"] == 60 else [0, 25, 50, 75])
    # The published panel carries no floating "x10^-3" tag inside the axes, so
    # the multiplier is folded into the axis label instead. That removes the
    # collision with the first percentage tag and keeps the unit explicit.
    ax.set_ylabel(r"MAE / RMSE ($\times10^{-3}$ Ah)")
    fx.boxed_frame(ax)
    fx.group_axis_label(ax, -0.44, 2.44, location, y=-0.205, extend=0.0)

    # Measured from the published panels: the three markers sit in the top
    # 0.83-0.955 band and stay clear of the tallest bars underneath.
    fx.r2_overlay(ax, x, spec["r2"], band=(0.74, 0.955), dy_text=0.045)
    # Land the arrowhead on the upper-left of the RE-CNN RMSE bar: aiming at the
    # bar centre puts the head straight into the R2 marker above it.
    fx.value_arrow(
        ax,
        spec["callout"],
        xy_text=(-0.10, spec["ymax"] * 0.45),
        xy_point=(1.0 + RMSE_OFFSET - BAR_WIDTH / 2.0 + 0.02, spec["rmse"][1]),
        rad=0.35,
    )
    fx.panel_label(ax, letter, dx=-0.115)


def main() -> None:
    args = parse_args()
    fx.apply_style(family=args.family)
    if args.font_scale != 1.0:
        plt.rcParams.update({k: v * args.font_scale for k, v in
                             [("font.size", plt.rcParams["font.size"]),
                              ("axes.labelsize", plt.rcParams["axes.labelsize"]),
                              ("xtick.labelsize", plt.rcParams["xtick.labelsize"]),
                              ("ytick.labelsize", plt.rcParams["ytick.labelsize"]),
                              ("legend.fontsize", plt.rcParams["legend.fontsize"])]})

    # Geometry measured off the published figure at 300 dpi (all in inches):
    #   panel 1.703 x 1.49, column gap 0.637, row gap 0.587,
    #   banner exactly as tall as a grid panel, canvas 7.37 x 6.55.
    layout = fx.compose_grid(
        nrows=2,
        ncols=3,
        panel_w_in=1.703,
        panel_ratio=1.143,
        banner_ratio=1.0,
        hspace_in=0.587,
        wspace_frac=0.374,
        banner_gap_in=0.587,
        strip_in=0.28,
        strip_gap_in=0.42,
        margin_in=(0.665, 0.250, 0.02, 0.18),
    )

    banner(layout.banner)
    for index, location in enumerate(LOCATIONS):
        bar_panel(layout.axes[index // 3, index % 3], location, "bcdefg"[index])

    # MAE is carried by the model colour, so its legend entry is one swatch per
    # model under a single label; HandlerTuple keeps them on one row.
    handles = [
        tuple(fx.patch_handle(c, "MAE") for c in MODEL_COLORS),
        fx.patch_handle(RMSE_COLOR, "RMSE"),
        plt.Line2D([], [], color=fx.TEXT, ls=(0, (5, 3)), marker="^", ms=4.0,
                   mfc="white", mec=fx.TEXT, mew=0.8, label=r"$R^2$"),
    ]
    # Anchor on the GRID centre, not the canvas centre: unequal left and right
    # margins would otherwise push the legend off-centre.
    middle = layout.axes[0, 1].get_position()
    grid_center_x = middle.x0 + middle.width / 2.0
    layout.fig.legend(
        handles=handles,
        labels=["MAE", "RMSE", r"$R^2$"],
        loc="center",
        bbox_to_anchor=(grid_center_x, (0.02 + 0.14) / layout.fig.get_figheight()),
        ncol=3,
        handler_map={tuple: HandlerTuple(ndivide=None, pad=0.15)},
    )

    # Keep the exact canvas: cropping to the ink would eat the deliberate
    # top margin and break the overlay comparison with the published figure.
    plt.rcParams["savefig.bbox"] = None
    layout.fig.savefig(args.out.with_suffix(".png"), dpi=args.dpi)
    layout.fig.savefig(args.out.with_suffix(".pdf"))
    plt.close(layout.fig)
    print(f"written: {args.out.with_suffix('.png')}")


if __name__ == "__main__":
    main()
