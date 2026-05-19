"""Quick connect — scan continuously, connect on first sight, enumerate & listen."""
import asyncio
from bleak import BleakScanner, BleakClient


def on_notify(char, data):
    print(f"NOTIFY [{str(char)[-8:]}] {len(data)}B: {data.hex()}", flush=True)


async def main():
    print("Scanning continuously for Bamboo Slate...", flush=True)

    # Use detection callback for instant notification
    found = asyncio.Event()
    found_dev = [None]

    def on_detect(device, adv_data):
        if device.name and "bamboo" in device.name.lower():
            found_dev[0] = device
            found.set()

    scanner = BleakScanner(on_detect)
    await scanner.start()

    try:
        await asyncio.wait_for(found.wait(), timeout=60)
    except asyncio.TimeoutError:
        print("Timed out after 60s", flush=True)
        await scanner.stop()
        return

    await scanner.stop()
    device = found_dev[0]
    print(f"Found {device.name} @ {device.address}", flush=True)

    # Try connecting — give it a generous timeout
    print("Connecting (60s timeout)...", flush=True)
    try:
        async with BleakClient(device.address, timeout=60.0) as client:
            if not client.is_connected:
                print("Not actually connected!", flush=True)
                return

            print("Connected! Enumerating services...", flush=True)
            for svc in client.services:
                for ch in svc.characteristics:
                    print(f"  {ch.uuid} props={ch.properties}", flush=True)
                    if "notify" in ch.properties:
                        try:
                            await client.start_notify(ch.uuid, on_notify)
                            print(f"    SUBSCRIBED", flush=True)
                        except Exception as e:
                            print(f"    sub fail: {e}", flush=True)

            # Try writing to write-capable chars
            for svc in client.services:
                for ch in svc.characteristics:
                    if "write" in ch.properties:
                        for cmd in [b"\x01", b"\x02", b"\x00\x01"]:
                            try:
                                await client.write_gatt_char(ch.uuid, cmd)
                                print(f"  Wrote {cmd.hex()} to {ch.uuid}", flush=True)
                            except Exception as e:
                                print(f"  Write fail: {e}", flush=True)

            print("\nListening 120s — draw on the Slate!", flush=True)
            await asyncio.sleep(120)

    except Exception as e:
        print(f"Connection error: {type(e).__name__}: {e}", flush=True)


asyncio.run(main())
