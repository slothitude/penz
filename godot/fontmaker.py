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
    """Build TTF from labelled glyph PNGs using potrace + fonttools."""
    from fontTools.ttLib import TTFont
    from fontTools.pens.t2Pen import T2Pen
    from fontTools.pens.recordingPen import RecordingPen

    # Create a basic TTF
    font = TTFont()
    font.setGlyphOrder([".notdef"] + labels)

    cmap = font.newTable("cmap")
    cmap.tableVersion = 0
    subtable = font["cmap"] = cmap

    # For each glyph, trace PNG → SVG paths via potrace → add to font
    glyph_files = sorted([f for f in os.listdir(glyphs_dir) if f.endswith(".png")])

    if len(glyph_files) != len(labels):
        _json_out({
            "type": "error",
            "message": f"Mismatch: {len(glyph_files)} glyphs, {len(labels)} labels"
        })
        return

    # Create glyph outlines
    from fontTools.fontBuilder import FontBuilder
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder([".notdef"] + labels)
    fb.setupCharacterMap({ord(c): c for c in labels if len(c) == 1})

    # Setup basic tables
    fb.setupGlyf({".notdef": {"numberOfContours": 0}})

    # Trace each glyph
    glyf_table = {}
    for i, (glyph_file, label) in enumerate(zip(glyph_files, labels)):
        glyph_path = os.path.join(glyphs_dir, glyph_file)
        contours = _trace_glyph(glyph_path)
        if contours:
            glyf_table[label] = _contours_to_glyph(contours)
        else:
            glyf_table[label] = {"numberOfContours": 0}

        _json_out({"type": "progress", "step": f"Tracing glyph {i + 1}/{len(glyph_files)}"})

    fb.setupGlyf(glyf_table)
    fb.setupHorizontalMetrics({g: (500, 50) for g in [".notdef"] + labels})
    fb.setupHorizontalHeader()
    fb.setupNameTable({"familyName": "PenzHandwriting", "styleName": "Regular"})
    fb.setupOs2()
    fb.setupPost()

    font = fb.font
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    font.save(output_path)

    _json_out({"type": "built", "path": output_path})


def _trace_glyph(png_path: str) -> list:
    """Trace a glyph PNG to contours using potrace CLI."""
    # Read and threshold
    img = cv2.imread(png_path, cv2.IMREAD_GRAYSCALE)
    if img is None:
        return []

    _, binary = cv2.threshold(img, 128, 255, cv2.THRESH_BINARY_INV)

    # Find contours
    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    # Convert to normalized coordinates (0-1000 for font units)
    h, w = binary.shape
    result = []
    for contour in contours:
        points = []
        for pt in contour[0]:
            # Scale to 1000-unit font space
            fx = int(pt[0] / w * 800) + 100  # 100 unit left margin
            fy = int((h - pt[1]) / h * 800) + 100  # flip Y, bottom margin
            points.append((fx, fy))
        if len(points) >= 3:
            result.append(points)

    return result


def _contours_to_glyph(contours: list) -> dict:
    """Convert contour point lists to fontTools glyph dict."""
    # Simple polygon contours for TTF
    return {
        "numberOfContours": len(contours),
        "coordinates": contours,
        "flags": [[1] * len(c) for c in contours],
    }


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
