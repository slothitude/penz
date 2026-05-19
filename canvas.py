# canvas.py — SVG + PNG rendering engine for Wacom ink data
import io
import os

from PIL import Image, ImageDraw

SLATE_W, SLATE_H = 21600, 14700  # Wacom A5 coordinate space
CANVAS_SCALE = 1 / 10
CANVAS_W, CANVAS_H = int(SLATE_W * CANVAS_SCALE), int(SLATE_H * CANVAS_SCALE)


class InkCanvas:
    def __init__(self):
        # SVG state — raw strokes for vector output
        self.strokes = []  # list of lists of (x, y, pressure)
        self._current_stroke = []
        # PNG state — raster fallback
        self.img = Image.new("RGB", (CANVAS_W, CANVAS_H), "white")
        self.draw = ImageDraw.Draw(self.img)
        self.last_point = None

    def add_point(self, x, y, pressure):
        # SVG
        self._current_stroke.append((x, y, pressure))
        # PNG
        sx = int(x * CANVAS_SCALE)
        sy = int(y * CANVAS_SCALE)
        if pressure > 0 and self.last_point:
            width = max(1, pressure // 200)
            self.draw.line([self.last_point, (sx, sy)], fill="black", width=width)
        self.last_point = (sx, sy) if pressure > 0 else None

    def pen_up(self):
        """End current stroke (pen lifted)."""
        if self._current_stroke:
            self.strokes.append(self._current_stroke)
            self._current_stroke = []
        self.last_point = None

    def add_stroke(self, points):
        for x, y, p in points:
            self.add_point(x, y, p)
        self.pen_up()

    def clear(self):
        self.strokes.clear()
        self._current_stroke.clear()
        self.img = Image.new("RGB", (CANVAS_W, CANVAS_H), "white")
        self.draw = ImageDraw.Draw(self.img)
        self.last_point = None

    # ─── SVG export ──────────────────────────────────────────────────

    def to_svg(self):
        """Return SVG string with variable-width strokes."""
        paths = []
        for stroke in self.strokes:
            for i in range(1, len(stroke)):
                x0, y0, p0 = stroke[i - 1]
                x1, y1, p1 = stroke[i]
                if p0 == 0 and p1 == 0:
                    continue
                w = max(1, ((p0 + p1) / 2) / 200)
                # Round to 1 decimal to keep file size reasonable
                paths.append(
                    f'<line x1="{x0:.0f}" y1="{y0:.0f}" '
                    f'x2="{x1:.0f}" y2="{y1:.0f}" '
                    f'stroke-width="{w:.1f}" '
                    f'stroke-linecap="round"/>'
                )
        lines = "\n  ".join(paths) if paths else ""
        return (
            f'<svg xmlns="http://www.w3.org/2000/svg" '
            f'viewBox="0 0 {SLATE_W} {SLATE_H}">\n'
            f'<rect width="100%" height="100%" fill="white"/>\n'
            f'<g stroke="black" stroke-linecap="round" stroke-linejoin="round">\n'
            f'  {lines}\n'
            f'</g>\n</svg>'
        )

    def save_svg(self, path):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(self.to_svg())

    # ─── PNG export (fallback) ───────────────────────────────────────

    def to_png_bytes(self):
        buf = io.BytesIO()
        self.img.save(buf, format="PNG")
        buf.seek(0)
        return buf

    def save(self, path):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        if path.endswith(".svg"):
            self.save_svg(path)
        else:
            self.img.save(path)


if __name__ == "__main__":
    c = InkCanvas()
    for i in range(0, 21600, 100):
        c.add_point(i, i * 14700 // 21600, 800)
    c.pen_up()
    c.save("data/test_canvas.svg")
    c.save("data/test_canvas.png")
    print("Saved test_canvas.svg and test_canvas.png")
