#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
cat > "$build/adb" <<'ADB'
#!/bin/bash
printf '%s\n' "$@" >> "$BOOX_TEST_LOG"
case "$*" in
  wait) exec /bin/sleep 20;;
  'mdns services') printf 'device _adb-tls-connect._tcp. 192.168.1.9:4567\n';;
  *get-state) echo device;;
  *ro.serialno)
    case "$*" in *192.168.1.8*) echo WRONG;; *) echo BOOX123;; esac;;
  *'am start'*) echo 'Status: ok';;
esac
ADB
chmod +x "$build/adb"
cp "$source_dir/Tests.swift" "$build/main.swift"
swiftc -D TESTING -module-cache-path "${BOOX_SWIFT_MODULE_CACHE:-$build/cache}" "$source_dir/SendToBoox.swift" "$build/main.swift" -o "$build/tests"
BOOX_TEST_LOG="$build/log" "$build/tests" "$build"
