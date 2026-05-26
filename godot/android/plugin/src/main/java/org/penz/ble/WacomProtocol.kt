package org.penz.ble

import java.util.UUID

/**
 * Wacom Bamboo Slate BLE protocol constants and helpers.
 * Reimplements the protocol from capture.py for Android BluetoothGatt.
 */
object WacomProtocol {

    // GATT Service UUIDs
    val NORDIC_SVC_UUID: UUID = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    val NORDIC_TX_UUID: UUID = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")  // write
    val NORDIC_RX_UUID: UUID = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e")  // notify
    val LIVE_SVC_UUID: UUID = UUID.fromString("00001523-1212-efde-1523-785feabcd123")
    val LIVE_CHAR_UUID: UUID = UUID.fromString("00001524-1212-efde-1523-785feabcd123")
    val SVC_1530_UUID: UUID = UUID.fromString("00001530-1212-efde-1523-785feabcd123")
    val SVC_FFEE_UUID: UUID = UUID.fromString("ffee0001-bbaa-9988-7766-554433221100")
    val CHAR_1531_UUID: UUID = UUID.fromString("00001531-1212-efde-1523-785feabcd123")
    val CHAR_1532_UUID: UUID = UUID.fromString("00001532-1212-efde-1523-785feabcd123")
    val CHAR_FFEE2_UUID: UUID = UUID.fromString("ffee0002-bbaa-9988-7766-554433221100")

    // Opcodes
    const val CMD_CHECK_AUTH: Byte = 0xE6.toByte()
    const val CMD_SET_TIME: Byte = 0xB6.toByte()
    const val CMD_GET_BATTERY: Byte = 0xB9.toByte()
    const val CMD_SET_MODE: Byte = 0xB1.toByte()

    // Modes
    const val MODE_LIVE: Byte = 0x00
    const val MODE_PAPER: Byte = 0x01
    const val MODE_IDLE: Byte = 0x02

    // Live data opcodes
    const val OP_PEN_DATA: Byte = 0xA1.toByte()
    const val OP_PEN_PROXIMITY: Byte = 0xA2.toByte()

    /**
     * Build a Nordic UART frame: [opcode, length, data...]
     */
    fun buildFrame(opcode: Byte, data: ByteArray): ByteArray {
        val frame = ByteArray(2 + data.size)
        frame[0] = opcode
        frame[1] = data.size.toByte()
        System.arraycopy(data, 0, frame, 2, data.size)
        return frame
    }

    /**
     * Build auth frame: [0xE6, uuid_length, uuid_bytes...]
     */
    fun buildAuthFrame(uuidBytes: ByteArray): ByteArray {
        return buildFrame(CMD_CHECK_AUTH, uuidBytes)
    }

    /**
     * Build mode command: [0xB1, 0x01, mode]
     */
    fun buildModeCommand(mode: Byte): ByteArray {
        return byteArrayOf(CMD_SET_MODE, 0x01, mode)
    }

    /**
     * Build set-time command with current time.
     */
    fun buildSetTime(): ByteArray {
        val now = java.util.Calendar.getInstance()
        val data = byteArrayOf(
            (now.get(java.util.Calendar.YEAR) % 100).toByte(),
            (now.get(java.util.Calendar.MONTH) + 1).toByte(),
            now.get(java.util.Calendar.DAY_OF_MONTH).toByte(),
            now.get(java.util.Calendar.HOUR_OF_DAY).toByte(),
            now.get(java.util.Calendar.MINUTE).toByte(),
            now.get(java.util.Calendar.SECOND).toByte()
        )
        return buildFrame(CMD_SET_TIME, data)
    }

    /**
     * Build get-battery command.
     */
    fun buildGetBattery(): ByteArray {
        return byteArrayOf(CMD_GET_BATTERY, 0x01, 0x00)
    }

    /**
     * Parse hex UUID string to bytes.
     */
    fun uuidHexToBytes(hex: String): ByteArray {
        val clean = hex.replace("-", "")
        val bytes = ByteArray(clean.length / 2)
        for (i in bytes.indices) {
            bytes[i] = ((Character.digit(clean[i * 2], 16) shl 4) +
                    Character.digit(clean[i * 2 + 1], 16)).toByte()
        }
        return bytes
    }

    /**
     * Parse live data from 0xA1 packets.
     * Returns list of (x, y, pressure) triples.
     */
    data class PenPoint(val x: Int, val y: Int, val pressure: Int)

    fun parseLiveData(data: ByteArray): Pair<List<PenPoint>, Boolean> {
        if (data.size < 2 || data[0] != OP_PEN_DATA) {
            return Pair(emptyList(), false)
        }

        val payload = data.copyOfRange(2, data.size)
        val points = mutableListOf<PenPoint>()
        var penUp = false

        // Check for all-0xFF (pen up)
        if (payload.size >= 6 && payload.all { it == 0xFF.toByte() }) {
            return Pair(emptyList(), true)  // pen up
        }

        // Parse 6-byte triplets: x:u16 LE, y:u16 LE, pressure:u16 LE
        var i = 0
        while (i + 5 < payload.size) {
            val x = (payload[i].toInt() and 0xFF) or ((payload[i + 1].toInt() and 0xFF) shl 8)
            val y = (payload[i + 2].toInt() and 0xFF) or ((payload[i + 3].toInt() and 0xFF) shl 8)
            val p = (payload[i + 4].toInt() and 0xFF) or ((payload[i + 5].toInt() and 0xFF) shl 8)
            points.add(PenPoint(x, y, p))
            i += 6
        }

        return Pair(points, penUp)
    }
}
