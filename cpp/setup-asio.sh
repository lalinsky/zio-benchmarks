#!/bin/sh
# Prepare standalone Asio (header-only) under cpp/libs/asio, ready for build.sh.
# Not vendored — this downloads it on demand. Override the version with
# ASIO_VERSION=1-xx-y ./setup-asio.sh
set -e
cd "$(dirname "$0")"

VERSION=${ASIO_VERSION:-1-38-1}
DEST=libs/asio

if [ -f "$DEST/asio/include/asio.hpp" ]; then
    echo "asio already present at $DEST (headers in $DEST/asio/include)"
    exit 0
fi

mkdir -p libs
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading asio-$VERSION ..."
curl -fsSL "https://github.com/chriskohlhoff/asio/archive/refs/tags/asio-$VERSION.tar.gz" \
    | tar xz -C "$tmp"
rm -rf "$DEST"
mv "$tmp/asio-asio-$VERSION" "$DEST"

echo "asio $VERSION -> $DEST (headers in $DEST/asio/include)"
