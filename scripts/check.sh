#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

zig fmt --check build.zig src tests
zig fmt --check --zon build.zig.zon
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test-integration
zig build test-planner
zig build
git diff --check
