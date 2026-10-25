extends RefCounted
class_name HostLogic

const PROTOCOL_VERSION : int = 1
const SHARED_ID : String = "shared_01"
var db : ItemDatabase
var invs : Dictionary = {}    # owner_id -> Inventory (host ถือของจริง)
var _seen : Dictionary = {}   # sender_id -> {rid: true}

func _err(rid : int, why : StringName) -> Dictionary:
	return {"rid": rid, "accepted": false, "net_reason": why, "result": null, "changed": {}}

func _shape_ok(r : Dictionary) -> bool:
	for k in ["op", "item", "src", "dst"]:
		if typeof(r.get(k)) != TYPE_STRING:
			return false
	return typeof(r.get("qty")) == TYPE_INT

# ตัวตนผู้ขอมาจาก sender (get_remote_sender_id) ไม่ใช่จาก payload
func _get_for(sender : int, owner : String) -> Inventory:
	if owner == SHARED_ID or owner == "player_%d" % sender:
		return invs.get(owner)
	return null

func host_handle(sender : int, req : Dictionary) -> Dictionary:
	var rid = req.get("rid")
	if typeof(rid) != TYPE_INT or rid < 0 or not _shape_ok(req):
		return _err(-1, &"bad_request")
	if typeof(req.get("pv")) != TYPE_INT or req["pv"] != PROTOCOL_VERSION:
		return _err(rid, &"bad_protocol")
	var seen : Dictionary = _seen.get_or_add(sender, {})
	if seen.has(rid):
		return _err(rid, &"duplicate_request")
	seen[rid] = true
	var id : StringName = StringName(req["item"])
	var q : int = req["qty"]
	var res : Dictionary
	var touched : Array = []
	match req["op"]:
		"add":    # test-only: production ให้ host เรียกเองจากการเก็บของ
			var inv : Inventory = _get_for(sender, req["dst"])
			if inv == null: return _err(rid, &"denied")
			res = inv.add_to_existing_stacks(db, id, q)
			touched = [req["dst"]]
		"remove":
			var inv : Inventory = _get_for(sender, req["src"])
			if inv == null: return _err(rid, &"denied")
			res = inv.remove_item(db, id, q)
			touched = [req["src"]]
		"transfer":    # ต้นทางต้องเป็นของตัวเองหรือ shared, ปลายทางเป็นใครก็ได้ที่มีอยู่
			var a : Inventory = _get_for(sender, req["src"])
			var b : Inventory = invs.get(req["dst"])
			if a == null or b == null: return _err(rid, &"denied")
			res = a.transfer_to(b, db, id, q)
			touched = [req["src"], req["dst"]]
		_:
			return _err(rid, &"bad_op")
	if res["reason"] == OpResult.INTERNAL:
		push_error("P-12: INTERNAL ใน transfer_to ถือเป็นบั๊ก หยุดและรายงาน")
	var changed : Dictionary = {}
	if res["done"] > 0:    # ตัดสินจาก done > 0 ตามสัญญา D-12 (partial add ก็ต้องส่ง state)
		for o in touched:
			changed[o] = invs[o].to_dict()
	return {"rid": rid, "accepted": true, "net_reason": &"", "result": res, "changed": changed}
