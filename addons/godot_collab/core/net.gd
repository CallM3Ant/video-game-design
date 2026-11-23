@tool
extends RefCounted
## Framed TCP transport for the LAN session: one host accepts many clients. Messages are
## Dictionaries sent as [u32 length][var_to_bytes(message)]. Decoding never instantiates objects.
##
## The host side knows peers by id (>= 2); a client has a single connection to the host.
## Large transfers use the low-priority lane so live edits never queue behind them.

const Log := preload("res://addons/godot_collab/core/log.gd")

signal state_changed(state: String)
signal peer_connected(pid: int)
signal peer_closed(pid: int, reason: String)
signal message(pid: int, msg: Dictionary)

const MAX_MESSAGE_BYTES := 24 * 1024 * 1024
const READ_PER_POLL := 1024 * 1024
const WRITE_PER_POLL := 1024 * 1024
const PING_INTERVAL_MS := 3000
const DEAD_AFTER_MS := 15000
const CONNECT_TIMEOUT_MS := 8000
const BACKOFF_MS := [500, 1000, 2000, 4000, 8000]
const HOST_PID := 1


class Conn:
	extends RefCounted
	var pid := 0
	var stream: StreamPeerTCP
	var inbuf := PackedByteArray()
	var outbuf := PackedByteArray()
	var hi: Array = []
	var lo: Array = []
	var authorized := false
	var last_recv := 0
	var last_send := 0
	var opened := 0
	var close_when_flushed := false
	var info := {}
	var nonce := ""


var state := "offline"
var _server: TCPServer = null
var _conns: Dictionary = {}
var _next_pid := 2
var _client: Conn = null
var _address := ""
var _port := 0
var _auto_reconnect := false
var _attempt := 0
var _reconnect_at := 0
var _bytes_in := 0
var _bytes_out := 0


func is_hosting() -> bool:
	return _server != null


func stats() -> Dictionary:
	return {"in": _bytes_in, "out": _bytes_out}


func _set_state(s: String) -> void:
	if state != s:
		state = s
		state_changed.emit(s)


# --- host -----------------------------------------------------------------------------------------

func start_host(port: int) -> Error:
	stop()
	var server := TCPServer.new()
	var err := server.listen(port)
	if err != OK:
		Log.error("net", "Could not listen on port %d: %s" % [port, error_string(err)])
		return err
	_server = server
	_next_pid = 2
	_set_state("hosting")
	Log.info("net", "Hosting on port %d" % port)
	return OK


func peer_ids() -> Array:
	return _conns.keys()


func peer_info(pid: int) -> Dictionary:
	var c: Conn = _conns.get(pid)
	return c.info if c != null else {}


func set_peer_info(pid: int, info: Dictionary) -> void:
	var c: Conn = _conns.get(pid)
	if c != null:
		c.info = info


func peer_nonce(pid: int) -> String:
	var c: Conn = _conns.get(pid)
	return c.nonce if c != null else ""


func peer_address(pid: int) -> String:
	var c: Conn = _conns.get(pid)
	if c == null or c.stream == null:
		return ""
	return "%s:%d" % [c.stream.get_connected_host(), c.stream.get_connected_port()]


func authorize(pid: int) -> void:
	var c: Conn = _conns.get(pid)
	if c != null:
		c.authorized = true


func is_authorized(pid: int) -> bool:
	var c: Conn = _conns.get(pid)
	return c != null and c.authorized


func close_peer(pid: int, reason: String, flush_first: bool = true) -> void:
	var c: Conn = _conns.get(pid)
	if c == null:
		return
	if flush_first:
		c.close_when_flushed = true
		return
	_drop_peer(pid, reason)


func _drop_peer(pid: int, reason: String) -> void:
	var c: Conn = _conns.get(pid)
	if c == null:
		return
	_conns.erase(pid)
	if c.stream != null:
		c.stream.disconnect_from_host()
	Log.info("net", "Peer %d disconnected (%s)" % [pid, reason])
	peer_closed.emit(pid, reason)


# --- client ---------------------------------------------------------------------------------------

func connect_to(address: String, port: int, auto_reconnect: bool = true) -> Error:
	stop()
	_address = address.strip_edges()
	_port = port
	_auto_reconnect = auto_reconnect
	_attempt = 0
	return _open_client()


func _open_client() -> Error:
	var stream := StreamPeerTCP.new()
	var err := stream.connect_to_host(_address, _port)
	if err != OK:
		Log.warn("net", "Could not start connecting to %s:%d: %s" % [_address, _port, error_string(err)])
		_schedule_reconnect("connect error")
		return err
	var c := Conn.new()
	c.pid = HOST_PID
	c.stream = stream
	c.opened = Time.get_ticks_msec()
	c.last_recv = c.opened
	c.last_send = c.opened
	_client = c
	_set_state("connecting")
	Log.info("net", "Connecting to %s:%d ..." % [_address, _port])
	return OK


## Called by the session once the host accepted us, so the next outage backs off from the start.
func mark_connected() -> void:
	_attempt = 0
	_set_state("connected")


func _schedule_reconnect(reason: String) -> void:
	if _client != null:
		if _client.stream != null:
			_client.stream.disconnect_from_host()
		_client = null
	if not _auto_reconnect:
		_set_state("offline")
		return
	var delay: int = BACKOFF_MS[mini(_attempt, BACKOFF_MS.size() - 1)]
	_attempt += 1
	_reconnect_at = Time.get_ticks_msec() + delay
	_set_state("reconnecting")
	Log.info("net", "Connection lost (%s). Retrying in %.1fs" % [reason, delay / 1000.0])
	peer_closed.emit(HOST_PID, reason)


func stop() -> void:
	if _server != null:
		_server.stop()
		_server = null
	for pid in _conns.keys():
		var c: Conn = _conns[pid]
		if c.stream != null:
			c.stream.disconnect_from_host()
	_conns.clear()
	if _client != null:
		if _client.stream != null:
			_client.stream.disconnect_from_host()
		_client = null
	_auto_reconnect = false
	_set_state("offline")


## Sends one final control message before closing TCP sockets. Pending collaboration edits are
## discarded on process shutdown; the last frame only flushes this small disconnect notice.
func graceful_stop(final_message: Dictionary = {}) -> void:
	if _server != null:
		_server.stop()
		_server = null
		for pid in _conns:
			var c: Conn = _conns[pid]
			c.outbuf.clear()
			c.hi.clear()
			c.lo.clear()
			if not final_message.is_empty() and c.authorized:
				_queue(c, final_message, false)
			c.close_when_flushed = true
		for attempt in 40:
			if _conns.is_empty():
				break
			_poll_server()
			OS.delay_msec(2)
	elif _client != null:
		var c: Conn = _client
		if c.stream.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			c.outbuf.clear()
			c.hi.clear()
			c.lo.clear()
			if not final_message.is_empty():
				_queue(c, final_message, false)
			for attempt in 20:
				var reason := _pump(c)
				if not reason.is_empty() or c.outbuf.is_empty() and c.hi.is_empty():
					break
				OS.delay_msec(2)
	stop()


func has_client_link() -> bool:
	return _client != null and _client.stream.get_status() == StreamPeerTCP.STATUS_CONNECTED


# --- sending --------------------------------------------------------------------------------------

func _encode(msg: Dictionary) -> PackedByteArray:
	var payload := var_to_bytes(msg)
	var framed := PackedByteArray()
	framed.resize(4)
	framed.encode_u32(0, payload.size())
	framed.append_array(payload)
	return framed


func send_to(pid: int, msg: Dictionary, low_priority: bool = false) -> bool:
	var c: Conn = _conns.get(pid)
	if c == null:
		return false
	return _queue(c, msg, low_priority)


func send_to_host(msg: Dictionary, low_priority: bool = false) -> bool:
	if _client == null:
		return false
	return _queue(_client, msg, low_priority)


func broadcast(msg: Dictionary, except_pid: int = -1, low_priority: bool = false) -> void:
	if _conns.is_empty():
		return
	var framed := _encode(msg)
	for pid in _conns:
		var c: Conn = _conns[pid]
		if pid == except_pid or not c.authorized:
			continue
		if low_priority:
			c.lo.append(framed)
		else:
			c.hi.append(framed)


func _queue(c: Conn, msg: Dictionary, low_priority: bool) -> bool:
	var framed := _encode(msg)
	if framed.size() > MAX_MESSAGE_BYTES:
		Log.error("net", "Refusing to send a %s message of %s (limit %s)" % [str(msg.get("t", "?")), String.humanize_size(framed.size()), String.humanize_size(MAX_MESSAGE_BYTES)])
		return false
	if low_priority:
		c.lo.append(framed)
	else:
		c.hi.append(framed)
	return true


func queued_low_priority(pid: int = -1) -> int:
	var c: Conn = _client if pid < 0 else _conns.get(pid)
	return c.lo.size() if c != null else 0


# --- polling --------------------------------------------------------------------------------------

func poll() -> void:
	if _server != null:
		_poll_server()
	elif _client != null:
		_poll_client()
	elif _auto_reconnect and state == "reconnecting" and Time.get_ticks_msec() >= _reconnect_at:
		_open_client()


func _poll_server() -> void:
	while _server != null and _server.is_connection_available():
		var stream := _server.take_connection()
		if stream == null:
			break
		stream.set_no_delay(true)
		var c := Conn.new()
		c.pid = _next_pid
		_next_pid += 1
		c.stream = stream
		c.opened = Time.get_ticks_msec()
		c.last_recv = c.opened
		c.last_send = c.opened
		c.nonce = "%x%x" % [randi(), Time.get_ticks_usec()]
		_conns[c.pid] = c
		Log.info("net", "Peer %d connected from %s:%d" % [c.pid, stream.get_connected_host(), stream.get_connected_port()])
		peer_connected.emit(c.pid)
	for pid in _conns.keys():
		var c: Conn = _conns.get(pid)
		if c == null:
			continue
		var reason := _pump(c)
		if not reason.is_empty():
			_drop_peer(pid, reason)


func _poll_client() -> void:
	var c := _client
	c.stream.poll()
	var status := c.stream.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTING:
		if Time.get_ticks_msec() - c.opened > CONNECT_TIMEOUT_MS:
			_schedule_reconnect("connect timeout")
		return
	if status != StreamPeerTCP.STATUS_CONNECTED:
		_schedule_reconnect("socket closed")
		return
	if state == "connecting":
		c.last_recv = Time.get_ticks_msec()
		c.stream.set_no_delay(true)
		_set_state("connected")
		Log.info("net", "TCP connected to %s:%d" % [_address, _port])
		peer_connected.emit(HOST_PID)
		if _client != c:
			return
	var reason := _pump(c)
	if not reason.is_empty() and _client == c:
		_schedule_reconnect(reason)


## Reads, dispatches and writes for one connection. Returns a reason string when it must be closed.
func _pump(c: Conn) -> String:
	c.stream.poll()
	var status := c.stream.get_status()
	if status != StreamPeerTCP.STATUS_CONNECTED:
		return "socket closed"
	var now := Time.get_ticks_msec()
	var available := mini(c.stream.get_available_bytes(), READ_PER_POLL)
	if available > 0:
		var res := c.stream.get_partial_data(available)
		if res[0] != OK and res[0] != ERR_BUSY:
			return "read error"
		var data: PackedByteArray = res[1]
		_bytes_in += data.size()
		c.inbuf.append_array(data)
		c.last_recv = now
	var consumed := 0
	var inbuf := c.inbuf
	while inbuf.size() - consumed >= 4:
		var len := inbuf.decode_u32(consumed)
		if len > MAX_MESSAGE_BYTES:
			return "oversized message (%d bytes)" % len
		if inbuf.size() - consumed - 4 < len:
			break
		var payload := inbuf.slice(consumed + 4, consumed + 4 + len)
		consumed += 4 + len
		var decoded: Variant = bytes_to_var(payload)
		if not decoded is Dictionary or not decoded.get("t") is String:
			return "malformed message"
		var msg: Dictionary = decoded
		var t: String = msg["t"]
		if t == "_ping":
			_queue(c, {"t": "_pong"}, false)
		elif t == "_pong":
			pass
		else:
			message.emit(c.pid, msg)
			if c.stream == null or (_client == null and not _conns.has(c.pid)):
				return "closed by handler"
	if consumed > 0:
		c.inbuf = inbuf.slice(consumed)
	if now - c.last_recv > DEAD_AFTER_MS:
		return "no data for %ds" % (DEAD_AFTER_MS / 1000)
	if now - c.last_send > PING_INTERVAL_MS and c.hi.is_empty() and c.outbuf.is_empty():
		_queue(c, {"t": "_ping"}, false)
	if c.outbuf.is_empty():
		if not c.hi.is_empty():
			c.outbuf = c.hi.pop_front()
		elif not c.lo.is_empty():
			c.outbuf = c.lo.pop_front()
	var budget := WRITE_PER_POLL
	while not c.outbuf.is_empty() and budget > 0:
		var w := c.stream.put_partial_data(c.outbuf)
		if w[0] != OK and w[0] != ERR_BUSY:
			return "write error"
		var sent: int = w[1]
		if sent <= 0:
			break
		_bytes_out += sent
		budget -= sent
		c.last_send = now
		c.outbuf = c.outbuf.slice(sent) if sent < c.outbuf.size() else PackedByteArray()
		if c.outbuf.is_empty():
			if not c.hi.is_empty():
				c.outbuf = c.hi.pop_front()
			elif not c.lo.is_empty() and budget > 0 and c.hi.is_empty():
				c.outbuf = c.lo.pop_front()
	if c.close_when_flushed and c.outbuf.is_empty() and c.hi.is_empty():
		return "closed"
	return ""
