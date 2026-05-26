#!/usr/bin/env python
# page_daemon.py — Watches for new pages and auto-OCRs them.
# Runs as a background process. Detects new SVG files, runs OCR via Ollama,
# and writes .meta.json alongside each page.

import argparse
import base64
import json
import os
import sys
import time
from pathlib import Path

try:
    import requests
except ImportError:
    # Fallback to urllib if requests not installed
    import urllib.request
    import urllib.error
    requests = None

# Default config
DEFAULT_PAGES_DIR = os.path.join(
    os.environ.get("APPDATA", ""),
    "Godot", "app_userdata", "Penz", "pages"
)
OLLAMA_URL = "http://localhost:11434/api/generate"
OLLAMA_MODEL = "minicpm-v"
OCR_PROMPT = "Transcribe all handwritten text exactly as written. Output only the text, no labels or commentary."
DEBOUNCE_SECONDS = 3.0


def find_pages_dir() -> str:
    """Find the pages directory — Godot user:// or project data/pages/."""
    # Try Godot's user:// path first
    if os.path.isdir(DEFAULT_PAGES_DIR):
        return DEFAULT_PAGES_DIR
    # Fallback to project data dir
    project_data = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "pages")
    if os.path.isdir(project_data):
        return project_data
    return DEFAULT_PAGES_DIR  # Return default even if it doesn't exist yet


def get_thumb_path(svg_path: str) -> str:
    """Find the PNG thumbnail for an SVG page."""
    thumb = svg_path.replace(".svg", "_thumb.png")
    if os.path.exists(thumb):
        return thumb
    return ""


def needs_ocr(svg_path: str) -> bool:
    """Check if a page needs OCR (no .meta.json or meta has no ocr_text)."""
    meta_path = svg_path.replace(".svg", ".meta.json")
    if not os.path.exists(meta_path):
        return True
    try:
        with open(meta_path, "r", encoding="utf-8") as f:
            meta = json.load(f)
        # Re-OCR if explicitly marked as needing it, or if ocr_text is empty
        if meta.get("ocr_status") == "pending":
            return True
        if not meta.get("ocr_text", "").strip():
            return True
        return False
    except (json.JSONDecodeError, OSError):
        return True


def count_svg_strokes(svg_path: str) -> int:
    """Count strokes in an SVG file (number of <line> elements = raw points, group by proximity)."""
    try:
        with open(svg_path, "r", encoding="utf-8") as f:
            content = f.read()
        return content.count("<line")
    except OSError:
        return 0


def write_meta(svg_path: str, **kwargs) -> None:
    """Write or update a .meta.json file alongside a page."""
    meta_path = svg_path.replace(".svg", ".meta.json")

    # Load existing meta if present
    meta = {}
    if os.path.exists(meta_path):
        try:
            with open(meta_path, "r", encoding="utf-8") as f:
                meta = json.load(f)
        except (json.JSONDecodeError, OSError):
            pass

    meta.update(kwargs)
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)


def run_ocr(image_path: str) -> str:
    """Run OCR on an image file via Ollama. Returns extracted text or empty string."""
    try:
        with open(image_path, "rb") as f:
            img_data = f.read()
    except OSError as e:
        print(f"  Error reading image: {e}")
        return ""

    b64 = base64.b64encode(img_data).decode("utf-8")

    payload = {
        "model": OLLAMA_MODEL,
        "prompt": OCR_PROMPT,
        "images": [b64],
        "stream": False,
    }

    try:
        if requests:
            resp = requests.post(OLLAMA_URL, json=payload, timeout=180)
            resp.raise_for_status()
            data = resp.json()
        else:
            req = urllib.request.Request(
                OLLAMA_URL,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=180) as resp:
                data = json.loads(resp.read().decode("utf-8"))

        if "error" in data:
            print(f"  Ollama error: {data['error']}")
            return ""
        # /api/generate returns "response", /api/chat returns "message.content"
        return data.get("response", "") or data.get("message", {}).get("content", "")
    except Exception as e:
        print(f"  OCR failed: {e}")
        return ""


def resize_image(image_path: str, max_width: int = 800) -> str:
    """Resize image to max_width, saving to a temp file. Returns temp path or original."""
    try:
        from PIL import Image
        img = Image.open(image_path)
        if img.width <= max_width:
            return image_path
        ratio = max_width / img.width
        new_size = (max_width, int(img.height * ratio))
        img = img.resize(new_size, Image.LANCZOS)
        tmp_path = image_path + ".resized.png"
        img.save(tmp_path, "PNG")
        return tmp_path
    except ImportError:
        # No PIL — send full size
        return image_path
    except Exception as e:
        print(f"  Resize failed: {e}")
        return image_path


def process_page(svg_path: str) -> None:
    """Process a single page: extract metadata, run OCR, write .meta.json."""
    page_name = os.path.basename(svg_path)
    print(f"Processing: {page_name}")

    # Basic metadata
    stroke_count = count_svg_strokes(svg_path)
    file_stat = os.stat(svg_path)
    meta = {
        "file": page_name,
        "timestamp": time.strftime(
            "%Y-%m-%dT%H:%M:%S", time.localtime(file_stat.st_mtime)
        ),
        "stroke_count": stroke_count,
        "ocr_status": "pending",
    }
    write_meta(svg_path, **meta)

    # Find image for OCR (thumbnail or render from SVG)
    thumb_path = get_thumb_path(svg_path)
    if not thumb_path:
        print(f"  No thumbnail found, skipping OCR")
        write_meta(svg_path, ocr_status="no_image")
        return

    # Resize and run OCR
    resized = resize_image(thumb_path)
    print(f"  Running OCR...", end=" ", flush=True)
    ocr_text = run_ocr(resized)

    # Clean up temp resized image
    if resized != thumb_path and os.path.exists(resized):
        os.remove(resized)

    if ocr_text.strip():
        print(f"got {len(ocr_text)} chars")
        write_meta(svg_path, ocr_text=ocr_text.strip(), ocr_status="done")
    else:
        print("no text detected")
        write_meta(svg_path, ocr_text="", ocr_status="empty")


def scan_and_process(pages_dir: str, force: bool = False) -> int:
    """Scan pages directory and process any pages needing OCR. Returns count processed."""
    if not os.path.isdir(pages_dir):
        print(f"Pages directory not found: {pages_dir}")
        return 0

    processed = 0
    svg_files = sorted(
        [f for f in os.listdir(pages_dir) if f.endswith(".svg") and "_thumb" not in f]
    )

    for svg_name in svg_files:
        svg_path = os.path.join(pages_dir, svg_name)
        if not force and not needs_ocr(svg_path):
            continue
        process_page(svg_path)
        processed += 1

    return processed


def watch(pages_dir: str, poll_interval: float = 5.0) -> None:
    """Watch pages directory for new files. Runs forever."""
    print(f"Watching: {pages_dir}")
    print(f"Polling every {poll_interval}s, debounce {DEBOUNCE_SECONDS}s")
    print(f"Ollama: {OLLAMA_URL} ({OLLAMA_MODEL})")
    print("Press Ctrl+C to stop.\n")

    # Track file modification times
    known_files: dict[str, float] = {}
    pending: dict[str, float] = {}  # path -> first-seen timestamp (for debounce)

    # Seed with existing files (don't process on startup unless --force)
    if os.path.isdir(pages_dir):
        for f in os.listdir(pages_dir):
            if f.endswith(".svg") and "_thumb" not in f:
                path = os.path.join(pages_dir, f)
                known_files[path] = os.path.getmtime(path)

    while True:
        try:
            time.sleep(poll_interval)
        except KeyboardInterrupt:
            print("\nStopping.")
            break

        if not os.path.isdir(pages_dir):
            continue

        now = time.time()

        # Detect new or modified files
        current_files = {}
        for f in os.listdir(pages_dir):
            if f.endswith(".svg") and "_thumb" not in f:
                path = os.path.join(pages_dir, f)
                current_files[path] = os.path.getmtime(path)

                if path not in known_files or known_files[path] != current_files[path]:
                    # New or modified file
                    if path not in pending:
                        pending[path] = now

        known_files = current_files

        # Process pending files after debounce period
        to_process = []
        to_remove = []
        for path, first_seen in pending.items():
            # Wait for the file to stabilize (no recent writes) + debounce
            try:
                mtime = os.path.getmtime(path)
                if now - mtime >= DEBOUNCE_SECONDS and now - first_seen >= DEBOUNCE_SECONDS:
                    # Also check that thumbnail exists (Godot saves it after SVG)
                    thumb = get_thumb_path(path)
                    if thumb or now - first_seen >= DEBOUNCE_SECONDS * 3:
                        to_process.append(path)
                        to_remove.append(path)
            except OSError:
                to_remove.append(path)

        for path in to_remove:
            pending.pop(path, None)

        for path in to_process:
            if needs_ocr(path):
                process_page(path)


def main():
    global OLLAMA_MODEL

    parser = argparse.ArgumentParser(description="Auto-OCR daemon for Penz pages")
    parser.add_argument("--dir", default=None, help="Pages directory (auto-detected if omitted)")
    parser.add_argument("--scan", action="store_true", help="Scan once and exit (no watch)")
    parser.add_argument("--force", action="store_true", help="Re-OCR all pages, even already processed ones")
    parser.add_argument("--poll", type=float, default=5.0, help="Poll interval in seconds (default: 5)")
    parser.add_argument("--model", default=OLLAMA_MODEL, help="Ollama model name")
    args = parser.parse_args()

    OLLAMA_MODEL = args.model

    pages_dir = args.dir or find_pages_dir()

    if args.scan:
        count = scan_and_process(pages_dir, force=args.force)
        print(f"\nProcessed {count} pages.")
    else:
        if args.force:
            scan_and_process(pages_dir, force=True)
        watch(pages_dir, poll_interval=args.poll)


if __name__ == "__main__":
    main()
