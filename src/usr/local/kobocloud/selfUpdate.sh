#!/bin/sh
# KoboCloud self-update
#
# Opt-in: add this line to kobocloudrc
#
#   UPDATE:owner/repo
#
# e.g. UPDATE:fsantini/KoboCloud   or   UPDATE:gerald-lnj/KoboCloud
#
# On every sync KoboCloud asks GitHub which commit is on the master branch of
# that repository and compares it with the commit recorded in the "version"
# file of the installed copy (/usr/local/kobocloud/version). If they differ,
# the latest release asset (KoboRoot.tgz) is downloaded and unpacked over the
# installation; if the repository has no release, the source archive of that
# commit is used instead. Before installing, every downloaded script is
# syntax checked; if anything looks wrong the previous copy is restored.
#
# The share/library configuration (kobocloudrc, Library/, get.log) lives on
# the reader partition and is never touched.
#
# Usage: selfUpdate.sh [--force]
#   --force (or KC_UPDATE_FORCE=1) installs even if the commit is unchanged.

#load config
. $(dirname $0)/config.sh

[ -z "$KC_CURL" ] && KC_CURL="$CURL"
[ -z "$KC_INSTALL_DIR" ] && KC_INSTALL_DIR=`dirname "$KC_HOME"`
[ -z "$KC_BACKUP_DIR" ] && KC_BACKUP_DIR="$KC_INSTALL_DIR/kobocloud.bak"
[ -z "$KC_WORK_DIR" ] && KC_WORK_DIR="/tmp/kobocloud-update"

forced=0
case "$1" in
    --force) forced=1 ;;
esac
[ "$KC_UPDATE_FORCE" = "1" ] && forced=1

dt() { date +%Y-%m-%d_%H:%M:%S; }
log() { echo "`dt` self-update: $1"; }

# ---------------------------------------------------------------------------
# which repository?
# ---------------------------------------------------------------------------

repo=`grep '^[[:space:]]*UPDATE:' "$UserConfig" 2>/dev/null | head -n 1 | sed 's/^[[:space:]]*UPDATE://' | tr -d '[:space:]'`

if [ -z "$repo" ]; then
    exit 0
fi

if ! echo "$repo" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    log "ignoring UPDATE line, expected UPDATE:owner/repo (got '$repo')"
    exit 1
fi

log "checking $repo"

installed=`cat "$KC_HOME/version" 2>/dev/null | tr -d '[:space:]'`

remote=`$KC_CURL -k -s -L --max-time 60 "https://api.github.com/repos/$repo/commits/master" |
    grep -m 1 -o '"sha": *"[0-9a-f]\{40\}"' |
    sed 's/.*"\([0-9a-f]\{40\}\)"/\1/')`

if [ -z "$remote" ]; then
    log "could not get the latest commit of $repo (no network, rate limit or bad repository name), giving up for now"
    exit 1
fi

if [ "$remote" = "$installed" ] && [ "$forced" = "0" ]; then
    log "already up to date ($remote)"
    exit 0
fi

if [ "$remote" = "$installed" ]; then
    log "forcing reinstall of $remote"
else
    log "update available: installed ${installed:-unknown}, latest $remote"
fi

# ---------------------------------------------------------------------------
# download
# ---------------------------------------------------------------------------

rm -rf "$KC_WORK_DIR"
mkdir -p "$KC_WORK_DIR" || { log "cannot create $KC_WORK_DIR"; exit 1; }
tgz="$KC_WORK_DIR/package.tgz"
unpacked="$KC_WORK_DIR/unpacked"
mkdir -p "$unpacked"

layout=""

# 1. release asset (this is what a normal installation uses)
if $KC_CURL -k -s -S -L --max-time 300 -o "$tgz" "https://github.com/$repo/releases/latest/download/KoboRoot.tgz" &&
   gzip -dc "$tgz" 2>/dev/null | tar tf - 2>/dev/null | grep -q '^usr/local/kobocloud/get.sh$'; then
    layout="release"
    log "downloaded the latest release of $repo"
# 2. source archive of the same commit (repositories without releases, e.g. forks)
elif $KC_CURL -k -s -S -L --max-time 300 -o "$tgz" "https://codeload.github.com/$repo/tar.gz/$remote" &&
     gzip -dc "$tgz" 2>/dev/null | tar tf - 2>/dev/null | grep -q 'src/usr/local/kobocloud/get.sh$'; then
    layout="source"
    log "downloaded the source archive of $remote ($repo has no release)"
else
    log "download failed, keeping the installed version"
    rm -rf "$KC_WORK_DIR"
    exit 1
fi

gzip -dc "$tgz" | tar xf - -C "$unpacked" 2>/dev/null ||
    { log "cannot unpack the downloaded archive"; rm -rf "$KC_WORK_DIR"; exit 1; }

if [ "$layout" = "release" ]; then
    newRoot="$unpacked"
else
    newRoot=`find "$unpacked" -maxdepth 1 -type d -name 'KoboCloud-*' | head -n 1`
    [ -z "$newRoot" ] && { log "unexpected source archive layout"; rm -rf "$KC_WORK_DIR"; exit 1; }
    newRoot="$newRoot/src"
fi

newKc="$newRoot/usr/local/kobocloud"
if [ ! -f "$newKc/get.sh" ]; then
    log "downloaded archive has no get.sh, aborting"
    rm -rf "$KC_WORK_DIR"
    exit 1
fi

# never install something that does not even parse
for script in "$newKc"/*.sh; do
    [ -e "$script" ] || continue
    if ! sh -n "$script" 2>/dev/null; then
        log "`basename "$script"` from the downloaded archive is not valid shell, aborting"
        rm -rf "$KC_WORK_DIR"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# install (write to a temp name, then rename, so the running scripts stay valid)
# ---------------------------------------------------------------------------

rm -rf "$KC_BACKUP_DIR"
if ! cp -a "$KC_HOME" "$KC_BACKUP_DIR" 2>/dev/null; then
    log "cannot back up $KC_HOME, aborting"
    rm -rf "$KC_WORK_DIR"
    exit 1
fi

installFile() { # installFile <source> <destination>
    local src dst tmp
    src="$1"
    dst="$2"
    tmp="$dst.kobocloud-new"
    if cp -p "$src" "$tmp" && mv -f "$tmp" "$dst"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

failed=0
for file in "$newKc"/*; do
    [ -e "$file" ] || continue
    installFile "$file" "$KC_HOME/`basename "$file"`" || failed=1
done

# udev rules and any other system file shipped in the release
if [ "$layout" = "release" ] && [ -d "$newRoot/etc/udev/rules.d" ] && [ -w /etc/udev/rules.d ]; then
    for file in "$newRoot/etc/udev/rules.d"/*; do
        [ -e "$file" ] || continue
        installFile "$file" "/etc/udev/rules.d/`basename "$file"`" || failed=1
    done
fi

if [ "$failed" = "0" ] && sh -n "$KC_HOME/get.sh" 2>/dev/null; then
    echo "$remote" > "$KC_HOME/version"
    log "updated to $remote (previous copy in $KC_BACKUP_DIR)"
else
    log "installation failed, restoring the previous version"
    rm -rf "$KC_HOME"
    if cp -a "$KC_BACKUP_DIR" "$KC_HOME"; then
        log "previous version restored"
    else
        log "ERROR: could not restore $KC_HOME, backup is in $KC_BACKUP_DIR"
    fi
    rm -rf "$KC_WORK_DIR"
    exit 1
fi

rm -rf "$KC_WORK_DIR"
exit 0
