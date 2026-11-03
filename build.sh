#!/bin/sh
# Builds the FLS command-line tool and FLS.app (the menu bar app that controls it).
set -e
cd "$(dirname "$0")"

clang -O2 -Wall -Wextra -o FLS fls.c

contents=FLS.app/Contents
rm -rf FLS.app
mkdir -p "$contents/MacOS" "$contents/Resources"
swiftc -O -o "$contents/MacOS/FLS" menu.swift
cp FLS install.sh uninstall.sh "$contents/Resources/"

info="$contents/Info.plist"
plutil -create xml1 "$info"
plutil -insert CFBundleName -string FLS "$info"
plutil -insert CFBundleExecutable -string FLS "$info"
plutil -insert CFBundleIdentifier -string com.fls.menu "$info"
plutil -insert CFBundlePackageType -string APPL "$info"
plutil -insert CFBundleShortVersionString -string 1.0 "$info"
plutil -insert LSUIElement -bool true "$info"  # menu bar only, no Dock icon

codesign --force --deep --sign - FLS.app
