#!/usr/bin/env bash
set -euo pipefail

# Run two independent headless Godot editors against isolated project copies.
# Usage: GODOT_BIN=/path/to/Godot ./run_e2e.sh [--keep] [--windowed]
GODOT_BIN="${GODOT_BIN:-godot}"
TIMEOUT_SEC="${TIMEOUT_SEC:-360}"
PORT="${PORT:-47950}"
KEEP=0
WINDOWED=0
for arg in "$@"; do
	case "$arg" in
		--keep) KEEP=1 ;;
		--windowed) WINDOWED=1 ;;
		*) echo "Unknown argument: $arg" >&2; exit 2 ;;
	esac
done

if ! command -v "$GODOT_BIN" >/dev/null 2>&1 && [[ ! -x "$GODOT_BIN" ]]; then
	echo "Godot executable not found: $GODOT_BIN" >&2
	exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ADDON_SRC="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/collab_e2e.XXXXXX")"
SHARED="$ROOT/shared"
mkdir -p "$SHARED"
HOST_PID=""
CLIENT_PID=""

cleanup() {
	status=$?
	for pid in "$HOST_PID" "$CLIENT_PID"; do
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
	done
	if [[ "$KEEP" -eq 1 || "$status" -ne 0 ]]; then
		echo "Logs and test projects: $ROOT"
	else
		case "$ROOT" in
			"${TMPDIR:-/tmp}"/collab_e2e.*) rm -rf -- "$ROOT" ;;
			*) echo "Refusing to remove unexpected test path: $ROOT" >&2; status=1 ;;
		esac
	fi
	exit "$status"
}
trap cleanup EXIT INT TERM

new_project() {
	local dir="$1" player_text="$2"
	local addon_dst="$dir/addons/godot_collab"
	mkdir -p "$addon_dst" "$dir/src"
	cp -R "$ADDON_SRC/." "$addon_dst/"
	find "$addon_dst" -name '*.uid' -type f -delete
	cat > "$dir/project.godot" <<'EOF'
config_version=5

[application]

config/name="CollabE2E"
run/main_scene="res://main.tscn"
config/features=PackedStringArray("4.4")

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_collab/plugin.cfg")
EOF
	cat > "$dir/main.tscn" <<'EOF'
[gd_scene format=3]

[node name="Main" type="Node3D"]

[node name="Block" type="Node3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0)

[node name="Other" type="Node3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 2, 0)

[node name="Mesh" type="MeshInstance3D" parent="."]
EOF
	printf '%s' "$player_text" > "$dir/player.gd"
	cat > "$dir/src/native.cpp" <<'EOF'
#include <godot_cpp/godot.hpp>

int main() {
	return 0;
}
EOF
}

HOST_DIR="$ROOT/host"
CLIENT_DIR="$ROOT/client"
mkdir -p "$HOST_DIR" "$CLIENT_DIR"
new_project "$HOST_DIR" $'extends Node\n\nvar speed = 5\n'
new_project "$CLIENT_DIR" $'extends Node\n# STALE LOCAL COPY\n'

for dir in "$HOST_DIR" "$CLIENT_DIR"; do
	echo "Importing test project: $dir"
	"$GODOT_BIN" --headless --editor --quit --path "$dir" > "$dir/import.log" 2>&1
done

HOST_ARGS=(--headless --editor --path "$HOST_DIR")
CLIENT_ARGS=(--headless --editor --path "$CLIENT_DIR")
if [[ "$WINDOWED" -eq 1 ]]; then
	HOST_ARGS=(--editor --path "$HOST_DIR")
	CLIENT_ARGS=(--editor --path "$CLIENT_DIR")
fi
HOST_LAUNCH="$(printf '{"mode":"host","port":%s,"key":"e2e","name":"Hana"}' "$PORT")"
CLIENT_LAUNCH="$(printf '{"mode":"join","address":"127.0.0.1","port":%s,"key":"e2e","name":"Cole"}' "$PORT")"

GODOT_COLLAB_LAUNCH="$HOST_LAUNCH" GODOT_COLLAB_TEST=res://addons/godot_collab/tests/editor/host_test.gd GODOT_COLLAB_SHARED="$SHARED" GODOT_COLLAB_VERBOSE=1 \
	"$GODOT_BIN" "${HOST_ARGS[@]}" > "$ROOT/host.log" 2>&1 &
HOST_PID=$!
sleep 4
GODOT_COLLAB_LAUNCH="$CLIENT_LAUNCH" GODOT_COLLAB_TEST=res://addons/godot_collab/tests/editor/client_test.gd GODOT_COLLAB_SHARED="$SHARED" GODOT_COLLAB_VERBOSE=1 \
	"$GODOT_BIN" "${CLIENT_ARGS[@]}" > "$ROOT/client.log" 2>&1 &
CLIENT_PID=$!

echo 'Waiting for both editors to finish...'
deadline=$((SECONDS + TIMEOUT_SEC))
while (( SECONDS < deadline )); do
	host_alive=0; client_alive=0
	kill -0 "$HOST_PID" 2>/dev/null && host_alive=1 || true
	kill -0 "$CLIENT_PID" 2>/dev/null && client_alive=1 || true
	if (( host_alive == 0 && client_alive == 0 )); then break; fi
	sleep 1
done

timeout_failure=0
if kill -0 "$HOST_PID" 2>/dev/null || kill -0 "$CLIENT_PID" 2>/dev/null; then
	echo "Timed out after ${TIMEOUT_SEC}s"
	timeout_failure=1
	for pid in "$HOST_PID" "$CLIENT_PID"; do kill "$pid" 2>/dev/null || true; done
fi
wait "$HOST_PID" 2>/dev/null || true
wait "$CLIENT_PID" 2>/dev/null || true
HOST_PID=""; CLIENT_PID=""

python3 - "$SHARED" <<'PY'
import json, pathlib, sys
shared = pathlib.Path(sys.argv[1])
failed = 0
for role in ("host", "client"):
    result_file = shared / f"{role}_results.json"
    if not result_file.exists():
        print(f"{role}: NO RESULTS")
        failed += 1
        continue
    data = json.loads(result_file.read_text())
    for name, ok in sorted(data.get("results", {}).items()):
        print(f"{role:6} {'PASS' if ok else 'FAIL'}  {name}")
        failed += not bool(ok)
print(f"e2e: {failed} failure(s)")
sys.exit(1 if failed else 0)
PY
test "$timeout_failure" -eq 0
