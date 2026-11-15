#!/bin/bash
# Tests for the self-update support of KoboCloud.
# No network access is needed: curl is replaced by a stub that serves prepared
# release/source archives.

cd "$(dirname "$0")" || exit 1

KC=src/usr/local/kobocloud
Work=/tmp/kobocloud-update-test
Root=$Work/usr/local
Install=$Root/kobocloud
Stubs=$Work/stubs
Data=$Work/data
CurlLog=$Work/curl.log
FAILED=0

. $KC/config_pc.sh

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }
check() {
    desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222

# ---------------------------------------------------------------------------
# stub curl: serves files from $Data depending on the URL
# ---------------------------------------------------------------------------
rm -rf "$Work"
mkdir -p "$Stubs" "$Data"

cat > "$Stubs/curl" <<EOF
#!/bin/bash
echo "curl \$*" >> "$CurlLog"
out=""
prev=""
for a in "\$@"; do
    [ "\$prev" = "-o" ] && out="\$a"
    prev="\$a"
done
url=""
for a in "\$@"; do
    case "\$a" in http*) url="\$a" ;; esac
done
case "\$url" in
    *api.github.com/repos/*/commits/master)
        cat "$Data/commits.json" ;;
    *releases/latest/download/KoboRoot.tgz)
        [ -f "$Data/release.tgz" ] || exit 22
        [ -n "\$out" ] && cp "$Data/release.tgz" "\$out" ;;
    *codeload.github.com/*)
        [ -f "$Data/source.tar.gz" ] || exit 22
        [ -n "\$out" ] && cp "$Data/source.tar.gz" "\$out" ;;
    *) exit 22 ;;
esac
EOF
chmod +x "$Stubs/curl"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
makeRelease() { # makeRelease <dir> <marker>
    rm -rf "$1"
    mkdir -p "$1/usr/local/kobocloud"
    for f in "$KC"/*; do
        [ -e "$f" ] || continue
        cp "$f" "$1/usr/local/kobocloud/"
    done
    echo "$2" >> "$1/usr/local/kobocloud/get.sh"
    rm -rf "$Data/release.tgz"
    tar czf "$Data/release.tgz" -C "$1" usr
}

makeSourceArchive() { # makeSourceArchive <marker>
    rm -rf "$Work/srcdir"
    mkdir -p "$Work/srcdir/KoboCloud-$NEW_SHA/src/usr/local"
    cp -a "$KC" "$Work/srcdir/KoboCloud-$NEW_SHA/src/usr/local/kobocloud"
    echo "$1" >> "$Work/srcdir/KoboCloud-$NEW_SHA/src/usr/local/kobocloud/get.sh"
    cp -a src/etc "$Work/srcdir/KoboCloud-$NEW_SHA/src/" 2>/dev/null
    rm -f "$Data/source.tar.gz"
    tar czf "$Data/source.tar.gz" -C "$Work/srcdir" "KoboCloud-$NEW_SHA"
}

resetInstall() { # resetInstall <installed-version> [<config lines>]
    rm -rf "$Root"
    mkdir -p "$Install"
    for f in "$KC"/*; do
        [ -e "$f" ] || continue
        cp "$f" "$Install/"
    done
    chmod +x "$Install"/*.sh
    if [ -n "$1" ]; then echo "$1" > "$Install/version"; fi
    rm -rf "$Logs"
    mkdir -p "$Logs" "$Lib"
    printf '%s\n' "$2" > "$UserConfig"
    rm -f "$CurlLog"
    rm -rf "$Work/work"
}

runUpdate() {
    ( cd "$Install" && \
      KC_CURL="$Stubs/curl" \
      KC_WORK_DIR="$Work/work" \
      "$@" sh "$Install/selfUpdate.sh" ${FORCE_ARG:-} ) > "$Work/out.log" 2>&1
    echo $? > "$Work/status"
}

status() { cat "$Work/status"; }

# ---------------------------------------------------------------------------
echo "== 1. no UPDATE line: nothing happens"
resetInstall "$OLD_SHA" "# nothing here"
runUpdate
check "exits cleanly"          test "`status`" = "0"
check "no network access"      test ! -s "$CurlLog"

# ---------------------------------------------------------------------------
echo "== 2. installed version is already the latest"
resetInstall "$OLD_SHA" "UPDATE:someone/KoboCloud"
printf '{\n  "sha": "%s",\n  "node_id": "x"\n}\n' "$OLD_SHA" > "$Data/commits.json"
runUpdate
check "exits cleanly"                 test "`status`" = "0"
check "no download"                   bash -c "! grep -q 'releases/latest' '$CurlLog'"
check "reports up to date"            grep -q "already up to date" "$Work/out.log"

# ---------------------------------------------------------------------------
echo "== 3. new commit: release asset installed"
makeRelease "$Work/release-v2" "MARKER_V2"
resetInstall "$OLD_SHA" "UPDATE:someone/KoboCloud"
printf '{\n  "sha": "%s",\n  "node_id": "x"\n}\n' "$NEW_SHA" > "$Data/commits.json"
runUpdate
check "exits cleanly"                 test "`status`" = "0"
check "get.sh replaced"               grep -q MARKER_V2 "$Install/get.sh"
check "version file updated"          grep -q "$NEW_SHA" "$Install/version"
check "backup of the old copy kept"   test -d "$Root/kobocloud.bak"
check "backup is the old version"     bash -c "! grep -q MARKER_V2 '$Root/kobocloud.bak/get.sh'"
check "config untouched"              grep -q "UPDATE:someone/KoboCloud" "$UserConfig"
check "workspace cleaned"             test ! -d "$Work/work"

# ---------------------------------------------------------------------------
echo "== 4. broken package is rejected, installed copy untouched"
makeRelease "$Work/release-broken" "MARKER_BROKEN"
echo "if then fi do (" >> "$Work/release-broken/usr/local/kobocloud/get.sh"
rm -f "$Data/release.tgz"
tar czf "$Data/release.tgz" -C "$Work/release-broken" usr
rm -f "$Data/source.tar.gz"
resetInstall "$OLD_SHA" "UPDATE:someone/KoboCloud"
printf '{\n  "sha": "%s"\n}\n' "$NEW_SHA" > "$Data/commits.json"
runUpdate
check "reports failure"               test "`status`" != "0"
check "get.sh untouched"              bash -c "! grep -q MARKER_BROKEN '$Install/get.sh'"
check "version not bumped"            grep -q "$OLD_SHA" "$Install/version"
check "explains why"                  grep -q "not valid shell" "$Work/out.log"

# ---------------------------------------------------------------------------
echo "== 5. no release: source archive of the commit is used"
makeSourceArchive "MARKER_SOURCE"
resetInstall "$OLD_SHA" "UPDATE:someone/KoboCloud"
printf '{\n  "sha": "%s"\n}\n' "$NEW_SHA" > "$Data/commits.json"
rm -f "$Data/release.tgz"
runUpdate
check "exits cleanly"                 test "`status`" = "0"
check "source archive was used"       grep -q "no release" "$Work/out.log"
check "scripts installed"             grep -q MARKER_SOURCE "$Install/get.sh"
check "version file updated"          grep -q "$NEW_SHA" "$Install/version"

# ---------------------------------------------------------------------------
echo "== 6. unusable UPDATE line is refused"
resetInstall "$OLD_SHA" "UPDATE:not-a-repo"
runUpdate
check "reports the problem"           grep -q "expected UPDATE:owner/repo" "$Work/out.log"
check "exits with error"              test "`status`" != "0"
check "no network access"             test ! -s "$CurlLog"

# ---------------------------------------------------------------------------
echo "== 7. --force reinstalls the same commit"
makeRelease "$Work/release-v3" "MARKER_V3"
resetInstall "$NEW_SHA" "UPDATE:someone/KoboCloud"
printf '{\n  "sha": "%s"\n}\n' "$NEW_SHA" > "$Data/commits.json"
FORCE_ARG="--force"
runUpdate
FORCE_ARG=""
check "exits cleanly"                 test "`status`" = "0"
check "reinstalled anyway"            grep -q MARKER_V3 "$Install/get.sh"
check "logged as forced"              grep -q "forcing reinstall" "$Work/out.log"

# ---------------------------------------------------------------------------
echo
if [ "$FAILED" -eq 0 ]; then
    echo "All self-update tests passed"
    exit 0
fi
echo "$FAILED self-update test(s) failed"
exit 1
