## Minimal SVG line charts for headless reports (no plotting libraries on the dev machine).
extends RefCounted

const W := 960
const H := 420
const PAD_L := 64
const PAD_R := 150
const PAD_T := 40
const PAD_B := 48
const GRID_LINES := 5
const FONT := "font-family:system-ui,sans-serif"


## series: Array of {"name": String, "color": Color, "values": PackedFloat64Array, "dash": bool}.
## x_labels: one label per value index; every label_every-th one is drawn.
static func line_chart(title: String, y_label: String, x_labels: PackedStringArray,
		series: Array, label_every: int = 4) -> String:
	var n := x_labels.size()
	var y_max := 0.0
	for s: Dictionary in series:
		for v in (s["values"] as PackedFloat64Array):
			y_max = maxf(y_max, v)
	y_max = _nice_ceiling(y_max)
	var pw := W - PAD_L - PAD_R
	var ph := H - PAD_T - PAD_B
	var out := PackedStringArray()
	out.append('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">' % [W, H, W, H])
	out.append('<rect width="100%" height="100%" fill="#ffffff"/>')
	out.append('<text x="%d" y="24" style="%s;font-size:16px;font-weight:600" fill="#222">%s</text>' % [PAD_L, FONT, _esc(title)])
	for g in GRID_LINES + 1:
		var yv := y_max * g / GRID_LINES
		var py := PAD_T + ph - ph * g / float(GRID_LINES)
		out.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="#e5e5e5"/>' % [PAD_L, py, PAD_L + pw, py])
		out.append('<text x="%d" y="%.1f" text-anchor="end" style="%s;font-size:11px" fill="#555">%s</text>' % [PAD_L - 6, py + 4, FONT, _fmt(yv)])
	out.append('<text x="14" y="%d" transform="rotate(-90 14 %d)" text-anchor="middle" style="%s;font-size:12px" fill="#444">%s</text>' % [PAD_T + ph / 2, PAD_T + ph / 2, FONT, _esc(y_label)])
	for i in n:
		if i % label_every != 0:
			continue
		var px := PAD_L + (pw * i / float(maxi(n - 1, 1)))
		out.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="#f0f0f0"/>' % [px, PAD_T, px, PAD_T + ph])
		out.append('<text x="%.1f" y="%d" text-anchor="middle" style="%s;font-size:11px" fill="#555">%s</text>' % [px, PAD_T + ph + 16, FONT, _esc(x_labels[i])])
	var legend_y := PAD_T + 4
	for s: Dictionary in series:
		var vals: PackedFloat64Array = s["values"]
		var pts := PackedStringArray()
		for i in vals.size():
			var px := PAD_L + (pw * i / float(maxi(n - 1, 1)))
			var py := PAD_T + ph - (ph * vals[i] / y_max if y_max > 0.0 else 0.0)
			pts.append("%.1f,%.1f" % [px, py])
		var col := (s["color"] as Color).to_html(false)
		var dash := ' stroke-dasharray="6 4"' if s.get("dash", false) else ""
		out.append('<polyline fill="none" stroke="#%s" stroke-width="2"%s points="%s"/>' % [col, dash, " ".join(pts)])
		out.append('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#%s" stroke-width="3"%s/>' % [W - PAD_R + 12, legend_y, W - PAD_R + 32, legend_y, col, dash])
		out.append('<text x="%d" y="%d" style="%s;font-size:12px" fill="#333">%s</text>' % [W - PAD_R + 38, legend_y + 4, FONT, _esc(s["name"])])
		legend_y += 18
	out.append("</svg>")
	return "\n".join(out)


static func _nice_ceiling(v: float) -> float:
	if v <= 0.0:
		return 1.0
	var mag := pow(10.0, floorf(log(v) / log(10.0)))
	for step: float in [1.0, 2.0, 2.5, 5.0, 10.0]:
		if v <= step * mag:
			return step * mag
	return 10.0 * mag


static func _fmt(v: float) -> String:
	if absf(v) >= 1000000.0:
		return "%dM" % roundi(v / 1000000.0) if absf(v) >= 10000000.0 else "%.1fM" % (v / 1000000.0)
	if absf(v) >= 1000.0:
		return "%dk" % roundi(v / 1000.0) if absf(v) >= 10000.0 else "%.1fk" % (v / 1000.0)
	if absf(v - roundf(v)) < 0.001:
		return "%d" % roundi(v)
	return "%.2f" % v


static func _esc(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
