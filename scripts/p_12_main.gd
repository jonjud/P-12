extends Node

func _ready() -> void:
	var a : PackedStringArray = OS.get_cmdline_user_args()
	var net := P12Net.new()
	net.name = "Net"
	add_child(net)
	net.db = ItemDatabase.new()
	net.db.load_from_directory("res://data/")
	if "--badpv" in a:
		net.hello_pv = 99
	if "--dropitem" in a:
		net.db._items.erase(net.db._items.keys()[0])
	for f in ["scenario", "full", "fuzz", "rtt", "dc", "show"]:
		if ("--" + f) in a:
			net.replicas_changed.connect(Callable(net, "run_" + f), CONNECT_ONE_SHOT)
	if "--quiet" in a:
		net.quiet = true
	if "--host" in a:
		net.start_host()
	elif "--client" in a:
		net.start_client("127.0.0.1")
