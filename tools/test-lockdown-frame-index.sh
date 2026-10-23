#!/bin/sh
set -eu
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BIN="$(mktemp "${TMPDIR:-/tmp}/gasspair-frame-test.XXXXXX")"
trap 'rm -f "$BIN"' EXIT
swiftc -parse-as-library "$HERE/LockdownFrameIndexRegressionTests.swift" -o "$BIN"
"$BIN"
