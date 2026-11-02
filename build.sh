#!/bin/sh
# Usage: ./build.sh          build build/Launcher.app
#        ./build.sh install  also copy it to /Applications and launch it
set -e
cd "$(dirname "$0")"

APP=build/Launcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/Launcher" Sources/main.swift
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "$1" = "install" ]; then
    pkill -x Launcher || true
    rm -rf /Applications/Launcher.app
    cp -R "$APP" /Applications/
    open /Applications/Launcher.app
    echo "Installed to /Applications/Launcher.app"
fi
