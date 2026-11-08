shader_type canvas_item;
render_mode unshaded;

// Smooth background falloff under the menu. UI is drawn above this overlay.
uniform float vignette_amount : hint_range(0.0, 1.0) = 0.44;
uniform vec4 tint : source_color = vec4(0.02, 0.015, 0.02, 1.0);

void fragment() {
	vec2 offset = (UV - vec2(0.48, 0.48)) * vec2(1.25, 1.0);
	float edge = smoothstep(0.13, 0.79, length(offset));
	COLOR = vec4(tint.rgb, edge * vignette_amount);
}
