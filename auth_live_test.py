"""Test auth + live mode with write-with-response."""
import asyncio, uuid, struct, time, json, os
from winrt.windows.devices.bluetooth import BluetoothLEDevice, BluetoothCacheMode
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattSharingMode, GattSession, GattClientCharacteristicConfigurationDescriptorValue,
    GattWriteOption,
)
from winrt.windows.storage.streams import DataReader, DataWriter

DEV = 0xFCF569C5F94B
NORDIC_SVC = uuid.UUID("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
LIVE_SVC = uuid.UUID("00001523-1212-efde-1523-785feabcd123")
NORDIC_TX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
NORDIC_RX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
LIVE_CHAR = "00001524-1212-efde-1523-785feabcd123"
UUID_FILE = "data/device_uuid.json"

got = []
live_pts = [0]

def beep(freq=1000, ms=400):
    os.system(f'powershell -Command "[Console]::Beep({freq},{ms})"')

def speak(text):
    os.system(f'powershell -Command "Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak(\'{text}\')"')

async def send_cmd(tx_c, op, data=b""):
    """Send command and wait for response."""
    frame = bytes([op, len(data)]) + data
    w = DataWriter()
    for b in frame: w.write_byte(b)
    got.clear()
    # Try write_with_result (uses GATT Write Request = with response)
    result = await tx_c.write_value_with_result_async(w.detach_buffer())
    print(f"  TX: {frame.hex()} write_status={result.status}", flush=True)
    # Wait for notification response
    for _ in range(20):
        await asyncio.sleep(0.25)
        if got:
            return got[0]
    return None

async def send_cmd_no_response(tx_c, op, data=b""):
    """Send via write_value_async (may be write-without-response)."""
    frame = bytes([op, len(data)]) + data
    w = DataWriter()
    for b in frame: w.write_byte(b)
    got.clear()
    await tx_c.write_value_async(w.detach_buffer())
    print(f"  TX (no-response): {frame.hex()}", flush=True)
    for _ in range(20):
        await asyncio.sleep(0.25)
        if got:
            return got[0]
    return None

async def main():
    # Load UUID
    if os.path.exists(UUID_FILE):
        with open(UUID_FILE) as f:
            device_uuid = bytes.fromhex(json.load(f)["uuid"])
        print(f"UUID: {device_uuid.hex()}", flush=True)
    else:
        print("No UUID file found!")
        return

    print("Connecting...", flush=True)
    device = await BluetoothLEDevice.from_bluetooth_address_async(DEV)
    if not device:
        print("Device not found"); return
    print(f"  Found: {device.name}", flush=True)

    session = await GattSession.from_device_id_async(device.bluetooth_device_id)
    session.maintain_connection = True

    for i in range(30):
        if device.connection_status == 1:
            print(f"  BLE connected after {i+1}s", flush=True)
            break
        await asyncio.sleep(1)
    else:
        print("BLE timeout"); return

    # Nordic UART
    nordic = device.get_gatt_service(NORDIC_SVC)
    await nordic.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
    chars = await nordic.get_characteristics_with_cache_mode_async(BluetoothCacheMode.UNCACHED)
    tx_c = rx_c = None
    for c in chars.characteristics:
        s = str(c.uuid)
        if s == NORDIC_TX: tx_c = c
        elif s == NORDIC_RX: rx_c = c
    print(f"  Nordic TX={tx_c is not None} RX={rx_c is not None}", flush=True)

    def on_rx(c, args):
        r = DataReader.from_buffer(args.characteristic_value)
        data = bytes(r.read_byte() for _ in range(r.unconsumed_buffer_length))
        got.append(data)
        print(f"  RX: {data.hex()}", flush=True)

    rx_c.add_value_changed(on_rx)
    await rx_c.write_client_characteristic_configuration_descriptor_async(
        GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)
    await asyncio.sleep(1)
    got.clear()

    # Live service
    live_svc = device.get_gatt_service(LIVE_SVC)
    await live_svc.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
    live_chars = await live_svc.get_characteristics_with_cache_mode_async(BluetoothCacheMode.UNCACHED)
    live_c = None
    for c in live_chars.characteristics:
        s = str(c.uuid)
        if s == LIVE_CHAR:
            live_c = c
            break

    if live_c:
        def on_live(c, args):
            r = DataReader.from_buffer(args.characteristic_value)
            data = bytes(r.read_byte() for _ in range(r.unconsumed_buffer_length))
            if len(data) >= 2 and data[0] == 0xA1:
                payload = data[2:]
                if len(payload) >= 6 and all(b == 0xFF for b in payload[:6]):
                    print("  PEN UP", flush=True)
                else:
                    for i in range(0, len(payload) - 5, 6):
                        x, y, p = struct.unpack_from("<HHH", payload, i)
                        live_pts[0] += 1
                        if live_pts[0] <= 5 or live_pts[0] % 50 == 0:
                            print(f"  LIVE #{live_pts[0]}: x={x} y={y} p={p}", flush=True)
            elif len(data) >= 2 and data[0] == 0xA2:
                print("  PEN PROX", flush=True)

        live_c.add_value_changed(on_live)
        await live_c.write_client_characteristic_configuration_descriptor_async(
            GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)
        print("  Live subscribed", flush=True)

    # === STEP 1: AUTH ===
    print("\n=== AUTH ===", flush=True)
    speak("Sending auth command.")
    await asyncio.sleep(2)

    reply = await send_cmd(tx_c, 0xE6, device_uuid)
    print(f"  Auth reply: {reply.hex() if reply else 'None'}", flush=True)

    if reply and reply[0] == 0x50:
        print("AUTHENTICATED!", flush=True)
        speak("Authenticated!")
    elif reply:
        print(f"  Auth response opcode: 0x{reply[0]:02x}", flush=True)
        speak("Auth failed. Trying without.")
    else:
        print("  No auth response", flush=True)
        speak("No auth response received.")

    # === STEP 2: Set time ===
    print("\n=== SET TIME ===", flush=True)
    now = time.localtime()
    td = bytes([now.tm_year%100, now.tm_mon, now.tm_mday, now.tm_hour, now.tm_min, now.tm_sec])
    reply = await send_cmd(tx_c, 0xB6, td)
    print(f"  Time reply: {reply.hex() if reply else 'None'}", flush=True)

    # === STEP 3: Battery ===
    print("\n=== BATTERY ===", flush=True)
    reply = await send_cmd(tx_c, 0xB9, b"\x00")
    if reply and len(reply) > 2:
        print(f"Battery: {reply[2]}%", flush=True)

    # === STEP 4: LIVE MODE ===
    print("\n=== LIVE MODE ===", flush=True)
    speak("Switching to live mode.")
    await asyncio.sleep(2)

    # Try write-with-response first
    reply = await send_cmd(tx_c, 0xB1, b"\x00")
    print(f"  Mode reply: {reply.hex() if reply else 'None'}", flush=True)

    if reply and len(reply) >= 2:
        mode_val = reply[2] if len(reply) >= 3 else reply[1]
        if mode_val == 0x00:
            print("LIVE MODE ACTIVE!", flush=True)
        else:
            print(f"  Mode is: {mode_val} (0=idle/live, 2=idle)", flush=True)

    # Also try via simple write (no response)
    if not reply or (len(reply) >= 3 and reply[2] != 0x00):
        print("\n  Retrying with simple write...", flush=True)
        reply2 = await send_cmd_no_response(tx_c, 0xB1, b"\x00")
        print(f"  Mode reply2: {reply2.hex() if reply2 else 'None'}", flush=True)

    # === STEP 5: Draw test ===
    print("\n=== DRAW TEST (10s) ===", flush=True)
    beep(1200, 300)
    speak("Draw on the slate now!")
    for i in range(10):
        await asyncio.sleep(1)
        if live_pts[0] > 0:
            print(f"  {live_pts[0]} points so far", flush=True)

    print(f"\nTotal live points: {live_pts[0]}", flush=True)

    # Back to idle
    await send_cmd(tx_c, 0xB1, b"\x02")
    print("Done.", flush=True)
    nordic.close()
    live_svc.close()
    device.close()

asyncio.run(main())
