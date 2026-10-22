#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BIN="${TMPDIR:-/tmp}/gasspair-localdevvpn-destination-tests-$$"
trap 'rm -f "$BIN"' EXIT INT TERM
swiftc "$ROOT/App/LocalDevVPNDestination.swift" "$ROOT/tools/LocalDevVPNDestinationTests.swift" -o "$BIN"
"$BIN"
