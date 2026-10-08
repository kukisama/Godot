shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Opaque, shaded river surface: no screen/depth sampling, SSR, compute or
// volumetrics. The caller supplies the clock so gameplay pause also stops water.
uniform float flow_time = 0.0;
uniform vec3 deep_color : source_color = vec3(0.035, 0.12, 0.15);
uniform vec3 jade_color : source_color = vec3(0.12, 0.27, 0.27);
uniform vec3 glint_color : source_color = vec3(0.35, 0.49, 0.43);

varying vec3 world_position;

void vertex() {
	VERTEX.y += sin(VERTEX.x * 1.4 + flow_time * 0.7) * 0.025;
	VERTEX.y += cos(VERTEX.z * 1.8 - flow_time * 0.5) * 0.018;
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Deliberately stepped ripple highlights fit the finely clustered pixel art.
	vec2 p = floor(world_position.xz * 18.0) / 18.0;
	float long_wave = sin(p.x * 0.76 + p.y * 2.6 - flow_time * 0.8);
	float cross_wave = cos(p.x * 2.1 - p.y * 0.55 + flow_time * 0.32);
	float ribbon = smoothstep(0.84, 0.98, long_wave) * smoothstep(-0.15, 0.7, cross_wave);
	float pool = 0.5 + 0.5 * sin(p.x * 0.14 + p.y * 0.35);
	ALBEDO = mix(deep_color, jade_color, pool * 0.53);
	ALBEDO = mix(ALBEDO, glint_color, ribbon * 0.30);
	ROUGHNESS = 0.43;
	METALLIC = 0.16;
	SPECULAR = 0.45;
	EMISSION = glint_color * ribbon * 0.015;
}