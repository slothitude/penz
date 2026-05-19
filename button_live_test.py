"""Test live mode with button press confirmation."""
import asyncio, uuid, struct, time, sys
from winrt.windows.devices.bluetooth import BluetoothLEDevice, BluetoothCacheMode
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattSharingMode, GattSession, GattClientCharacteristicConfigurationDescriptorValue,
)
from winrt.windows.storage.streams import DataReader, DataWriter

DEV = 0xFCF569C5F94B
NORDIC_SVC = uuid.UUID("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
LIVE_SVC = uuid.UUID("00001523-1212-efde-1523-785feabcd123")
NORDIC_TX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
NORDIC_RX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
LIVE_CHAR = "00001524-1212-efde-1523-785feabcd123"
LIVE_CTRL = "00001525-1212-efde-1523-785feabcd123"

got = []
live_pts = [0]

def beep(freq=1000, ms=500):
    import os
    os.system(f'powershell -Command "[Console]::Beep({freq},{ms})"')

def speak(text):
    import os
    os.system(f'powershell -Command "Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak(\'{text}\')"')

async def main():
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

    # Open Nordic UART
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

    # Set time
    now = time.localtime()
    td = bytes([now.tm_year%100, now.tm_mon, now.tm_mday, now.tm_hour, now.tm_min, now.tm_sec])
    w = DataWriter()
    for b in bytes([0xB6, len(td)]) + td: w.write_byte(b)
    await tx_c.write_value_async(w.detach_buffer())
    await asyncio.sleep(1)

    # Battery
    w = DataWriter()
    for b in bytes([0xB9, 0x01, 0x00]): w.write_byte(b)
    got.clear()
    await tx_c.write_value_async(w.detach_buffer())
    await asyncio.sleep(1)
    for r in got:
        if len(r) > 2:
            print(f"Battery: {r[2]}%", flush=True)
            break

    # Open Live service
    live_svc = device.get_gatt_service(LIVE_SVC)
    await live_svc.open_async(GattSharingMode.SHARED_READ_AND_WRITE)
    live_chars = await live_svc.get_characteristics_with_cache_mode_async(BluetoothCacheMode.UNCACHED)
    live_c = live_ctrl_c = None
    for c in live_chars.characteristics:
        s = str(c.uuid)
        print(f"  Live char: {s} props={c.characteristic_properties}", flush=True)
        if s == LIVE_CHAR: live_c = c
        elif s == LIVE_CTRL: live_ctrl_c = c

    # Subscribe to live data
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

    # Subscribe to live ctrl (00001525) if available — might need writes here
    if live_ctrl_c:
        print(f"  Live ctrl found: props={live_ctrl_c.characteristic_properties}", flush=True)

    # Check current mode
    print("\n--- Checking current mode ---", flush=True)
    w = DataWriter()
    for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
    got.clear()
    await tx_c.write_value_async(w.detach_buffer())
    await asyncio.sleep(2)
    print(f"  Current mode response: {[g.hex() for g in got[-3:]]}", flush=True)

    # Now try: send live mode + ask user to press button
    print("\n=== BUTTON PRESS TEST ===", flush=True)
    speak("Ready to switch to live mode. I will send the command now. Press the button on the slate when you hear the beep.")
    await asyncio.sleep(3)

    got.clear()
    w = DataWriter()
    for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
    await tx_c.write_value_async(w.detach_buffer())
    print("  Sent B1 01 00 (live mode)", flush=True)

    await asyncio.sleep(0.5)
    beep(1200, 300)
    print("  >>> PRESS THE BUTTON NOW <<<", flush=True)

    # Wait for mode response
    await asyncio.sleep(5)
    print(f"  Responses: {[g.hex() for g in got]}", flush=True)

    # Check if we got live mode confirmation
    live_mode = False
    for r in got:
        if len(r) >= 3 and r[0] in (0xB1, 0xB3) and r[2] == 0x00:
            live_mode = True
            break

    if not live_mode:
        # Try writing to live_ctrl (00001525) instead
        if live_ctrl_c:
            print("\n  Trying via 00001525 control char...", flush=True)
            got.clear()
            w = DataWriter()
            for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
            try:
                await live_ctrl_c.write_value_async(w.detach_buffer())
                print("  Written to 00001525", flush=True)
                await asyncio.sleep(2)
                print(f"  Responses: {[g.hex() for g in got]}", flush=True)
            except Exception as e:
                print(f"  00001525 write failed: {e}", flush=True)

    # Also try: write_via_write_without_response flag
    print("\n--- Trying with GATT_WRITE_OPTION ---", flush=True)
    try:
        from winrt.windows.devices.bluetooth.genericattributeprofile import GattWriteOption
        got.clear()
        w = DataWriter()
        for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
        result = await tx_c.write_value_with_result_async(w.detach_buffer())
        print(f"  write_value_with_result: status={result.status}", flush=True)
        await asyncio.sleep(2)
        print(f"  Responses: {[g.hex() for g in got]}", flush=True)
    except Exception as e:
        print(f"  write_value_with_result failed: {e}", flush=True)

    # Final status check
    speak("What color is the light now?")
    await asyncio.sleep(4)

    got.clear()
    w = DataWriter()
    for b in bytes([0xB1, 0x01, 0x00]): w.write_byte(b)
    await tx_c.write_value_async(w.detach_buffer())
    await asyncio.sleep(2)
    print(f"\n  Final mode: {[g.hex() for g in got]}", flush=True)

    print(f"\n  Total live points received: {live_pts[0]}", flush=True)
    print("Done.", flush=True)
    nordic.close()
    if live_svc: live_svc.close()
    device.close()

asyncio.run(main())
