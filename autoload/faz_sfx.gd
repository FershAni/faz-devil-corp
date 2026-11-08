extends Node

## UI sound without an audio department: short procedural hits rendered once at boot.
## Industrial clicks rather than sci-fi beeps, to match the scrap-yard interior.

enum Cue { CLICK, HOVER, DENIED }

var _players: Array[AudioStreamPlayer] = []
var _streams := {}


func _ready() -> void:
	_streams[Cue.CLICK] = _make_click(0.055, 1300.0, 190.0, -9.0)
	_streams[Cue.HOVER] = _make_click(0.030, 2400.0, 260.0, -20.0)
	_streams[Cue.DENIED] = _make_thud(0.22, 92.0, -8.0)
	for i in 6:
		var player := AudioStreamPlayer.new()
		player.bus = _bus_or_master("UI")
		add_child(player)
		_players.append(player)


func play(cue: int) -> void:
	if not _streams.has(cue):
		return
	for player in _players:
		if not player.playing:
			player.stream = _streams[cue]
			player.play()
			return
	_players[0].stream = _streams[cue]
	_players[0].play()


## A tiny noise burst through a falling resonant filter reads as a mechanical button.
func _make_click(duration: float, freq_start: float, freq_end: float, gain_db: float) -> AudioStreamWAV:
	var rate := 32000
	var count := maxi(int(rate * duration), 8)
	var bytes := PackedByteArray()
	bytes.resize(count * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var filter_state := 0.0
	var gain := db_to_linear(gain_db)
	for i in count:
		var t := float(i) / float(count)
		filter_state = lerpf(filter_state, rng.randf_range(-1.0, 1.0), lerpf(freq_end, freq_start, t) / 6000.0)
		var env := pow(1.0 - t, 2.6)
		var value := filter_state * env * 2.4 + sin(2.0 * PI * 170.0 * float(i) / rate) * env * 0.25
		bytes.encode_s16(i * 2, int(clampf(value * gain, -1.0, 1.0) * 32000.0))
	return _wrap(bytes, rate)


func _make_thud(duration: float, freq: float, gain_db: float) -> AudioStreamWAV:
	var rate := 32000
	var count := int(rate * duration)
	var bytes := PackedByteArray()
	bytes.resize(count * 2)
	var gain := db_to_linear(gain_db)
	for i in count:
		var t := float(i) / float(rate)
		var env := exp(-t * 12.0)
		var value := (sin(2.0 * PI * freq * t) * 0.8 + sin(2.0 * PI * freq * 1.5 * t) * 0.25) * env
		bytes.encode_s16(i * 2, int(clampf(value * gain, -1.0, 1.0) * 32000.0))
	return _wrap(bytes, rate)


func _wrap(bytes: PackedByteArray, rate: int) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = bytes
	return wav


func _bus_or_master(candidate: String) -> String:
	return candidate if AudioServer.get_bus_index(candidate) >= 0 else "Master"
