extends "res://tests/test_base.gd"

const Parallel := preload("res://sim/core/parallel.gd")

const BIG := 64 * 1024 * 1024

var shared_buffer := PackedByteArray()
var hits := PackedInt32Array()


func test_for_each_runs_every_item_once() -> void:
	for workers in [1, 4]:
		hits.resize(1000)
		hits.fill(0)
		Parallel.for_each(1000, func(i: int) -> void: hits[i] += 1, workers)
		check_eq(hits.count(1), 1000, "every item exactly once with %d workers" % workers)


func test_ensure_unique_breaks_copy_on_write_sharing() -> void:
	shared_buffer.resize(BIG)
	shared_buffer.fill(1)
	var alias := shared_buffer.duplicate()  # lazy: shares the buffer until someone writes
	var t0 := Time.get_ticks_usec()
	Parallel.ensure_unique(self, &"shared_buffer")
	var t_unique := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	shared_buffer[12345] = 7
	var t_write := Time.get_ticks_usec() - t0
	check(t_write < 1000, "first write after ensure_unique is cheap (%d us)" % t_write)
	check(t_unique > t_write, "ensure_unique paid for the copy (%d us vs %d us)" % [t_unique, t_write])
	check_eq(alias[12345], 1, "the old alias keeps its own data")
	check_eq(shared_buffer[12345], 7, "the owner sees its write")
	shared_buffer = PackedByteArray()
