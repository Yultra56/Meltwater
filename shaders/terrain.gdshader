shader_type canvas_item;
// Draws the whole glacier in one pass from two small data textures, one texel per tile.
// cells (nearest): r = tile type * 32 / 255, g = strength, b = water, a = 1 when the tile is a sealed camp.
// heat (linear):   r = temperature mapped from -40..40 °C to 0..1, g = firelight 0..1, b = strength (smooth).

uniform sampler2D cells : filter_nearest;
uniform sampler2D heat : filter_linear;
uniform vec2 grid = vec2(64.0, 40.0);
uniform float surface_rows = 3.0;
uniform float bedrock_rows = 3.0;
uniform bool heat_view = false;

const int AIR = 0;
const int ICE = 1;
const int ROCK = 2;
const int FELT = 3;
const int SNOW = 4;
const int CRATE = 5;

const vec3 YOUNG_ICE = vec3(0.80, 0.88, 0.95);
const vec3 OLD_ICE = vec3(0.16, 0.40, 0.74);
const vec3 CAVE = vec3(0.035, 0.045, 0.075);
const vec3 FIRE_LIGHT = vec3(1.0, 0.58, 0.26);
const vec3 WATER = vec3(0.12, 0.34, 0.66);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 4; k++) {
		v += a * noise(p);
		p *= 2.03;
		a *= 0.5;
	}
	return v;
}

int type_at(ivec2 c) {
	if (c.x < 0 || c.y < 0 || c.x >= int(grid.x) || c.y >= int(grid.y)) {
		return ROCK;
	}
	vec4 t = texelFetch(cells, c, 0);
	if (t.a > 0.5) {
		return ICE; // a camp nobody has dug into yet is still solid ice to look at
	}
	return int(round(t.r * 255.0 / 32.0));
}

bool open_at(ivec2 c) {
	return type_at(c) == AIR;
}

// How close this point is to an open (air) neighbour, 1 at the shared edge, 0 a third of a tile in.
float edge_to_air(ivec2 c, vec2 local) {
	float e = 0.0;
	if (open_at(c + ivec2(-1, 0))) e = max(e, 1.0 - local.x * 3.0);
	if (open_at(c + ivec2(1, 0))) e = max(e, local.x * 3.0 - 2.0);
	if (open_at(c + ivec2(0, -1))) e = max(e, 1.0 - local.y * 3.0);
	if (open_at(c + ivec2(0, 1))) e = max(e, local.y * 3.0 - 2.0);
	return clamp(e, 0.0, 1.0);
}

// How close this open point is to a solid wall: walls of ice give the dark caves a faint blue glow.
float near_wall(ivec2 c, vec2 local) {
	float w = 0.0;
	if (!open_at(c + ivec2(-1, 0))) w = max(w, pow(1.0 - local.x, 3.0));
	if (!open_at(c + ivec2(1, 0))) w = max(w, pow(local.x, 3.0));
	if (!open_at(c + ivec2(0, -1))) w = max(w, pow(1.0 - local.y, 3.0));
	if (!open_at(c + ivec2(0, 1))) w = max(w, pow(local.y, 3.0));
	return w;
}

vec3 ice_color(vec2 gp, ivec2 c, vec2 local, float strength, float smooth_strength, float temp) {
	float depth = clamp((gp.y - surface_rows) / (grid.y - surface_rows - bedrock_rows), 0.0, 1.0);
	// Old, deep ice is dense and blue; young ice near the surface is white with air.
	vec3 col = mix(YOUNG_ICE, OLD_ICE, smoothstep(0.0, 1.0, depth));
	// Looking into clear ice: some places go deep and dark, others are milky.
	float murk = fbm(gp * 0.22 + vec2(7.0, 2.0));
	col *= mix(0.72, 1.08, murk);
	// Seasonal layers pressed into the glacier, bent a little by its slow flow.
	float bend = fbm(gp * vec2(0.18, 0.4)) * 5.0;
	float strata = sin(gp.y * 2.2 + bend);
	col *= 0.93 + 0.07 * strata;
	col = mix(col, vec3(0.90, 0.95, 1.0), smoothstep(0.96, 1.0, sin(gp.y * 0.9 + bend * 0.6)) * 0.25);
	// Milky veins that run across tile borders, fewer in old ice.
	float veins = fbm(gp * vec2(0.5, 1.2) + vec2(3.0, 0.0));
	col = mix(col, vec3(0.86, 0.92, 0.98), smoothstep(0.66, 0.86, veins) * (0.25 - depth * 0.15));
	// Thin light streaks where the ice refracts.
	float streak = smoothstep(0.992, 1.0, sin((gp.x + gp.y * 0.6) * 0.9 + fbm(gp * 0.3) * 3.0));
	col += vec3(0.05, 0.07, 0.09) * streak * (1.0 - depth * 0.5);
	// A few trapped air bubbles, mostly in young ice.
	float bubbles = 0.0;
	for (int k = 0; k < 2; k++) {
		vec2 seed = vec2(c) + float(k) * vec2(17.3, 9.1);
		if (hash(seed + 4.0) < (0.45 - depth * 0.38) / float(k + 1)) {
			vec2 center = vec2(0.2, 0.2) + vec2(hash(seed), hash(seed + 1.7)) * 0.6;
			float r = 0.025 + hash(seed + 3.1) * 0.045;
			float d = length(local - center);
			float ring = smoothstep(r, r - 0.018, d) - smoothstep(r - 0.018, r - 0.04, d) * 0.6;
			bubbles = max(bubbles, ring);
			col = mix(col, col * 0.8, smoothstep(r * 1.6, r, d) * 0.25); // faint shadow under it
		}
	}
	col = mix(col, vec3(0.95, 0.98, 1.0), clamp(bubbles, 0.0, 1.0) * 0.6);
	// Weak ice turns grey and cracks; the grey blends smoothly between tiles.
	float weak = clamp(1.0 - smooth_strength / 0.75, 0.0, 1.0);
	col = mix(col, vec3(0.52, 0.57, 0.63), weak * 0.4);
	if (strength < 0.5) {
		float n = noise(gp * 3.2 + hash(vec2(c)) * 10.0);
		float crack = smoothstep(0.035, 0.0, abs(n - 0.5)) * (1.0 - strength * 1.6);
		col = mix(col, vec3(0.10, 0.15, 0.24), clamp(crack, 0.0, 0.85));
	}
	// Ice warmed close to melting gets a wet sheen.
	float wet = smoothstep(-1.5, 0.0, temp);
	col = mix(col, vec3(0.88, 0.96, 1.0), wet * 0.2 * (0.6 + 0.4 * noise(gp * 6.0)));
	return col;
}

vec3 snow_color(vec2 gp) {
	float grain = noise(gp * 9.0) * 0.5 + noise(gp * 23.0) * 0.5;
	return vec3(0.90, 0.93, 0.97) * (0.95 + 0.06 * grain);
}

vec3 rock_color(vec2 gp) {
	float n = fbm(gp * 1.3);
	vec3 col = mix(vec3(0.17, 0.16, 0.16), vec3(0.33, 0.31, 0.29), n);
	col *= 0.9 + 0.2 * smoothstep(0.45, 0.6, noise(gp * 5.0));
	return col;
}

vec3 felt_color(vec2 gp, vec2 local) {
	float weave = 0.5 + 0.5 * sin(local.x * 40.0) * sin(local.y * 40.0);
	vec3 col = vec3(0.45, 0.31, 0.20) * (0.88 + 0.12 * weave);
	col *= 0.9 + 0.15 * noise(gp * 8.0);
	return col;
}

vec3 crate_color(vec2 gp, ivec2 c, vec2 local, float temp) {
	vec3 ice = ice_color(gp, c, local, 1.0, 1.0, temp);
	vec2 box = abs(local - 0.5);
	if (max(box.x, box.y) > 0.36) {
		return ice;
	}
	float planks = step(0.5, fract(local.y * 3.0 + 0.1));
	vec3 wood = mix(vec3(0.42, 0.27, 0.12), vec3(0.52, 0.35, 0.16), planks);
	wood *= 0.85 + 0.2 * noise(vec2(gp.x * 14.0, gp.y * 2.0));
	if (max(box.x, box.y) > 0.31) {
		wood *= 0.55; // frame
	}
	// Seen through a thin skin of ice.
	return mix(wood, ice, 0.28);
}

vec3 storm_color(vec2 gp) {
	float streaks = noise(vec2(gp.x * 0.6 - TIME * 4.0, gp.y * 5.0));
	float gusts = noise(vec2(gp.x * 0.15 - TIME * 0.7, gp.y));
	vec3 col = mix(vec3(0.46, 0.50, 0.58), vec3(0.70, 0.74, 0.80), gusts);
	return mix(col, vec3(0.92, 0.94, 0.97), smoothstep(0.62, 0.9, streaks) * 0.7);
}

vec3 heat_map(float temp) {
	if (temp < 0.0) {
		return mix(vec3(0.95, 0.97, 1.0), vec3(0.10, 0.20, 0.70), clamp(-temp / 20.0, 0.0, 1.0));
	}
	return mix(vec3(0.95, 0.97, 1.0), vec3(0.85, 0.20, 0.10), clamp(temp / 30.0, 0.0, 1.0));
}

void fragment() {
	vec2 gp = UV * grid;
	ivec2 c = ivec2(floor(gp));
	vec2 local = fract(gp);
	vec4 data = texelFetch(cells, c, 0);
	int t = type_at(c);
	float strength = data.g;
	float water = data.b;
	vec4 h = texture(heat, UV);
	float temp = h.r * 80.0 - 40.0;
	float light = h.g;
	float smooth_strength = h.b;

	vec3 col;
	bool solid = t != AIR;
	if (t == AIR) {
		if (gp.y < surface_rows) {
			col = storm_color(gp);
		} else {
			col = CAVE * (0.85 + 0.3 * noise(gp * 0.8));
			col += vec3(0.07, 0.15, 0.27) * near_wall(c, local) * 0.9;
		}
	} else if (t == ICE) {
		col = ice_color(gp, c, local, data.a > 0.5 ? 1.0 : strength, data.a > 0.5 ? 1.0 : max(smooth_strength, strength), temp);
	} else if (t == SNOW) {
		col = snow_color(gp);
	} else if (t == ROCK) {
		col = rock_color(gp);
	} else if (t == FELT) {
		col = felt_color(gp, local);
	} else {
		col = crate_color(gp, c, local, temp);
	}

	if (solid) {
		// Faces that meet open air catch the light; the ice just behind them is a little darker.
		float e = edge_to_air(c, local);
		vec3 rim = t == ROCK || t == FELT ? col * 1.35 : vec3(0.93, 0.97, 1.0);
		col = mix(col * 0.92, rim, e * e * 0.55);
		// Firelight soaks into ice and glows inside it; it barely enters rock and felt.
		float soak = (t == ICE || t == SNOW || t == CRATE) ? 0.75 : 0.25;
		col += FIRE_LIGHT * light * soak * (0.6 + 0.4 * e);
	} else if (gp.y >= surface_rows) {
		col += FIRE_LIGHT * light * light * 0.9;
		col = mix(col, col + FIRE_LIGHT * 0.25, light * 0.5);
	}

	// Pooled meltwater, filling each tile from the bottom with a moving surface.
	if (t == AIR && water > 0.02) {
		float wave = sin(gp.x * 5.0 + TIME * 2.2) * 0.03 * min(water * 3.0, 1.0);
		float surface = 1.0 - clamp(water, 0.0, 1.0) + wave;
		if (local.y > surface) {
			vec3 w = WATER * (0.85 + 0.25 * noise(gp * 3.0 + vec2(TIME * 0.4, 0.0)));
			w += FIRE_LIGHT * light * 0.5;
			col = mix(col, w, 0.82);
			col += vec3(0.5, 0.7, 0.9) * smoothstep(0.08, 0.0, local.y - surface) * 0.5;
		}
	}

	if (heat_view) {
		col = mix(heat_map(temp), col, 0.18);
	}
	COLOR = vec4(col, 1.0);
}
