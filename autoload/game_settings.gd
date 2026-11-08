extends Node

## GameSettings - local (never networked) settings repository.
## Audio buses come from res://audio/faz_buses.tres; video modes go through DisplayServer.
## Persisted to user://settings.cfg so a player keeps preferences across sessions.

const SAVE_PATH := "user://settings.cfg"

const BUSES := ["Master", "Music", "UI", "SFX", "Ambient"]

const DEFAULT_AUDIO := {
	"Master": 1.0,
	"Music": 0.8,
	"UI": 0.9,
	"SFX": 1.0,
	"Ambient": 1.0,
}
const DEFAULT_VIDEO := {
	"display_mode": "Windowed",
	"resolution": "",
	"vsync": true,
	"max_fps": 0,
}

signal settings_changed(section: StringName)

var audio := DEFAULT_AUDIO.duplicate(true)
var video := DEFAULT_VIDEO.duplicate(true)


## «СБРОСИТЬ» in the settings overlay: back to shipped defaults, applied live, and
## deliberately not written to disk - saving stays a separate, explicit action.
func reset_to_defaults() -> void:
	audio = DEFAULT_AUDIO.duplicate(true)
	video = DEFAULT_VIDEO.duplicate(true)
	apply_all()
	settings_changed.emit(&"all")


func _ready() -> void:
	load_settings()
	apply_all()


func _index(bus_name: String) -> int:
	return AudioServer.get_bus_index(bus_name)


func set_bus_volume(bus_name: String, linear: float) -> void:
	var idx := _index(bus_name)
	if idx < 0:
		push_warning("Missing audio bus: " + bus_name)
		return
	audio[bus_name] = clampf(linear, 0.0, 1.0)
	AudioServer.set_bus_volume_db(idx, linear_to_db(audio[bus_name]))
	settings_changed.emit(&"audio")


func get_bus_volume(bus_name: String) -> float:
	return float(audio.get(bus_name, 1.0))


func set_display_mode(mode_name: String) -> void:
	video["display_mode"] = mode_name
	_apply_video_mode()
	settings_changed.emit(&"video")


func set_vsync(enabled: bool) -> void:
	video["vsync"] = enabled
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if enabled else DisplayServer.VSYNC_DISABLED
	)
	settings_changed.emit(&"video")


func set_max_fps(value: int) -> void:
	video["max_fps"] = value
	Engine.max_fps = value
	settings_changed.emit(&"video")


func set_resolution(width: int, height: int) -> void:
	video["resolution"] = "%dx%d" % [width, height]
	DisplayServer.window_set_size(Vector2i(maxi(width, 320), maxi(height, 180)))
	settings_changed.emit(&"video")


func apply_all() -> void:
	for bus_name in BUSES:
		set_bus_volume(bus_name, get_bus_volume(bus_name))
	set_display_mode(String(video.get("display_mode", "Windowed")))
	set_vsync(bool(video.get("vsync", true)))
	set_max_fps(int(video.get("max_fps", 0)))


func _apply_video_mode() -> void:
	var mode := String(video.get("display_mode", "Windowed"))
	var windowed := DisplayServer.WINDOW_MODE_WINDOWED
	match mode:
		"Fullscreen":
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		"Borderless":
			# 4.7 has no WINDOW_MODE_BORDERLESS: borderless is a flag on a windowed window.
			DisplayServer.window_set_mode(windowed)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
		_:
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_mode(windowed)


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for bus_name in audio:
		cfg.set_value("audio", bus_name, audio[bus_name])
	for key in video:
		cfg.set_value("video", key, video[key])
	var err := cfg.save(SAVE_PATH)
	if err != OK:
		push_warning("Settings could not be saved: " + error_string(err))


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	for bus_name in audio.keys():
		audio[bus_name] = cfg.get_value("audio", bus_name, audio[bus_name])
	for key in video.keys():
		video[key] = cfg.get_value("video", key, video[key])
