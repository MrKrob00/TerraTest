#ifndef TERRAIN_NATIVE_H
#define TERRAIN_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

namespace godot {

// ТОТ ЖЕ РАСЧЁТ, ЧТО В LiteTerrainGen.raw_height_at, НА C++ — ради одного вопроса: сколько
// из 22 мкс на точку остаётся, когда из них уходит GDScript.
//
// Шумы берём у самого движка (FastNoiseLite через godot-cpp): это те же октавы, что считает
// GDScript-версия, но вызов к ним из C++ идёт прямым вызовом, а не через границу языка.
// Маски биомов и вся арифметика переписаны здесь.
class TerrainNative : public RefCounted {
	GDCLASS(TerrainNative, RefCounted)

	Ref<FastNoiseLite> base_noise;
	Ref<FastNoiseLite> ridge_noise;
	Ref<FastNoiseLite> dune_noise;
	Ref<FastNoiseLite> value_noise;   // то, чем считаются маски биомов

	double amplitude = 130.0;
	double power = 2.8;
	double mtn_amount = 0.8;
	double ridge_sharp = 2.5;
	double mtn_rise = 48.0;
	double dune_amp = 6.0;
	double biome_scale = 340.0, canyon_scale = 450.0, mountain_scale = 420.0;
	double biome_bias = 0.5, biome_blend = 0.07, biome_contrast = 1.8;
	double canyon_threshold = 0.66, canyon_edge = 0.05;
	double mountain_threshold = 0.71, mountain_edge = 0.05;
	double dune_wavelength = 34.0, desert_flatten = 0.4;
	double off_x = 0.0, off_z = 0.0;

protected:
	static void _bind_methods();

public:
	TerrainNative();

	void setup(int seed_value, double amp, double scale, double pwr, double mountains,
			double ox, double oz);
	double raw_height_at(double wx, double wz) const;
	// Ровно то, что делает LiteTerrainGen._sample_unit: сетка n×n с каймой, размытая пятью
	// отсчётами. Мерить надо её, а не одну точку: чанк считается именно так.
	PackedFloat32Array sample_unit(double ox, double oz, int n) const;

private:
	static double smoothstep01(double a, double b, double x);
	double cv(double x, double z) const;   // маска-шум в 0..1
};

}

#endif
