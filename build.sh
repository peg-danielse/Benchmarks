#!/usr/bin/env bash
# Builds the demo binaries into demo/bin: operate (hotel operator + its loadgen),
# goperate (social operator + its loadgen) and speculator (Mercury's live view).
# Sources: the `demo` branches. HOTEL_SRC / SOCIAL_SRC / MERCURY_SRC point at
# checkouts (or worktrees) of those branches; defaults are the usual repos.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=${DSB_ROOT:-$(cd "$here/.." && pwd)}
HOTEL_SRC=${HOTEL_SRC:-$root/deathstar-hotelReservations}
SOCIAL_SRC=${SOCIAL_SRC:-$root/deathstar-socialNetwork}
MERCURY_SRC=${MERCURY_SRC:-${MERCURY_ROOT:-$HOME/Mercury}}
mkdir -p "$here/bin"
for src in "$HOTEL_SRC/operate/demoload.go" "$SOCIAL_SRC/goperate/demoload.go"; do
  [ -f "$src" ] || { echo "build.sh: $src missing: check out the demo branch (or set HOTEL_SRC/SOCIAL_SRC)" >&2; exit 1; }
done
(cd "$HOTEL_SRC" && CGO_ENABLED=0 go build -o "$here/bin/operate" ./operate)
(cd "$SOCIAL_SRC/goperate" && CGO_ENABLED=0 go build -o "$here/bin/goperate" .)
grep -q -- '--status' "$MERCURY_SRC/src/speculator.cpp" || { echo "build.sh: $MERCURY_SRC is not on Mercury's demo branch (speculator --status)" >&2; exit 1; }
g++ -std=c++20 -O2 -o "$here/bin/speculator" "$MERCURY_SRC/src/speculator.cpp"
ls -l "$here/bin"
