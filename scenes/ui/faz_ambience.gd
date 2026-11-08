extends AudioStreamPlayer

## Procedural menu bed: sub-drone, filtered air, distant creaks and one metal clank,
## rendered once into a looping 16-bit stream. No audio files exist yet, so the menu
## would otherwise be silent - and silence is the wrong mood for a haunted pizzeria.

const RATE := 32000
const SECONDS := 12
const SAMPLE_COUNT := RATE * SECONDS

@export_range(-40.0, 0.0, 0.5) var bed_volume_db := -13.0


func _ready() -> void:
	stream = _build_stream()
	volume_db = bed_volume_db
	bus = _bus_or_master("Ambient")
	play()


func _build_stream() -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	samples.resize(SAMPLE_COUNT)
	var noise_state := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xFAD0
	for i in SAMPLE_COUNT:
		var t := float(i) / float(RATE)
		# Two detuned subs with a slow tremolo: the building breathing.
		var breath := 0.55 + 0.45 * sin(2.0 * PI * t * 0.0833)
		var value := sin(2.0 * PI * 41.2 * t) * 0.42 * breath
		value += sin(2.0 * PI * 61.74 * t) * 0.16 * breath
		value += sin(2.0 * PI * 82.4 * t) * 0.07
		# One-pole low passed noise = air through the vents.
		noise_state = lerpf(noise_state, rng.randf_range(-1.0, 1.0), 0.012)
		value += noise_state * 0.30 * (0.5 + 0.5 * sin(2.0 * PI * t * 0.1667))
		value += _creak_at(t, 2.15, 190.0, 61.0) * 0.5
		value += _creak_at(t, 6.70, 132.0, 47.0) * 0.42
		value += _creak_at(t, 9.40, 248.0, 74.0) * 0.30
		value += _clank_at(t, 8.05) * 0.55
		samples[i] = clampf(value, -1.0, 1.0)

	# Crossfade the tail into the head so the loop has no seam.
	var fade := RATE / 2
	for i in fade:
		var blend := float(i) / float(fade)
		samples[i] = lerpf(samples[SAMPLE_COUNT - fade + i], samples[i], blend)

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = SAMPLE_COUNT - 1
	var bytes := PackedByteArray()
	bytes.resize(SAMPLE_COUNT * 2)
	for i in SAMPLE_COUNT:
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	wav.data = bytes
	return wav


## A short resonant sweep: what a stressed joint in the ceiling sounds like from below.
func _creak_at(t: float, at: float, freq_start: float, freq_end: float) -> float:
	var age := t - at
	if age < 0.0 or age > 1.4:
		return 0.0
	var sweep := lerpf(freq_start, freq_end, clampf(age / 1.4, 0.0, 1.0))
	var wobble := 1.0 + 0.35 * sin(2.0 * PI * age * 7.3)
	return sin(2.0 * PI * sweep * age * wobble) * exp(-age * 3.4) * 0.5


func _clank_at(t: float, at: float) -> float:
	var age := t - at
	if age < 0.0 or age > 1.8:
		return 0.0
	var ring := sin(2.0 * PI * 316.0 * age) * 0.5 + sin(2.0 * PI * 471.0 * age) * 0.3
	ring += sin(2.0 * PI * 705.0 * age) * 0.2
	return ring * exp(-age * 4.2) + sin(2.0 * PI * 54.0 * age) * exp(-age * 9.0) * 0.7


func _bus_or_master(candidate: String) -> String:
	return candidate if AudioServer.get_bus_index(candidate) >= 0 else "Master"
