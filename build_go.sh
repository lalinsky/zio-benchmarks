#!/bin/sh
# Build all go benchmark counterparts into zig-out/bin/<name>_go.
set -e

cd "$(dirname "$0")"
mkdir -p zig-out/bin
for dir in go/*/; do
    name=$(basename "$dir")
    (cd go && go build -o "../zig-out/bin/${name}_go" "./$name")
    echo "zig-out/bin/${name}_go"
done
