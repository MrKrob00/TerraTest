#include "terrain_native.h"
#include <godot_cpp/core/class_db.hpp>
#include <cmath>

using namespace godot;

void TerrainNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "seed", "amplitude", "scale", "power", "mountains",
			"off_x", "off_z"), &TerrainNative::setup);
	ClassDB::bind_method(D_METHOD("raw_height_at", "wx", "wz"), &TerrainNative::raw_height_at);
	ClassDB::bind_method(D_METHOD("sample_unit", "ox", "oz", "n"), &TerrainNative::sample_unit);
}

TerrainNative::TerrainNative() {
	base_noise.instantiate();
	ridge_noise.instantiate();
	dune_noise.instantiate();
	value_noise.instantiate();
}

void TerrainNative::setup(int seed_value, double amp, double scale, double pwr, double mountains,
		double ox, double oz) {
	amplitude = amp;
	power = pwr;
	mtn_amount = 0.25 + (1.1 - 0.25) * mountains;
	ridge_sharp = 1.6 + (3.6 - 1.6) * mountains;
	mtn_rise = amp * 0.75;
	dune_amp = std::fmin(std::fmax(amp * 0.05, 1.0), 14.0);
	off_x = ox;
	off_z = oz;

	base_noise->set_seed(seed_value);
	base_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
	base_noise->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
	base_noise->set_fractal_octaves(6);
	base_noise->set_frequency(1.0 / scale);
	base_noise->set_fractal_lacunarity(2.0);
	base_noise->set_fractal_gain(0.42);

	ridge_noise->set_seed(seed_value + 17);
	ridge_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
	ridge_noise->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
	ridge_noise->set_fractal_octaves(5);
	ridge_noise->set_frequency(1.0 / (scale * 0.55));
	ridge_noise->set_fractal_lacunarity(2.2);
	ridge_noise->set_fractal_gain(0.45);

	dune_noise->set_seed(seed_value + 211);
	dune_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
	dune_noise->set_frequency(1.0 / 140.0);

	value_noise->set_noise_type(FastNoiseLite::TYPE_VALUE);
	value_noise->set_fractal_type(FastNoiseLite::FRACTAL_NONE);
	value_noise->set_frequency(1.0);
	value_noise->set_seed(0);
}

double TerrainNative::smoothstep01(double a, double b, double x) {
	if (b <= a) return x < a ? 0.0 : 1.0;
	double t = (x - a) / (b - a);
	t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
	return t * t * (3.0 - 2.0 * t);
}

double TerrainNative::cv(double x, double z) const {
	return value_noise->get_noise_2d(x, z) * 0.5 + 0.5;
}

double TerrainNative::raw_height_at(double wx, double wz) const {
	const double base = (base_noise->get_noise_2d(wx, wz) + 1.0) * 0.5;
	const double continental = std::pow(base, power);
	const double ridge = std::pow(1.0 - std::fabs(ridge_noise->get_noise_2d(wx, wz)), ridge_sharp);
	const double mountain_mask_h = smoothstep01(0.52, 0.78, continental);
	const double ridge_term = ridge * mtn_amount * mountain_mask_h;

	// Маски биомов — те же формулы, что в TerrainBiomes, но без вызова в GDScript.
	double n = cv(wx / biome_scale + off_x, wz / biome_scale + off_z);
	n = (n - 0.5) * biome_contrast + 0.5;
	n = n < 0.0 ? 0.0 : (n > 1.0 ? 1.0 : n);
	const double meadow = smoothstep01(biome_bias - biome_blend, biome_bias + biome_blend, n);

	const double mn = cv(wx / mountain_scale + 700.0 + off_x, wz / mountain_scale + 700.0 + off_z);
	const double mtn_mask = smoothstep01(mountain_threshold - mountain_edge,
			mountain_threshold + mountain_edge, mn);
	const double mtn_dome = smoothstep01(mountain_threshold - mountain_edge, 0.95, mn);

	const double sand_m = 1.0 - meadow;
	const double not_mtn = 1.0 - mtn_mask;
	const double land_sand = sand_m * not_mtn;
	const double cont_biome = continental * (1.0 + (desert_flatten - 1.0) * land_sand);
	double h = cont_biome + ridge_term * not_mtn;

	const double duneph = wx / dune_wavelength + dune_noise->get_noise_2d(wx, wz) * 3.5;
	const double dune = std::pow(0.5 + 0.5 * std::sin(duneph), 1.4) * dune_amp * land_sand;
	const double rise = mtn_dome * mtn_rise
			+ dune_noise->get_noise_2d(wx * 1.7, wz * 1.7) * 4.0 * mtn_mask;
	return h * amplitude + dune + rise;
}

PackedFloat32Array TerrainNative::sample_unit(double ox, double oz, int n) const {
	const int m = n + 2;
	PackedFloat32Array raw;
	raw.resize(m * m);
	float *rw = raw.ptrw();
	for (int j = 0; j < m; j++) {
		const double wz = oz + double(j - 1);
		const int row = j * m;
		for (int i = 0; i < m; i++) {
			rw[row + i] = float(raw_height_at(ox + double(i - 1), wz));
		}
	}
	PackedFloat32Array out;
	out.resize(n * n);
	float *ow = out.ptrw();
	const float *rr = raw.ptr();
	for (int j = 0; j < n; j++) {
		const int c = (j + 1) * m, u = j * m, d = (j + 2) * m;
		for (int i = 0; i < n; i++) {
			ow[j * n + i] = (rr[c + i + 1] + rr[c + i] + rr[c + i + 2]
					+ rr[u + i + 1] + rr[d + i + 1]) * 0.2f;
		}
	}
	return out;
}
