# capture.py — Real-time ink capture from Wacom Bamboo Slate
# Connection: WinRT GATT → multi-path mode switch → live streaming
# The Wacom Slate requires writes to multiple characteristics to enter live mode:
#   ffee0002 → 00001532 → 00001531 → auth(0xE6) via Nordic TX → mode(0xB1) via Nordic TX
import argparse
import asyncio
import json
import os
import struct
import sys
import time
import uuid
from collections import deque

import aiohttp
from canvas import InkCanvas

# GATT UUIDs
NORDIC_SVC_UUID = uuid.UUID("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
NORDIC_RX_UUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
NORDIC_TX_UUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
LIVE_SVC_UUID = uuid.UUID("00001523-1212-efde-1523-785feabcd123")
LIVE_CHAR_UUID = "00001524-1212-efde-1523-785feabcd123"
SVC_1530_UUID = uuid.UUID("00001530-1212-efde-1523-785feabcd123")
SVC_FFEE_UUID = uuid.UUID("ffee0001-bbaa-9988-7766-554433221100")
CHAR_1531 = "00001531-1212-efde-1523-785feabcd123"
CHAR_1532 = "00001532-1212-efde-1523-785feabcd123"
CHAR_FFEE2 = "ffee0002-bbaa-9988-7766-554433221100"
DEVICE_ADDR_INT = 0xFCF569C5F94B
UUID_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "device_uuid.json")

# Wacom protocol opcodes
CMD_CHECK_AUTH = 0xE6
CMD_SET_TIME = 0xB6
CMD_GET_BATTERY = 0xB9
CMD_SET_MODE = 0xB1
MODE_LIVE = 0x00
MODE_PAPER = 0x01
MODE_IDLE = 0x02
OP_BUTTON_PRESS = 0xCB


class PenCapture:
    def __init__(self, canvas=None, on_point=None, api_url=None):
        self.canvas = canvas or InkCanvas()
        self.on_point = on_point
        self.api_url = api_url
        self.got = []
        self.connected = False
        self._pending = deque()
        self._hover_pending = deque()  # hover points (p=0) for calibration
        self._posted = 0
        self._pen_down = False  # only true when pressure > 0
        self._stroke_ended = False
        self._button_pressed = False  # flag for button events to forward
        self._device = None
        self._nordic_svc = None
        self._live_svc = None
        self._svc_1530 = None
        self._svc_ffee = None
        self._tx_char = None
        self._rx_char = None
        self._live_char = None
        self._char_1531 = None
        self._char_1532 = None
        self._char_ffee2 = None
        self._device_uuid = None
        self._last_heartbeat = 0

    def _on_nordic(self, char, args):
        from winrt.windows.storage.streams import DataReader
        try:
            reader = DataReader.from_buffer(args.characteristic_value)
            data = bytes(reader.read_byte() for _ in range(reader.unconsumed_buffer_length))
            if len(data) >= 1 and data[0] == OP_BUTTON_PRESS:
                self._button_pressed = True
            else:
                self.got.append(data)
        except Exception:
            pass

    def _on_live(self, char, args):
        from winrt.windows.storage.streams import DataReader
        try:
            reader = DataReader.from_buffer(args.characteristic_value)
            data = bytes(reader.read_byte() for _ in range(reader.unconsumed_buffer_length))
            if len(data) < 2:
                return
            op = data[0]
            if op == 0xA1:
                payload = data[2:]
                if len(payload) >= 6 and all(b == 0xFF for b in payload[:6]):
                    self.canvas.pen_up()
                    self._pen_down = False
                    self._stroke_ended = True
                else:
                    for i in range(0, len(payload) - 5, 6):
                        x, y, p = struct.unpack_from("<HHH", payload, i)
                        if p > 0:
                            self._pen_down = True
                            self.canvas.add_point(x, y, p)
                            if self.api_url:
                                self._pending.append((x, y, p))
                            if self.on_point:
                                self.on_point(x, y, p)
                        elif not self._pen_down:
                            # Hover: pen detected but not touching (p=0, pen was never down)
                            if self.api_url:
                                self._hover_pending.append((x, y))
                        else:
                            # Pressure 0 while pen was down = lift off
                            self.canvas.pen_up()
                            self._pen_down = False
                            self._stroke_ended = True
            elif op == 0xA2:
                self.canvas.pen_up()
                self._stroke_ended = True
        except Exception:
            pass

    async def _post_loop(self, session):
        """Batch-post pending points to the server."""
        while self.connected:
            batch = []
            while self._pending and len(batch) < 50:
                batch.append(self._pending.popleft())

            if batch or self._stroke_ended:
                try:
                    payload = {"points": batch}
                    if self._stroke_ended:
                        payload["stroke_end"] = True
                        self._stroke_ended = False
                    await session.post(
                        f"{self.api_url}/stream/stroke",
                        json=payload,
                        timeout=aiohttp.ClientTimeout(total=2),
                    )
                    self._posted += len(batch)
                except Exception:
                    pass

            # Forward button press events to server
            if self._button_pressed:
                try:
                    await session.post(
                        f"{self.api_url}/stream/event",
                        json={"type": "button"},
                        timeout=aiohttp.ClientTimeout(total=2),
                    )
                except Exception:
                    pass
                self._button_pressed = False

            # Forward hover points (pen detected, not touching)
            if self._hover_pending:
                hover_batch = []
                while self._hover_pending and len(hover_batch) < 20:
                    hover_batch.append(self._hover_pending.popleft())
                if hover_batch:
                    try:
                        await session.post(
                            f"{self.api_url}/stream/hover",
                            json={"points": hover_batch},
                            timeout=aiohttp.ClientTimeout(total=2),
                        )
                    except Exception:
                        pass

            # Heartbeat every 5s
            now = time.time()
            if now - self._last_heartbeat > 5.0:
                self._last_heartbeat = now
                try:
                    await session.post(
                        f"{self.api_url}/stream/heartbeat",
                        json={"live": True, "pen_down": self._pen_down},
                        timeout=aiohttp.ClientTimeout(total=2),
                    )
                except Exception:
                    pass

            await asyncio.sleep(0.05)

    def _write_frame(self, frame):
        """Create a DataWriter buffer from a byte frame."""
        from winrt.windows.storage.streams import DataWriter
        w = DataWriter()
        for b in frame:
            w.write_byte(b)
        return w.detach_buffer()

    async def _enter_live_mode(self):
        """Multi-path mode switch: write to alternate characteristics then auth."""
        from winrt.windows.devices.bluetooth import BluetoothCacheMode
        from winrt.windows.devices.bluetooth.genericattributeprofile import (
            GattSharingMode, GattClientCharacteristicConfigurationDescriptorValue,
        )
        from winrt.windows.storage.streams import DataWriter

        mode_cmd = bytes([CMD_SET_MODE, 0x01, MODE_LIVE])

        # Open alternate services
        self._svc_1530 = self._device.get_gatt_service(SVC_1530_UUID)
        await self._svc_1530.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
        chars_1530 = await self._svc_1530.get_characteristics_with_cache_mode_async(
            BluetoothCacheMode.UNCACHED)
        for c in chars_1530.characteristics:
            s = str(c.uuid)
            if s == CHAR_1531:
                self._char_1531 = c
            elif s == CHAR_1532:
                self._char_1532 = c

        self._svc_ffee = self._device.get_gatt_service(SVC_FFEE_UUID)
        await self._svc_ffee.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
        chars_ffee = await self._svc_ffee.get_characteristics_with_cache_mode_async(
            BluetoothCacheMode.UNCACHED)
        for c in chars_ffee.characteristics:
            if str(c.uuid) == CHAR_FFEE2:
                self._char_ffee2 = c

        # Subscribe to 1531 notifications
        if self._char_1531:
            self._char_1531.add_value_changed(self._on_nordic)
            try:
                await self._char_1531.write_client_characteristic_configuration_descriptor_async(
                    GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)
            except Exception:
                pass

        print("  Activating live mode (multi-path)...", flush=True)

        # Step 1: Write mode cmd to ffee0002
        if self._char_ffee2:
            await self._char_ffee2.write_value_with_result_async(
                self._write_frame(mode_cmd))
            await asyncio.sleep(0.5)

        # Step 2: Write mode cmd to 00001532
        if self._char_1532:
            await self._char_1532.write_value_with_result_async(
                self._write_frame(mode_cmd))
            await asyncio.sleep(0.5)

        # Step 3: Write mode cmd to 00001531
        if self._char_1531:
            await self._char_1531.write_value_with_result_async(
                self._write_frame(mode_cmd))
            await asyncio.sleep(0.5)

        # Step 4: Auth via Nordic TX
        self.got.clear()
        auth_frame = bytes([CMD_CHECK_AUTH, len(self._device_uuid)]) + self._device_uuid
        await self._tx_char.write_value_with_result_async(
            self._write_frame(auth_frame))
        await asyncio.sleep(2)

        # Step 5: Mode via Nordic TX
        self.got.clear()
        await self._tx_char.write_value_with_result_async(
            self._write_frame(mode_cmd))
        for _ in range(20):
            await asyncio.sleep(0.25)
            if self.got:
                break

        is_live = False
        if self.got:
            resp = self.got[-1]
            print(f"  Mode: {resp.hex()}", flush=True)
            if len(resp) >= 3 and resp[2] == MODE_LIVE:
                is_live = True

        if is_live:
            print("  LIVE MODE ACTIVE!", flush=True)
            return True
        else:
            print("  Mode may not have switched — drawing will tell.", flush=True)
            return False

    async def connect_and_stream(self):
        """Connect via WinRT GATT, enter live mode, stream ink data."""
        from winrt.windows.devices.bluetooth import BluetoothLEDevice, BluetoothCacheMode
        from winrt.windows.devices.bluetooth.genericattributeprofile import (
            GattSharingMode,
            GattClientCharacteristicConfigurationDescriptorValue,
            GattSession,
        )
        from winrt.windows.storage.streams import DataWriter

        # Load device UUID for auth
        if os.path.exists(UUID_FILE):
            with open(UUID_FILE) as f:
                self._device_uuid = bytes.fromhex(json.load(f)["uuid"])
        else:
            print("No device UUID file found. Run register.py first.")
            return False

        # Step 1: Connect to device
        print("Connecting...", flush=True)
        self._device = await BluetoothLEDevice.from_bluetooth_address_async(DEVICE_ADDR_INT)
        if not self._device:
            print("Device not found. Make sure it's paired and turned on.")
            return False
        print(f"  Found: {self._device.name}", flush=True)

        session = await GattSession.from_device_id_async(self._device.bluetooth_device_id)
        session.maintain_connection = True

        for i in range(40):
            if self._device.connection_status == 1:
                print(f"  BLE connected after {i+1}s", flush=True)
                break
            await asyncio.sleep(1)
        else:
            # Stale session — try GATT anyway (Windows may hold link open)
            print("  Status=0 but trying GATT operations...", flush=True)

        # Step 2: Open Nordic UART
        self._nordic_svc = self._device.get_gatt_service(NORDIC_SVC_UUID)
        await self._nordic_svc.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
        chars = await self._nordic_svc.get_characteristics_with_cache_mode_async(
            BluetoothCacheMode.UNCACHED)
        for c in chars.characteristics:
            s = str(c.uuid)
            if s == NORDIC_TX_UUID:
                self._tx_char = c
            elif s == NORDIC_RX_UUID:
                self._rx_char = c

        if not self._tx_char or not self._rx_char:
            print("  Nordic TX/RX not found.")
            self._cleanup()
            return False
        print("  Nordic UART ready", flush=True)

        # Step 3: Subscribe to RX
        self._rx_char.add_value_changed(self._on_nordic)
        await self._rx_char.write_client_characteristic_configuration_descriptor_async(
            GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)
        await asyncio.sleep(2)
        self.got.clear()

        # Step 4: Set time
        now = time.localtime()
        td = bytes([now.tm_year % 100, now.tm_mon, now.tm_mday,
                     now.tm_hour, now.tm_min, now.tm_sec])
        await self._tx_char.write_value_with_result_async(
            self._write_frame(bytes([CMD_SET_TIME, len(td)]) + td))
        await asyncio.sleep(1)

        # Step 5: Battery
        self.got.clear()
        await self._tx_char.write_value_with_result_async(
            self._write_frame(bytes([CMD_GET_BATTERY, 0x01, 0x00])))
        await asyncio.sleep(1)
        for r in self.got:
            if len(r) > 2:
                print(f"  Battery: {r[2]}%", flush=True)
                break

        # Step 6: Open Live service and subscribe
        self._live_svc = self._device.get_gatt_service(LIVE_SVC_UUID)
        await self._live_svc.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
        live_chars = await self._live_svc.get_characteristics_with_cache_mode_async(
            BluetoothCacheMode.UNCACHED)
        for c in live_chars.characteristics:
            if str(c.uuid) == LIVE_CHAR_UUID:
                self._live_char = c
                break

        if self._live_char:
            self._live_char.add_value_changed(self._on_live)
            await self._live_char.write_client_characteristic_configuration_descriptor_async(
                GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)
            print("  Live characteristic subscribed", flush=True)

        # Step 7: Enter live mode via multi-path sequence
        await self._enter_live_mode()

        self.connected = True
        print("\n" + "=" * 60, flush=True)
        print("DRAWING! Light should be blue while pen is down.")
        print("Press button on Slate to save page (back to green).")
        print("Press Ctrl+C here to stop.", flush=True)
        if self.api_url:
            print(f"Streaming to {self.api_url}", flush=True)
        print("=" * 60 + "\n", flush=True)

        try:
            if self.api_url:
                async with aiohttp.ClientSession() as session:
                    post_task = asyncio.create_task(self._post_loop(session))
                    try:
                        while True:
                            await asyncio.sleep(1)
                    finally:
                        post_task.cancel()
            else:
                while True:
                    await asyncio.sleep(1)
        except (KeyboardInterrupt, asyncio.CancelledError):
            pass

        self.connected = False
        self._cleanup()
        print("Stopped.", flush=True)
        return True

    def _cleanup(self):
        for svc in [self._nordic_svc, self._live_svc, self._svc_1530, self._svc_ffee]:
            if svc:
                try:
                    svc.close()
                except Exception:
                    pass
        if self._device:
            try:
                self._device.close()
            except Exception:
                pass
        self._nordic_svc = self._live_svc = self._svc_1530 = self._svc_ffee = None
        self._device = None
        self._tx_char = self._rx_char = self._live_char = None
        self._char_1531 = self._char_1532 = self._char_ffee2 = None


class JsonStdoutCanvas:
    """Minimal canvas substitute that emits JSON lines for Godot."""
    def __init__(self):
        pass

    def add_point(self, x, y, pressure):
        _json_out({"type": "point", "x": x, "y": y, "p": pressure})

    def pen_up(self):
        _json_out({"type": "stroke_end"})

    def save(self, path):
        pass  # Godot handles saving


class JsonPenCapture(PenCapture):
    """PenCapture subclass that emits JSON progress instead of print()."""
    def __init__(self, canvas=None):
        super().__init__(canvas=canvas, api_url=None, on_point=None)

    def _on_nordic(self, char, args):
        """Override to detect button press (0xE4) and mode changes."""
        from winrt.windows.storage.streams import DataReader
        try:
            reader = DataReader.from_buffer(args.characteristic_value)
            data = bytes(reader.read_byte() for _ in range(reader.unconsumed_buffer_length))
            if len(data) >= 1 and data[0] == OP_BUTTON_PRESS:
                _json_out({"type": "button_press"})
                self.canvas.pen_up()
            else:
                self.got.append(data)
        except Exception:
            pass

    async def connect_and_stream(self):
        from winrt.windows.devices.bluetooth import BluetoothLEDevice, BluetoothCacheMode
        from winrt.windows.devices.bluetooth.genericattributeprofile import (
            GattSharingMode,
            GattClientCharacteristicConfigurationDescriptorValue,
            GattSession,
        )

        # Load UUID
        if os.path.exists(UUID_FILE):
            with open(UUID_FILE) as f:
                self._device_uuid = bytes.fromhex(json.load(f)["uuid"])
        else:
            _json_out({"type": "error", "message": "No device UUID found. Run register.py first."})
            return False

        # Connect
        _json_out({"type": "progress", "step": "connecting"})
        self._device = await BluetoothLEDevice.from_bluetooth_address_async(DEVICE_ADDR_INT)
        if not self._device:
            _json_out({"type": "error", "message": "Device not found. Make sure it's paired and on."})
            return False

        session = await GattSession.from_device_id_async(self._device.bluetooth_device_id)
        session.maintain_connection = True

        for i in range(40):
            if self._device.connection_status == 1:
                break
            await asyncio.sleep(1)

        # Nordic UART
        _json_out({"type": "progress", "step": "discovering_services"})
        self._nordic_svc = self._device.get_gatt_service(NORDIC_SVC_UUID)
        await self._nordic_svc.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
        chars = await self._nordic_svc.get_characteristics_with_cache_mode_async(
            BluetoothCacheMode.UNCACHED)
        for c in chars.characteristics:
            s = str(c.uuid)
            if s == NORDIC_TX_UUID:
                self._tx_char = c
            elif s == NORDIC_RX_UUID:
                self._rx_char = c

        if not self._tx_char or not self._rx_char:
            _json_out({"type": "error", "message": "Nordic UART not found"})
            self._cleanup()
            return False

        # Subscribe to RX
        self._rx_char.add_value_changed(self._on_nordic)
        await self._rx_char.write_client_characteristic_configuration_descriptor_async(
            GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)
        await asyncio.sleep(2)
        self.got.clear()

        # Set time
        now = time.localtime()
        td = bytes([now.tm_year % 100, now.tm_mon, now.tm_mday,
                     now.tm_hour, now.tm_min, now.tm_sec])
        await self._tx_char.write_value_with_result_async(
            self._write_frame(bytes([CMD_SET_TIME, len(td)]) + td))
        await asyncio.sleep(1)

        # Battery
        _json_out({"type": "progress", "step": "querying_battery"})
        self.got.clear()
        await self._tx_char.write_value_with_result_async(
            self._write_frame(bytes([CMD_GET_BATTERY, 0x01, 0x00])))
        await asyncio.sleep(1)
        for r in self.got:
            if len(r) > 2:
                _json_out({"type": "status", "info": {"battery": r[2]}})

        # Live service
        self._live_svc = self._device.get_gatt_service(LIVE_SVC_UUID)
        await self._live_svc.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
        live_chars = await self._live_svc.get_characteristics_with_cache_mode_async(
            BluetoothCacheMode.UNCACHED)
        for c in live_chars.characteristics:
            if str(c.uuid) == LIVE_CHAR_UUID:
                self._live_char = c
                break

        if self._live_char:
            self._live_char.add_value_changed(self._on_live)
            await self._live_char.write_client_characteristic_configuration_descriptor_async(
                GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)

        # Enter live mode
        _json_out({"type": "progress", "step": "entering_live"})

        self.connected = True
        _json_out({"type": "connected"})

        await self._enter_live_mode()

        try:
            while True:
                await asyncio.sleep(1)
        except (KeyboardInterrupt, asyncio.CancelledError):
            pass

        self.connected = False
        self._cleanup()
        _json_out({"type": "disconnected"})
        return True


_pipe_file = None


def _json_out(obj):
    """Write a JSON line to stdout and pipe file."""
    line = json.dumps(obj)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()
    if _pipe_file:
        _pipe_file.write(line + "\n")
        _pipe_file.flush()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Capture Wacom Bamboo Slate ink data")
    parser.add_argument("--save", default=None, help="Save canvas to this path on exit")
    parser.add_argument("--api", default=None, help="POST strokes to server URL")
    parser.add_argument("--json-stdout", action="store_true",
                        help="Output JSON lines for Godot subprocess mode")
    parser.add_argument("--uuid", default=None, help="Device UUID hex (overrides file)")
    parser.add_argument("--pipe", default=None, help="JSONL file path for Godot IPC")
    args = parser.parse_args()

    if args.json_stdout:
        # JSON subprocess mode for Godot
        if args.uuid:
            with open(UUID_FILE, "w") as f:
                json.dump({"uuid": args.uuid}, f)

        # Open pipe file if specified
        if args.pipe:
            pipe_dir = os.path.dirname(args.pipe)
            if pipe_dir:
                os.makedirs(pipe_dir, exist_ok=True)
            _pipe_file = open(args.pipe, "w", encoding="utf-8")

        canvas = JsonStdoutCanvas()
        capture = JsonPenCapture(canvas=canvas)

        try:
            asyncio.run(capture.connect_and_stream())
        except (KeyboardInterrupt, asyncio.CancelledError):
            pass
        _json_out({"type": "disconnected"})
        if _pipe_file:
            _pipe_file.close()
    else:
        # Normal interactive mode
        canvas = InkCanvas()
        capture = PenCapture(canvas=canvas, api_url=args.api)
        try:
            asyncio.run(capture.connect_and_stream())
        except KeyboardInterrupt:
            pass

        canvas.pen_up()
        save_path = args.save or "data/live_capture.svg"
        canvas.save(save_path)
        print(f"Canvas saved to {save_path}")
        if capture._posted:
            print(f"Posted {capture._posted} points to server")
