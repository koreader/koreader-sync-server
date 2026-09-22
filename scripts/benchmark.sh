#!/bin/sh
# A/B benchmark for two refs of this repository.
#
# Builds each ref into a container image with the repo Dockerfile, runs both,
# and drives the same requests at each with scripts/benchmark.lua. Arms are
# interleaved and every figure is a ratio against the base measured in the same
# repetition, because a shared CI runner drifts more than the differences being
# measured.
#
# Redis commands per request are exact. Wall-clock figures are advisory.
#
#     ./scripts/benchmark.sh --base origin/master --head HEAD

set -eu

base=origin/master
head=HEAD
reps=3
duration=10
warmup=3
conns=2
engine=${BENCH_ENGINE:-}
json=

while [ $# -gt 0 ]; do
    case $1 in
        --base) base=$2; shift 2 ;;
        --head) head=$2; shift 2 ;;
        --reps) reps=$2; shift 2 ;;
        --duration) duration=$2; shift 2 ;;
        --warmup) warmup=$2; shift 2 ;;
        --conns) conns=$2; shift 2 ;;
        --engine) engine=$2; shift 2 ;;
        --json) json=$2; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$engine" ]; then
    if command -v docker >/dev/null 2>&1; then engine=docker; else engine=podman; fi
fi
command -v "$engine" >/dev/null 2>&1 || { echo "no container engine: $engine" >&2; exit 1; }

repo=$(git rev-parse --show-toplevel)
driver=$repo/scripts/benchmark.lua
resty=/opt/openresty/bin/resty
work=$(mktemp -d)

cleanup() {
    for arm in base head; do
        "$engine" rm -f "kosync-bench-$arm" >/dev/null 2>&1 || true
    done
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

base_sha=$(git -C "$repo" rev-parse "$base")
head_sha=$(git -C "$repo" rev-parse "$head")
if [ "$base_sha" = "$head_sha" ]; then
    echo "note: base and head are the same commit; this run measures the noise floor" >&2
fi

for arm in base head; do
    if [ "$arm" = base ]; then ref=$base; else ref=$head; fi
    container=kosync-bench-$arm
    tree=$work/$arm
    mkdir "$tree"
    git -C "$repo" archive "$ref" | tar -x -C "$tree"

    "$engine" build -t "kosync-bench:$arm" "$tree"
    "$engine" rm -f "$container" >/dev/null 2>&1 || true
    "$engine" run -d --name "$container" "kosync-bench:$arm" >/dev/null
    "$engine" cp "$driver" "$container:/tmp/benchmark.lua"
    "$engine" exec "$container" "$resty" /tmp/benchmark.lua prepare || {
        "$engine" logs --tail 40 "$container" >&2
        exit 1
    }
done

runs=$work/runs.ndjson
printf '{"type":"meta","base_ref":"%s","base_sha":"%s","head_ref":"%s","head_sha":"%s","reps":%d,"duration":%d,"warmup":%d,"conns":%d}\n' \
    "$base" "$base_sha" "$head" "$head_sha" "$reps" "$duration" "$warmup" "$conns" > "$runs"

rep=1
while [ "$rep" -le "$reps" ]; do
    for arm in base head; do
        for endpoint in put get; do
            "$engine" exec "kosync-bench-$arm" "$resty" /tmp/benchmark.lua measure \
                --arm "$arm" --rep "$rep" --endpoint "$endpoint" \
                --duration "$duration" --warmup "$warmup" --conns "$conns" >> "$runs"
        done
    done
    rep=$((rep + 1))
done

[ -z "$json" ] || cp "$runs" "$json"

report=$work/report.md
status=0
"$engine" exec -i kosync-bench-base "$resty" /tmp/benchmark.lua report \
    < "$runs" > "$report" || status=$?
echo
cat "$report"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat "$report" >> "$GITHUB_STEP_SUMMARY"
exit $status
