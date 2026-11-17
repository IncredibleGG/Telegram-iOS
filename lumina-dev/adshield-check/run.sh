#!/bin/sh
# AdShield iOS conformance checker (not part of any Bazel target).
#
#   sh lumina-dev/adshield-check/run.sh            # -O, Swift 5 mode, -warnings-as-errors (like TelegramUIPreferences)
#   SWIFT_MODE=6 sh lumina-dev/adshield-check/run.sh   # also must pass in Swift 6 language mode
#   OPT=-Onone sh lumina-dev/adshield-check/run.sh     # debug-build optimization level (timings)
#
# Compiles the engine sources exactly as they are in the app module (they import only Foundation) together with
# AdShieldCheck.swift, then runs every check against the vectors / scenarios copied next to this script
# (copies of adshield/vectors and adshield/corpus; keep them byte-identical, see .gitattributes).
# Extra generated corpora: --extra-fingerprints FILE / --extra-scenarios FILE (see fuzz_gen.py); --no-timing.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC="$REPO/submodules/TelegramUIPreferences/Sources"
OUT="${TMPDIR:-/tmp}/adshield_check_ios.$$"
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT
SWIFTC="swiftc"
if command -v xcrun >/dev/null 2>&1; then
  SWIFTC="xcrun swiftc"
fi
$SWIFTC ${OPT:--O} -swift-version "${SWIFT_MODE:-5}" -warnings-as-errors -parse-as-library -module-name AdShieldCheck \
  "$SRC/AdShieldTables.swift" "$SRC/LuminaAdShield.swift" "$SRC/LuminaAdShieldStore.swift" "$SRC/LuminaAdShieldAccount.swift" \
  "$HERE/AdShieldCheck.swift" -o "$OUT/adshield_check"
"$OUT/adshield_check" "$HERE" "$@"
