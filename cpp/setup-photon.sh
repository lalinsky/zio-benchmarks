#!/bin/sh
# Prepare PhotonLibOS under cpp/libs/photon (clone + build), ready for build.sh.
# Not vendored — this clones and builds it on demand. Override the ref with
# PHOTON_REF=<tag|branch|commit> ./setup-photon.sh
#
# Needs cmake, a C++ toolchain, and (for --uring at runtime) kernel >= 5.8.
# The build compiles its own OpenSSL/libaio/liburing (PHOTON_BUILD_DEPENDENCIES).
set -e
cd "$(dirname "$0")"

REF=${PHOTON_REF:-}
DEST=libs/photon

mkdir -p libs
if [ ! -d "$DEST/.git" ]; then
    echo "Cloning PhotonLibOS ..."
    git clone https://github.com/alibaba/PhotonLibOS "$DEST"
fi
if [ -n "$REF" ]; then
    ( cd "$DEST" && git fetch --tags origin && git checkout "$REF" )
fi

cd "$DEST"
cmake -B build -D CMAKE_BUILD_TYPE=Release -D PHOTON_BUILD_TESTING=OFF \
      -D PHOTON_ENABLE_LIBCURL=OFF -D PHOTON_ENABLE_URING=ON \
      -D PHOTON_BUILD_DEPENDENCIES=ON \
      -D CMAKE_CXX_FLAGS="-Wno-error=unused-value"
cmake --build build -j"$(nproc)"

echo "photon built at cpp/$DEST"
