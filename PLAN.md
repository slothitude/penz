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
- [x] Wacom coordinate transform (21600x14700 → screen, 90° CCW rotation)
- [x] Page save (SVG + PNG thumbnail) + gallery (view, delete, select+merge)
- [x] Connect dialog with progress steps
- [x] Settings panel (UUID config)

### Phase 3: Bug Fixes & Polish
- [x] **Double-save bug** — `_page_just_saved` flag prevents duplicate pages on button-press disconnect
- [x] **Gallery thumbnails** — PNG generated alongside SVG on every save
- [x] **OCR panel** — working with `minicpm-v` model on localhost:11434 (~30s)
- [x] **Display rotation** — 90° counter-clockwise for portrait Slate usage
- [x] **OCR image resize** — downscaled to 800px wide before sending to model

### Protocol Opcodes — Shipped Status

| Opcode | Name | Status | Notes |
|--------|------|--------|-------|
| `0xA1` | PenData | shipped | Core live stream — 6-byte triplets, x/y/pressure |
| `0xA2` | Proximity | shipped | Pen enter/leave — stroke boundary detection |
| `0xB1` | SetMode | shipped | Live/paper/idle switching via multi-path sequence |
| `0xB6` | SetTime | unused | **Trivial to add** — sync device clock on connect |
| `0xB9` | GetBattery | shipped | Battery display in HUD |
| `0xCB` | ButtonPress | partial | Triggers new page only — **underused** |
| `0xCC`/`0xCF` | StrokeInfo | shipped | Page size + timestamp on sync |
| `0xCA` | DeletePage | shipped | Auto-delete after sync |
| `0xE4` | ButtonConfirm | shipped | Registration flow |
| `0xEC` | SelectTransfer | shipped | File transfer service switch |

### OCR Notes
- `minicpm-v` (5.5 GB, quantized): current model, works on Rog localhost
- `glm-ocr` (2.2 GB F16): too slow on CPU, custom renderer incompatible with Lappy Ollama 0.24
- Future: fine-tune on Slate handwriting samples via font maker's labelled glyph dataset
- Future: NVIDIA phi-4-multimodal cloud API for instant OCR (needs API key)

---

## Next Sessions — Priority Order

### Session 1: Wire the Button — 0xCB as Universal Trigger
**Why**: The physical button on the Slate is the only hardware input in a paper computer. One button, three gestures, zero keyboard.

- [ ] Implement press duration detection (short < 500ms, long > 1000ms)
- [ ] Short press → file page (save + clear, current behavior)
- [ ] Long press → start voice command (Whisper STT, intent parser)
- [ ] Double press → queue to plotter (POST to plotter /api endpoint)
- [ ] Debounce logic to distinguish single/double/long press
- [ ] Visual feedback in HUD for each gesture type

**Files**: `godot/main.gd`, `godot/core/ble_bridge.gd`, `godot/ui/hud.gd`, `capture.py`

### Session 2: page_daemon.py — The Invisible Layer
**Why**: Makes everything composable. New pages auto-OCR, auto-index, auto-embed. No user action required.

- [ ] Watch `data/pages/` and `user://pages/` for new SVG files
- [ ] Auto-OCR via Ollama on new page detection
- [ ] Write `.meta.json` alongside each page (OCR text, timestamp, stroke count)
- [ ] File watcher with debounced batch processing
- [ ] Runs as background service / scheduled task

**Files**: New `page_daemon.py`, reuses OCR logic from `godot/ui/ocr_panel.gd`

### Session 3: Close the Font Loop in Godot
**Why**: Draw letters → press button → TTF appears in Godot → live preview in your own handwriting. The moment Penz becomes showable.

- [ ] Wire `glyph_labeller.gd` → `fontmaker.py segment` subprocess call
- [ ] Wire label input → `fontmaker.py build` → TTF output
- [ ] Load built TTF as DynamicFont in Godot for live preview
- [ ] End-to-end: draw alphabet on Slate → segment → label each glyph → export → preview

**Files**: `godot/ui/glyph_labeller.gd`, `godot/fontmaker.py`, `godot/main.gd`

### Session 4: Bézier Tracing for fontmaker.py
**Why**: Quality multiplier. Currently importing raster outlines from OpenCV. potrace gives smooth vector curves — the difference between a real font and a blurry bitmap font.

- [ ] Add potrace subprocess step between segmentation and FontBuilder
- [ ] Replace raster contour import with vector outlines
- [ ] Test output quality with handwriting samples
- [ ] Consider opencv `approxPolyDP` as fallback if potrace unavailable

**Files**: `godot/fontmaker.py`

### Session 5: SetTime on Connect
**Why**: 30 minutes of work. Every stored page gets an accurate timestamp. Free improvement.

- [ ] Send `0xB6` with current datetime after auth succeeds
- [ ] Verify stored page timestamps improve after sync
- [ ] Add to both `capture.py` and `godot/core/ble_bridge.gd`

**Files**: `capture.py`, `godot/core/ble_bridge.gd`

### Session 6: Sync Integration
**Goal**: Sync stored Slate pages into the Godot gallery.

- [ ] Bridge `sync.py` output (`data/pages/*.svg`) → Godot `user://pages/`
- [ ] Generate PNG thumbnails for synced pages
- [ ] Wire sync button in toolbar to trigger sync and refresh gallery
- [ ] End-to-end: write on Slate offline → sync → pages appear in gallery

**Files**: `godot/main.gd`, `godot/core/ble_bridge.gd`, `sync.py`, `godot/canvas/ink_canvas.gd`

---

## Backlog

- [ ] Android BLE plugin field test (Gradle build + physical device)
- [ ] Voice pipeline (Whisper STT, TTS, wake word, intent parser)
- [ ] Graph integration (property graph, node IDs, fabricated-from edges, knowledge layer)
- [ ] Canvas undo/redo (stroke-level)
- [ ] Page renaming in gallery
- [ ] Export to PDF
- [ ] Pressure sensitivity settings
- [ ] Pen color/width picker
- [ ] Multi-page view (scrollable canvas)
- [ ] Cloud sync (Google Drive / Dropbox)
- [ ] Note search (OCR index + full-text search)
- [ ] Faster OCR (Lappy GPU or NVIDIA cloud API)
- [ ] Plotter integration (auto-queue from button press)
