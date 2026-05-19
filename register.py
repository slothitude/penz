"""One-shot register + authenticate + live capture for Bamboo Slate.

Usage:
  1. Press Bluetooth button on Slate (LED flashes blue)
  2. Run: python register.py
  3. When prompted, HOLD the button 6+ sec, release, then press once
"""
import asyncio, json, os, secrets, struct, time
from bleak import BleakScanner, BleakClient

NORDIC_RX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
NORDIC_TX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
LIVE_CHAR = "00001524-1212-efde-1523-785feabcd123"
UUID_FILE = "data/device_uuid.json"

notifications = []


def on_nordic(char, data):
    notifications.append(data)
    print(f"  [NORDIC] {data.hex()}", flush=True)


def on_live(char, data):
    if len(data) < 2:
        return
    opcode = data[0]
    if opcode == 0xA1:
        payload = data[2:]
        if len(payload) >= 6 and all(b == 0xFF for b in payload[:6]):
            print("  [PEN UP]", flush=True)
        else:
            for i in range(0, len(payload) - 5, 6):
                x, y, p = struct.unpack_from("<HHH", payload, i)
                print(f"  x={x:5d} y={y:5d} p={p:4d}", flush=True)
    elif opcode == 0xA2:
        print("  [PEN IN PROXIMITY]", flush=True)
    else:
        print(f"  [LIVE 0x{opcode:02x}] {data.hex()}", flush=True)


async def send_cmd(client, opcode, data=b""):
    frame = bytes([opcode, len(data)]) + data
    notifications.clear()
    await client.write_gatt_char(NORDIC_TX, frame, response=True)
    print(f"  [TX] {frame.hex()}", flush=True)
    for _ in range(20):
        await asyncio.sleep(0.25)
        if notifications:
            return notifications[0]
    return None


async def wait_for_notification(opcode, timeout=90):
    """Wait for a specific notification opcode."""
    for _ in range(int(timeout * 2)):
        await asyncio.sleep(0.5)
        for n in notifications:
            if n[0] == opcode:
                return n
    return None


async def do_register(client, uuid):
    """Register device: send 0xe7, wait for button press (0xe4), send 0xe5."""
    notifications.clear()
    frame = bytes([0xE7, 0x06]) + uuid
    await client.write_gatt_char(NORDIC_TX, frame, response=True)
    print(f"  [TX] {frame.hex()}", flush=True)
    print("\n>>> HOLD BUTTON 6+ SEC, RELEASE, PRESS ONCE <<<\n", flush=True)

    reply = await wait_for_notification(0xE4, timeout=90)
    if not reply:
        print("  Timed out waiting for button press", flush=True)
        return False

    print(f"  Got 0xe4: {reply.hex()}", flush=True)
    await asyncio.sleep(1)

    # Complete registration
    reply2 = await send_cmd(client, 0xE5, uuid)
    print(f"  Register complete: {reply2.hex() if reply2 else 'None'}", flush=True)
    await asyncio.sleep(1)
    return True


async def main():
    # Load or generate UUID
    os.makedirs("data", exist_ok=True)
    if os.path.exists(UUID_FILE):
        with open(UUID_FILE) as f:
            uuid = bytes.fromhex(json.load(f)["uuid"])
        print(f"Using saved UUID: {uuid.hex()}")
    else:
        uuid = secrets.token_bytes(6)
        with open(UUID_FILE, "w") as f:
            json.dump({"uuid": uuid.hex()}, f)
        print(f"Generated UUID: {uuid.hex()}")

    # Scan and connect
    found = asyncio.Event()
    dev = [None]

    def on_detect(d, ad):
        if d.name and "bamboo" in d.name.lower():
            dev[0] = d
            found.set()

    scanner = BleakScanner(on_detect)
    await scanner.start()
    print("Scanning for Bamboo Slate...", flush=True)
    try:
        await asyncio.wait_for(found.wait(), timeout=30)
    except asyncio.TimeoutError:
        print("Not found. Press Bluetooth button and retry.")
        await scanner.stop()
        return
    await scanner.stop()

    d = dev[0]
    print(f"Found {d.name} @ {d.address}", flush=True)
    print("Connecting...", flush=True)
    async with BleakClient(d.address, timeout=60.0) as client:
        print("Connected! Subscribing...", flush=True)
        await client.start_notify(NORDIC_RX, on_nordic)
        try:
            await client.start_notify(LIVE_CHAR, on_live)
            print("  Subscribed to Live pen data", flush=True)
        except Exception:
            pass

        # ── Authenticate ──
        print(f"\nTrying CONNECT with UUID {uuid.hex()}...", flush=True)
        reply = await send_cmd(client, 0xE6, uuid)

        if reply and reply[0] == 0x50:
            print("AUTHENTICATED!", flush=True)
        else:
            # Need registration
            if reply:
                print(f"  Reply: {reply.hex()}", flush=True)
            else:
                print("  No reply", flush=True)

            if not await do_register(client, uuid):
                return

            # Retry CONNECT
            print("\nRetrying CONNECT...", flush=True)
            reply = await send_cmd(client, 0xE6, uuid)
            if reply and reply[0] == 0x50:
                print("AUTHENTICATED!", flush=True)
            else:
                print(f"  Auth failed: {reply.hex() if reply else 'None'}", flush=True)
                return

        # ── Set time ──
        now = time.localtime()
        await send_cmd(client, 0xB6, bytes([now.tm_year % 100, now.tm_mon, now.tm_mday,
                                             now.tm_hour, now.tm_min, now.tm_sec]))

        # ── Get battery ──
        reply = await send_cmd(client, 0xB9, b"\x00")
        if reply and len(reply) > 2:
            print(f"Battery: {reply[1]}%", flush=True)

        # ── Switch to LIVE mode ──
        print("\nSwitching to LIVE mode...", flush=True)
        reply = await send_cmd(client, 0xB1, bytes([0x00]))
        if reply and len(reply) >= 2 and reply[1] == 0x00:
            print("LIVE MODE ACTIVE!", flush=True)
        else:
            print(f"Mode reply: {reply.hex() if reply else 'None'}", flush=True)

        print("\n" + "=" * 60, flush=True)
        print("DRAW ON THE SLATE! Press Ctrl+C to stop", flush=True)
        print("=" * 60 + "\n", flush=True)

        try:
            while True:
                await asyncio.sleep(1)
        except (KeyboardInterrupt, asyncio.CancelledError):
            pass

        # Cleanup
        await send_cmd(client, 0xB1, bytes([0x02]))  # IDLE mode
        print("\nDone.", flush=True)


asyncio.run(main())
