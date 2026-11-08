shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform float curvature : hint_range(0.0, 0.15) = 0.019;
uniform float interference : hint_range(0.0, 1.0) = 0.0;
uniform float monochrome : hint_range(0.0, 1.0) = 0.0;

float hash(vec2 cell) {
	return fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	// Derivatives convert the panel's local UV to screen UV even during its scale tween.
	vec2 centered = UV * 2.0 - 1.0;
	vec2 warped = centered * (1.0 + curvature * dot(centered, centered));
	vec2 glass_uv = warped * 0.5 + 0.5;
	vec2 pixel_uv = max(fwidth(UV), vec2(0.00001));
	vec2 screen_extent = SCREEN_PIXEL_SIZE / pixel_uv;
	float edge = max(abs(warped.x), abs(warped.y));
	float frame = floor(TIME * 18.0);
	float row = floor(glass_uv.y * 96.0);
	float tear = step(0.96, hash(vec2(row, frame))) * interference;
	glass_uv.x += tear * (hash(vec2(frame, row)) - 0.5) * 0.022;
	glass_uv = clamp(glass_uv, pixel_uv, 1.0 - pixel_uv);
	vec3 source = texture(screen_texture, SCREEN_UV + (glass_uv - UV) * screen_extent).rgb;
	float luma = dot(source, vec3(0.2126, 0.7152, 0.0722));
	source = mix(source, vec3(luma) * vec3(0.88, 1.0, 0.95), monochrome);
	float line = 0.965 + 0.035 * cos(FRAGCOORD.y * 2.0944);
	float noise = hash(floor(FRAGCOORD.xy / 1.5) + vec2(frame * 31.0, frame)) - 0.5;
	float vignette = 1.0 - 0.16 * dot(centered, centered);
	vec3 phosphor = source * line * vignette + noise * (0.022 + 0.17 * interference);
	COLOR = vec4(mix(max(phosphor, vec3(0.0)), vec3(0.011, 0.014, 0.017),
		smoothstep(0.985, 1.0, edge)), 1.0);
}
