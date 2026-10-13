shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float daylight : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec3 scene = texture(screen_texture, SCREEN_UV).rgb;
	float edge_focus = pow(abs(SCREEN_UV.y - 0.55) * 2.0, 3.0);
	vec3 soft = textureLod(screen_texture, SCREEN_UV, 1.3).rgb;
	scene = mix(scene, soft, clamp(edge_focus * 0.20, 0.0, 0.20));
	float vignette = pow(length((SCREEN_UV - 0.5) * vec2(1.0, 1.15)), 2.4);
	scene *= 1.0 - vignette * mix(0.30, 0.17, daylight);
	COLOR = vec4(scene, 1.0);
}