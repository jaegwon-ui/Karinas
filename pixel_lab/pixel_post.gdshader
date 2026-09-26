shader_type canvas_item;
// 저해상도로 렌더링한 캐릭터를 도트처럼 다듬는다.
// 1) 반투명 가장자리를 없애 픽셀 경계를 딱 떨어지게
// 2) 실루엣 바깥에 1픽셀 외곽선 (한 가지 색, 또는 옆 픽셀 색을 어둡게 한 "색 외곽선")
// 3) 주변과 동떨어진 외톨이 픽셀 청소
// 4) 색 단계 줄이기(포스터라이즈)와 채도 보정

uniform bool outline_enabled = true;
uniform bool colored_outline = false;
uniform vec4 outline_color : source_color = vec4(0.13, 0.08, 0.16, 1.0);
uniform bool outline_diagonal = false;
uniform bool cleanup = false;
uniform float cleanup_threshold : hint_range(0.0, 1.0) = 0.16;
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.5;
uniform float color_levels : hint_range(0.0, 32.0, 1.0) = 0.0;
uniform float saturation : hint_range(0.0, 2.0) = 1.1;

vec4 texel(sampler2D tex, vec2 uv) {
	vec4 c = texture(tex, uv);
	c.a = step(alpha_cutoff, c.a);
	return c;
}

void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE;
	vec4 c = texel(TEXTURE, UV);
	vec4 n[4] = vec4[](
		texel(TEXTURE, UV + vec2(px.x, 0.0)), texel(TEXTURE, UV - vec2(px.x, 0.0)),
		texel(TEXTURE, UV + vec2(0.0, px.y)), texel(TEXTURE, UV - vec2(0.0, px.y)));

	if (c.a < 0.5) {
		float hits = 0.0;
		vec3 sum = vec3(0.0);
		for (int i = 0; i < 4; i++) {
			hits += n[i].a;
			sum += n[i].rgb * n[i].a;
		}
		if (outline_diagonal) {
			vec4 d[4] = vec4[](
				texel(TEXTURE, UV + px), texel(TEXTURE, UV - px),
				texel(TEXTURE, UV + vec2(px.x, -px.y)), texel(TEXTURE, UV + vec2(-px.x, px.y)));
			for (int i = 0; i < 4; i++) {
				hits += d[i].a;
				sum += d[i].rgb * d[i].a;
			}
		}
		if (!outline_enabled || hits < 0.5) {
			COLOR = vec4(0.0);
		} else if (colored_outline) {
			// 붙어 있는 부분의 색을 아주 어둡게 하고, 기본 외곽선 색(보라 기운) 쪽으로 살짝 당긴다
			COLOR = vec4(mix(sum / hits * 0.32, outline_color.rgb, 0.35), 1.0);
		} else {
			COLOR = outline_color;
		}
	} else {
		vec3 rgb = c.rgb;
		if (cleanup) {
			float similar = 0.0;
			float opaque = 0.0;
			vec3 sum = vec3(0.0);
			for (int i = 0; i < 4; i++) {
				opaque += n[i].a;
				sum += n[i].rgb * n[i].a;
				similar += n[i].a * step(distance(n[i].rgb, rgb), cleanup_threshold);
			}
			if (opaque > 3.5 && similar < 0.5) {
				rgb = sum / opaque;
			}
		}
		float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
		rgb = clamp(mix(vec3(luma), rgb, saturation), 0.0, 1.0);
		if (color_levels > 0.5) {
			rgb = floor(rgb * color_levels + 0.5) / color_levels;
		}
		COLOR = vec4(rgb, 1.0);
	}
}
