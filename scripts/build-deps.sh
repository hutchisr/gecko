#!/usr/bin/env bash
# Cross-compile the libraries Gecko links for iOS and Mac Catalyst: libomemo-c
# (with protobuf-c) for OMEMO, GRDB for the store, and the prebuilt WebRTC
# framework for calls.
#
# Usage: ./build-deps.sh [sim-arm64|device-arm64|catalyst-arm64] [dep ...]
#        With no dep arguments, builds everything in order.
#
# Everything lands in build/prefix/<target> (static libraries, WebRTC framework).
set -euo pipefail

TARGET="${1:-sim-arm64}"
shift || true

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$REPO/build/deps"
PREFIX="$REPO/build/prefix/$TARGET"
NCPU="$(sysctl -n hw.ncpu)"
MIN_IOS=16.0

OMEMO_C_VER=0.5.1
PROTOBUF_C_VER=1.5.2
WEBRTC_VER=157.0.0
# Keep equal to the GRDB version in GeckoKit/Package.swift (host tests).
GRDB_VER=7.12.0

case "$TARGET" in
  sim-arm64)      SDK=iphonesimulator; TRIPLE="arm64-apple-ios${MIN_IOS}-simulator" ;;
  device-arm64)   SDK=iphoneos;        TRIPLE="arm64-apple-ios${MIN_IOS}" ;;
  catalyst-arm64) SDK=macosx;          TRIPLE="arm64-apple-ios${MIN_IOS}-macabi" ;;
  *) echo "unknown target $TARGET" >&2; exit 1 ;;
esac

SDKPATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
CLANG="$(xcrun --sdk "$SDK" -f clang)"
CLANGXX="$(xcrun --sdk "$SDK" -f clang++)"

mkdir -p "$DEPS" "$PREFIX"

fetch() { # fetch <url> <dirname>
  local url="$1" dir="$2"
  if [ ! -d "$DEPS/$dir" ]; then
    echo "downloading $url"
    curl -fsSL "$url" -o "$DEPS/$dir.tar.xz.tmp"
    mkdir -p "$DEPS/$dir"
    tar -xf "$DEPS/$dir.tar.xz.tmp" -C "$DEPS/$dir" --strip-components=1
    rm "$DEPS/$dir.tar.xz.tmp"
  fi
}

fetch_zip() { # fetch_zip <url> <dirname> <entry expected inside it>
  local url="$1" dir="$2" entry="$3"
  if [ ! -e "$DEPS/$dir/$entry" ]; then
    echo "downloading $url"
    curl -fsSL "$url" -o "$DEPS/$dir.zip.tmp"
    mkdir -p "$DEPS/$dir"
    ditto -x -k "$DEPS/$dir.zip.tmp" "$DEPS/$dir"
    rm "$DEPS/$dir.zip.tmp"
  fi
}

autotools_build() { # autotools_build <srcdir> [extra configure args...]
  local src="$1"; shift
  cd "$src"
  make distclean >/dev/null 2>&1 || true
  PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig" \
  CC="$CLANG -target $TRIPLE -isysroot $SDKPATH" \
  CXX="$CLANGXX -target $TRIPLE -isysroot $SDKPATH" \
  ./configure --host=aarch64-apple-darwin --prefix="$PREFIX" \
    --disable-shared --enable-static "$@"
  make -j "$NCPU"
  make install
  cd -
}

build_protobuf_c() {
  fetch "https://github.com/protobuf-c/protobuf-c/releases/download/v$PROTOBUF_C_VER/protobuf-c-$PROTOBUF_C_VER.tar.gz" "protobuf-c"
  autotools_build "$DEPS/protobuf-c" --disable-protoc
}

build_omemo_c() {
  fetch "https://github.com/dino/libomemo-c/archive/refs/tags/v$OMEMO_C_VER.tar.gz" "libomemo-c"
  local platform_args cmake_cflags="-I$PREFIX/include"
  if [ "$TARGET" = "catalyst-arm64" ]; then
    platform_args=(
      -DCMAKE_SYSTEM_NAME=Darwin
      -DCMAKE_OSX_SYSROOT="$SDKPATH"
      -DCMAKE_C_COMPILER="$CLANG"
      -DCMAKE_C_COMPILER_TARGET="$TRIPLE"
    )
    cmake_cflags="-target $TRIPLE -isysroot $SDKPATH -I$PREFIX/include"
  else
    platform_args=(
      -DCMAKE_SYSTEM_NAME=iOS
      -DCMAKE_OSX_SYSROOT="$SDKPATH"
      -DCMAKE_OSX_ARCHITECTURES=arm64
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS"
    )
  fi
  cmake -S "$DEPS/libomemo-c" -B "$DEPS/libomemo-c/_build-$TARGET" \
    "${platform_args[@]}" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_C_FLAGS="$cmake_cflags" \
    -DCMAKE_EXE_LINKER_FLAGS="-L$PREFIX/lib" \
    -DCMAKE_FIND_ROOT_PATH="$PREFIX"
  cmake --build "$DEPS/libomemo-c/_build-$TARGET" -j "$NCPU"
  cmake --install "$DEPS/libomemo-c/_build-$TARGET"
}

build_webrtc() {
  # Prebuilt, so nothing is compiled: fetch the xcframework once and stage the
  # slice for this target where the app build links and embeds it. ditto keeps
  # the symlinks of the Catalyst slice, which is a versioned macOS-style bundle.
  local dir="webrtc-$WEBRTC_VER" slice
  case "$TARGET" in
    sim-arm64)      slice=ios-x86_64_arm64-simulator ;;
    device-arm64)   slice=ios-arm64 ;;
    catalyst-arm64) slice=ios-x86_64_arm64-maccatalyst ;;
  esac
  fetch_zip "https://github.com/stasel/WebRTC/releases/download/$WEBRTC_VER/WebRTC-M${WEBRTC_VER%%.*}.xcframework.zip" \
    "$dir" WebRTC.xcframework
  rm -rf "$PREFIX/Frameworks/WebRTC.framework"
  mkdir -p "$PREFIX/Frameworks"
  ditto "$DEPS/$dir/WebRTC.xcframework/$slice/WebRTC.framework" "$PREFIX/Frameworks/WebRTC.framework"
}

build_grdb() {
  # GRDB (MIT) ships no binaries: compile its Swift sources into a static
  # library and module for this target, against the system SQLite. The app
  # imports it through lib/swift and include/GRDBSQLite. The textual interface
  # lets a newer Xcode's compiler keep importing it without a rebuild.
  local dir="GRDB.swift-$GRDB_VER"
  fetch "https://github.com/groue/GRDB.swift/archive/refs/tags/v$GRDB_VER.tar.gz" "$dir"
  mkdir -p "$PREFIX/lib/swift" "$PREFIX/include/GRDBSQLite"
  cp "$DEPS/$dir/Sources/GRDBSQLite/module.modulemap" "$DEPS/$dir/Sources/GRDBSQLite/shim.h" \
    "$PREFIX/include/GRDBSQLite/"
  local catalyst=()
  # Catalyst finds UIKit among the macOS SDK's iOS-support frameworks.
  [ "$TARGET" = catalyst-arm64 ] && catalyst=(-Fsystem "$SDKPATH/System/iOSSupport/System/Library/Frameworks")
  (cd "$DEPS/$dir" && xcrun -sdk "$SDK" swiftc -target "$TRIPLE" -sdk "$SDKPATH" ${catalyst[@]+"${catalyst[@]}"} \
    -module-name GRDB -parse-as-library -O -whole-module-optimization -swift-version 6 \
    -enable-upcoming-feature MemberImportVisibility -D SQLITE_ENABLE_FTS5 -D SQLITE_ENABLE_SNAPSHOT \
    -I Sources/GRDBSQLite -emit-library -static -emit-module \
    -enable-library-evolution -emit-module-interface-path "$PREFIX/lib/swift/GRDB.swiftinterface" \
    -emit-module-path "$PREFIX/lib/swift/GRDB.swiftmodule" -o "$PREFIX/lib/libGRDB.a" \
    $(find GRDB -name '*.swift'))
}

if [ $# -eq 0 ]; then
  set -- protobuf_c omemo_c webrtc grdb
fi
for dep in "$@"; do
  echo "=== building $dep ($TARGET) ==="
  "build_$dep"
done
echo "=== done: $PREFIX ==="
