## godot-web.sh click-node / node-rect が Control のグローバル矩形を問い合わせるための診断 autoload。
## Web エクスポートでだけ動き (OS.has_feature("web"))、それ以外のプラットフォームでは何もしない。
##
## 導入: プロジェクト設定 > Autoload にこのスクリプトを追加する (名前は任意。例: GodotWebDiag)。
## プロトコル (window オブジェクト経由。JavaScriptBridge のコールバックは戻り値を返せないため、
## godot-web.sh が window.__godotWebDiag.request を置き、本スクリプトが毎フレーム見て response を書く):
##   request:  {id: "<一意>", name: "<Control の name>"}
##   response: {id, name, found: true, x, y, w, h}  (Control.get_global_rect()。ゲーム座標)
##             {id, name, found: false}
## 前提: stretch mode が canvas_items で aspect が keep のプロジェクト。get_global_rect() はビューポート座標を返し、
## これがゲームの表示解像度の座標と一致する。CanvasLayer に transform を掛けている場合や Node2D (Control でない)
## は対象外 (found: false)。名前はツリー全体から find_child(name, true, false) で最初に一致した Control を返す。
extends Node

var _last_id: String = ""


func _process(_delta: float) -> void:
	if not OS.has_feature("web"):
		return
	var raw: Variant = JavaScriptBridge.eval(
		"JSON.stringify((window.__godotWebDiag && window.__godotWebDiag.request) || null)"
	)
	if raw == null or typeof(raw) != TYPE_STRING or raw == "null":
		return
	var request: Variant = JSON.parse_string(raw)
	if typeof(request) != TYPE_DICTIONARY or not request.has("id"):
		return
	var id: String = str(request["id"])
	if id == _last_id:
		return
	_last_id = id
	var name_to_find: String = str(request.get("name", ""))
	var response: Dictionary = {"id": id, "name": name_to_find, "found": false}
	var node: Node = get_tree().root.find_child(name_to_find, true, false)
	if node is Control:
		var rect: Rect2 = (node as Control).get_global_rect()
		response["found"] = true
		response["x"] = rect.position.x
		response["y"] = rect.position.y
		response["w"] = rect.size.x
		response["h"] = rect.size.y
	JavaScriptBridge.eval(
		"window.__godotWebDiag = window.__godotWebDiag || {}; window.__godotWebDiag.response = %s;"
		% JSON.stringify(response)
	)
