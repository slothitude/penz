"""Test mode command through ALL possible write characteristics."""
import asyncio, uuid, struct, time, json, os
from winrt.windows.devices.bluetooth import BluetoothLEDevice, BluetoothCacheMode
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattSharingMode, GattSession, GattClientCharacteristicConfigurationDescriptorValue,
)
from winrt.windows.storage.streams import DataReader, DataWriter

DEV = 0xFCF569C5F94B
NORDIC_SVC = uuid.UUID("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
LIVE_SVC = uuid.UUID("00001523-1212-efde-1523-785feabcd123")
FFEE_SVC = uuid.UUID("ffee0001-bbaa-9988-7766-554433221100")
NORDIC_TX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
NORDIC_RX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
UUID_FILE = "data/device_uuid.json"

all_notifications = {}

def key(char):
    return str(char.uuid)[:8]

async def main():
    device_uuid = bytes.fromhex(json.load(open(UUID_FILE))["uuid"])
    print(f"UUID: {device_uuid.hex()}", flush=True)

    print("Connecting...", flush=True)
    device = await BluetoothLEDevice.from_bluetooth_address_async(DEV)
    if not device:
        print("Not found"); return
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

    # Discover ALL services and chars
    services_result = await device.get_gatt_services_with_cache_mode_async(BluetoothCacheMode.UNCACHED)
    print(f"\nServices: {len(services_result.services)}", flush=True)

    write_chars = {}  # chars we can write to
    notify_chars = {}  # chars we can subscribe to

    for svc in services_result.services:
        await svc.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
        chars_r = await svc.get_characteristics_with_cache_mode_async(BluetoothCacheMode.UNCACHED)
        print(f"\n  Service: {svc.uuid}", flush=True)
        for c in chars_r.characteristics:
            props = c.characteristic_properties
            k = str(c.uuid)
            print(f"    {k}  props={props} (W={bool(props&8)} WNR={bool(props&4)} N={bool(props&16)} I={bool(props&32)} R={bool(props&2)})", flush=True)
            if props & 0x0C:  # WRITE or WRITE_WITHOUT_RESPONSE
                write_chars[k] = c
            if props & 0x30:  # NOTIFY or INDICATE
                notify_chars[k] = c

    # Subscribe to ALL notify/indicate chars
    print("\n--- Subscribing to all ---", flush=True)
    for k, c in notify_chars.items():
        all_notifications[k] = []
        def make_handler(k):
            def handler(c, args):
                r = DataReader.from_buffer(args.characteristic_value)
                data = bytes(r.read_byte() for _ in range(r.unconsumed_buffer_length))
                all_notifications[k].append(data)
                print(f"  NOTIFY [{k[:8]}]: {data.hex()}", flush=True)
            return handler
        c.add_value_changed(make_handler(k))
        try:
            if c.characteristic_properties & 0x20:  # INDICATE
                await c.write_client_characteristic_configuration_descriptor_async(
                    GattClientCharacteristicConfigurationDescriptorValue.INDICATE)
            else:
                await c.write_client_characteristic_configuration_descriptor_async(
                    GattClientCharacteristicConfigurationDescriptorValue.NOTIFY)
            print(f"  Subscribed: {k[:8]}", flush=True)
        except Exception as e:
            print(f"  Subscribe failed {k[:8]}: {e}", flush=True)

    await asyncio.sleep(2)
    # Clear all
    for k in all_notifications:
        all_notifications[k].clear()

    # Now try sending mode command through each write characteristic
    mode_cmd = bytes([0xB1, 0x01, 0x00])

    for k, c in write_chars.items():
        print(f"\n=== Writing mode cmd to {k[:8]} ===", flush=True)
        for nk in all_notifications:
            all_notifications[nk].clear()

        w = DataWriter()
        for b in mode_cmd:
            w.write_byte(b)

        try:
            result = await c.write_value_with_result_async(w.detach_buffer())
            print(f"  write status: {result.status}", flush=True)
        except Exception as e:
            print(f"  write failed: {e}", flush=True)
            continue

        await asyncio.sleep(2)

        # Check all notification channels for mode response
        for nk, notifs in all_notifications.items():
            if notifs:
                for n in notifs:
                    print(f"  Response on [{nk[:8]}]: {n.hex()}", flush=True)

    # Also try auth + mode through Nordic TX
    print("\n=== Auth + Mode via Nordic TX ===", flush=True)
    nordic_tx = write_chars.get(NORDIC_TX)
    if nordic_tx:
        # Auth
        for k in all_notifications: all_notifications[k].clear()
        auth_frame = bytes([0xE6, len(device_uuid)]) + device_uuid
        w = DataWriter()
        for b in auth_frame: w.write_byte(b)
        await nordic_tx.write_value_with_result_async(w.detach_buffer())
        print(f"  Sent auth: {auth_frame.hex()}", flush=True)
        await asyncio.sleep(2)
        for nk, notifs in all_notifications.items():
            for n in notifs:
                print(f"  Auth resp [{nk[:8]}]: {n.hex()}", flush=True)

        # Mode
        for k in all_notifications: all_notifications[k].clear()
        w = DataWriter()
        for b in mode_cmd: w.write_byte(b)
        await nordic_tx.write_value_with_result_async(w.detach_buffer())
        print(f"  Sent mode: {mode_cmd.hex()}", flush=True)
        await asyncio.sleep(2)
        for nk, notifs in all_notifications.items():
            for n in notifs:
                print(f"  Mode resp [{nk[:8]}]: {n.hex()}", flush=True)

    print("\nDone.", flush=True)
    device.close()

asyncio.run(main())
