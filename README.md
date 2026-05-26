# Penz

**Open-source BLE capture, real-time drawing, OCR, and font creation for the Wacom Bamboo Slate smartpad.**

[![Godot 4.6](https://img.shields.io/badge/Godot-4.6-blue)](https://godotengine.org)
[![Python 3.13](https://img.shields.io/badge/Python-3.13-green)](https://python.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

<p align="center">
  <img src="godot/screenshot.png" width="300" alt="Penz app showing paper canvas with dark chrome HUD and toolbar">
</p>

Penz connects to a Wacom Bamboo Slate over Bluetooth Low Energy, streams pen strokes in real-time (x, y, pressure at 200+ Hz), and renders them in a native Godot app. It also downloads stored pages from the device, transcribes handwriting via local AI, and builds custom TTF fonts from handwritten glyphs.

Everything below was reverse-engineered from scratch — no SDK, no documentation, no public API.

## Features

- **Live capture** — Stream pen strokes from the Slate in real time, rendered instantly on a warm paper canvas
- **Stored page sync** — Download pages from the device's onboard memory, parse the proprietary binary stroke format
- **Cross-platform app** — Native Godot UI for Windows and Android with live drawing, gallery, and settings
- **Handwriting OCR** — Draw text, press a button, get transcription via local vision AI (Ollama)
- **Font maker** — Segment handwritten glyphs, label them, export a TTF font
- **Web server** — FastAPI backend with live canvas preview and device control
- **Hardware button** — Single press saves, double press runs OCR + save

## Comparison with [Tuhi](https://github.com/tuhiproject/tuhi)

[Tuhi](https://github.com/tuhiproject/tuhi) (166 stars) is the only other open-source Wacom smartpad tool. Both projects independently reverse-engineered the same BLE protocol. Key differences:

| | **Penz** | **Tuhi** |
|---|---|---|
| Live stroke capture with real-time canvas | Yes | No (routes through Linux uhid) |
| Stored page download | Yes | Yes |
| Cross-platform | Windows + Android | Linux only |
| OCR / transcription | Yes (local vision model) | No |
| Font creation | Yes (glyph segmentation + TTF) | No |
| GUI framework | Godot 4.6 (native) | GTK (Python) |
| Coordinate transform | 90-degree rotation for portrait use | None |
| Pressure-sensitive rendering | Yes | No |

## Quick Start

### Prerequisites

- A **Wacom Bamboo Slate** paired via Bluetooth
- **Python 3.13+** with bleak, winrt, fastapi, uvicorn, Pillow, aiohttp
- **Godot 4.6** for the native app
- **Ollama** with a vision model for OCR (optional)
- **OpenCV + fonttools** for font maker (optional)

### Install

```bash
git clone https://github.com/slothitude/penz.git
cd penz
pip install -r requirements.txt
```

### Register Your Device (first time only)

```bash
python register.py                 # requires physical button press on Slate
```

### Live Capture

```bash
python capture.py                  # saves to data/live_capture.svg
python capture.py --save out.svg --api http://localhost:8000
```

### Sync Stored Pages

```bash
python sync.py                     # downloads to data/pages/, deletes from device
python sync.py --keep              # download without deleting
```

### Web Server

```bash
python server.py                   # http://localhost:8000
```

### Godot App

```bash
godot godot/project.godot          # open in Godot 4.6 editor
```

Connect → draw on paper → strokes appear on screen in real time.

### OCR Setup

```bash
ollama pull minicpm-v              # pull the vision model (5.5 GB)
```

Draw handwriting on the Slate, press the OCR button (or double-press the hardware button), text appears in ~30 seconds. No cloud, no API keys — everything runs locally.

### Font Maker

```bash
python godot/fontmaker.py segment --input handwriting.png --outdir glyphs/
python godot/fontmaker.py build --glyphs glyphs/ --labels A,B,C,D --output my_font.ttf
```

---

## The Reverse Engineering Story

The Wacom Bamboo Slate has no public API, no SDK, no documentation. Everything below was discovered by capturing BLE traffic, analyzing packet dumps, and methodically probing the device.

### The Device

The Slate is an A5 smartpad with an inductive pen sensor. It stores strokes in onboard memory and streams them live over BLE. The coordinate space is **21600 x 14700** units with **2047 pressure levels** — Wacom's standard high-resolution digitizer output.

### The Breakthrough: Multi-Path Mode Switch

The single hardest problem was getting live data out of the device. Writing to one GATT characteristic does nothing. Writing to two? Nothing. The Slate requires writes to **four different characteristics across three different services in exact sequence** before it starts streaming pen data:

```
Step 1:  Write [0xB1, 0x01, 0x00]  →  ffee0002  (Wacom File Transfer)
Step 2:  Write [0xB1, 0x01, 0x00]  →  00001532  (DFU Packet)
Step 3:  Write [0xB1, 0x01, 0x00]  →  00001531  (DFU Control) + subscribe
Step 4:  Write [0xE6, 0x06, UUID]  →  6e400002  (Nordic UART TX)
Step 5:  Write [0xB1, 0x01, 0x00]  →  6e400002  (Nordic UART TX)
```

Why? Wacom spreads the mode switch across unrelated services — a DFU service, a file transfer service, and a UART — presumably to make reverse engineering harder. Each write alone is ignored. All four must fire in order. This was discovered after weeks of packet captures and dead ends.

### The Wake Problem

On Windows, a paired but sleeping Slate can't be woken by `bleak` (the standard Python BLE library). Bleak only discovers 4 of 9 GATT services after device re-pairing. The solution: wake the device with WinRT (`BluetoothLEDevice.from_bluetooth_address_async`), then hand off to `bleak` with `use_cached=True`. This hybrid approach is the only way to reliably connect on Windows.

---

## Protocol Documentation

### GATT Services

| Service UUID | Name | Role |
|---|---|---|
| `6e400001-b5a3-f393-e0a9-e50e24dcca9e` | Nordic UART | Command channel (TX/RX) |
| `00001523-1212-efde-1523-785feabcd123` | Wacom Live | Real-time pen data stream |
| `ffee0001-bbaa-9988-7766-554433221100` | Wacom File Transfer | Stored page downloads |
| `3a340720-c572-11e5-86c5-0002a5d5c51b` | System Event | Physical button events |
| `00001530-1212-efde-1523-785feabcd123` | DFU | Mode switch path (repurposed) |

### Protocol Opcodes

| Op | Name | Direction | Description |
|---|---|---|---|
| `0xE6` | CheckAuth | TX → device | Send 6-byte UUID to authenticate |
| `0xE7` | Register | TX → device | One-time registration with new UUID |
| `0xE4` | ButtonConfirm | device → RX | Physical button press confirmed |
| `0xE5` | RegisterComplete | TX → device | Finalize registration |
| `0xB1` | SetMode | TX → device | `0x00` = live, `0x01` = paper, `0x02` = idle |
| `0xB6` | SetTime | TX → device | Sync clock (6 bytes: YY MM DD HH MM SS) |
| `0xB9` | GetBattery | TX → device | Query battery level |
| `0xA1` | PenData | device → client | 6-byte triplets: x, y, pressure (u16 LE) |
| `0xA2` | Proximity | device → client | Pen entered/left proximity |
| `0xCB` | ButtonPress | device → client | Physical button pressed |
| `0xC1` | GetFileCount | TX → device | Request number of stored pages |
| `0xC2` | FileCount | device → RX | Response: count as u16 LE |
| `0xC3` | StartDownload | TX → device | Begin downloading a stored page |
| `0xC8` | DownloadStatus | device → RX | Progress markers + CRC32 at end |
| `0xCA` | DeletePage | TX → device | Delete page from device memory |
| `0xCC` | GetStrokeInfo | TX → device | Request page size + timestamp |
| `0xCF` | StrokeInfo | device → RX | Response: size (u32 LE) + 6-byte timestamp |
| `0xEC` | SelectTransfer | TX → device | Switch to file transfer characteristic |

### Authentication Flow

```
First time (registration):
  Client → [0xE7, 0x06, <uuid>]     # Send registration request
  Device → [0xE4, ...]              # User must press physical button
  Client → [0xE5, 0x06, <uuid>]     # Complete registration

Every subsequent connection:
  Client → [0xE6, 0x06, <uuid>]     # Check authentication
  Device → [0x50, ...]              # Authenticated
  Device → [0xB0, 0x01, 0x07]       # Error 7 = wrong UUID
```

Error codes: `0` = success, `1` = general, `2` = invalid state, `5` = unrecognized command, `6` = needs button press, `7` = auth error.

### Live Pen Data (0xA1)

Pen data arrives as 6-byte triplets inside notification payloads:

```
[x_low, x_high, y_low, y_high, pressure_low, pressure_high]
```

All values are little-endian `u16`. Stroke boundaries are marked by all-`0xFF` payloads (pen up) or `0xA2` proximity events.

### Stored Page Binary Format

Pages are stored in Wacom's proprietary binary stroke format:

**Magic:** `b8bt` (4 bytes: `0x62 0x38 0x62 0x74`)

**Delta encoding:** Each packet starts with a header byte. The header's popcount determines payload size. Bits encode per-axis encoding:
- `0x02` = signed 8-bit delta (accumulates)
- `0x03` = absolute 16-bit value (resets accumulator)

**Stroke separators:** 6 or 7 bytes of `0xFF` (with `0xFC` header)
**EOF:** 8 bytes of `0xFF`

**CRC32 verification** after download — the CRC is byte-reversed in the response.

### Sync Download Flow

```
1.  Select file transfer service (0xEC)
2.  Switch to PAPER mode (0xB1 0x01)
3.  Get file count (0xC1) → response (0xC2)
4.  For each page:
    - Get stroke info (0xCC) → size + timestamp (0xCF)
    - Start download (0xC3)
    - Receive bulk data on ffee0003 notifications
    - Verify CRC32
    - Delete from device (0xCA)
5.  Return to IDLE mode (0xB1 0x02)
```

---

## Architecture

```
Wacom Slate (BLE)
      |
      +-- live stream ---> capture.py ---> InkCanvas (SVG/PNG)
      |                                  +-- HTTP POST --> server.py --> Web UI
      |                                  +-- JSON stdout --> Godot app
      |
      +-- stored pages --> sync.py ---> binary parser --> SVG
                                          +-- JSON stdout --> Godot app

Godot App (Windows)
  capture.py --json-stdout --> pipe file --> ble_bridge.gd polls at 60fps

Godot App (Android)
  Kotlin BLE plugin --> direct BluetoothGatt --> Godot signals
```

## Project Layout

```
penz/
+-- capture.py            # Real-time BLE capture (WinRT), multi-path mode switch
+-- sync.py               # Stored page download (bleak), binary stroke parser
+-- register.py           # One-time device registration
+-- scanner.py            # BLE discovery + GATT enumeration
+-- canvas.py             # PIL rasterization + SVG generation
+-- listen.py             # Debug listener for all BLE notifications
+-- server.py             # FastAPI backend with live preview
+-- fontmaker.py          # OpenCV glyph segmentation + fonttools TTF build
+-- godot/
|   +-- main.gd           # Bootstrap -- wires BLE + canvas + UI
|   +-- main.tscn         # Scene tree (CanvasLayer overlay architecture)
|   +-- canvas/
|   |   +-- ink_canvas.gd       # Live drawing surface (Line2D nodes)
|   |   +-- stroke_store.gd     # Stroke data + SVG export
|   |   +-- stroke_renderer.gd  # Pressure-sensitive line rendering
|   |   +-- dot_grid.gd         # Subtle paper dot grid background
|   |   +-- canvas_transform.gd # 21600x14700 -> screen (90-degree rotation)
|   +-- core/
|   |   +-- ble_bridge.gd       # Platform BLE dispatch (Windows/Android)
|   +-- ui/
|   |   +-- theme.gd            # Design system -- palette, spacing, factories
|   |   +-- hud.gd              # Top bar -- LED, battery, mode, toast
|   |   +-- toolbar.gd          # Bottom bar -- connect, sync, OCR, font, thickness
|   |   +-- connect_dialog.gd   # Animated BLE connection progress
|   |   +-- ocr_panel.gd        # Ollama OCR integration
|   |   +-- gallery.gd          # Page gallery (paper cards, viewer)
|   |   +-- glyph_labeller.gd   # Font maker UI
|   |   +-- settings_panel.gd   # UUID config + settings
|   +-- fontmaker.py            # Python subprocess for glyph segmentation
|   +-- android/plugin/         # Kotlin BLE plugin (full Wacom protocol)
|   +-- screenshot.png          # App screenshot
```

## Requirements

- **Python 3.13+** with bleak, winrt, fastapi, uvicorn, Pillow, aiohttp
- **Godot 4.6** for the native app
- **Ollama** with a vision model (e.g. `minicpm-v`) for OCR
- **OpenCV + fonttools** for font maker
- **Windows** for WinRT BLE (the only platform with reliable BLE + this device)
- A **Wacom Bamboo Slate** paired via Bluetooth

## Related Projects

- **[Tuhi](https://github.com/tuhiproject/tuhi)** — GTK app for Wacom smartpad stored page download (Linux, Python/GTK)
- **[Wacom Inkspace (decompiled)](https://github.com/elliotberry/wacom-inkspace)** — Decompiled official app, useful for protocol reference

## License

MIT
