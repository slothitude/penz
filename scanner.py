# scanner.py — Phase 1: BLE device discovery & service enumeration
import asyncio
import json
import os
import subprocess
import sys

from bleak import BleakScanner, BleakClient

TARGET_NAME_PREFIX = "Bamboo"  # Wacom Bamboo Slate advert name


async def pair_device(address: str) -> bool:
    """Pair device via Windows if not already paired."""
    addr_no_colons = address.replace(":", "")
    result = subprocess.run(
        ["powershell", "-Command",
         f"Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | "
         f"Where-Object {{ $_.InstanceId -like '*{addr_no_colons}*' }} | "
         f"Select-Object -First 1"],
        capture_output=True, text=True,
    )
    if result.stdout.strip():
        print(f"Already paired: {address}")
        return True

    print(f"Pairing with {address}...")
    # Use built-in Bluetooth pairing via PowerShell
    result = subprocess.run(
        ["powershell", "-Command",
         f"$device = Get-BluetoothPairing -DeviceName 'Bamboo*' -ErrorAction SilentlyContinue; "
         f"if (-not $device) {{ "
         f"  [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime] | Out-Null; "
         f"  [Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime] | Out-Null; "
         f"  $addr = '{address}'; "
         f"  $btAddr = [UInt64]::Parse($addr.Replace(':',''), [System.Globalization.NumberStyles]::HexNumber); "
         f"  $device = [Windows.Devices.Bluetooth.BluetoothDevice]::FromBluetoothAddressAsync($btAddr).GetAwaiter().GetResult(); "
         f"  $result = $device.DeviceInformation.Pairing.PairAsync(); "
         f"  while ($result.Status -eq 'Started') {{ Start-Sleep -Milliseconds 100 }}; "
         f"  Write-Host $result.Status; "
         f"}}"],
        capture_output=True, text=True, timeout=30,
    )
    print(f"Pair result: {result.stdout.strip()}")
    if result.stderr:
        print(f"  stderr: {result.stderr.strip()}")
    return True


async def scan():
    # 1. Find the device
    print("Scanning for BLE devices (15s)...")
    devices = await BleakScanner.discover(timeout=15)
    target = None
    for d in devices:
        if d.name and TARGET_NAME_PREFIX.lower() in d.name.lower():
            target = d
            print(f"Found: {d.name} @ {d.address}")
            break

    if not target:
        print("Bamboo Slate not found. Devices seen:")
        for d in devices:
            print(f"  {d.address} — {d.name}")
        return

    # 2. Ensure paired
    await pair_device(target.address)

    # 3. Connect and enumerate GATT services
    print(f"\nConnecting to {target.address}...")
    try:
        async with BleakClient(target.address, timeout=30.0) as client:
            results = {}
            for service in client.services:
                svc = {
                    "uuid": str(service.uuid),
                    "description": service.description,
                    "characteristics": [],
                }
                print(f"\nService: {service.uuid} ({service.description})")
                for char in service.characteristics:
                    ch = {
                        "uuid": str(char.uuid),
                        "properties": char.properties,
                        "description": char.description,
                    }
                    svc["characteristics"].append(ch)
                    props = ", ".join(char.properties)
                    print(f"  [{props}] {char.uuid}  ({char.description})")
                results[str(service.uuid)] = svc

            os.makedirs("data", exist_ok=True)
            with open("data/scan_results.json", "w") as f:
                json.dump(
                    {"address": target.address, "name": target.name, "services": results},
                    f,
                    indent=2,
                )
            print(f"\nSaved to data/scan_results.json")
    except TimeoutError:
        print("\nERROR: Connection timed out during GATT discovery.")
        print("This usually means the device needs to be paired first.")
        print("Try pairing via Windows Settings > Bluetooth & devices, then re-run.")
        print(f"\nDevice address: {target.address}")
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(scan())
