#!/usr/bin/env bash
# Run the Godot console binary. Resolution order: $GODOT, then the single line in
# tools/.godot_bin (untracked, machine-specific), then `godot` on PATH.
here="$(cd "$(dirname "$0")" && pwd)"
bin="${GODOT:-}"
if [ -z "$bin" ] && [ -f "$here/.godot_bin" ]; then bin="$(head -n1 "$here/.godot_bin" | tr -d '\r')"; fi
bin="${bin:-godot}"
exec "$bin" "$@"
