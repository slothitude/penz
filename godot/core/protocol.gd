extends RefCounted
## Message type constants for the BLE protocol.

enum MsgType {
	POINT,
	STROKE_END,
	STATUS,
	ERROR,
	CONNECTED,
	DISCONNECTED,
	PROGRESS,
	PAGES_SYNCED,
}
