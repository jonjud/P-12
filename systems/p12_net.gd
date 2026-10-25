extends Node
class_name P12Net

const PORT : int = 24567
var db : ItemDatabase
var logic : HostLogic
var accepted : Dictionary = {}   # host: peer_id -> true
var replicas : Dictionary = {}   # client: owner_id -> Inventory (อ่านอย่างเดียว)
var _resyncs : int = 0
var hello_pv : int = HostLogic.PROTOCOL_VERSION
var _rid : int = 0
var quiet : bool = false
signal replicas_changed
signal result_received(res : Dictionary)

var _exp : Dictionary = {}
var _reqs : int = 0
var _inv_fail : int = 0
var _max_delta : int = 0
var _last : int = 0
var _switches : int = 0

func _log(s : String) -> void:
	print("[%s] %s" % ["HOST" if multiplayer.is_server() else "CLIENT %d" % multiplayer.get_unique_id(), s])

static func state_hash(d : Dictionary) -> String:    # d: owner_id -> Inventory
	var o : Dictionary = {}
	for k in d:
		o[k] = d[k].to_dict()
	return JSON.stringify(o, "", true).sha256_text().left(12)

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
	for p in accepted:    # คนเก่าต้องรู้จัก Inventory ของคนใหม่
		if p != id:
			cli_delta.rpc_id(p, {o: logic.invs[o].to_dict()})

@rpc("any_peer", "call_remote", "reliable")
func srv_resync() -> void:
	var id : int = multiplayer.get_remote_sender_id()
	if multiplayer.is_server() and accepted.has(id):
		cli_full.rpc_id(id, _snapshot())

func _check(id : int, req : Dictionary, res : Dictionary) -> void:
	_reqs += 1
	if id != _last:
		_switches += 1
		_last = id
	var it : String = str(req.get("item"))
	if res["accepted"]:
		var r : Dictionary = res["result"]
		if req["op"] == "add": _exp[it] = _exp.get(it, 0) + r["done"]
		elif req["op"] == "remove": _exp[it] = _exp.get(it, 0) - r["done"]
	var t : int = 0
	for o in logic.invs: t += logic.invs[o].count_of(StringName(it))
	if t != _exp.get(it, 0):
		_inv_fail += 1
		_log("INVARIANT FAIL item=%s total=%d expected=%d" % [it, t, _exp.get(it, 0)])
	_max_delta = maxi(_max_delta, var_to_bytes(res["changed"]).size())
	if _reqs % 500 == 0:
		_summary()

func _on_left(id : int) -> void:
	accepted.erase(id)
	_log("peer %d left | reqs=%d invariant_fail=%d switches=%d max_delta=%dB full_snapshot=%dB" % [id, _reqs, _inv_fail, _switches, _max_delta, var_to_bytes(_snapshot()).size()])

# ---------- client ----------
func start_client(addr : String) -> void:
	var p := ENetMultiplayerPeer.new()
	p.create_client(addr, PORT)
	multiplayer.multiplayer_peer = p
	multiplayer.connected_to_server.connect(func():
		_log("connected, sending hello")
		hs_hello.rpc_id(1, hello_pv, db_sig(db)))
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
	if not quiet:
		_log("synced %s: %s" % ["full" if full else "delta", str(fresh.keys())])
	replicas_changed.emit()

@rpc("any_peer", "call_remote", "reliable")
func srv_request(req : Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var id : int = multiplayer.get_remote_sender_id()
	if not accepted.has(id):
		return
	var res : Dictionary = logic.host_handle(id, req)
	_check(id, req, res)
	var r = res["result"]
	if not quiet:
		_log("req %d rid=%s %s x%s -> acc=%s net=%s reason=%s done=%s" % [id, req.get("rid"), req.get("op"), req.get("qty"), res["accepted"], res["net_reason"], r["reason"] if r else "-", r["done"] if r else "-"])
	if not res["changed"].is_empty():
		for p in accepted:
			cli_delta.rpc_id(p, res["changed"])
	res["h"] = state_hash(logic.invs)
	cli_result.rpc_id(id, res)

@rpc("authority", "call_remote", "reliable")
func cli_result(res : Dictionary) -> void:
	result_received.emit(res)

func send_raw(req : Dictionary) -> void:
	srv_request.rpc_id(1, req)

func send_request(op : String, item : StringName, qty : int, src : String = "", dst : String = "") -> int:
	_rid += 1
	send_raw({"pv": HostLogic.PROTOCOL_VERSION, "rid": _rid, "op": op, "item": String(item), "qty": qty, "src": src, "dst": dst})
	return _rid

func _go(op : String, item : StringName, qty : int, src : String = "", dst : String = "") -> Dictionary:
	var rid : int = send_request(op, item, qty, src, dst)
	var r : Dictionary = await result_received
	while r["rid"] != rid:
		r = await result_received
	return r

func _show(n : String, r : Dictionary) -> void:
	var res = r.get("result")
	var m : String = "MATCH" if r.get("h", "") == state_hash(replicas) else "DIVERGE"
	_log("%s -> acc=%s net=%s ok=%s reason=%s done=%s hash=%s" % [n, r["accepted"], r["net_reason"], res["ok"] if res else "-", res["reason"] if res else "-", res["done"] if res else "-", m])

func _first_item() -> StringName:
	var ids : Array = db._items.keys()
	ids.sort()
	return ids[0]

func run_full() -> void:    # partial add + ปลายทางเต็มพอดี (host สดใหม่ shared ต้องว่าง)
	var me : String = "player_%d" % multiplayer.get_unique_id()
	var it : StringName = _first_item()
	_show("A add 100000 (partial)", await _go("add", it, 100000, "", me))
	_show("B transfer 2 -> shared", await _go("transfer", it, 2, me, "shared_01"))
	var rest : int = replicas[me].count_of(it)
	_show("C transfer ที่เหลือ %d -> shared (เต็มพอดี)" % rest, await _go("transfer", it, rest, me, "shared_01"))
	_show("D add 5", await _go("add", it, 5, "", me))
	_show("E transfer 5 -> shared (เต็มแล้ว)", await _go("transfer", it, 5, me, "shared_01"))

func run_fuzz(n : int = 500) -> void:    # รัน 2 client พร้อมกัน; เริ่มเมื่อเห็นครบ 3 Inventory
	while replicas.size() < 3:
		await replicas_changed
	var me : String = "player_%d" % multiplayer.get_unique_id()
	var it : StringName = _first_item()
	var owners : Array = [HostLogic.SHARED_ID, me]
	for o in replicas:
		if o != me and o != HostLogic.SHARED_ID:
			owners.append(o)
	var rng := RandomNumberGenerator.new()
	rng.seed = multiplayer.get_unique_id()
	var st : Dictionary = {"pend": {}, "match": 0, "div": 0, "internal": 0, "denied": 0}
	var cb : Callable = func(r : Dictionary) -> void:
		if not st["pend"].erase(r["rid"]):
			return
		st["match" if r.get("h", "") == state_hash(replicas) else "div"] += 1
		if str(r["net_reason"]) == "denied":
			st["denied"] += 1
		if r["result"] and str(r["result"]["reason"]) == str(OpResult.INTERNAL):
			st["internal"] += 1
	result_received.connect(cb)
	for i in n:
		var op : String = ["add", "remove", "transfer"][rng.randi() % 3]
		var rid : int = send_request(op, it, rng.randi_range(-1, 60), owners[rng.randi() % owners.size()], owners[rng.randi() % owners.size()])
		st["pend"][rid] = true
		if i % 5 == 0:
			await get_tree().process_frame
	var w : int = 0
	while not st["pend"].is_empty() and w < 600:
		w += 1
		await get_tree().process_frame
	result_received.disconnect(cb)
	_log("FUZZ n=%d match=%d diverge=%d denied=%d internal=%d pending=%d" % [n, st["match"], st["div"], st["denied"], st["internal"], st["pend"].size()])

func run_rtt() -> void:
	var me : String = "player_%d" % multiplayer.get_unique_id()
	var it : StringName = _first_item()
	var t0 : int = Time.get_ticks_usec()
	for i in 100:
		await _go("remove", it, 0, me)
	_log("RTT avg = %.2f ms (100 ครั้ง, localhost)" % ((Time.get_ticks_usec() - t0) / 100000.0))

func run_dc() -> void:    # ส่ง transfer แล้วตัดการเชื่อมต่อทันที
	var me : String = "player_%d" % multiplayer.get_unique_id()
	var it : StringName = _first_item()
	await _go("add", it, 10, "", me)
	_log("DC: ส่ง transfer 4 แล้วตัด, id=" + me)
	send_request("transfer", it, 4, me, "shared_01")
	multiplayer.multiplayer_peer.close()

func run_show() -> void:
	var it : StringName = _first_item()
	for o in replicas:
		_log("SHOW %s %s=%d" % [o, it, replicas[o].count_of(it)])

func run_scenario() -> void:
	var me : String = "player_%d" % multiplayer.get_unique_id()
	var ids : Array = db._items.keys()
	ids.sort()
	var it : StringName = ids[0]
	_log("scenario item=" + String(it))
	_show("1 add 10", await _go("add", it, 10, "", me))
	_show("2 transfer 4 -> shared", await _go("transfer", it, 4, me, "shared_01"))
	_show("3 remove 99 (เกินที่มี)", await _go("remove", it, 99, me))
	_show("4 ดึงจาก player_9 (ไม่มีสิทธิ์)", await _go("transfer", it, 1, "player_9", me))
	_show("5 qty 0", await _go("remove", it, 0, me))
	_show("6 item ปลอม", await _go("remove", &"no_such_item", 1, me))
	_show("7 remove 3", await _go("remove", it, 3, me))
	var dup : Dictionary = {"pv": 1, "rid": 9001, "op": "remove", "item": String(it), "qty": 1, "src": me, "dst": ""}
	send_raw(dup)
	var a : Dictionary = await result_received
	_show("8a rid 9001 ครั้งแรก", a)
	send_raw(dup)
	_show("8b rid 9001 ซ้ำ", await result_received)
	var t : int = 0
	for o in replicas:
		t += replicas[o].count_of(it)
	_log("TOTAL ในสำเนา = %d (คาดไว้ 6 = 10 - 3 - 1)" % t)
func _summary() -> void:
	_log("SUMMARY reqs=%d invariant_fail=%d switches=%d max_delta=%dB full_snapshot=%dB" % [_reqs, _inv_fail, _switches, _max_delta, var_to_bytes(_snapshot()).size()])
