shader_type canvas_item;
// 저해상도로 렌더링한 캐릭터를 도트처럼 다듬는다.
// 1) 반투명 가장자리를 없애 픽셀 경계를 딱 떨어지게
// 2) 실루엣 바깥에 1픽셀 외곽선
// 3) 색 단계 줄이기(포스터라이즈)와 채도 보정

uniform bool outline_enabled = true;
uniform vec4 outline_color : source_color = vec4(0.13, 0.08, 0.16, 1.0);
uniform bool outline_diagonal = false;
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.5;
uniform float color_levels : hint_range(0.0, 32.0, 1.0) = 0.0;
uniform float saturation : hint_range(0.0, 2.0) = 1.1;

float alpha_at(sampler2D tex, vec2 uv) {
	return step(alpha_cutoff, texture(tex, uv).a);
}

void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE;
	vec4 c = texture(TEXTURE, UV);

	if (c.a < alpha_cutoff) {
		float n = 0.0;
		if (outline_enabled) {
			n = max(max(alpha_at(TEXTURE, UV + vec2(px.x, 0.0)), alpha_at(TEXTURE, UV - vec2(px.x, 0.0))),
					max(alpha_at(TEXTURE, UV + vec2(0.0, px.y)), alpha_at(TEXTURE, UV - vec2(0.0, px.y))));
			if (outline_diagonal) {
				n = max(n, max(max(alpha_at(TEXTURE, UV + px), alpha_at(TEXTURE, UV - px)),
						max(alpha_at(TEXTURE, UV + vec2(px.x, -px.y)), alpha_at(TEXTURE, UV + vec2(-px.x, px.y)))));
			}
		}
		COLOR = n > 0.5 ? outline_color : vec4(0.0);
	} else {
		vec3 rgb = c.rgb;
		float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
		rgb = clamp(mix(vec3(luma), rgb, saturation), 0.0, 1.0);
		if (color_levels > 0.5) {
			rgb = floor(rgb * color_levels + 0.5) / color_levels;
		}
		COLOR = vec4(rgb, 1.0);
	}
}
