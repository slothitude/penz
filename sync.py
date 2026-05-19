# sync.py — Download stored pages from Wacom Bamboo Slate
# Uses the same wake→connect→auth flow as capture.py, then switches to PAPER mode
# to enumerate and download all stored pages via the file transfer characteristic.
import argparse
import asyncio
import json
import os
import struct
import sys
import time
import zlib
from collections import deque
from datetime import datetime

from bleak import BleakClient
from canvas import InkCanvas

# GATT UUIDs
NORDIC_RX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
NORDIC_TX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
TRANSFER_CHAR = "ffee0003-bbaa-9988-7766-554433221100"
DEVICE_ADDR = "FC:F5:69:C5:F9:4B"
DEVICE_ADDR_INT = 0xFCF569C5F94B
UUID_FILE = "data/device_uuid.json"
OUTPUT_DIR = "data/pages"


# ─── Stroke file parser (Wacom proprietary binary) ─────────────────────────

class StrokeFile:
    """Parse the Wacom binary stroke format used by Bamboo Slate."""

    MAGIC = b"\x62\x38\x62\x74"  # "b8bt"

    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0
        self.strokes = []  # list of lists of (x, y, pressure)

    def parse(self):
        if self.data[:4] != self.MAGIC:
            print(f"  Warning: unexpected magic {self.data[:4].hex()}, trying anyway")
        self.pos = 4

        current_stroke = []
        last_x, last_y, last_p = 0, 0, 0
        acc_dx, acc_dy, acc_dp = 0, 0, 0

        while self.pos < len(self.data):
            header = self.data[self.pos]
            nbytes = bin(header).count("1")
            self.pos += 1

            if nbytes == 0:
                continue

            if self.pos + nbytes > len(self.data):
                break

            payload = self.data[self.pos : self.pos + nbytes]
            self.pos += nbytes

            # Stroke end / separator:
            # - 7-byte payload starting with 0xFC then 6x 0xFF (hdr popcount=7)
            # - 6-byte payload all 0xFF (hdr popcount=6, e.g. 0xFC) — separator between strokes
            is_all_ff = all(b == 0xFF for b in payload)
            if (nbytes == 7 and payload[0] == 0xFC and all(b == 0xFF for b in payload[1:])):
                if current_stroke:
                    self.strokes.append(current_stroke)
                    current_stroke = []
                acc_dx, acc_dy, acc_dp = 0, 0, 0
                last_x, last_y, last_p = 0, 0, 0
                continue
            if (nbytes == 6 and is_all_ff):
                if current_stroke:
                    self.strokes.append(current_stroke)
                    current_stroke = []
                acc_dx, acc_dy, acc_dp = 0, 0, 0
                last_x, last_y, last_p = 0, 0, 0
                continue

            # EOF: payload is all 0xFF AND 8+ bytes (header 0xFF with all-FF payload)
            if nbytes == 8 and is_all_ff:
                break

            # Stroke header: payload starts with ff ee ee
            if len(payload) >= 3 and payload[0] == 0xFF and payload[1] == 0xEE and payload[2] == 0xEE:
                if current_stroke:
                    self.strokes.append(current_stroke)
                    current_stroke = []
                acc_dx, acc_dy, acc_dp = 0, 0, 0
                last_x, last_y, last_p = 0, 0, 0
                continue

            # Point packet: payload starts with ff ff
            if len(payload) >= 4 and payload[0] == 0xFF and payload[1] == 0xFF:
                # ff ff is the point marker, remaining bytes are the delta data
                # Use the outer header byte for axis masks
                inner_data = payload[2:]
                x, y, p, adx, ady, adp = self._decode_delta(
                    header, inner_data,
                    0, 0, 0, 0, 0, 0,
                )
                if x is not None:
                    last_x, last_y, last_p = x, y, p
                    acc_dx, acc_dy, acc_dp = adx, ady, adp
                    current_stroke.append((x, y, p))
                continue

            # Delta packet: bottom 2 bits of header = 00
            if (header & 0x03) == 0x00:
                x, y, p, adx, ady, adp = self._decode_delta(
                    header, payload,
                    last_x, last_y, last_p,
                    acc_dx, acc_dy, acc_dp,
                )
                if x is not None:
                    last_x, last_y, last_p = x, y, p
                    acc_dx, acc_dy, acc_dp = adx, ady, adp
                    current_stroke.append((x, y, p))
                continue

            # Lost point or unknown — skip

        if current_stroke:
            self.strokes.append(current_stroke)

        return self.strokes

    def _decode_delta(self, header, payload, last_x, last_y, last_p, acc_dx, acc_dy, acc_dp):
        """Decode a delta packet. Returns (x, y, p, acc_dx, acc_dy, acc_dp) or Nones."""
        x_mask = (header >> 2) & 0x03
        y_mask = (header >> 4) & 0x03
        p_mask = (header >> 6) & 0x03

        offset = 0
        x, y, p = last_x, last_y, last_p

        # X axis
        if x_mask == 0x02:
            if offset >= len(payload):
                return None, None, None, 0, 0, 0
            dx = struct.unpack_from("<b", payload, offset)[0]
            offset += 1
            acc_dx += dx
            x = last_x + acc_dx
        elif x_mask == 0x03:
            if offset + 2 > len(payload):
                return None, None, None, 0, 0, 0
            x = struct.unpack_from("<H", payload, offset)[0]
            offset += 2
            acc_dx = 0

        # Y axis
        if y_mask == 0x02:
            if offset >= len(payload):
                return None, None, None, 0, 0, 0
            dy = struct.unpack_from("<b", payload, offset)[0]
            offset += 1
            acc_dy += dy
            y = last_y + acc_dy
        elif y_mask == 0x03:
            if offset + 2 > len(payload):
                return None, None, None, 0, 0, 0
            y = struct.unpack_from("<H", payload, offset)[0]
            offset += 2
            acc_dy = 0

        # Pressure axis
        if p_mask == 0x02:
            if offset >= len(payload):
                return None, None, None, 0, 0, 0
            dp = struct.unpack_from("<b", payload, offset)[0]
            offset += 1
            acc_dp += dp
            p = last_p + acc_dp
        elif p_mask == 0x03:
            if offset + 2 > len(payload):
                return None, None, None, 0, 0, 0
            p = struct.unpack_from("<H", payload, offset)[0]
            offset += 2
            acc_dp = 0

        return x, y, max(0, p), acc_dx, acc_dy, acc_dp


# ─── BLE sync protocol ─────────────────────────────────────────────────────

class PageSyncer:
    def __init__(self):
        self.notifications = deque()
        self.pen_data = bytearray()

    def _on_nordic(self, char, data):
        self.notifications.append(bytes(data))

    def _on_transfer(self, char, data):
        self.pen_data.extend(data)

    async def _send(self, client, op, data=b"", timeout=5):
        frame = bytes([op, len(data)]) + data
        self.notifications.clear()
        await client.write_gatt_char(NORDIC_TX, frame, response=True)
        for _ in range(timeout * 10):
            await asyncio.sleep(0.1)
            if self.notifications:
                reply = self.notifications.popleft()
                return reply
        return None

    async def _wait_reply(self, op_match=None, timeout=30):
        """Wait for a notification matching an opcode."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while self.notifications:
                reply = self.notifications.popleft()
                if op_match is None or (len(reply) > 0 and reply[0] == op_match):
                    return reply
            await asyncio.sleep(0.1)
        return None

    async def run(self):
        # Load UUID
        if not os.path.exists(UUID_FILE):
            print(f"ERROR: No UUID file at {UUID_FILE}. Run register.py first.")
            return
        with open(UUID_FILE) as f:
            uuid = bytes.fromhex(json.load(f)["uuid"])

        # Wake device
        from winrt.windows.devices.bluetooth import BluetoothLEDevice

        print("Waking device...", flush=True)
        device = await BluetoothLEDevice.from_bluetooth_address_async(DEVICE_ADDR_INT)
        if not device:
            print("Device not found. Make sure it's paired and turned on.")
            return
        print(f"  Found: {device.name}", flush=True)
        device.close()
        await asyncio.sleep(1)

        # Connect
        print("Connecting...", flush=True)
        async with BleakClient(DEVICE_ADDR, timeout=30.0, use_cached=True) as client:
            print("Connected!", flush=True)
            await client.start_notify(NORDIC_RX, self._on_nordic)
            await client.start_notify(TRANSFER_CHAR, self._on_transfer)

            # Authenticate
            print("Authenticating...", flush=True)
            r = await self._send(client, 0xE6, uuid)
            if not r or len(r) < 3 or r[2] != 0x00:
                code = r[2] if r and len(r) > 2 else "?"
                print(f"Auth failed (code={code})")
                return
            print("Authenticated!", flush=True)

            # Set time
            now = time.localtime()
            await self._send(
                client,
                0xB6,
                bytes([now.tm_year % 100, now.tm_mon, now.tm_mday, now.tm_hour, now.tm_min, now.tm_sec]),
            )

            # Select file transfer on ffee0003
            print("Selecting file transfer...", flush=True)
            r = await self._send(client, 0xEC, b"\x06\x00\x00\x00\x00\x00")
            if r:
                print(f"  Transfer: {r.hex()}", flush=True)

            # Switch to PAPER mode (0x01)
            print("Entering PAPER mode...", flush=True)
            r = await self._send(client, 0xB1, b"\x01")
            if r:
                print(f"  Mode: {r.hex()}", flush=True)

            # Get file count
            r = await self._send(client, 0xC1, b"\x00")
            if not r or r[0] != 0xC2:
                print(f"Failed to get file count: {r.hex() if r else 'None'}")
                return
            file_count = struct.unpack_from("<H", r, 2)[0]
            print(f"\nFound {file_count} stored page(s)\n", flush=True)

            if file_count == 0:
                print("No pages to sync.")
                return

            os.makedirs(OUTPUT_DIR, exist_ok=True)

            for i in range(file_count):
                print(f"--- Page {i + 1}/{file_count} ---", flush=True)

                # Get stroke info (count + timestamp)
                r = await self._send(client, 0xCC, b"\x00")
                if not r or r[0] != 0xCF:
                    print(f"  Failed to get stroke info: {r.hex() if r else 'None'}")
                    break

                data_size = struct.unpack_from("<I", r, 2)[0]
                ts_bytes = r[6:12]
                ts_str = "".join(f"{b:02x}" for b in ts_bytes)
                try:
                    ts_dt = datetime.strptime(ts_str, "%y%m%d%H%M%S")
                    ts_label = ts_dt.strftime("%Y%m%d_%H%M%S")
                except ValueError:
                    ts_label = f"page_{int(time.time())}"
                print(f"  Size: {data_size} bytes, Time: {ts_label}", flush=True)

                # Start download
                self.pen_data.clear()
                self.notifications.clear()

                r = await self._send(client, 0xC3, b"\x00")
                if not r or r[0] != 0xC8 or len(r) < 3 or r[2] != 0xBE:
                    print(f"  Download failed to start: {r.hex() if r else 'None'}")
                    break

                # Wait for end-of-data marker (0xC8 reply with 0xED in data)
                # and CRC reply (0xC8 reply with CRC bytes)
                # Both come as Nordic notifications after the bulk data arrives on ffee0003
                got_end = False
                got_crc = False
                crc_value = None
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline and not (got_end and got_crc):
                    while self.notifications:
                        reply = self.notifications.popleft()
                        if reply[0] == 0xC8 and len(reply) >= 3:
                            if reply[2] == 0xED and not got_end:
                                got_end = True
                                print(f"  Data end marker received", flush=True)
                            elif not got_crc:
                                # CRC is 4 bytes, reversed, in the data after opcode+length
                                crc_data = reply[2:]
                                if len(crc_data) >= 4:
                                    crc_value = int.from_bytes(crc_data[:4][::-1], "little")
                                    got_crc = True
                    await asyncio.sleep(0.1)

                if not got_end:
                    print("  Timeout waiting for data end marker")
                    break

                raw = bytes(self.pen_data)
                print(f"  Received {len(raw)} bytes", flush=True)

                # Verify CRC
                if got_crc and crc_value is not None:
                    actual_crc = zlib.crc32(raw) & 0xFFFFFFFF
                    if actual_crc != crc_value:
                        print(f"  CRC mismatch: expected {crc_value:08x}, got {actual_crc:08x}")
                    else:
                        print(f"  CRC OK ({actual_crc:08x})", flush=True)

                # Parse strokes
                sf = StrokeFile(raw)
                strokes = sf.parse()
                total_points = sum(len(s) for s in strokes)
                print(f"  Parsed {len(strokes)} strokes, {total_points} points", flush=True)

                if total_points == 0:
                    print(f"  Skipping empty page", flush=True)
                    # Still delete from device
                    await self._send(client, 0xCA, b"\x00")
                    continue

                # Render to image
                canvas = InkCanvas()
                for stroke in strokes:
                    for x, y, p in stroke:
                        canvas.add_point(x, y, p)

                out_path = os.path.join(OUTPUT_DIR, f"{ts_label}.svg")
                canvas.save(out_path)
                print(f"  Saved: {out_path}", flush=True)

                # Also save raw data for debugging
                raw_path = os.path.join("data", "raw", f"{ts_label}.bin")
                os.makedirs(os.path.dirname(raw_path), exist_ok=True)
                with open(raw_path, "wb") as f:
                    f.write(raw)

                # Delete the file from device
                await self._send(client, 0xCA, b"\x00")
                print(f"  Deleted from device", flush=True)

            # Back to idle
            await self._send(client, 0xB1, b"\x02")
            print(f"\nDone! Synced {file_count} pages to {OUTPUT_DIR}/", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Sync stored pages from Wacom Bamboo Slate")
    parser.add_argument("--keep", action="store_true", help="Don't delete pages from device after sync")
    args = parser.parse_args()

    syncer = PageSyncer()
    try:
        asyncio.run(syncer.run())
    except KeyboardInterrupt:
        pass
