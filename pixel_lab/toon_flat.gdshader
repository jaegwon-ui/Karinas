shader_type spatial;
// 도트용 평면 셀 셰이딩. 빛을 3단계(그림자, 기본, 하이라이트)로만 나눈다.
// 그림자 색은 기본색을 어둡게 한 게 아니라 따로 고른 색이라서, 도트 장인들처럼 색조를 옮길 수 있다.
// 양면 재질: 뒷면(망토 안감)은 inner 색을 쓴다.
render_mode unshaded, cull_disabled;

uniform vec4 base_color : source_color = vec4(0.55, 0.08, 0.12, 1.0);
uniform vec4 shade_color : source_color = vec4(0.28, 0.04, 0.14, 1.0);
uniform vec4 highlight_color : source_color = vec4(0.78, 0.22, 0.2, 1.0);
uniform vec4 inner_color : source_color = vec4(0.12, 0.1, 0.22, 1.0);
uniform vec4 inner_shade_color : source_color = vec4(0.07, 0.05, 0.14, 1.0);
uniform vec4 trim_color : source_color = vec4(0.86, 0.66, 0.26, 1.0);
uniform vec4 trim_shade_color : source_color = vec4(0.55, 0.33, 0.14, 1.0);
uniform float trim_start = 2.0;  // UV.y 가 이보다 크면 테두리 색. 1보다 크면 테두리 없음
uniform vec3 light_dir = vec3(0.4, 0.7, 0.6);  // 빛이 오는 방향(월드)
uniform float shade_threshold = 0.05;
uniform float highlight_threshold = 0.85;

void fragment() {
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float ndl = dot(n, normalize(light_dir));
	bool trim = UV.y > trim_start;
	vec3 color;
	if (!FRONT_FACING && !trim) {
		color = ndl > shade_threshold ? inner_color.rgb : inner_shade_color.rgb;
	} else if (trim) {
		color = ndl > shade_threshold ? trim_color.rgb : trim_shade_color.rgb;
	} else if (ndl > highlight_threshold) {
		color = highlight_color.rgb;
	} else if (ndl > shade_threshold) {
		color = base_color.rgb;
	} else {
		color = shade_color.rgb;
	}
	ALBEDO = color;
}
