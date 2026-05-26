package org.penz.ble

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.UUID

/**
 * Manages Android BLE connection to Wacom Bamboo Slate.
 * Handles scanning, GATT connection, service discovery, and characteristic ops.
 */
class BLEManager(private val context: Context) {

    private val tag = "PenzBLE"
    private val handler = Handler(Looper.getMainLooper())

    private var bluetoothManager: BluetoothManager? = null
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var scanner: BluetoothLeScanner? = null
    private var gatt: BluetoothGatt? = null

    // Characteristics
    private var nordicTx: BluetoothGattCharacteristic? = null
    private var nordicRx: BluetoothGattCharacteristic? = null
    private var liveChar: BluetoothGattCharacteristic? = null
    private var char1531: BluetoothGattCharacteristic? = null
    private var char1532: BluetoothGattCharacteristic? = null
    private var charFfee2: BluetoothGattCharacteristic? = null

    var onConnected: (() -> Unit)? = null
    var onDisconnected: (() -> Unit)? = null
    var onProgress: ((String) -> Unit)? = null
    var onError: ((String) -> Unit)? = null
    var onNordicData: ((ByteArray) -> Unit)? = null
    var onLiveData: ((ByteArray) -> Unit)? = null
    var onServicesDiscovered: (() -> Unit)? = null

    fun initialize(): Boolean {
        bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter
        if (bluetoothAdapter == null || !bluetoothAdapter!!.isEnabled) {
            Log.e(tag, "Bluetooth not available or not enabled")
            return false
        }
        scanner = bluetoothAdapter?.bluetoothLeScanner
        return scanner != null
    }

    fun scanForDevice(namePrefix: String, callback: (BluetoothDevice?) -> Unit) {
        onProgress?.invoke("Scanning for device...")
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        val filters = listOf<ScanFilter>()  // No filter — check name manually

        val scanCb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val device = result.device
                val name = device.name ?: ""
                if (name.contains(namePrefix, ignoreCase = true)) {
                    scanner?.stopScan(this)
                    onProgress?.invoke("Found: ${device.name} (${device.address})")
                    callback(device)
                }
            }

            override fun onScanFailed(errorCode: Int) {
                Log.e(tag, "Scan failed: $errorCode")
                onError?.invoke("Scan failed: $errorCode")
                callback(null)
            }
        }

        scanner?.startScan(filters, settings, scanCb)

        // Timeout after 15s
        handler.postDelayed({
            scanner?.stopScan(scanCb)
            callback(null)
        }, 15000)
    }

    @SuppressLint("MissingPermission")
    fun connect(device: BluetoothDevice) {
        onProgress?.invoke("Connecting to ${device.name}...")
        gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    @SuppressLint("MissingPermission")
    fun disconnect() {
        gatt?.disconnect()
        gatt?.close()
        gatt = null
        clearCharacteristics()
    }

    @SuppressLint("MissingPermission")
    fun writeCharacteristic(uuid: UUID, data: ByteArray) {
        val char = findCharacteristic(uuid) ?: return
        char.value = data
        char.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        gatt?.writeCharacteristic(char)
    }

    @SuppressLint("MissingPermission")
    fun subscribeToNotifications(uuid: UUID) {
        val char = findCharacteristic(uuid) ?: return
        gatt?.setCharacteristicNotification(char, true)
        val descriptor = char.getDescriptor(UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"))
        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        gatt?.writeDescriptor(descriptor)
    }

    fun getNordicTx(): BluetoothGattCharacteristic? = nordicTx
    fun getNordicRx(): BluetoothGattCharacteristic? = nordicRx
    fun getLiveChar(): BluetoothGattCharacteristic? = liveChar
    fun getChar1531(): BluetoothGattCharacteristic? = char1531
    fun getChar1532(): BluetoothGattCharacteristic? = char1532
    fun getCharFfee2(): BluetoothGattCharacteristic? = charFfee2

    // ── Private ──────────────────────────────────────────────────────

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    onProgress?.invoke("Connected, discovering services...")
                    gatt.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    onDisconnected?.invoke()
                    clearCharacteristics()
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                cacheCharacteristics(gatt)
                onServicesDiscovered?.invoke()
            } else {
                onError?.invoke("Service discovery failed: $status")
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            val uuid = characteristic.uuid
            val value = characteristic.value ?: return

            when (uuid) {
                WacomProtocol.NORDIC_RX_UUID -> onNordicData?.invoke(value)
                WacomProtocol.LIVE_CHAR_UUID -> onLiveData?.invoke(value)
                WacomProtocol.CHAR_1531_UUID -> onNordicData?.invoke(value)
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(tag, "Write failed to ${characteristic.uuid}: $status")
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun cacheCharacteristics(gatt: BluetoothGatt) {
        for (service in gatt.services) {
            for (char in service.characteristics) {
                when (char.uuid) {
                    WacomProtocol.NORDIC_TX_UUID -> nordicTx = char
                    WacomProtocol.NORDIC_RX_UUID -> nordicRx = char
                    WacomProtocol.LIVE_CHAR_UUID -> liveChar = char
                    WacomProtocol.CHAR_1531_UUID -> char1531 = char
                    WacomProtocol.CHAR_1532_UUID -> char1532 = char
                    WacomProtocol.CHAR_FFEE2_UUID -> charFfee2 = char
                }
            }
        }
    }

    private fun findCharacteristic(uuid: UUID): BluetoothGattCharacteristic? {
        return when (uuid) {
            WacomProtocol.NORDIC_TX_UUID -> nordicTx
            WacomProtocol.NORDIC_RX_UUID -> nordicRx
            WacomProtocol.LIVE_CHAR_UUID -> liveChar
            WacomProtocol.CHAR_1531_UUID -> char1531
            WacomProtocol.CHAR_1532_UUID -> char1532
            WacomProtocol.CHAR_FFEE2_UUID -> charFfee2
            else -> null
        }
    }

    private fun clearCharacteristics() {
        nordicTx = null
        nordicRx = null
        liveChar = null
        char1531 = null
        char1532 = null
        charFfee2 = null
    }
}
