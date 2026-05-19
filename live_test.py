"""One-shot live capture + stream to plotter server."""
import asyncio, uuid, struct, time, os
from winrt.windows.devices.bluetooth import BluetoothLEDevice, BluetoothCacheMode
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattSharingMode, GattSession, GattClientCharacteristicConfigurationDescriptorValue,
)
from winrt.windows.storage.streams import DataReader, DataWriter
import aiohttp
from collections import deque

DEV = 0xFCF569C5F94B
pending = deque()
posted = 0

async def post_loop(session, api_url, connected_flag):
    global posted
    while connected_flag[0]:
        if pending:
            batch = []
            while pending and len(batch) < 50:
                batch.append(pending.popleft())
            if batch:
                try:
                    await session.post(api_url + "/stream/stroke", json={"points": batch},
                        timeout=aiohttp.ClientTimeout(total=2))
                    posted += len(batch)
                except Exception:
                    pass
        await asyncio.sleep(0.05)

async def main():
    api_url = "http://localhost:5000"
    device = await BluetoothLEDevice.from_bluetooth_address_async(DEV)
    session = await GattSession.from_device_id_async(device.bluetooth_device_id)
    session.maintain_connection = True
    for i in range(30):
        if device.connection_status == 1: break
        await asyncio.sleep(1)
    else:
        print("BLE timeout"); return
    print("Connected", flush=True)

    nordic = device.get_gatt_service(uuid.UUID("6e400001-b5a3-f393-e0a9-e50e24dcca9e"))
    await nordic.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
    chars = await nordic.get_characteristics_with_cache_mode_async(BluetoothCacheMode.UNCACHED)
    tx_c = rx_c = None
    for c in chars.characteristics:
        s = str(c.uuid)
        if s == "6e400002-b5a3-f393-e0a9-e50e24dcca9e": tx_c = c
        elif s == "6e400003-b5a3-f393-e0a9-e50e24dcca9e": rx_c = c

    rx_data = []
    def on_rx(c, args):
        r = DataReader.from_buffer(args.characteristic_value)
        rx_data.append(bytes(r.read_byte() for _ in range(r.unconsumed_buffer_length)))

    rx_c.add_value_changed(on_rx)
    await rx_c.write_client_characteristic_configuration_descriptor_async(
        GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)
    await asyncio.sleep(2)
    rx_data.clear()

    now = time.localtime()
    td = bytes([now.tm_year%100, now.tm_mon, now.tm_mday, now.tm_hour, now.tm_min, now.tm_sec])
    w = DataWriter()
    for b in bytes([0xB6, len(td)]) + td: w.write_byte(b)
    await tx_c.write_value_async(w.detach_buffer())
    await asyncio.sleep(1)

    w = DataWriter()
    for b in bytes([0xB9, 0x01, 0x00]): w.write_byte(b)
    rx_data.clear()
    await tx_c.write_value_async(w.detach_buffer())
    await asyncio.sleep(1)
    if rx_data: print(f"Battery: {rx_data[-1][2]}%", flush=True)

    live_svc = device.get_gatt_service(uuid.UUID("00001523-1212-efde-1523-785feabcd123"))
    await live_svc.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
    live_chars = await live_svc.get_characteristics_with_cache_mode_async(BluetoothCacheMode.UNCACHED)
    live_c = None
    for c in live_chars.characteristics:
        if str(c.uuid) == "00001524-1212-efde-1523-785feabcd123":
            live_c = c
    print(f"Live char: {live_c is not None}", flush=True)

    pts = [0]
    def on_live(c, args):
        r = DataReader.from_buffer(args.characteristic_value)
        data = bytes(r.read_byte() for _ in range(r.unconsumed_buffer_length))
        if len(data) >= 2 and data[0] == 0xA1:
            payload = data[2:]
            if len(payload) >= 6 and all(b == 0xFF for b in payload[:6]):
                print("  PEN UP", flush=True)
            else:
                batch = []
                for i in range(0, len(payload) - 5, 6):
                    x, y, p = struct.unpack_from("<HHH", payload, i)
                    pts[0] += 1
                    batch.append((x, y, p))
                    if pts[0] <= 3 or pts[0] % 100 == 0:
                        print(f"  PT #{pts[0]}: x={x} y={y} p={p}", flush=True)
                if batch:
                    pending.extend(batch)
        elif len(data) >= 2 and data[0] == 0xA2:
            print("  PEN PROX", flush=True)

    if live_c:
        live_c.add_value_changed(on_live)
        s = await live_c.write_client_characteristic_configuration_descriptor_async(
            GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)
        print(f"Live sub: {s}", flush=True)

    w = DataWriter()
    for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
    rx_data.clear()
    await tx_c.write_value_async(w.detach_buffer())
    await asyncio.sleep(1)
    print(f"Mode: {[d.hex() for d in rx_data]}", flush=True)

    os.system('powershell -Command "[Console]::Beep(1000,500)"')
    print("=" * 60, flush=True)
    print("LIVE! Draw on Slate (60s)...", flush=True)
    print("=" * 60, flush=True)

    conn = [True]
    async with aiohttp.ClientSession() as sess:
        pt = asyncio.create_task(post_loop(sess, api_url, conn))
        try:
            await asyncio.sleep(60)
        finally:
            conn[0] = False
            pt.cancel()

    w = DataWriter()
    for b in bytes([0xB1, 0x01, 0x02]): w.write_byte(b)
    await tx_c.write_value_async(w.detach_buffer())
    print(f"Total: {pts[0]} pts, posted: {posted}", flush=True)
    nordic.close(); live_svc.close(); device.close()

asyncio.run(main())
