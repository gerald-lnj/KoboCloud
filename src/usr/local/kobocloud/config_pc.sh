#!/bin/sh
: "${KC_BASE_DIR:=/tmp/KoboCloud}"
Logs="$KC_BASE_DIR"
Lib="$KC_BASE_DIR/Library"
SD="$KC_BASE_DIR/sd"
UserConfig="$KC_BASE_DIR/kobocloudrc"
Dt="date +%Y-%m-%d_%H:%M:%S"
CURL=/usr/bin/curl
SMBMOUNT="$KC_BASE_DIR/smb"
PLATFORM=PC
