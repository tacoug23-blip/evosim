## Fixed-point conventions shared by sim code.
##
## Quantities that accumulate every tick (movement progress, energy) are stored as integers
## in thousandths so results do not depend on float rounding, and stay bit-identical if the
## core is ported to Rust. These are unit definitions, not tunables.
extends RefCounted

const MILLI := 1000


static func to_milli(value: float) -> int:
	return roundi(value * MILLI)
