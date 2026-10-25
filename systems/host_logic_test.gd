extends Node
const W := &"wood_00"
var h : HostLogic
var fails : int = 0
var _rid : int = 0

func _t(n : String, c : bool) -> void:
	if not c:
		fails += 1
		print("FAIL ", n)

func _fresh(shared_slots : int = 20) -> void:
	h = HostLogic.new()
	h.db = ItemDatabase.new()
	h.db.load_from_directory("res://data/")
	for o in ["player_2", "player_3", "shared_01"]:
		var inv := Inventory.new()
		inv.owner_id = o
		inv.max_slots = shared_slots if o == "shared_01" else 20
		h.invs[o] = inv

func _r(op : String, item : StringName, q : int, src : String = "", dst : String = "") -> Dictionary:
	_rid += 1
	return {"pv": 1, "rid": _rid, "op": op, "item": String(item), "qty": q, "src": src, "dst": dst}

func _snap() -> Dictionary:
	var d : Dictionary = {}
	for o in h.invs: d[o] = h.invs[o].to_dict()
	return d

func _tot(id : StringName) -> int:
	var t : int = 0
	for o in h.invs: t += h.invs[o].count_of(id)
	return t

func _ready() -> void:
	_fresh()
	var r := h.host_handle(2, _r("add", W, 5, "", "player_2"))
	_t("add ok", r["accepted"] and r["result"]["ok"] and r["result"]["done"] == 5 and r["changed"].has("player_2"))
	var before := _snap()
	r = h.host_handle(2, _r("remove", W, 99, "player_2"))
	_t("remove เกินที่มี", r["result"]["reason"] == OpResult.NOT_ENOUGH and _snap() == before)
	r = h.host_handle(2, _r("transfer", W, 3, "player_2", "shared_01"))
	_t("transfer ok", r["result"]["ok"] and _tot(W) == 5 and h.invs["shared_01"].count_of(W) == 3)
	var dup := _r("remove", W, 1, "player_2")
	h.host_handle(2, dup)
	before = _snap()
	r = h.host_handle(2, dup)
	_t("rid ซ้ำ", not r["accepted"] and r["net_reason"] == &"duplicate_request" and _snap() == before)
	r = h.host_handle(2, _r("remove", W, 0, "player_2"))
	_t("qty 0", r["result"]["reason"] == OpResult.INVALID_QUANTITY)
	r = h.host_handle(2, _r("remove", &"no_such_item", 1, "player_2"))
	_t("item ปลอม", r["result"]["reason"] == OpResult.UNKNOWN_ITEM)
	before = _snap()
	r = h.host_handle(2, _r("remove", W, 1, "player_3"))
	_t("แตะของคนอื่น", r["net_reason"] == &"denied" and _snap() == before)
	r = h.host_handle(2, _r("transfer", W, 1, "player_3", "player_2"))
	_t("ดึงจากคนอื่น", r["net_reason"] == &"denied" and _snap() == before)
	var bad := _r("add", W, 1, "", "player_2")
	bad["pv"] = 99
	_t("protocol ไม่ตรง", h.host_handle(2, bad)["net_reason"] == &"bad_protocol")
	bad = _r("add", W, 1, "", "player_2")
	bad["qty"] = 1.0
	_t("qty เป็น float", h.host_handle(2, bad)["net_reason"] == &"bad_request")
	_fresh(1)
	h.invs["shared_01"].add_to_existing_stacks(h.db, W, 1)
	h.invs["player_2"].add_to_existing_stacks(h.db, W, 500)
	before = _snap()
	r = h.host_handle(2, _r("transfer", W, 500, "player_2", "shared_01"))
	_t("ปลายทางเต็ม", r["result"]["reason"] == OpResult.DESTINATION_FULL and _snap() == before)
	_fuzz()
	print("P-12 host logic: fails = ", fails)

func _fuzz() -> void:
	_fresh()
	var exp : int = 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var owners := ["player_2", "player_3", "shared_01"]
	for i in 500:
		var s : int = [2, 3][rng.randi() % 2]
		var op : String = ["add", "remove", "transfer"][rng.randi() % 3]
		var res := h.host_handle(s, _r(op, W, rng.randi_range(-1, 60), owners[rng.randi() % 3], owners[rng.randi() % 3]))
		if not res["accepted"]: continue
		_t("ไม่เข้า INTERNAL", res["result"]["reason"] != OpResult.INTERNAL)
		if op == "add": exp += res["result"]["done"]
		elif op == "remove": exp -= res["result"]["done"]
	_t("fuzz: ผลรวมคงที่", _tot(W) == exp)
	for o in owners:
		_t("round-trip " + o, Inventory.from_dict(h.invs[o].to_dict(), h.db)["inventory"].to_dict() == h.invs[o].to_dict())
