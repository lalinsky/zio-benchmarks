#!/bin/sh
set -e

name=$1
bin=./zig-out/bin

hyperfine \
    --warmup 3 \
    "$bin/$name --zio" \
    "$bin/$name --zio-mt" \
    "$bin/$name --threaded" \
    "$bin/${name}_go"
