#!/bin/sh

repo=$1
build=$2

cd "$repo/build-x86-$build"

cmake .. -DCMAKE_BUILD_TYPE="$build" -DENABLE_FAUDIO=TRUE -DUPSTREAM_RELEASE=TRUE -G Ninja

if [ ! -f build.ninja ]; then
    echo >&2 "mingw cmake failed"
    exit 1
fi

ninja

if [ $? -ne 0 ]; then
    echo >&2 "mingw build failed"
    exit 1
fi
