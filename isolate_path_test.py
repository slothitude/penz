"""Isolate which write path switches to live mode."""
import asyncio, uuid, time, json, os
from winrt.windows.devices.bluetooth import BluetoothLEDevice, BluetoothCacheMode
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattSharingMode, GattSession, GattClientCharacteristicConfigurationDescriptorValue,
)
from winrt.windows.storage.streams import DataReader, DataWriter

DEV = 0xFCF569C5F94B
UUID_FILE = "data/device_uuid.json"

# Service/char UUIDs
SVC_NORDIC = uuid.UUID("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
SVC_1530 = uuid.UUID("00001530-1212-efde-1523-785feabcd123")
SVC_1523 = uuid.UUID("00001523-1212-efde-1523-785feabcd123")
SVC_FFEE = uuid.UUID("ffee0001-bbaa-9988-7766-554433221100")
SVC_3A34 = uuid.UUID("3a340720-c572-11e5-86c5-0002a5d5c51b")

CHAR_NORDIC_TX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
CHAR_NORDIC_RX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
CHAR_1531 = "00001531-1212-efde-1523-785feabcd123"
CHAR_1532 = "00001532-1212-efde-1523-785feabcd123"
CHAR_1524 = "00001524-1212-efde-1523-785feabcd123"
CHAR_1525 = "00001525-1212-efde-1523-785feabcd123"
CHAR_FFEE2 = "ffee0002-bbaa-9988-7766-554433221100"
CHAR_FFEE3 = "ffee0003-bbaa-9988-7766-554433221100"

got_nordic = []
got_1531 = []
got_1525 = []
got_ffee3 = []
live_pts = [0]

async def main():
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

    # Open all relevant services
    services = {}
    for name, svc_uuid in [("nordic", SVC_NORDIC), ("1530", SVC_1530), ("1523", SVC_1523), ("ffee", SVC_FFEE), ("3a34", SVC_3A34)]:
        svc = device.get_gatt_service(svc_uuid)
        await svc.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
        chars_r = await svc.get_characteristics_with_cache_mode_async(BluetoothCacheMode.UNCACHED)
        services[name] = {}
        for c in chars_r.characteristics:
            services[name][str(c.uuid)] = c

    # Subscribe to Nordic RX
    nordic_rx = services["nordic"].get(CHAR_NORDIC_RX)
    nordic_tx = services["nordic"].get(CHAR_NORDIC_TX)
    def on_nordic(c, args):
        r = DataReader.from_buffer(args.characteristic_value)
        data = bytes(r.read_byte() for _ in range(r.unconsumed_buffer_length))
        got_nordic.append(data)
        print(f"  [NORDIC] {data.hex()}", flush=True)
    nordic_rx.add_value_changed(on_nordic)
    await nordic_rx.write_client_characteristic_configuration_descriptor_async(
        GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)

    # Subscribe to 00001531
    char_1531 = services["1530"].get(CHAR_1531)
    if char_1531:
        def on_1531(c, args):
            r = DataReader.from_buffer(args.characteristic_value)
            data = bytes(r.read_byte() for _ in range(r.unconsumed_buffer_length))
            got_1531.append(data)
            print(f"  [1531] {data.hex()}", flush=True)
        char_1531.add_value_changed(on_1531)
        await char_1531.write_client_characteristic_configuration_descriptor_async(
            GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)

    # Subscribe to 00001525 (indicate)
    char_1525 = services["1523"].get(CHAR_1525)
    if char_1525:
        def on_1525(c, args):
            r = DataReader.from_buffer(args.characteristic_value)
            data = bytes(r.read_byte() for _ in range(r.unconsumed_buffer_length))
            got_1525.append(data)
            print(f"  [1525] {data.hex()}", flush=True)
        char_1525.add_value_changed(on_1525)
        try:
            await char_1525.write_client_characteristic_configuration_descriptor_async(
                GattClientCharacteristicConfigurationDescriptorValue.INDICATE)
        except Exception as e:
            print(f"  1525 subscribe failed: {e}", flush=True)

    # Subscribe to ffee0003
    char_ffee3 = services["ffee"].get(CHAR_FFEE3)
    if char_ffee3:
        def on_ffee3(c, args):
            r = DataReader.from_buffer(args.characteristic_value)
            data = bytes(r.read_byte() for _ in range(r.unconsumed_buffer_length))
            got_ffee3.append(data)
            print(f"  [ffee3] {data.hex()}", flush=True)
        char_ffee3.add_value_changed(on_ffee3)
        await char_ffee3.write_client_characteristic_configuration_descriptor_async(
            GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)

    # Subscribe to live data
    char_1524 = services["1523"].get(CHAR_1524)
    import struct
    if char_1524:
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
        char_1524.add_value_changed(on_live)
        await char_1524.write_client_characteristic_configuration_descriptor_async(
            GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)

    await asyncio.sleep(2)
    got_nordic.clear(); got_1531.clear(); got_1525.clear(); got_ffee3.clear()

    # Check initial mode
    print("\n=== Initial mode query via Nordic ===", flush=True)
    w = DataWriter()
    for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
    await nordic_tx.write_value_with_result_async(w.detach_buffer())
    await asyncio.sleep(1)
    print(f"  Nordic notifications: {[g.hex() for g in got_nordic]}", flush=True)
    got_nordic.clear()

    # TEST 1: Write to 00001532 only
    char_1532 = services["1530"].get(CHAR_1532)
    print("\n=== TEST 1: Write B10100 to 00001532 ===", flush=True)
    w = DataWriter()
    for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
    got_nordic.clear(); got_1531.clear()
    await char_1532.write_value_with_result_async(w.detach_buffer())
    await asyncio.sleep(2)
    print(f"  1531: {[g.hex() for g in got_1531]}", flush=True)
    print(f"  Nordic: {[g.hex() for g in got_nordic]}", flush=True)

    # Check mode now
    w = DataWriter()
    for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
    got_nordic.clear()
    await nordic_tx.write_value_with_result_async(w.detach_buffer())
    await asyncio.sleep(1)
    print(f"  Mode now: {[g.hex() for g in got_nordic]}", flush=True)
    got_nordic.clear()

    # If still idle, try 00001531
    mode_live = any(len(g) >= 3 and g[2] == 0x00 for g in got_nordic)
    if not mode_live:
        print("\n=== TEST 2: Write B10100 to 00001531 ===", flush=True)
        w = DataWriter()
        for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
        got_nordic.clear(); got_1531.clear()
        await char_1531.write_value_with_result_async(w.detach_buffer())
        await asyncio.sleep(2)
        print(f"  1531: {[g.hex() for g in got_1531]}", flush=True)
        print(f"  Nordic: {[g.hex() for g in got_nordic]}", flush=True)

        w = DataWriter()
        for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
        got_nordic.clear()
        await nordic_tx.write_value_with_result_async(w.detach_buffer())
        await asyncio.sleep(1)
        print(f"  Mode now: {[g.hex() for g in got_nordic]}", flush=True)
        got_nordic.clear()

    # If still idle, try ffee0002
    mode_live = any(len(g) >= 3 and g[2] == 0x00 for g in got_nordic)
    if not mode_live:
        char_ffee2 = services["ffee"].get(CHAR_FFEE2)
        print("\n=== TEST 3: Write B10100 to ffee0002 ===", flush=True)
        w = DataWriter()
        for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
        got_nordic.clear(); got_ffee3.clear()
        await char_ffee2.write_value_with_result_async(w.detach_buffer())
        await asyncio.sleep(2)
        print(f"  ffee3: {[g.hex() for g in got_ffee3]}", flush=True)
        print(f"  Nordic: {[g.hex() for g in got_nordic]}", flush=True)

        w = DataWriter()
        for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
        got_nordic.clear()
        await nordic_tx.write_value_with_result_async(w.detach_buffer())
        await asyncio.sleep(1)
        print(f"  Mode now: {[g.hex() for g in got_nordic]}", flush=True)
        got_nordic.clear()

    # If still idle, try 00001525
    mode_live = any(len(g) >= 3 and g[2] == 0x00 for g in got_nordic)
    if not mode_live:
        print("\n=== TEST 4: Write B10100 to 00001525 ===", flush=True)
        w = DataWriter()
        for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
        got_nordic.clear(); got_1525.clear()
        try:
            await char_1525.write_value_with_result_async(w.detach_buffer())
            await asyncio.sleep(2)
            print(f"  1525: {[g.hex() for g in got_1525]}", flush=True)
            print(f"  Nordic: {[g.hex() for g in got_nordic]}", flush=True)
        except Exception as e:
            print(f"  1525 write failed: {e}", flush=True)

        w = DataWriter()
        for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
        got_nordic.clear()
        await nordic_tx.write_value_with_result_async(w.detach_buffer())
        await asyncio.sleep(1)
        print(f"  Mode now: {[g.hex() for g in got_nordic]}", flush=True)

    # Draw test if live
    import os
    os.system('powershell -Command "[Console]::Beep(1200,300)"')
    print("\n=== DRAW TEST (8s) ===", flush=True)
    for i in range(8):
        await asyncio.sleep(1)
        if live_pts[0]:
            print(f"  {live_pts[0]} points", flush=True)

    print(f"\nTotal: {live_pts[0]} points", flush=True)
    print("Done.", flush=True)
    device.close()

asyncio.run(main())
