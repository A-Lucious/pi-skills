#!/usr/bin/env python3
"""Measure a published figure so it can be reproduced panel by panel.

Given a rasterised figure and the known y-axis range of each panel, the script
recovers the numbers that are otherwise guessed by eye:

* panel boxes, from the long frame lines;
* bar rectangles (x extent and top) converted back into data units;
* the shaded highlight band, if any;
* the ink height of every text row, which fixes font sizes;
* the exact RGB of the data colours actually used.

    python scripts/measure_figure.py --image fig.png --dpi 300 \
        --ylim 0,60,0,60,0,75,0,60,0,75,0,75 --grid 2x3 --banner
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

DARK = 120
FRAME_FRACTION = 0.55
SPINE_FRACTION = 0.90


def load(path: Path, dpi: float, reference_dpi: float = 200.0) -> np.ndarray:
    """Open a figure and resample it to ``reference_dpi`` so all lengths are comparable."""
    image = Image.open(path).convert("RGB")
    scale = reference_dpi / dpi
    if abs(scale - 1.0) > 1e-9:
        image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    return np.asarray(image)


def long_lines(grey: np.ndarray, fraction: float) -> list[tuple[int, int]]:
    """Contiguous run of rows (or columns) that are mostly dark along the other axis."""
    hits = (grey < DARK).mean(axis=1) if grey.ndim == 2 else None
    runs, start = [], None
    for index, value in enumerate(hits > fraction):
        if value and start is None:
            start = index
        elif not value and start is not None:
            if index - start <= 6:
                runs.append((start, index - 1))
            start = None
    return runs


def frame_grid(grey: np.ndarray) -> tuple[list[int], list[int]]:
    """Rows that carry a long frame line, merged into single centres."""
    rows = [round((a + b) / 2) for a, b in long_lines(grey, FRAME_FRACTION)]
    return rows


def vertical_spines(grey: np.ndarray, y0: int, y1: int) -> list[int]:
    """Columns that are almost fully dark inside one band of panels.

    The interior spines of a grid only span their own band, so this has to be
    measured per band rather than over the whole image.
    """
    band = grey[y0 + 3:y1 - 2, :]
    hits = (band < DARK).mean(axis=0)
    runs, start = [], None
    for index, value in enumerate(hits > SPINE_FRACTION):
        if value and start is None:
            start = index
        elif not value and start is not None:
            if index - start <= 6:
                runs.append(round((start + index - 1) / 2))
            start = None
    return runs


def boxes_from_rows(rows: list[int]) -> list[tuple[int, int]]:
    """Consecutive row pairs are the top and bottom of each band of panels."""
    return [(rows[i], rows[i + 1]) for i in range(0, len(rows) - 1, 2)]


def colour_mask(rgb: np.ndarray, colour, tol: int = 14) -> np.ndarray:
    return (np.abs(rgb.astype(int) - np.array(colour, dtype=int)).max(axis=2) < tol)


def bar_shapes(rgb: np.ndarray, colour, min_area: int = 160, min_height: int = 12) -> list[tuple[int, int, int, int]]:
    """Solid rectangles of one colour; anti-aliased text and thin markers drop out."""
    from scipy import ndimage

    labelled, count = ndimage.label(colour_mask(rgb, colour))
    shapes = []
    for index in range(1, count + 1):
        rows, cols = np.where(labelled == index)
        if rows.size < min_area:
            continue
        top, bottom = int(rows.min()), int(rows.max())
        left, right = int(cols.min()), int(cols.max())
        if bottom - top + 1 < min_height:
            continue
        if (bottom - top + 1) * (right - left + 1) < 0.55 * rows.size:
            continue
        shapes.append((left, right, top, bottom))
    return sorted(shapes)


def bar_report(rgb, band, cols, colours, ylim):
    """Report every bar of every colour in one row of panels, in data units."""
    y0, y1 = band
    spans = [(cols[i], cols[i + 1]) for i in range(0, len(cols) - 1, 2)]
    out = []
    for panel_index, (x0, x1) in enumerate(spans):
        lo, hi = ylim[panel_index]
        px_per_unit = (y1 - y0) / (hi - lo)
        sub = rgb[y0 + 2:y1 - 1, x0 + 2:x1 - 1]
        entry = {"panel": panel_index, "x0": x0, "x1": x1, "ylim": (lo, hi), "bars": []}
        for name, colour in colours.items():
            for left, right, top, _ in bar_shapes(sub, colour):
                entry["bars"].append(
                    {
                        "colour": name,
                        "x_left": left + x0 + 2,
                        "x_right": right + x0 + 2,
                        "width_px": right - left + 1,
                        "value": round((sub.shape[0] - top) / px_per_unit, 2),
                    }
                )
        entry["bars"].sort(key=lambda d: d["x_left"])
        out.append((entry, (x0, x1)))
    return out


def text_rows(grey: np.ndarray, x0: int, x1: int, y0: int, y1: int) -> list[tuple[int, int, int]]:
    """Ink runs in a horizontal band, so each run is one line of text."""
    band = grey[y0:y1, x0:x1] < DARK
    runs, start = [], None
    for index, count in enumerate(band.sum(axis=1)):
        if count > 2 and start is None:
            start = index
        elif count <= 2 and start is not None:
            runs.append((y0 + start, y0 + index - 1, index - start))
            start = None
    return runs


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--dpi", type=float, required=True, help="dpi the raster was produced at")
    parser.add_argument("--ylim", required=True, help="per-panel y range, e.g. 0,60,0,60")
    parser.add_argument("--colors", default="#104680,#4B73A0,#6D011F,#F6B293")
    parser.add_argument("--reference-dpi", type=float, default=200.0)
    args = parser.parse_args()

    rgb = load(args.image, args.dpi, args.reference_dpi)
    grey = np.asarray(Image.fromarray(rgb).convert("L"))
    height, width = grey.shape
    scale = args.reference_dpi / args.dpi
    print(f"image {width} x {height} px at {args.reference_dpi} dpi "
          f"= {width / args.reference_dpi:.2f} x {height / args.reference_dpi:.2f} in")

    rows = frame_grid(grey)
    print(f"frame rows {rows}")

    values = [float(v) for v in args.ylim.split(",")]
    ylim = list(zip(values[::2], values[1::2]))
    colours = {}
    for index, token in enumerate(args.colors.split(",")):
        token = token.strip().lstrip("#")
        colours[f"c{index}"] = tuple(int(token[i:i + 2], 16) for i in (0, 2, 4))

    for band in boxes_from_rows(rows):
        cols = vertical_spines(grey, *band)
        print(f"\n=== band rows {band}  ({len(cols)} spine lines)  cols {cols}")
        if len(cols) < 2:
            continue
        for entry, extent in bar_report(rgb, band, cols, colours, ylim):
            lo, hi = entry["ylim"]
            units_per_px = (hi - lo) / (band[1] - band[0])
            width_units = (extent[1] - extent[0]) * units_per_px
            print(f"\n  panel {entry['panel']}  cols {extent}  ylim {entry['ylim']}")
            print(f"    plot {((extent[1] - extent[0]) / args.reference_dpi):.3f} x "
                  f"{((band[1] - band[0]) / args.reference_dpi):.3f} in; "
                  f"x spans {width_units:.1f} data units")
            for bar in entry["bars"]:
                left = (bar["x_left"] - extent[0]) * units_per_px
                width = bar["width_px"] * units_per_px
                print(f"    {bar['colour']:>3}  x {left:>7.3f} .. {left + width:>7.3f}  "
                      f"(w {width:.3f})  value {bar['value']:>6.2f}")

    print("\ntext bands below the last row (ink height in px):")
    for start, stop, size in text_rows(grey, 140, 1417, rows[-1] + 2, height):
        print(f"    rows {start}-{stop}  height {size}")


if __name__ == "__main__":
    main()
