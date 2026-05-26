# Penz — Roadmap

## Completed

### Phase 1: Core BLE Capture
- [x] Real-time BLE capture via WinRT (`capture.py`)
- [x] Canvas rendering with PIL + SVG export (`canvas.py`)
- [x] FastAPI server with live preview (`server.py`)
- [x] Device registration + auth (`register.py`)
- [x] BLE scanner (`scanner.py`)
- [x] Stored page sync (`sync.py`)

### Phase 2: Godot App — Core
- [x] CanvasLayer overlay architecture (InkCanvas + HUD + toolbar + dialogs)
- [x] Live stroke rendering via Line2D nodes
- [x] Windows BLE bridge (capture.py subprocess + pipe file polling)
- [x] Wacom coordinate transform (21600x14700 → screen)
- [x] Page save (SVG) + gallery (view, delete, select+merge)
- [x] Connect dialog with progress steps
- [x] Settings panel (UUID config)

### Phase 3: Bug Fixes & Features
- [x] **Double-save bug** — `_page_just_saved` flag prevents duplicate pages on button-press disconnect
- [x] **Gallery thumbnails** — PNG thumbnails generated on save, gallery loads PNG instead of broken SVG
- [x] **OCR panel** — working with `minicpm-v` model on localhost:11434 (~30s response)
- [x] **Display rotation** — 90° counter-clockwise (portrait Slate → landscape screen)
- [x] **OCR image resize** — downscaled to 800px wide before sending to model

### OCR Notes
- `glm-ocr` (1.1B, F16): works on Rog but ~28s CPU inference. Uses custom renderer — not compatible with standard Ollama API on Lappy (v0.24.0).
- `minicpm-v` (5.5 GB, quantized): works on Rog, ~33s. Currently active.
- `gemma4` on Lappy: works via `/api/chat` but 9.6 GB model = slow load. Lappy Ollama not reachable from Godot (connection refused).
- Future: NVIDIA phi-4-multimodal cloud API would be instant but needs API key.

---

## Upcoming Sessions

### Session A: Polish & Stress-Test
**Goal**: Verify all completed features work end-to-end with the Slate.

- [ ] Connect to Slate → draw strokes → verify rendering with rotation
- [ ] Press Slate button → verify only ONE page saved (double-save fix)
- [ ] Open gallery → verify PNG thumbnails render
- [ ] Test gallery actions: View full-size, Delete, Select+Merge
- [ ] Draw handwriting → press OCR → verify text output (~30s)
- [ ] Test disconnect auto-save (put Slate to sleep while drawing)
- [ ] Fix any bugs found during testing

**Files**: `godot/main.gd`, `godot/canvas/ink_canvas.gd`, `godot/ui/gallery.gd`, `godot/ui/ocr_panel.gd`

### Session B: Sync Integration
**Goal**: Sync stored Slate pages into the Godot gallery.

- [ ] Bridge `sync.py` output (`data/pages/*.svg`) → Godot `user://pages/`
- [ ] Generate PNG thumbnails for synced pages
- [ ] Wire sync button in toolbar to trigger sync and refresh gallery
- [ ] End-to-end test: write on Slate offline → sync → pages appear in gallery

**Files**: `godot/main.gd`, `godot/core/ble_bridge.gd`, `sync.py`, `godot/canvas/ink_canvas.gd`

### Session C: Android BLE Plugin
**Goal**: Working BLE on Android via Kotlin plugin.

- [ ] Set up Gradle build for `godot/android/plugin/` (Godot 4.6 plugin format)
- [ ] Configure Android export preset in Godot
- [ ] Test build compiles and plugin loads
- [ ] Physical device test with the Slate — connect, draw, save
- [ ] Verify auto-HUD-hide works on touch

**Files**: `godot/android/plugin/src/main/java/org/penz/ble/*.kt`, `godot/export_presets.cfg`

### Session D: Font Maker Pipeline
**Goal**: Draw glyphs on canvas → segment → label → export TTF.

- [ ] Test `glyph_labeller.gd` UI (segment view, label input, build button)
- [ ] Test `fontmaker.py segment` (OpenCV contour detection → glyph PNGs)
- [ ] Test `fontmaker.py build` (glyph labels → potrace + fonttools → TTF)
- [ ] End-to-end: draw alphabet → segment → label each glyph → export font

**Files**: `godot/ui/glyph_labeller.gd`, `godot/fontmaker.py`

---

## Backlog

- [ ] Canvas undo/redo (stroke-level)
- [ ] Page renaming in gallery
- [ ] Export to PDF
- [ ] Pressure sensitivity settings (min/max threshold)
- [ ] Pen color/width picker
- [ ] Multi-page view (scrollable canvas)
- [ ] Cloud sync (Google Drive / Dropbox)
- [ ] Note search (OCR index + full-text search)
- [ ] Faster OCR (Lappy GPU or NVIDIA cloud API)
