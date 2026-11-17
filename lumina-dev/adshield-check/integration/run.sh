#!/bin/sh
# AdShield iOS integration checks (LuminaAdShieldService / LuminaAdShieldChatSession), on a Mac.
# NOT part of any Bazel target.
#
#   sh lumina-dev/adshield-check/integration/run.sh
#
# Builds SwiftSignalKit from the repo and a small TelegramCore stand-in (TelegramCoreStub.swift), then compiles the
# TelegramUIPreferences files the service needs plus ServiceCheck.swift into one executable (Swift 5 mode,
# -warnings-as-errors) and runs it against a temp directory with a fixed key (no Keychain access).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SRC="$REPO/submodules/TelegramUIPreferences/Sources"
SSK="$REPO/submodules/SSignalKit/SwiftSignalKit/Source"
OUT="${TMPDIR:-/tmp}/adshield_service_check.$$"
mkdir -p "$OUT/mods"
trap 'rm -rf "$OUT"' EXIT
SWIFTC="swiftc"
if command -v xcrun >/dev/null 2>&1; then
  SWIFTC="xcrun swiftc"
fi
$SWIFTC -O -swift-version 5 -parse-as-library -module-name SwiftSignalKit -emit-library -static \
  -emit-module -emit-module-path "$OUT/mods/SwiftSignalKit.swiftmodule" "$SSK"/*.swift -o "$OUT/libSwiftSignalKit.a"
$SWIFTC -O -swift-version 5 -parse-as-library -module-name TelegramCore -emit-library -static -I "$OUT/mods" \
  -emit-module -emit-module-path "$OUT/mods/TelegramCore.swiftmodule" "$HERE/TelegramCoreStub.swift" -o "$OUT/libTelegramCore.a"
$SWIFTC ${OPT:--O} -swift-version 5 -warnings-as-errors -parse-as-library -module-name TelegramUIPreferences -I "$OUT/mods" \
  "$SRC/AdShieldTables.swift" "$SRC/LuminaAdShield.swift" "$SRC/LuminaAdShieldStore.swift" "$SRC/LuminaAdShieldAccount.swift" \
  "$SRC/LuminaKeychain.swift" "$SRC/LuminaLocalization.swift" "$SRC/LuminaSettings.swift" "$SRC/LuminaAdShieldService.swift" \
  "$HERE/PostboxKeysStub.swift" "$HERE/ServiceCheck.swift" \
  -L "$OUT" -lSwiftSignalKit -lTelegramCore -o "$OUT/service_check"
"$OUT/service_check"
