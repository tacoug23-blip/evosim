extends "res://tests/test_base.gd"

const Rng := preload("res://sim/core/rng.gd")

const DRAWS := 64


func test_same_seed_same_sequence() -> void:
	check_eq(_draws(Rng.new(42).stream("a")), _draws(Rng.new(42).stream("a")), "same seed + stream")


func test_seeds_and_names_separate_streams() -> void:
	var base := _draws(Rng.new(42).stream("a"))
	check(base != _draws(Rng.new(43).stream("a")), "different master seed differs")
	check(base != _draws(Rng.new(42).stream("b")), "different stream name differs")


func test_streams_do_not_disturb_each_other() -> void:
	var alone := _draws(Rng.new(7).stream("terrain"))
	var r := Rng.new(7)
	_draws(r.stream("spike.decide"))  # another subsystem draws first
	_draws(r.stream("new.feature"))
	check_eq(_draws(r.stream("terrain")), alone, "terrain sequence unaffected by other streams")


func test_state_roundtrip_through_json() -> void:
	var r := Rng.new(99)
	_draws(r.stream("a"))
	_draws(r.stream("b"))
	var text := JSON.stringify(r.get_state())
	var expected_a := _draws(r.stream("a"))
	var expected_b := _draws(r.stream("b"))
	var r2 := Rng.new(99)
	r2.set_state(JSON.parse_string(text))
	check_eq(_draws(r2.stream("a")), expected_a, "stream a continues after restore")
	check_eq(_draws(r2.stream("b")), expected_b, "stream b continues after restore")


func test_seed_derivation_is_pinned() -> void:
	# Golden values: if these change, every existing seed produces a different world.
	check_eq(Rng.derive_seed(1337, "terrain"), GOLDEN_TERRAIN_1337, "derive_seed(1337, terrain)")
	check_eq(Rng.derive_seed(0, "spike.decide"), GOLDEN_SPIKE_DECIDE_0, "derive_seed(0, spike.decide)")


func _draws(rng: RandomNumberGenerator) -> Array:
	var out := []
	for i in DRAWS:
		out.append(rng.randi())
	return out


const GOLDEN_TERRAIN_1337 := -6535498337875657233
const GOLDEN_SPIKE_DECIDE_0 := -7379562471253161243
