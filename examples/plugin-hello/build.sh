#!/bin/sh
# Build the hello plugin into ./build/ (hello.dylib on macOS, hello.so elsewhere).
# Usage: ./build.sh   — requires only a C compiler (cc/clang/gcc).
set -eu
cd "$(dirname "$0")"
mkdir -p build

CC="${CC:-cc}"
case "$(uname -s)" in
    Darwin)
        OUT=build/hello.dylib
        # clang -shared produces a loadable dylib; -fPIC is implicit but explicit is fine.
        FLAGS="-shared -fPIC"
        ;;
    *)
        OUT=build/hello.so
        FLAGS="-shared -fPIC"
        ;;
esac

"$CC" $FLAGS -O2 -Wall -Wextra -o "$OUT" hello.c
echo "built $OUT"
