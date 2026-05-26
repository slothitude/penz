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

---

## Next Sessions — Priority Order

### Session 1: Wire the Button — 0xCB as Universal Trigger
**Why**: The physical button on the Slate is the only hardware input in a paper computer.

- [x] Single press → save page + clear canvas (400ms debounce timer)
- [x] Double press → OCR the page + save + clear canvas
- [x] HUD messages with auto-fade ("Saved", "OCR + Save", "Button x2")
- [x] Toolbar "New" button bypasses gesture detection (immediate)
- [ ] ~~Long press → voice command~~ (not feasible — device sends 0xCB on press only, no release event)
- [ ] ~~Double press → queue to plotter~~ (repurposed as OCR trigger instead)

**Files**: `godot/main.gd`, `godot/ui/hud.gd`

### Session 2: page_daemon.py — The Invisible Layer
**Why**: Makes everything composable. New pages auto-OCR, auto-index, auto-embed. No user action required.

- [x] Watch `data/pages/` and `user://pages/` for new SVG files
- [x] Auto-OCR via Ollama on new page detection
- [x] Write `.meta.json` alongside each page (OCR text, timestamp, stroke count)
- [x] File watcher with debounced batch processing
- [x] Runs as background service / scheduled task

**Usage**: `python page_daemon.py` (watch mode) or `python page_daemon.py --scan` (one-shot)

**Files**: `page_daemon.py`

### Session 3: Close the Font Loop in Godot
**Why**: Draw letters → press button → TTF appears in Godot → live preview in your own handwriting. The moment Penz becomes showable.

- [x] Wire `glyph_labeller.gd` → `fontmaker.py segment` subprocess call
- [x] Wire label input → `fontmaker.py build` → TTF output
- [x] Load built TTF as DynamicFont in Godot for live preview
- [x] End-to-end: draw alphabet on Slate → segment → label each glyph → export → preview

**Files**: `godot/ui/glyph_labeller.gd`, `godot/fontmaker.py`, `godot/main.gd`, `godot/ui/toolbar.gd`

### Session 4: Bézier Tracing for fontmaker.py
**Why**: Quality multiplier. Smooth quadratic Bézier curves instead of jagged polygons — the difference between a real font and a bitmap font.

- [x] Use `approxPolyDP` for contour simplification
- [x] Convert polygon vertices to smooth quadratic Bézier curves (midpoint interpolation)
- [x] Build proper `Glyph` objects via `TTGlyphPen.qCurveTo()` instead of raw dicts
- [x] Fix dead imports and API misuse (`setupOs2` → `setupOS2`, removed unused `TTFont` init)
- [x] Test output: A/B/C glyphs render with 50/50 on-curve/off-curve points

**Note**: potrace not available on Windows without C compiler — used `approxPolyDP` + midpoint Bézier instead (same quality at glyph scale).

**Files**: `godot/fontmaker.py`

### Session 5: SetTime on Connect
**Why**: Every stored page gets an accurate timestamp. Free improvement.

- [x] Send `0xB6` with current datetime after auth succeeds
- [x] Verify stored page timestamps improve after sync
- [x] Add to both `capture.py` and `godot/core/ble_bridge.gd`

**Note**: Already implemented — `capture.py` lines 294-299/468-474, `PenzBLEPlugin.kt` line 178, `WacomProtocol.buildSetTime()`.

**Files**: `capture.py`, `godot/core/ble_bridge.gd`

### Session 6: Sync Integration
**Why**: Sync stored Slate pages into the Godot gallery.

- [x] Bridge `sync.py` output (`data/pages/*.svg`) → Godot `user://pages/`
- [x] Generate PNG thumbnails for synced pages (PIL thumbnail from InkCanvas)
- [x] Wire sync button in toolbar to trigger sync and refresh gallery
- [x] End-to-end: write on Slate offline → sync → pages appear in gallery

**Files**: `sync.py`, `godot/core/ble_bridge.gd`, `godot/main.gd`

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

---

## Protocol Opcodes — Shipped Status

| Opcode | Name | Status | Notes |
|--------|------|--------|-------|
| `0xA1` | PenData | shipped | Core live stream — 6-byte triplets, x/y/pressure |
| `0xA2` | Proximity | shipped | Pen enter/leave — stroke boundary detection |
| `0xB1` | SetMode | shipped | Live/paper/idle switching via multi-path sequence |
| `0xB6` | SetTime | unused | **Trivial to add** — sync device clock on connect |
| `0xB9` | GetBattery | shipped | Battery display in HUD |
| `0xCB` | ButtonPress | shipped | Single press = save, double press = OCR + save |
| `0xCC`/`0xCF` | StrokeInfo | shipped | Page size + timestamp on sync |
| `0xCA` | DeletePage | shipped | Auto-delete after sync |
| `0xE4` | ButtonConfirm | shipped | Registration flow |
| `0xEC` | SelectTransfer | shipped | File transfer service switch |

## OCR Notes
- `minicpm-v` (5.5 GB, quantized): current model, works on Rog localhost
- `glm-ocr` (2.2 GB F16): too slow on CPU, custom renderer incompatible with Lappy Ollama 0.24
- Future: fine-tune on Slate handwriting samples via font maker's labelled glyph dataset
- Future: NVIDIA phi-4-multimodal cloud API for instant OCR (needs API key)
