extends Node
class_name P12Net

const PORT : int = 24567
var db : ItemDatabase
var logic : HostLogic
var accepted : Dictionary = {}   # host: peer_id -> true
var replicas : Dictionary = {}   # client: owner_id -> Inventory (อ่านอย่างเดียว)
var _resyncs : int = 0
signal replicas_changed
signal result_received(res : Dictionary)

func _log(s : String) -> void:
	print("[%s] %s" % ["HOST" if multiplayer.is_server() else "CLIENT %d" % multiplayer.get_unique_id(), s])

static func db_sig(d : ItemDatabase) -> String:
	var ids : Array = d._items.keys().map(func(k): return String(k))
	ids.sort()
	return "%d:%s" % [ids.size(), "|".join(ids).sha256_text()]

func _new_inv(o : String) -> Inventory:
	var inv := Inventory.new()
	inv.owner_id = o
	return inv

func _snapshot() -> Dictionary:
	var d : Dictionary = {}
	for o in logic.invs:
		d[o] = logic.invs[o].to_dict()
	return d

# ---------- host ----------
func start_host() -> void:
	logic = HostLogic.new()
	logic.db = db
	logic.invs[HostLogic.SHARED_ID] = _new_inv(HostLogic.SHARED_ID)
	var p := ENetMultiplayerPeer.new()
	p.create_server(PORT, 4)
	multiplayer.multiplayer_peer = p
	multiplayer.peer_disconnected.connect(func(id): accepted.erase(id); _log("peer %d left" % id))
	_log("listening on %d, db_sig=%s" % [PORT, db_sig(db)])

func _reject(id : int, why : String) -> void:
	_log("reject %d: %s" % [id, why])
	cli_rejected.rpc_id(id, why)
	get_tree().create_timer(0.3).timeout.connect(func():
		if multiplayer.get_peers().has(id):
			multiplayer.multiplayer_peer.disconnect_peer(id))

@rpc("any_peer", "call_remote", "reliable")
func hs_hello(pv : int, sig : String) -> void:
	if not multiplayer.is_server():
		return
	var id : int = multiplayer.get_remote_sender_id()
	if pv != HostLogic.PROTOCOL_VERSION:
		_reject(id, "bad_protocol")
		return
	if sig != db_sig(db):
		_reject(id, "db_mismatch")
		return
	var o : String = "player_%d" % id
	if not logic.invs.has(o):
		logic.invs[o] = _new_inv(o)
	accepted[id] = true
	_log("accepted %d" % id)
	cli_full.rpc_id(id, _snapshot())

@rpc("any_peer", "call_remote", "reliable")
func srv_resync() -> void:
	var id : int = multiplayer.get_remote_sender_id()
	if multiplayer.is_server() and accepted.has(id):
		cli_full.rpc_id(id, _snapshot())

# ---------- client ----------
func start_client(addr : String) -> void:
	var p := ENetMultiplayerPeer.new()
	p.create_client(addr, PORT)
	multiplayer.multiplayer_peer = p
	multiplayer.connected_to_server.connect(func():
		_log("connected, sending hello")
		hs_hello.rpc_id(1, HostLogic.PROTOCOL_VERSION, db_sig(db)))
	multiplayer.server_disconnected.connect(func(): _log("lost host"))

@rpc("authority", "call_remote", "reliable")
func cli_rejected(why : String) -> void:
	_log("REJECTED by host: " + why)

@rpc("authority", "call_remote", "reliable")
func cli_full(snap : Dictionary) -> void:
	_apply(snap, true)

# ตัวนี้ใช้ต่อในก้อนที่ 2 (ส่ง changed หลัง op)
@rpc("authority", "call_remote", "reliable")
func cli_delta(changed : Dictionary) -> void:
	_apply(changed, false)

func _apply(d : Dictionary, full : bool) -> void:
	var fresh : Dictionary = {}
	for o in d:
		var r : Dictionary = Inventory.from_dict(d[o], db)
		if not r["ok"]:
			_log("from_dict ล้ม %s: %s" % [o, r["reason"]])
			if _resyncs < 3:
				_resyncs += 1
				srv_resync.rpc_id(1)
			return
		fresh[o] = r["inventory"]
	if full:
		replicas = fresh
	else:
		replicas.merge(fresh, true)
	_log("synced %s: %s" % ["full" if full else "delta", str(fresh.keys())])
	replicas_changed.emit()
