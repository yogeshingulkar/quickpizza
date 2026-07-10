#!/usr/bin/env bash
# Run k6 tests by tier. Usage: ./run-tier.sh <tier> [extra k6 args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIER="${1:-}"
shift || true

if [[ -z "$TIER" ]]; then
  echo "Usage: $0 <tier> [k6 args...]"
  echo "Tiers: basic auth websockets browser grpc extensions ci"
  exit 1
fi

# Load .env if present
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

K6_ROOT="${K6_ROOT:-$SCRIPT_DIR/../k6}"
BASE_URL="${BASE_URL:-http://localhost:3333}"
K6_PATH="${K6_PATH:-k6}"
TIERS_DIR="$SCRIPT_DIR/tiers"

export K6_BROWSER_HEADLESS="${K6_BROWSER_HEADLESS:-true}"
export K6_BROWSER_ARGS="${K6_BROWSER_ARGS:-no-sandbox,disable-dev-shm-usage,disable-features=PartitionAllocSchedulerLoopQuarantineTaskControlledPurge}"

resolve_tier_file() {
  local tier="$1"
  if [[ -f "$TIERS_DIR/${tier}.txt" ]]; then
    echo "$TIERS_DIR/${tier}.txt"
  else
    echo "Unknown tier: $tier" >&2
    exit 1
  fi
}

collect_tests() {
  local file="$1"
  local line tier
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [[ -z "$line" ]] && continue
    if [[ "$line" == @include* ]]; then
      tier="${line#@include }"
      collect_tests "$(resolve_tier_file "$tier")"
    else
      echo "$line"
    fi
  done < "$file"
}

run_test() {
  local rel="$1"
  local test="$K6_ROOT/$rel"
  if [[ ! -f "$test" ]]; then
    echo "Missing test file: $test" >&2
    exit 1
  fi
  echo "==> k6 run $rel"
  "$K6_PATH" run --no-thresholds -e "BASE_URL=$BASE_URL" "$@" "$test"
}

mapfile -t TESTS < <(collect_tests "$(resolve_tier_file "$TIER")")

if [[ "$TIER" == "ci" ]]; then
  for rel in "${TESTS[@]}"; do
    run_test "$rel" "$@"
  done
  echo "==> Building xk6 binary with quickpizzaext"
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  if ! command -v xk6 >/dev/null 2>&1; then
    go install go.k6.io/xk6/cmd/xk6@latest
  fi
  xk6 build \
    --output "$K6_ROOT/extensions/k6" \
    --with "github.com/grafana/quickpizza/extensions/quickpizzaext=$K6_ROOT/extensions/quickpizzaext" \
    --replace "github.com/grafana/quickpizza=$REPO_ROOT"
  echo "==> k6 run extensions/01.quickpizzaext.js"
  "$K6_ROOT/extensions/k6" run --no-thresholds -e "BASE_URL=$BASE_URL" "$K6_ROOT/extensions/01.quickpizzaext.js"
  exit 0
fi

if [[ "$TIER" == "extensions" ]]; then
  echo "Note: extensions tier may need custom xk6 binaries. See README.md." >&2
fi

for rel in "${TESTS[@]}"; do
  run_test "$rel" "$@"
done

echo "Tier '$TIER' completed (${#TESTS[@]} tests)."
