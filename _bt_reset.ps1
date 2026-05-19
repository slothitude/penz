Write-Host "=== Bluetooth Devices ==="
Get-PnpDevice -Class Bluetooth | Where-Object { $_.Status -eq 'OK' } | Format-Table FriendlyName, Status, InstanceId -AutoSize

Write-Host "`n=== Trying to toggle Bluetooth radio ==="
$bt = Get-PnpDevice -Class Bluetooth | Where-Object { $_.FriendlyName -like '*Radio*' -or $_.FriendlyName -like '*Adapter*' } | Select-Object -First 1
if ($bt) {
    Write-Host "Found: $($bt.FriendlyName) ($($bt.Status))"
    Write-Host "Disabling..."
    Disable-PnpDevice -InstanceId $bt.InstanceId -Confirm:$false
    Start-Sleep -Seconds 3
    Write-Host "Enabling..."
    Enable-PnpDevice -InstanceId $bt.InstanceId -Confirm:$false
    Start-Sleep -Seconds 3
    Write-Host "Done. Status: $((Get-PnpDevice -InstanceId $bt.InstanceId).Status)"
} else {
    Write-Host "No Bluetooth radio/adapter found. Listing all Bluetooth devices:"
    Get-PnpDevice -Class Bluetooth | Format-Table FriendlyName, Status, InstanceId -AutoSize
}
