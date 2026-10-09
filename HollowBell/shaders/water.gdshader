shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Opaque, shaded river surface: no screen/depth sampling, SSR, compute or
// volumetrics. The caller supplies the clock so gameplay pause also stops water.
uniform float flow_time = 0.0;
uniform vec3 deep_color : source_color = vec3(0.035, 0.10, 0.13);
uniform vec3 jade_color : source_color = vec3(0.09, 0.19, 0.21);
uniform vec3 glint_color : source_color = vec3(0.22, 0.32, 0.32);

varying vec3 world_position;

void vertex() {
	VERTEX.y += sin(VERTEX.x * 1.4 + flow_time * 0.7) * 0.025;
	VERTEX.y += cos(VERTEX.z * 1.8 - flow_time * 0.5) * 0.018;
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Broad continuous ripples avoid quantized shimmer at grazing angles.
	vec2 p = world_position.xz;
	float long_wave = sin(p.x * 0.48 + p.y * 1.6 - flow_time * 0.55);
	float cross_wave = cos(p.x * 1.1 - p.y * 0.35 + flow_time * 0.2);
	float ribbon = smoothstep(0.72, 1.0, long_wave) * smoothstep(-0.1, 0.75, cross_wave);
	float pool = 0.5 + 0.5 * sin(p.x * 0.14 + p.y * 0.35);
	ALBEDO = mix(deep_color, jade_color, pool * 0.45);
	ALBEDO = mix(ALBEDO, glint_color, ribbon * 0.16);
	ROUGHNESS = 0.88;
	METALLIC = 0.0;
	SPECULAR = 0.08;
}