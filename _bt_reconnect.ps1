# Remove Bamboo Slate BLE device (keeps pairing)
Write-Host "Removing BLE device cache..."
$dev = Get-PnpDevice | Where-Object { $_.FriendlyName -like '*Bamboo Slate*' -and $_.InstanceId -like 'BTHLE*' }
if ($dev) {
    Write-Host "Found: $($dev.FriendlyName) [$($dev.InstanceId)]"
    Write-Host "Status: $($dev.Status)"
    # Just remove the device - it will re-pair
    pnputil /remove-device $dev.InstanceId
    Start-Sleep 2
    Write-Host "Removed. Scanning..."
    # Trigger a rescan
    $null = Get-PnpDevice -Class Bluetooth -PresentOnly
    Start-Sleep 5
    # Check if it came back
    $dev2 = Get-PnpDevice | Where-Object { $_.FriendlyName -like '*Bamboo Slate*' }
    if ($dev2) {
        Write-Host "Device back: $($dev2.FriendlyName) [$($dev2.Status)]"
    } else {
        Write-Host "Device not re-detected yet"
    }
} else {
    Write-Host "Bamboo Slate BLE device not found in PnP"
}
