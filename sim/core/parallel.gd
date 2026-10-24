## Parallel-for over the WorkerThreadPool.
##
## Rules for callers (see docs/DECISIONS.md):
## - Results must not depend on how items are spread over threads: each item writes only its own
##   slots, and any cross-item effects are collected and applied sequentially afterwards.
## - Never copy, duplicate, or resize sim arrays during a parallel phase. Call ensure_unique()
##   on every array the items will write before dispatching.
extends RefCounted


## Run fn(i) for i in [0, count). Inline when workers <= 1. Otherwise one high-priority group
## task: low-priority group tasks are capped to a fraction of the pool (2 of 8 threads on the
## dev machine), which silently halves the speedup.
static func for_each(count: int, fn: Callable, workers: int) -> void:
	if count <= 0:
		return
	if workers <= 1 or count == 1:
		for i in count:
			fn.call(i)
		return
	var task := WorkerThreadPool.add_group_task(fn, count, mini(workers, count), true)
	WorkerThreadPool.wait_for_group_task_completion(task)


## sim.worker_threads value -> thread count (0 = one per logical core).
static func resolve_workers(param_value: int) -> int:
	return param_value if param_value > 0 else OS.get_processor_count()


## Make sure `owner.<prop>` exclusively owns its buffer before worker threads write into it.
## A write on the calling thread forces any pending copy-on-write copy to happen here, once,
## instead of racing inside the workers. Cheap when the buffer is already unique.
static func ensure_unique(owner: Object, prop: StringName) -> void:
	var arr: Variant = owner.get(prop)
	if arr.size() > 0:
		arr[0] = arr[0]
		owner.set(prop, arr)
