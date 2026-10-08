#!/usr/bin/env python3
"""Reusable matplotlib style for battery / SOT journal figures.

The palette and the layout constants reproduce the graphical language of the
reference article analysed in ``references/style-reference.md`` (Energy Storage
Materials 86 (2026) 104947): sans-serif type, thin light-grey frames, a blue and
a red ramp used consistently, in-panel metric blocks, dashed R2 overlays,
circular-arrow percentage callouts and inset colour bars.

Usage
-----
    import figstyle as fx

    fx.apply_style()
    fig, ax = fx.journal_figure(width="full", panels=1, height=2.6)

Nothing in this module depends on the analysis pipeline, so it can be copied
into a workspace ``scripts/`` directory and imported directly.
"""

from __future__ import annotations

from typing import NamedTuple

import numpy as np
from matplotlib import colors as mcolors
from matplotlib.lines import Line2D
from matplotlib.patches import Rectangle

# --------------------------------------------------------------------------
# Palette
# --------------------------------------------------------------------------

BLUE = {
    "deep": "#104680",
    "mid": "#4B73A0",
    "soft": "#86A1BE",
    "pale": "#B6D7E8",
    "wash": "#D9E9F2",
}
RED = {
    "deep": "#6D011F",
    "mid": "#B72230",
    "soft": "#DC6D57",
    "pale": "#F6B293",
    "wash": "#FBE7DC",
}
GREEN_WASH = "#EBF4E4"
GREY = {
    "text": "#1A1A1A",
    "axis": "#1A1A1A",
    "tick": "#1A1A1A",
    "frame": "#0E0E0E",
    "grid": "#EBEBEB",
}
# A near-black hairline is what the reference actually uses for axes and legends;
# a light grey frame reads as "no frame at all" once the figure is printed.
FRAME_LW = 0.45
GOLD = "#E2B33C"  # median line of the reference boxplots

# Ordered ramps, darkest first. Use BLUE_RAMP for "the proposed method" and
# RED_RAMP for baselines so the pairing stays stable across the whole paper.
BLUE_RAMP = [BLUE["deep"], BLUE["mid"], BLUE["soft"], BLUE["pale"]]
RED_RAMP = [RED["deep"], RED["mid"], RED["soft"], RED["pale"]]
GREY_RAMP = ["#3E3E3E", "#686868", "#8F8F8F", "#B3B3B3", "#D2D2D2"]

# Diverging map for signed / correlated quantities (Pearson vs Spearman style).
DIVERGING = mcolors.LinearSegmentedColormap.from_list(
    "batdiv", [RED["deep"], RED["pale"], "#FFFFFF", BLUE["pale"], BLUE["deep"]]
)
# Sequential maps for error magnitude and density.
SEQ_RED = mcolors.LinearSegmentedColormap.from_list("batseq_red", ["#FFFFFF", RED["pale"], RED["deep"]])
SEQ_BLUE = mcolors.LinearSegmentedColormap.from_list("batseq_blue", ["#FFFFFF", BLUE["pale"], BLUE["deep"]])

TEXT = GREY["text"]

# --------------------------------------------------------------------------
# Canvas sizes (Elsevier): full text 190 mm, half column 90 mm
# --------------------------------------------------------------------------

WIDTH_FULL_IN = 7.48
WIDTH_HALF_IN = 3.54


def apply_style(base_font: float = 9.4, family: str = "sans") -> None:
    """Set global rcParams. Call once before creating any figure.

    family="sans" matches the reference article (Arial / Helvetica look).
    family="serif" switches to Times, which is what the older project figures
    used; keep one family for the whole manuscript, never mix.

    Note: ``font.family`` only accepts the generic names "sans-serif" and
    "serif"; passing "sans" makes matplotlib fall back to DejaVu Sans without
    raising, so the mapping below is deliberate.
    """
    import matplotlib as mpl

    serif = ["Times New Roman", "Nimbus Roman", "DejaVu Serif"]
    sans = ["Arial", "Helvetica", "Liberation Sans", "DejaVu Sans"]
    generic = {"sans": "sans-serif", "serif": "serif"}[family]
    mpl.rcParams.update(
        {
            "figure.dpi": 200,
            "savefig.dpi": 600,
            "savefig.bbox": "tight",
            "savefig.pad_inches": 0.02,
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
            "font.family": generic,
            "font.serif": serif,
            "font.sans-serif": sans,
            "mathtext.fontset": "custom" if family == "sans" else "stix",
            "mathtext.rm": sans[0],
            "mathtext.it": f"{sans[0]}:italic",
            "mathtext.bf": f"{sans[0]}:bold",
            "mathtext.sf": sans[0],
            "mathtext.default": "regular",
            "font.size": base_font,
            "axes.labelsize": base_font + 0.6,
            "axes.titlesize": base_font + 0.6,
            "xtick.labelsize": base_font - 0.4,
            "ytick.labelsize": base_font - 0.4,
            "legend.fontsize": base_font - 0.4,
            "axes.linewidth": FRAME_LW,
            "axes.edgecolor": GREY["frame"],
            "axes.labelcolor": TEXT,
            "axes.titlecolor": TEXT,
            "text.color": TEXT,
            "xtick.color": GREY["axis"],
            "ytick.color": GREY["axis"],
            "xtick.direction": "out",
            "ytick.direction": "out",
            "xtick.major.width": 0.6,
            "ytick.major.width": 0.6,
            "xtick.major.size": 2.4,
            "ytick.major.size": 2.4,
            "xtick.minor.size": 1.3,
            "lines.linewidth": 1.0,
            "lines.markersize": 3.0,
            "legend.frameon": True,
            "legend.framealpha": 1.0,
            "legend.edgecolor": GREY["frame"],
            "legend.linewidth": FRAME_LW,
            "legend.facecolor": "white",
            "legend.fancybox": False,
            "legend.borderpad": 0.25,
            "legend.handlelength": 3.12,
            "legend.handleheight": 0.71,
            "legend.handletextpad": 0.6,
            "legend.columnspacing": 1.6,
            "legend.labelspacing": 0.45,
            "grid.color": GREY["grid"],
            "grid.linewidth": 0.5,
            "axes.grid": False,
            "axes.axisbelow": True,
            "figure.facecolor": "white",
            "axes.facecolor": "white",
        }
    )


class Composition(NamedTuple):
    """Result of :func:`compose_grid`."""

    fig: object
    axes: np.ndarray  # (nrows, ncols) array of Axes for the equal-size grid
    banner: object  # full-width lead panel, or None
    strip: object  # reserved empty strip at the bottom, or None


def compose_grid(
    width: str = "full",
    nrows: int = 1,
    ncols: int = 1,
    panel_ratio: float = 1.35,
    panel_w_in: float | None = None,
    banner_ratio: float = 0.0,
    hspace_in: float = 0.42,
    wspace_frac: float = 0.28,
    banner_gap_in: float = 0.46,
    margin_in=(0.50, 0.12, 0.30, 0.10),
    strip_in: float = 0.0,
    strip_gap_in: float = 0.10,
) -> Composition:
    """Compose a figure out of panels that all have the same physical size.

    The figure width is pinned to the journal column; the panel width then
    follows from the column count and the gaps, and the panel height follows
    from ``panel_ratio`` (width / height). Only two things are chosen freely:
    how many panels, and how big each panel is. Everything else is derived, so
    a figure can never come out with mismatched panel sizes.

    Parameters
    ----------
    banner_ratio
        Height of the optional full-width lead panel, in units of the panel
        height. Use it for the one panel that carries the overall story
        (Fig. 2a, Fig. 4b, Fig. 6a of the reference article).
    strip_in
        Reserved empty strip at the bottom for a figure-level legend or for the
        dot-arrow group labels, so labels never eat into a data panel.
    margin_in
        (left, right, bottom, top) margins in inches.

    Returns
    -------
    Composition
        ``.fig``, ``.axes`` (2-D array, row-major), ``.banner``, ``.strip``.
    """
    import matplotlib.pyplot as plt

    left, right, bottom, top = margin_in
    if panel_w_in is not None:
        panel_w = float(panel_w_in)
    else:
        total_w = WIDTH_FULL_IN if width == "full" else WIDTH_HALF_IN
        panel_w = (total_w - left - right) / (ncols + wspace_frac * (ncols - 1))
    panel_h = panel_w / panel_ratio
    banner_h = panel_h * banner_ratio

    blocks: list[tuple[float, float]] = []
    if banner_h > 0:
        blocks.append((banner_h, banner_gap_in))
    for row in range(nrows):
        last = row == nrows - 1
        gap = (strip_gap_in if strip_in > 0 else 0.0) if last else hspace_in
        blocks.append((panel_h, gap))
    if strip_in > 0:
        blocks.append((strip_in, 0.0))

    total_h = top + bottom + sum(height + gap for height, gap in blocks)
    if panel_w_in is not None:
        total_w = left + right + ncols * panel_w + (ncols - 1) * panel_w * wspace_frac
    fig = plt.figure(figsize=(total_w, total_h))

    def rect(x_in: float, y_in: float, w_in: float, h_in: float) -> list[float]:
        return [x_in / total_w, y_in / total_h, w_in / total_w, h_in / total_h]

    grid_w = ncols * panel_w + (ncols - 1) * panel_w * wspace_frac
    cursor = total_h - top
    banner_ax = None
    if banner_h > 0:
        banner_ax = fig.add_axes(rect(left, cursor - banner_h, grid_w, banner_h))
        cursor -= banner_h + banner_gap_in

    offset = 1 if banner_h > 0 else 0
    axes = np.empty((nrows, ncols), dtype=object)
    for row in range(nrows):
        for col in range(ncols):
            x = left + col * panel_w * (1.0 + wspace_frac)
            axes[row, col] = fig.add_axes(rect(x, cursor - panel_h, panel_w, panel_h))
        cursor -= panel_h + blocks[offset + row][1]

    strip_ax = None
    if strip_in > 0:
        strip_ax = fig.add_axes(rect(left, cursor - strip_in, grid_w, strip_in))
        strip_ax.axis("off")

    return Composition(fig=fig, axes=axes, banner=banner_ax, strip=strip_ax)


# --------------------------------------------------------------------------
# Panel decoration
# --------------------------------------------------------------------------


def panel_label(ax, label: str, dx: float = -0.085, dy: float = 1.03, fontsize=None) -> None:
    """Bold lowercase panel tag placed outside the top-left corner."""
    ax.text(
        dx,
        dy,
        f"({label})",
        transform=ax.transAxes,
        fontsize=fontsize,
        fontweight="bold",
        ha="left",
        va="bottom",
        clip_on=False,
    )


def open_frame(ax, keep=("left", "bottom")) -> None:
    """Drop the spines that carry no scale, as most panels in the reference do."""
    for name in ("left", "bottom", "top", "right"):
        ax.spines[name].set_visible(name in keep)


def boxed_frame(ax) -> None:
    """Full thin light-grey box; the reference uses it for framed grids."""
    for name in ("left", "bottom", "top", "right"):
        ax.spines[name].set_visible(True)
        ax.spines[name].set_color(GREY["frame"])


def highlight_band(ax, x0, x1, color=None, alpha: float = 0.35, zorder: int = 0) -> None:
    """Light wash used to single out a region (peach for bars, green for curves)."""
    ax.axvspan(x0, x1, color=color or RED["pale"], alpha=alpha, lw=0, zorder=zorder)


def offset_text(ax, text: str, loc: str = "upper left") -> None:
    """Scientific-notation tag such as x10^-3 printed inside the axes corner.

    Only use this when the corner is otherwise free. The reference article puts
    the multiplier into the y-axis label instead, because a floating tag in the
    corner collides with the first in-panel annotation (see SKILL.md 3.1).
    """
    xy = {"upper left": (0.02, 0.995), "lower left": (0.02, 0.04), "upper right": (0.98, 0.995)}[loc]
    ha = "left" if "left" in loc else "right"
    va = "top" if "upper" in loc else "bottom"
    ax.text(*xy, text, transform=ax.transAxes, ha=ha, va=va)


def metric_block(ax, lines, loc: str = "upper right", fontsize=None, **kwargs) -> None:
    """Plain metric lines inside a panel, e.g. MAE / RMSE / R2 of one model."""
    xy = {
        "upper right": (0.97, 0.95, "right", "top"),
        "upper left": (0.03, 0.95, "left", "top"),
        "lower right": (0.97, 0.06, "right", "bottom"),
        "center right": (0.97, 0.5, "right", "center"),
    }[loc]
    ax.text(
        xy[0],
        xy[1],
        "\n".join(lines) if isinstance(lines, (list, tuple)) else str(lines),
        transform=ax.transAxes,
        ha=xy[2],
        va=xy[3],
        fontsize=fontsize,
        **kwargs,
    )


def group_axis_label(ax, x0, x1, text: str, y: float = -0.30, extend: float = 0.14, font_size=None) -> None:
    """Signature bracket used under bar-chart axes: dot---[label]---dot."""
    tr = ax.get_xaxis_transform()
    ax.plot([x0 - extend, x1 + extend], [y, y], transform=tr, color=GREY["axis"], lw=0.6, clip_on=False)
    ax.plot([x0 - extend], [y], transform=tr, marker="o", ms=3.2, color=GREY["text"], clip_on=False)
    ax.plot([x1 + extend], [y], transform=tr, marker="o", ms=3.2, color=GREY["text"], clip_on=False)
    ax.text(
        (x0 + x1) / 2.0,
        y,
        text,
        transform=tr,
        ha="center",
        va="center",
        fontweight="bold",
        fontsize=font_size,
        clip_on=False,
        bbox={"facecolor": "white", "edgecolor": "none", "pad": 1.6},
    )


def span_arrow(ax, x0, x1, y: float, text: str, color=None) -> None:
    """Double-headed arrow with a label, drawn at a fixed height in data coords."""
    color = color or TEXT
    ax.annotate(
        "",
        xy=(x1, y),
        xytext=(x0, y),
        arrowprops={"arrowstyle": "<->", "color": color, "lw": 0.7, "shrinkA": 0, "shrinkB": 0},
    )
    ax.text((x0 + x1) / 2.0, y, text, ha="center", va="bottom", color=color)


def value_arrow(ax, text: str, xy_text, xy_point, color=None, rad: float = -0.35) -> None:
    """Curved callout arrow in the series colour, e.g. the 32% improvement tag."""
    color = color or RED["mid"]
    ax.annotate(
        text,
        xy=xy_point,
        xytext=xy_text,
        color=color,
        fontweight="bold",
        ha="center",
        va="center",
        arrowprops={"arrowstyle": "-|>", "color": color, "lw": 0.8, "connectionstyle": f"arc3,rad={rad}"},
    )


def point_arrow(ax, text: str, xy, xytext, color=None, **kwargs) -> None:
    """Straight leader arrow for labelling an extremum such as Min or Max."""
    color = color or BLUE["deep"]
    ax.annotate(
        text,
        xy=xy,
        xytext=xytext,
        color=color,
        fontweight="bold",
        ha="left",
        va="center",
        arrowprops={"arrowstyle": "->", "color": color, "lw": 0.8},
        **kwargs,
    )


def dashed_guides(ax, xs, **kwargs) -> None:
    for x in np.atleast_1d(xs):
        ax.axvline(x, color=TEXT, lw=0.6, ls=(0, (4, 2)), alpha=0.75, zorder=1)


def identity_line(ax, color=None, **kwargs) -> None:
    """y = x reference for estimated-versus-real scatter panels."""
    lo, hi = ax.get_xlim()
    ax.plot([lo, hi], [lo, hi], color=color or TEXT, lw=0.9, ls=(0, (5, 3)), zorder=3, **kwargs)


# --------------------------------------------------------------------------
# Composite elements
# --------------------------------------------------------------------------


def r2_overlay(ax, x, r2_percent, band=(0.60, 0.87), color=None, dy_text: float = 0.02,
               font_size=None, extend: float = 0.0) -> None:
    """Dashed line with hollow triangles and percentage tags, mapped onto a band
    of the current y-axis so it can share the panel with bars."""
    x = np.asarray(x, dtype=float)
    r2_percent = np.asarray(r2_percent, dtype=float)
    lo, hi = ax.get_ylim()
    span = hi - lo
    lo_band = lo + band[0] * span
    hi_band = lo + band[1] * span
    lo_r2 = np.nanmin(r2_percent) - extend
    hi_r2 = np.nanmax(r2_percent) + extend
    scale = (hi_band - lo_band) / max(hi_r2 - lo_r2, 1e-9)
    y = lo_band + (r2_percent - lo_r2) * scale
    color = color or TEXT
    ax.plot(x, y, color=color, lw=0.8, ls=(0, (5, 3)), zorder=5)
    ax.plot(x, y, ls="none", marker="^", ms=5.0, mfc="white", mec=color, mew=0.8, zorder=6)

    # The topmost marker has no room above it, so its label goes underneath;
    # every other label sits above its marker. This is how the reference keeps
    # the percentages clear of both the marker and the axes frame.
    gap = dy_text * span
    ceiling = lo + (band[1] + 0.06) * span
    for xi, yi, value in zip(x, y, r2_percent):
        below = yi + gap + 0.06 * span > ceiling
        ax.text(
            xi,
            yi - gap * 1.6 if below else yi + gap,
            f"{value:.2f}%",
            ha="center",
            va="top" if below else "bottom",
            fontsize=font_size,
            color=color,
            zorder=7,
        )


def inset_colorbar(ax, mappable, label: str, width: float = 0.26, height: float = 0.055, loc=(0.62, 0.52), ticks=None):
    """Compact horizontal colour bar placed inside the axes, label underneath."""
    from matplotlib.colorbar import Colorbar

    fig = ax.figure
    box = ax.get_position()
    cax = fig.add_axes(
        [
            box.x0 + loc[0] * box.width,
            box.y0 + loc[1] * box.height,
            width * box.width,
            height * box.height,
        ]
    )
    cb = Colorbar(cax, mappable, orientation="horizontal", ticks=ticks)
    cb.outline.set_linewidth(0.5)
    cb.outline.set_edgecolor(GREY["frame"])
    cax.tick_params(length=1.5, width=0.5, labelsize=7.0)
    cax.set_xlabel(label, fontsize=8.0, labelpad=1.5)


def figure_legend(fig, handles, loc: str = "bottom", ncol: int = 4, y: float | None = None) -> None:
    """One horizontal legend for the whole figure; avoids repeating it per panel.

    ``loc`` is "bottom" or "top"; ``y`` overrides the anchor in figure fraction.
    """
    anchor = {"bottom": (0.5, 0.0), "top": (0.5, 1.0)}[loc]
    position = "lower center" if loc == "bottom" else "upper center"
    fig.legend(
        handles=handles,
        loc=position,
        bbox_to_anchor=anchor if y is None else (0.5, y),
        ncol=ncol,
        borderaxespad=0.4,
    )


def bubble_matrix(ax, x, y, size, value, cmap=None, smax: float = 6.0) -> None:
    """Dot matrix: marker area encodes |value|, colour encodes the signed value."""
    x = np.asarray(x)
    y = np.asarray(y)
    value = np.asarray(value, dtype=float)
    size = np.asarray(size, dtype=float)
    norm = mcolors.Normalize(vmin=-max(abs(value).max(), 1e-9), vmax=max(abs(value).max(), 1e-9))
    return ax.scatter(x, y, s=smax * 6 * (size / max(size.max(), 1e-9)), c=value, cmap=cmap or DIVERGING, norm=norm, linewidths=0)


def line_handle(color, label: str, ls: str = "-") -> Line2D:
    return Line2D([], [], color=color, ls=ls, lw=1.2, label=label)


def patch_handle(color, label: str) -> Rectangle:
    return Rectangle((0, 0), 1, 1, facecolor=color, edgecolor="white", label=label)
