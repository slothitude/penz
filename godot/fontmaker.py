"""
fontmaker.py — Handwriting → Font pipeline.
Runs as subprocess from Godot, communicates via JSON stdout.

Modes:
  fontmaker.py segment --input image.png --outdir tmp/
    → Otsu threshold, findContours, extract glyph bounding boxes
    → Writes numbered PNGs, outputs JSON: {"type":"glyphs","paths":["tmp/g001.png",...]}
    → Also outputs OCR hints: {"type":"ocr_hints","chars":["A","b","c",...]}

  fontmaker.py build --glyphs dir/ --labels A,b,c,d --output myfont.ttf
    → Traces each glyph PNG to SVG via potrace
    → Assembles TTF via fonttools

Requires: opencv-python, potrace (CLI), fonttools, pillow
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

import cv2
import numpy as np
from PIL import Image


def _json_out(obj: dict):
    print(json.dumps(obj), flush=True)


def segment(input_path: str, outdir: str) -> None:
    """Segment handwriting image into individual glyph PNGs."""
    os.makedirs(outdir, exist_ok=True)

    img = cv2.imread(input_path, cv2.IMREAD_GRAYSCALE)
    if img is None:
        _json_out({"type": "error", "message": f"Cannot read image: {input_path}"})
        return

    # Otsu threshold (invert so text is white on black)
    _, binary = cv2.threshold(img, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)

    # Morphological cleanup — close small gaps
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (3, 3))
    binary = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel, iterations=1)

    # Find contours
    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    # Filter tiny noise (contours with area < 50px)
    contours = [c for c in contours if cv2.contourArea(c) > 50]

    if not contours:
        _json_out({"type": "error", "message": "No contours found"})
        return

    # Sort L→R, T→B (reading order)
    bboxes = []
    for c in contours:
        x, y, w, h = cv2.boundingRect(c)
        bboxes.append((x, y, w, h, c))

    # Sort by y first (rows), then by x within rows
    bboxes.sort(key=lambda b: (b[1] // 30, b[0]))  # 30px row tolerance

    # Extract each glyph
    glyph_paths = []
    padding = 4

    for i, (x, y, w, h, _) in enumerate(bboxes):
        # Crop from original (not binary) for better quality
        x1 = max(0, x - padding)
        y1 = max(0, y - padding)
        x2 = min(img.shape[1], x + w + padding)
        y2 = min(img.shape[0], y + h + padding)

        glyph = img[y1:y2, x1:x2]

        # Save as PNG
        fname = f"g{i + 1:03d}.png"
        fpath = os.path.join(outdir, fname)
        cv2.imwrite(fpath, glyph)
        glyph_paths.append(fpath)

    _json_out({
        "type": "glyphs",
        "paths": glyph_paths,
        "count": len(glyph_paths)
    })


def build(glyphs_dir: str, labels: list[str], output_path: str) -> None:
    """Build TTF from labelled glyph PNGs using Bézier tracing + fonttools."""
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from fontTools.ttLib.tables._g_l_y_f import Glyph

    glyph_files = sorted([f for f in os.listdir(glyphs_dir) if f.endswith(".png")])

    if len(glyph_files) != len(labels):
        _json_out({
            "type": "error",
            "message": f"Mismatch: {len(glyph_files)} glyphs, {len(labels)} labels"
        })
        return

    # Trace each glyph into a Glyph object via TTGlyphPen
    glyph_table = {}
    widths = {}
    for i, (glyph_file, label) in enumerate(zip(glyph_files, labels)):
        glyph_path = os.path.join(glyphs_dir, glyph_file)
        contours = _trace_glyph(glyph_path)
        glyph_table[label] = _draw_glyph(contours)
        widths[label] = 500

        _json_out({"type": "progress", "step": f"Tracing glyph {i + 1}/{len(glyph_files)}"})

    # Empty .notdef glyph
    glyph_table[".notdef"] = Glyph()
    widths[".notdef"] = 500

    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder([".notdef"] + labels)
    fb.setupCharacterMap({ord(c): c for c in labels if len(c) == 1})
    fb.setupGlyf(glyph_table, calcGlyphBounds=True, validateGlyphFormat=False)
    fb.setupHorizontalMetrics({g: (widths[g], 50) for g in [".notdef"] + labels})
    fb.setupHorizontalHeader()
    fb.setupNameTable({"familyName": "PenzHandwriting", "styleName": "Regular"})
    fb.setupOS2()
    fb.setupPost()

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    fb.font.save(output_path)
    _json_out({"type": "built", "path": output_path})


def _trace_glyph(png_path: str) -> list:
    """Trace a glyph PNG to smooth quadratic Bézier contours."""
    img = cv2.imread(png_path, cv2.IMREAD_GRAYSCALE)
    if img is None:
        return []

    _, binary = cv2.threshold(img, 128, 255, cv2.THRESH_BINARY_INV)
    h, w = binary.shape

    # Find contours with full point storage
    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_TC89_L1)

    result = []
    for contour in contours:
        # Simplify with approxPolyDP for fewer, smoother control points
        epsilon = cv2.arcLength(contour, True) * 0.02
        approx = cv2.approxPolyDP(contour, epsilon, True)

        if len(approx) < 3:
            continue

        # Scale to 1000-unit font space with margins
        points = []
        for pt in approx:
            fx = int(pt[0][0] / w * 800) + 100
            fy = int((h - pt[0][1]) / h * 800) + 100
            points.append((fx, fy))

        result.append(points)

    return result


def _draw_glyph(contours: list) -> "Glyph":
    """Draw smooth quadratic Bézier contours into a Glyph via TTGlyphPen.

    Converts polygon vertices to smooth curves by inserting midpoints
    as on-curve anchors, keeping original vertices as off-curve controls.
    """
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from fontTools.ttLib.tables._g_l_y_f import Glyph

    if not contours:
        return Glyph()

    pen = TTGlyphPen(None)

    for contour in contours:
        n = len(contour)
        if n < 3:
            continue

        # Start at midpoint between last and first vertex
        mid_start = (
            (contour[-1][0] + contour[0][0]) // 2,
            (contour[-1][1] + contour[0][1]) // 2,
        )
        pen.moveTo(mid_start)

        for i in range(n):
            # Off-curve control point (original vertex)
            # On-curve midpoint to next vertex
            next_i = (i + 1) % n
            mid = (
                (contour[i][0] + contour[next_i][0]) // 2,
                (contour[i][1] + contour[next_i][1]) // 2,
            )
            pen.qCurveTo(contour[i], mid)

        pen.closePath()

    return pen.glyph()


def main():
    parser = argparse.ArgumentParser(description="Font maker pipeline")
    sub = parser.add_subparsers(dest="command")

    seg = sub.add_parser("segment", help="Segment image into glyphs")
    seg.add_argument("--input", required=True, help="Input image path")
    seg.add_argument("--outdir", default="tmp/glyphs", help="Output directory")

    bld = sub.add_parser("build", help="Build TTF from glyphs")
    bld.add_argument("--glyphs", required=True, help="Directory of labelled glyphs")
    bld.add_argument("--labels", required=True, help="Comma-separated labels")
    bld.add_argument("--output", default="output/font.ttf", help="Output TTF path")

    args = parser.parse_args()

    if args.command == "segment":
        segment(args.input, args.outdir)
    elif args.command == "build":
        labels = [l.strip() for l in args.labels.split(",")]
        build(args.glyphs, labels, args.output)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
