extends Node

func _ready() -> void:
	var net := P12Net.new()
	net.name = "Net"
	add_child(net)
	net.db = ItemDatabase.new()
	net.db.load_from_directory("res://data/")
	var a : PackedStringArray = OS.get_cmdline_user_args()
	if "--host" in a:
		net.start_host()
	elif "--client" in a:
		net.start_client("127.0.0.1")
