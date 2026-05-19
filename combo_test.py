"""Replicate the exact multi_path sequence that triggered live mode."""
import asyncio, uuid, struct, time, json, os
from winrt.windows.devices.bluetooth import BluetoothLEDevice, BluetoothCacheMode
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattSharingMode, GattSession, GattClientCharacteristicConfigurationDescriptorValue,
)
from winrt.windows.storage.streams import DataReader, DataWriter

DEV = 0xFCF569C5F94B
UUID_FILE = "data/device_uuid.json"

async def main():
    device_uuid = bytes.fromhex(json.load(open(UUID_FILE))["uuid"])

    print("Connecting...", flush=True)
    device = await BluetoothLEDevice.from_bluetooth_address_async(DEV)
    if not device: print("Not found"); return
    print(f"  Found: {device.name}", flush=True)

    session = await GattSession.from_device_id_async(device.bluetooth_device_id)
    session.maintain_connection = True

    for i in range(30):
        if device.connection_status == 1:
            print(f"  Connected after {i+1}s", flush=True)
            break
        await asyncio.sleep(1)
    else:
        print("Timeout"); return

    # Open all services
    SVC_NORDIC = uuid.UUID("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    SVC_1530 = uuid.UUID("00001530-1212-efde-1523-785feabcd123")
    SVC_1523 = uuid.UUID("00001523-1212-efde-1523-785feabcd123")
    SVC_FFEE = uuid.UUID("ffee0001-bbaa-9988-7766-554433221100")

    nordic_svc = device.get_gatt_service(SVC_NORDIC)
    await nordic_svc.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
    svc_1530 = device.get_gatt_service(SVC_1530)
    await svc_1530.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
    svc_1523 = device.get_gatt_service(SVC_1523)
    await svc_1523.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
    svc_ffee = device.get_gatt_service(SVC_FFEE)
    await svc_ffee.open_async(GattSharingMode.SHARED_READ_AND_WRITE)

    # Get chars
    nordic_chars = await nordic_svc.get_characteristics_with_cache_mode_async(BluetoothCacheMode.UNCACHED)
    chars_1530 = await svc_1530.get_characteristics_with_cache_mode_async(BluetoothCacheMode.UNCACHED)
    chars_1523 = await svc_1523.get_characteristics_with_cache_mode_async(BluetoothCacheMode.UNCACHED)
    chars_ffee = await svc_ffee.get_characteristics_with_cache_mode_async(BluetoothCacheMode.UNCACHED)

    chars = {}
    for cl in [nordic_chars, chars_1530, chars_1523, chars_ffee]:
        for c in cl.characteristics:
            chars[str(c.uuid)] = c

    got = []
    live_pts = [0]

    # Subscribe to Nordic RX
    def on_rx(c, args):
        r = DataReader.from_buffer(args.characteristic_value)
        data = bytes(r.read_byte() for _ in range(r.unconsumed_buffer_length))
        got.append(data)
        print(f"  [RX] {data.hex()}", flush=True)
    chars["6e400003-b5a3-f393-e0a9-e50e24dcca9e"].add_value_changed(on_rx)
    await chars["6e400003-b5a3-f393-e0a9-e50e24dcca9e"].write_client_characteristic_configuration_descriptor_async(
        GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)

    # Subscribe to 00001531
    def on_1531(c, args):
        r = DataReader.from_buffer(args.characteristic_value)
        data = bytes(r.read_byte() for _ in range(r.unconsumed_buffer_length))
        print(f"  [1531] {data.hex()}", flush=True)
    chars["00001531-1212-efde-1523-785feabcd123"].add_value_changed(on_1531)
    await chars["00001531-1212-efde-1523-785feabcd123"].write_client_characteristic_configuration_descriptor_async(
        GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)

    # Subscribe to live
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
                    if live_pts[0] <= 5 or live_pts[0] % 100 == 0:
                        print(f"  LIVE #{live_pts[0]}: x={x} y={y}", flush=True)
    chars["00001524-1212-efde-1523-785feabcd123"].add_value_changed(on_live)
    await chars["00001524-1212-efde-1523-785feabcd123"].write_client_characteristic_configuration_descriptor_async(
        GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)

    await asyncio.sleep(2)
    got.clear()

    # REPLICATE exact multi_path sequence:
    # 1. Write mode to ffee0002
    print("\n1. Write to ffee0002...", flush=True)
    w = DataWriter()
    for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
    await chars["ffee0002-bbaa-9988-7766-554433221100"].write_value_with_result_async(w.detach_buffer())
    await asyncio.sleep(1)

    # 2. Write mode to Nordic TX
    print("2. Write to Nordic TX...", flush=True)
    got.clear()
    w = DataWriter()
    for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
    await chars["6e400002-b5a3-f393-e0a9-e50e24dcca9e"].write_value_with_result_async(w.detach_buffer())
    await asyncio.sleep(1)
    print(f"  Response: {[g.hex() for g in got]}", flush=True)

    # 3. Write mode to 00001532
    print("3. Write to 00001532...", flush=True)
    w = DataWriter()
    for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
    await chars["00001532-1212-efde-1523-785feabcd123"].write_value_with_result_async(w.detach_buffer())
    await asyncio.sleep(1)

    # 4. Write mode to 00001531
    print("4. Write to 00001531...", flush=True)
    w = DataWriter()
    for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
    await chars["00001531-1212-efde-1523-785feabcd123"].write_value_with_result_async(w.detach_buffer())
    await asyncio.sleep(1)

    # 5. Auth via Nordic TX (THIS was when mode changed in multi_path)
    print("5. Auth via Nordic TX...", flush=True)
    got.clear()
    auth_frame = bytes([0xE6, len(device_uuid)]) + device_uuid
    w = DataWriter()
    for b in auth_frame: w.write_byte(b)
    await chars["6e400002-b5a3-f393-e0a9-e50e24dcca9e"].write_value_with_result_async(w.detach_buffer())
    await asyncio.sleep(2)
    print(f"  Auth response: {[g.hex() for g in got]}", flush=True)

    # 6. Mode via Nordic TX
    print("6. Mode via Nordic TX...", flush=True)
    got.clear()
    w = DataWriter()
    for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
    await chars["6e400002-b5a3-f393-e0a9-e50e24dcca9e"].write_value_with_result_async(w.detach_buffer())
    await asyncio.sleep(2)
    print(f"  Mode response: {[g.hex() for g in got]}", flush=True)

    # Check
    is_live = any(len(g) >= 3 and g[0] in (0xB1, 0xB3) and g[2] == 0x00 for g in got)
    if is_live:
        print("LIVE MODE!", flush=True)
    else:
        print("Still idle. Trying Bleak approach...", flush=True)
        # Try write_value_async (no response) instead of write_value_with_result_async
        got.clear()
        w = DataWriter()
        for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
        await chars["6e400002-b5a3-f393-e0a9-e50e24dcca9e"].write_value_async(w.detach_buffer())
        await asyncio.sleep(2)
        print(f"  Fire-and-forget mode: {[g.hex() for g in got]}", flush=True)

    # Draw test
    os.system('powershell -Command "[Console]::Beep(1200,300)"')
    os.system('powershell -Command "Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak(\'Draw now!\')"')
    print("\n=== DRAW TEST (10s) ===", flush=True)
    for i in range(10):
        await asyncio.sleep(1)
        if live_pts[0]:
            print(f"  {live_pts[0]} points", flush=True)

    print(f"\nTotal: {live_pts[0]}", flush=True)
    print("Done.", flush=True)
    device.close()

asyncio.run(main())
