package org.penz.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.UsedByGodot

/**
 * Godot 4.6 Kotlin plugin for Wacom Bamboo Slate BLE.
 * Exposes BLE connection, auth, live mode, and data parsing to GDScript.
 */
class PenzBLEPlugin(godot: Godot) : GodotPlugin(godot) {

    private val tag = "PenzBLE"
    private val handler = Handler(Looper.getMainLooper())
    private var bleManager: BLEManager? = null
    private var deviceUuid: ByteArray = ByteArray(0)
    private var isLive = false
    private var penDown = false

    override fun getPluginName(): String = "PenzBLE"

    override fun onMainDestroy() {
        bleManager?.disconnect()
        super.onMainDestroy()
    }

    // ── Godot-exposed methods ────────────────────────────────────────

    @UsedByGodot
    fun initialize(): Boolean {
        bleManager = BLEManager(activity!!.applicationContext)
        val ok = bleManager!!.initialize()
        if (!ok) {
            emitSignal("on_connection_progress", "Bluetooth not available")
        }
        return ok
    }

    @UsedByGodot
    fun scanForDevice(namePrefix: String) {
        if (bleManager == null) initialize()

        bleManager!!.onProgress = { step ->
            handler.post { emitSignal("on_connection_progress", step) }
        }
        bleManager!!.onError = { msg ->
            handler.post { emitSignal("on_connection_progress", "Error: $msg") }
        }

        bleManager!!.scanForDevice(namePrefix) { device ->
            if (device != null) {
                handler.post { connectDevice(device.address) }
            } else {
                handler.post {
                    emitSignal("on_connection_progress", "Device not found")
                }
            }
        }
    }

    @UsedByGodot
    fun connectDevice(address: String) {
        val btAdapter = bleManager?.let {
            val mgr = activity!!.getSystemService(android.content.Context.BLUETOOTH_SERVICE)
                    as android.bluetooth.BluetoothManager
            mgr.adapter
        } ?: return

        val device = btAdapter.getRemoteDevice(address)
        setupCallbacks()
        bleManager!!.connect(device)
    }

    @UsedByGodot
    fun disconnectDevice() {
        bleManager?.disconnect()
        isLive = false
        penDown = false
    }

    @UsedByGodot
    fun authenticate(uuidHex: String) {
        deviceUuid = WacomProtocol.uuidHexToBytes(uuidHex)
        val authFrame = WacomProtocol.buildAuthFrame(deviceUuid)
        bleManager?.writeCharacteristic(
            WacomProtocol.NORDIC_TX_UUID, authFrame
        )
    }

    @UsedByGodot
    fun enterLiveMode() {
        if (bleManager == null) return

        val modeCmd = WacomProtocol.buildModeCommand(WacomProtocol.MODE_LIVE)

        // Multi-path mode switch sequence (mirrors capture.py)
        Thread {
            try {
                // Step 1: Write mode to ffee0002
                handler.post { emitSignal("on_connection_progress", "Entering live mode...") }
                bleManager?.getCharFfee2()?.let {
                    bleManager?.writeCharacteristic(WacomProtocol.CHAR_FFEE2_UUID, modeCmd)
                }
                Thread.sleep(500)

                // Step 2: Write mode to 00001532
                bleManager?.getChar1532()?.let {
                    bleManager?.writeCharacteristic(WacomProtocol.CHAR_1532_UUID, modeCmd)
                }
                Thread.sleep(500)

                // Step 3: Write mode to 00001531 + subscribe
                bleManager?.getChar1531()?.let {
                    bleManager?.writeCharacteristic(WacomProtocol.CHAR_1531_UUID, modeCmd)
                    bleManager?.subscribeToNotifications(WacomProtocol.CHAR_1531_UUID)
                }
                Thread.sleep(500)

                // Step 4: Auth via Nordic TX
                val authFrame = WacomProtocol.buildAuthFrame(deviceUuid)
                bleManager?.writeCharacteristic(WacomProtocol.NORDIC_TX_UUID, authFrame)
                Thread.sleep(2000)

                // Step 5: Mode via Nordic TX
                bleManager?.writeCharacteristic(WacomProtocol.NORDIC_TX_UUID, modeCmd)
                Thread.sleep(1000)

                handler.post {
                    emitSignal("on_connection_progress", "Live mode activated")
                    emitSignal("on_connected")
                }
                isLive = true
            } catch (e: Exception) {
                Log.e(tag, "Live mode failed", e)
                handler.post {
                    emitSignal("on_connection_progress", "Live mode failed: ${e.message}")
                }
            }
        }.start()
    }

    @UsedByGodot
    fun getBattery() {
        val cmd = WacomProtocol.buildGetBattery()
        bleManager?.writeCharacteristic(WacomProtocol.NORDIC_TX_UUID, cmd)
    }

    @UsedByGodot
    fun syncPages() {
        emitSignal("on_connection_progress", "Sync not yet implemented on Android")
    }

    // ── Internal ────────────────────────────────────────────────────

    private fun setupCallbacks() {
        bleManager!!.onConnected = {
            handler.post { emitSignal("on_connected") }
        }

        bleManager!!.onDisconnected = {
            handler.post { emitSignal("on_disconnected") }
            isLive = false
        }

        bleManager!!.onServicesDiscovered = {
            // Subscribe to Nordic RX and Live characteristic
            bleManager!!.subscribeToNotifications(WacomProtocol.NORDIC_RX_UUID)
            Handler(Looper.getMainLooper()).postDelayed({
                bleManager!!.subscribeToNotifications(WacomProtocol.LIVE_CHAR_UUID)
            }, 500)

            // Set time
            val setTimeCmd = WacomProtocol.buildSetTime()
            bleManager!!.writeCharacteristic(WacomProtocol.NORDIC_TX_UUID, setTimeCmd)

            handler.post {
                emitSignal("on_connection_progress", "Services discovered, ready for auth")
            }
        }

        bleManager!!.onNordicData = { data ->
            handler.post {
                // Parse responses (battery, mode confirmations, etc.)
                if (data.size > 2) {
                    val opcode = data[0]
                    when {
                        opcode == WacomProtocol.CMD_GET_BATTERY -> {
                            val pct = data[2].toInt() and 0xFF
                            emitSignal("on_status", pct, if (isLive) "live" else "idle")
                        }
                        opcode == WacomProtocol.CMD_SET_MODE -> {
                            Log.d(tag, "Mode response: ${data.joinToString(" ") { "%02x".format(it) }}")
                        }
                    }
                }
            }
        }

        bleManager!!.onLiveData = { data ->
            if (data.size < 2) return@onLiveData

            val op = data[0]
            when (op) {
                WacomProtocol.OP_PEN_DATA -> {
                    val (points, penUp) = WacomProtocol.parseLiveData(data)
                    handler.post {
                        for (pt in points) {
                            if (pt.pressure > 0) {
                                penDown = true
                                emitSignal("on_point", pt.x, pt.y, pt.pressure)
                            } else if (penDown) {
                                penDown = false
                                emitSignal("on_stroke_end")
                            }
                        }
                        if (penUp) {
                            penDown = false
                            emitSignal("on_stroke_end")
                        }
                    }
                }
                WacomProtocol.OP_PEN_PROXIMITY -> {
                    handler.post {
                        if (penDown) {
                            penDown = false
                            emitSignal("on_stroke_end")
                        }
                    }
                }
            }
        }
    }

    companion object {
        init {
            // Register signals
            // GodotPlugin auto-registers signals from @UsedByGodot methods
        }
    }
}
