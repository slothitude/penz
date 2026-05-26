# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Penz — BLE capture tools for the Wacom Bamboo Slate smartpad. Captures real-time pen strokes over Bluetooth Low Energy and syncs stored pages from the device. Python tools run on Windows (Rog) using WinRT BLE APIs. Godot 4.6 app provides native UI for both Windows and Android.

## Architecture

### Data Flow
```
Wacom Slate (BLE) ──live stream──> capture.py ──HTTP──> server.py (FastAPI :8000)
                   ──stored pages──> sync.py ──parse──> data/pages/*.svg
```

### Core Modules

| File | Role |
|------|------|
| `capture.py` | Real-time BLE capture via WinRT GATT. Multi-path mode switch across 4 characteristics to enter live streaming. Streams (x, y, pressure) points to canvas + optional HTTP server. |
| `canvas.py` | `InkCanvas` — PIL rasterizer + SVG generator. Coordinate space: 21600×14700 (Wacom A5), rendered at 1/10 scale for PNG. Stores raw stroke data for vector export. |
| `server.py` | FastAPI backend (port 8000). Live canvas preview with auto-refresh, gallery of saved pages, device control (start/stop capture, sync). |
| `sync.py` | Downloads stored pages from device via bleak. Parses Wacom proprietary binary stroke format (`StrokeFile` class with delta encoding). CRC32 verification. Deletes pages from device after sync. |
| `register.py` | One-shot device registration + auth. Generates 6-byte UUID, requires physical button press on Slate. Saves UUID to `data/device_uuid.json`. |
| `scanner.py` | BLE discovery + GATT service enumeration. Saves results to `data/scan_results.json`. |
| `listen.py` | Debug listener — connects, subscribes to all notify characteristics, dumps raw data. |

### BLE Connection (Critical Details)
- **capture.py uses pure WinRT** (not bleak) — bleak only discovers 4 of 9 GATT services after device re-pairing
- **sync.py uses bleak** with `use_cached=True` for stored page downloads (works fine for file transfer)
- Device must be **paired via Windows Bluetooth Settings** before any programmatic connection
- Sleeping paired devices require WinRT wake first, then bleak `use_cached=True` for sync.py
- All GATT reads must use `BluetoothCacheMode.UNCACHED`

### Multi-Path Live Mode Sequence (capture.py)
Enter live mode requires writes to 4 characteristics in order:
1. `ffee0002` → mode command (`0xB1 0x01 0x00`)
2. `00001532` → mode command
3. `00001531` → mode command + subscribe to notifications
4. Nordic TX → auth (`0xE6` + UUID) → mode command

### Wacom Binary Stroke Format (sync.py)
- Magic: `b8bt` (4 bytes)
- Delta-encoded: header byte's popcount = payload size, bit pairs encode per-axis encoding (0x02=signed delta, 0x03=absolute u16)
- Stroke separators: all-0xFF payloads (6 or 7 bytes)
- EOF: 8-byte all-0xFF payload

### Protocol Opcodes
| Op | Name | Direction |
|----|------|-----------|
| `0xE6` | CheckAuth | TX→device |
| `0xE7` | Register | TX→device |
| `0xE4` | Button confirm | device→RX |
| `0xE5` | Register complete | TX→device |
| `0xB1` | SetMode (0x00=live, 0x01=paper, 0x02=idle) | TX→device |
| `0xB6` | SetTime | TX→device |
| `0xB9` | GetBattery | TX→device |
| `0xA1` | Live pen data (6-byte triplets) | Live char→client |
| `0xA2` | Pen proximity | Live char→client |
| `0xC1`/`0xC2` | Get/Set file count | sync |
| `0xC3`/`0xC8` | Start/End download | sync |
| `0xCA` | Delete page | sync |
| `0xEC` | Select file transfer | sync |

## Godot App (`godot/`)

Cross-platform native app with direct BLE on Android and subprocess BLE on Windows.

### Architecture: CanvasLayer Overlay
```
InkCanvas (full-screen base) — Wacom 21600×14700 → screen coordinates
  HUDLayer (CanvasLayer) — floating top bar, semi-transparent
  ToolbarLayer (CanvasLayer) — floating bottom bar
  DialogLayer (CanvasLayer) — connect dialog, gallery, settings, OCR panel, glyph labeller
```

### BLE Backends
- **Windows**: `capture.py --json-stdout` subprocess → pipe file → `ble_bridge.gd` polls at 60fps
- **Android**: Kotlin plugin (`PenzBLEPlugin.kt`) — direct `BluetoothGatt` with full Wacom protocol

### Key Files
| File | Role |
|------|------|
| `godot/main.gd` | Bootstrap, wires BLE bridge + canvas + UI |
| `godot/core/ble_bridge.gd` | Platform dispatch — Android plugin vs Windows subprocess |
| `godot/canvas/ink_canvas.gd` | Drawing surface — Line2D strokes baked to SubViewport texture |
| `godot/canvas/stroke_store.gd` | Stroke data + SVG export (same format as canvas.py) |
| `godot/canvas/canvas_transform.gd` | Wacom 21600×14700 → screen coordinate mapping |
| `godot/ui/ocr_panel.gd` | OCR via Ollama `glm-ocr` model (localhost:11434) |
| `godot/ui/glyph_labeller.gd` | Font maker UI — label segmented glyphs → build TTF |
| `godot/fontmaker.py` | Python subprocess: segment glyphs (OpenCV) + build TTF (fonttools) |
| `godot/android/plugin/` | Kotlin BLE plugin — full Wacom protocol reimplementation |

### New Pipeline Features
- **OCR**: Canvas → PNG → Ollama `glm-ocr` → extracted text panel
- **Font Maker**: Canvas → PNG → OpenCV segmentation → glyph labeller UI → potrace + fonttools → TTF

### Commands
```bash
# Open in Godot editor
cd godot && godot project.godot

# Run from command line
godot godot/project.godot

# Font maker standalone
python godot/fontmaker.py segment --input image.png --outdir tmp/glyphs
python godot/fontmaker.py build --glyphs tmp/glyphs/ --labels A,b,c,d --output font.ttf
```

```bash
# Install dependencies
pip install -r requirements.txt    # bleak, fastapi, uvicorn, Pillow, aiohttp + winrt

# Start web server (live preview + gallery)
python server.py                   # http://localhost:8000

# Live capture (saves SVG on exit)
python capture.py                  # saves to data/live_capture.svg
python capture.py --save out.svg --api http://localhost:8000   # capture + stream to server

# Sync stored pages from device
python sync.py                     # downloads to data/pages/, deletes from device
python sync.py --keep              # download without deleting

# First-time device registration
python register.py                 # requires physical button press on Slate

# Scan for device
python scanner.py                  # saves GATT map to data/scan_results.json
```

## Windows BLE Gotchas
- `winrt` package is required (`pip install winrt`) — provides Windows RT BLE bindings
- Device address is hardcoded: `FC:F5:69:C5:F9:4B` (int: `0xFCF569C5F94B`)
- UUID stored in `data/device_uuid.json` — required for auth, generated by register.py
- Device pages saved to `data/pages/`, raw binary to `data/raw/`
