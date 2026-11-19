#!/bin/sh
# KoboCloud self-update
#
# Opt-in: add this line to kobocloudrc
#
#   UPDATE:owner/repo
#
# e.g. UPDATE:fsantini/KoboCloud   or   UPDATE:gerald-lnj/KoboCloud
#
# On every sync KoboCloud asks GitHub for the latest release of that
# repository (the "releases/latest" API endpoint) and compares its release id
# with the one recorded in the "release" file of the installed copy. When a
# different release is published, its KoboRoot.tgz asset is downloaded and
# installed: that is exactly the archive a normal installation unpacks.
# Before installing, every downloaded script is syntax checked; if anything
# looks wrong the previous copy is restored.
#
# The repository must publish releases. Both fsantini/KoboCloud and its forks
# do that from CI on every push to master. Upstream keeps reusing the tag
# "latest" and replaces the release, so the release id - not the tag - is what
# identifies a version here.
#
# The configuration (kobocloudrc, Library/, get.log) lives on the reader
# partition and is never touched.
#
# Usage: selfUpdate.sh [--force]
#   --force (or KC_UPDATE_FORCE=1) installs even if the release is unchanged.

#load config
. $(dirname $0)/config.sh

# Resolve a plain curl binary path. config_kobo.sh sets $CURL to a shell command
# string with embedded quotes ("curl --cacert \"$KC_HOME/ca-bundle.crt\""), which
# does not word-split correctly when expanded unquoted. selfUpdate passes -k (no
# certificate verification), so --cacert is not needed here.
if [ -z "$KC_CURL" ]; then
    if [ -x "$KC_HOME/curl" ]; then
        KC_CURL="$KC_HOME/curl"
    else
        KC_CURL=`command -v curl 2>/dev/null || echo /usr/bin/curl`
    fi
fi
[ -z "$KC_INSTALL_DIR" ] && KC_INSTALL_DIR=`dirname "$KC_HOME"`
[ -z "$KC_BACKUP_DIR" ] && KC_BACKUP_DIR="$KC_INSTALL_DIR/kobocloud.bak"
[ -z "$KC_WORK_DIR" ] && KC_WORK_DIR="/tmp/kobocloud-update"

forced=0
case "$1" in
    --force) forced=1 ;;
esac
[ "$KC_UPDATE_FORCE" = "1" ] && forced=1

dt() { echo "`date +%Y-%m-%d_%H:%M:%S`"; }
log() { echo "`dt` self-update: $1"; }

cleanup() { rm -rf "$KC_WORK_DIR"; }
trap cleanup EXIT INT TERM

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

log "checking the latest release of $repo"

rm -rf "$KC_WORK_DIR"
mkdir -p "$KC_WORK_DIR" || { log "cannot create $KC_WORK_DIR"; exit 1; }
json="$KC_WORK_DIR/release.json"

"$KC_CURL" -k -s -S -L --max-time 60 \
    "https://api.github.com/repos/$repo/releases/latest" -o "$json" 2>/dev/null

release=`grep -m 1 -o '"id": *[0-9]\{1,\}' "$json" 2>/dev/null | sed 's/.*: *//'`

if [ -z "$release" ]; then
    if grep -q '"message"' "$json" 2>/dev/null; then
        message=`grep -m 1 -o '"message": *"[^"]*"' "$json" | sed 's/.*: *"\([^"]*\)"/\1/'`
        log "GitHub returned no release for $repo ($message), nothing to do"
    else
        log "could not query GitHub for $repo (network problem or rate limit), giving up for now"
    fi
    exit 1
fi

tag=`grep -m 1 -o '"tag_name": *"[^"]*"' "$json" | sed 's/.*: *"\([^"]*\)"/\1/'`
published=`grep -m 1 -o '"published_at": *"[^"]*"' "$json" | sed 's/.*: *"\([^"]*\)"/\1/'`
assetUrl=`grep -o '"browser_download_url": *"[^"]*KoboRoot\.tgz"' "$json" |
    sed 's/.*: *"\([^"]*\)"/\1/' | head -n 1`

installed=`cat "$KC_HOME/release" 2>/dev/null | tr -d '[:space:]'`

if [ "$release" = "$installed" ] && [ "$forced" = "0" ]; then
    log "already up to date (release $release, tag ${tag:-?})"
    exit 0
fi

if [ "$release" = "$installed" ]; then
    log "forcing reinstall of release $release"
else
    log "update available: release $release (tag ${tag:-?}, published ${published:-?}), installed release ${installed:-unknown}"
fi

if [ -z "$assetUrl" ]; then
    log "release $release has no KoboRoot.tgz asset, keeping the installed version"
    exit 1
fi

# ---------------------------------------------------------------------------
# download and check
# ---------------------------------------------------------------------------

tgz="$KC_WORK_DIR/package.tgz"
unpacked="$KC_WORK_DIR/unpacked"
mkdir -p "$unpacked"

if ! "$KC_CURL" -k -s -S -L --max-time 300 -o "$tgz" "$assetUrl" ||
   ! gzip -dc "$tgz" 2>/dev/null | tar tf - 2>/dev/null | grep -q '^usr/local/kobocloud/get.sh$'; then
    log "download of $assetUrl failed, keeping the installed version"
    exit 1
fi

log "downloaded release $release from $assetUrl"

gzip -dc "$tgz" | tar xf - -C "$unpacked" 2>/dev/null ||
    { log "cannot unpack the downloaded archive"; exit 1; }

newKc="$unpacked/usr/local/kobocloud"
if [ ! -f "$newKc/get.sh" ]; then
    log "downloaded archive has no get.sh, aborting"
    exit 1
fi

# never install something that does not even parse
for script in "$newKc"/*.sh; do
    [ -e "$script" ] || continue
    if ! sh -n "$script" 2>/dev/null; then
        log "`basename "$script"` from release $release is not valid shell, aborting"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# install (write to a temp name, then rename, so the running scripts stay valid)
# ---------------------------------------------------------------------------

rm -rf "$KC_BACKUP_DIR"
if ! cp -a "$KC_HOME" "$KC_BACKUP_DIR" 2>/dev/null; then
    log "cannot back up $KC_HOME, aborting"
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
if [ -d "$unpacked/etc/udev/rules.d" ] && [ -w /etc/udev/rules.d ]; then
    for file in "$unpacked/etc/udev/rules.d"/*; do
        [ -e "$file" ] || continue
        installFile "$file" "/etc/udev/rules.d/`basename "$file"`" || failed=1
    done
fi

if [ "$failed" = "0" ] && sh -n "$KC_HOME/get.sh" 2>/dev/null; then
    echo "$release" > "$KC_HOME/release"
    log "installed release $release (tag ${tag:-?}, previous copy in $KC_BACKUP_DIR)"
else
    log "installation failed, restoring the previous version"
    rm -rf "$KC_HOME"
    if cp -a "$KC_BACKUP_DIR" "$KC_HOME"; then
        log "previous version restored"
    else
        log "ERROR: could not restore $KC_HOME, backup is in $KC_BACKUP_DIR"
    fi
    exit 1
fi

exit 0
