shader_type canvas_item;
render_mode unshaded, blend_mix;

// An alpha veil behind the Controls, NOT a screen-texture/postprocessing pass.
// No blur, framebuffer reads, depth texture, HDR or Compatibility-only hazards.
uniform float menu_shade : hint_range(0.0, 1.0) = 0.0;
uniform float menu_edge : hint_range(0.4, 0.73) = 0.53;
uniform float hit_strength : hint_range(0.0, 0.2) = 0.0;
uniform float vignette_strength : hint_range(0.0, 0.2) = 0.10;
uniform float grain_strength : hint_range(0.0, 0.015) = 0.004;

void fragment() {
	vec2 centered = UV * 2.0 - 1.0;
	float edge = smoothstep(0.36, 1.25, length(centered * vec2(0.78, 0.90)));
	float left = 1.0 - smoothstep(0.08, menu_edge, UV.x);
	float shade = 1.0 - (1.0 - edge * vignette_strength) * (1.0 - left * menu_shade * 0.82);
	// Soft edge gradients preserve readable UI over bright masonry and leaves
	// without covering the character or turning the HUD into opaque panels.
	float hud_top = (1.0 - smoothstep(0.04, 0.27, UV.y)) * 0.62;
	float hud_bottom = smoothstep(0.72, 1.0, UV.y) * 0.76;
	float hud_shade = max(hud_top, hud_bottom) * (1.0 - menu_shade);
	shade = 1.0 - (1.0 - shade) * (1.0 - hud_shade);
	float impact = edge * hit_strength;
	// Static, sub-visible paper grain; no animated noise over character pixels.
	float grain = fract(sin(dot(floor(FRAGCOORD.xy / 2.0), vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
	vec3 ink = vec3(0.022, 0.042, 0.048) + grain * grain_strength;
	float alpha = min(0.88, shade + impact);
	vec3 tint = mix(ink, vec3(0.89, 0.64, 0.31), impact / max(alpha, 0.001));
	COLOR = vec4(tint, alpha);
}