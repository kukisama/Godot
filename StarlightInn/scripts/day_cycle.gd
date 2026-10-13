extends RefCounted
## One shared clock for painted backgrounds, actor tint, lights and HUD.

const PHASES: Array[String] = ["dawn", "day", "sunset", "night"]
const LABELS: Array[String] = ["初晓 · 茶香渐起", "白昼 · 窗边暖阳", "夕照 · 满堂蜜色", "夜泊 · 星灯长明"]
const TINTS: Array[Color] = [Color(1.03, 0.98, 0.95), Color(1.04, 1.03, 0.98), Color(1.07, 0.93, 0.85), Color(0.91, 0.95, 1.04)]
const DAYLIGHT: Array[float] = [0.62, 1.0, 0.38, 0.0]
const HOLD_SECONDS := 64.0
const FADE_SECONDS := 12.0

var phase_index: int = 3
var phase_time: float = 0.0
var blend: float = 0.0
var fade_duration: float = FADE_SECONDS


func advance(delta: float) -> void:
	phase_time += maxf(delta, 0.0)
	while phase_time >= HOLD_SECONDS + fade_duration:
		phase_time -= HOLD_SECONDS + fade_duration
		phase_index = (phase_index + 1) % PHASES.size()
		fade_duration = FADE_SECONDS
	blend = smoothstep(0.0, fade_duration, maxf(0.0, phase_time - HOLD_SECONDS))


func request_next() -> void:
	# Start a short fade, never snap between backgrounds or restart an active fade.
	if phase_time < HOLD_SECONDS:
		phase_time = HOLD_SECONDS
		fade_duration = 3.2


func next_index() -> int:
	return (phase_index + 1) % PHASES.size()


func ambient_tint() -> Color:
	return TINTS[phase_index].lerp(TINTS[next_index()], blend)


func daylight() -> float:
	return lerpf(DAYLIGHT[phase_index], DAYLIGHT[next_index()], blend)


func label() -> String:
	return LABELS[phase_index] if blend <= 0.01 else "%s → %s" % [LABELS[phase_index].get_slice(" · ", 0), LABELS[next_index()].get_slice(" · ", 0)]


func snapshot() -> Dictionary:
	return {"phase": PHASES[phase_index], "next_phase": PHASES[next_index()], "blend": blend, "daylight": daylight()}