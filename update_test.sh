#!/bin/bash
# Tests for the self-update support of KoboCloud.
# No network access is needed: curl is replaced by a stub that serves a
# prepared releases/latest response and release asset.

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

OLD_RELEASE=111111111
NEW_RELEASE=222222222

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
    *api.github.com/repos/*/releases/latest)
        [ -f "$Data/release.json" ] || exit 22
        [ -n "\$out" ] && cp "$Data/release.json" "\$out" || cat "$Data/release.json" ;;
    *releases/download/*/KoboRoot.tgz)
        [ -f "$Data/release.tgz" ] || exit 22
        [ -n "\$out" ] && cp "$Data/release.tgz" "\$out" ;;
    *) exit 22 ;;
esac
EOF
chmod +x "$Stubs/curl"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
writeReleaseJson() { # writeReleaseJson <id> [<asset>]
    asset="${2-https://github.com/someone/KoboCloud/releases/download/latest/KoboRoot.tgz}"
    [ "$asset" = "NONE" ] && asset=""
    {
        echo '{'
        echo '  "url": "https://api.github.com/repos/someone/KoboCloud/releases/'"$1"'",'
        echo '  "id": '"$1"','
        echo '  "tag_name": "latest",'
        echo '  "target_commitish": "master",'
        echo '  "published_at": "2026-11-15T12:00:00Z",'
        echo '  "assets": ['
        if [ -n "$asset" ]; then
            echo '    { "name": "KoboRoot.tgz", "browser_download_url": "'"$asset"'" }'
        fi
        echo '  ]'
        echo '}'
    } > "$Data/release.json"
}

noReleaseJson() {
    printf '{\n  "message": "Not Found",\n  "documentation_url": "https://docs.github.com"\n}\n' > "$Data/release.json"
}

makeRelease() { # makeRelease <dir> <marker>
    rm -rf "$1"
    mkdir -p "$1/usr/local/kobocloud"
    for f in "$KC"/*; do
        [ -e "$f" ] || continue
        cp "$f" "$1/usr/local/kobocloud/"
    done
    echo "$2" >> "$1/usr/local/kobocloud/get.sh"
    rm -f "$Data/release.tgz"
    tar czf "$Data/release.tgz" -C "$1" usr
}

resetInstall() { # resetInstall <installed-release-id> [<config line>]
    rm -rf "$Root"
    mkdir -p "$Install"
    for f in "$KC"/*; do
        [ -e "$f" ] || continue
        cp "$f" "$Install/"
    done
    chmod +x "$Install"/*.sh
    if [ -n "$1" ]; then echo "$1" > "$Install/release"; fi
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
resetInstall "" "# nothing here"
runUpdate
check "exits cleanly"          test "`status`" = "0"
check "no network access"      test ! -s "$CurlLog"

# ---------------------------------------------------------------------------
echo "== 2. repository has no release"
resetInstall "" "UPDATE:someone/KoboCloud"
noReleaseJson
makeRelease "$Work/release-v1" "MARKER_V1"
runUpdate
check "exits with an error"    test "`status`" != "0"
check "explains there is no release" grep -q "returned no release" "$Work/out.log"
check "nothing installed"      bash -c "! grep -q MARKER_V1 '$Install/get.sh'"
check "no asset downloaded"    bash -c "! grep -q 'KoboRoot.tgz' '$CurlLog'"

# ---------------------------------------------------------------------------
echo "== 3. installed release is already the latest"
resetInstall "$OLD_RELEASE" "UPDATE:someone/KoboCloud"
writeReleaseJson "$OLD_RELEASE"
runUpdate
check "exits cleanly"          test "`status`" = "0"
check "reports up to date"     grep -q "already up to date" "$Work/out.log"
check "no asset downloaded"    bash -c "! grep -q 'KoboRoot.tgz' '$CurlLog'"

# ---------------------------------------------------------------------------
echo "== 4. new release published: asset installed"
makeRelease "$Work/release-v2" "MARKER_V2"
resetInstall "$OLD_RELEASE" "UPDATE:someone/KoboCloud"
writeReleaseJson "$NEW_RELEASE"
runUpdate
check "exits cleanly"                 test "`status`" = "0"
check "get.sh replaced"               grep -q MARKER_V2 "$Install/get.sh"
check "release id recorded"           grep -q "$NEW_RELEASE" "$Install/release"
check "backup of the old copy kept"   test -d "$Root/kobocloud.bak"
check "backup is the old version"     bash -c "! grep -q MARKER_V2 '$Root/kobocloud.bak/get.sh'"
check "config untouched"              grep -q "UPDATE:someone/KoboCloud" "$UserConfig"
check "workspace cleaned"             test ! -d "$Work/work"
check "logs the download"             grep -q "downloaded release $NEW_RELEASE" "$Work/out.log"

# ---------------------------------------------------------------------------
echo "== 5. broken package is rejected, installed copy untouched"
makeRelease "$Work/release-broken" "MARKER_BROKEN"
echo "if then fi do (" >> "$Work/release-broken/usr/local/kobocloud/get.sh"
rm -f "$Data/release.tgz"
tar czf "$Data/release.tgz" -C "$Work/release-broken" usr
resetInstall "$OLD_RELEASE" "UPDATE:someone/KoboCloud"
writeReleaseJson "$NEW_RELEASE"
runUpdate
check "reports failure"               test "`status`" != "0"
check "get.sh untouched"              bash -c "! grep -q MARKER_BROKEN '$Install/get.sh'"
check "release id not bumped"         grep -q "$OLD_RELEASE" "$Install/release"
check "explains why"                  grep -q "not valid shell" "$Work/out.log"

# ---------------------------------------------------------------------------
echo "== 6. release without a KoboRoot.tgz asset"
resetInstall "$OLD_RELEASE" "UPDATE:someone/KoboCloud"
writeReleaseJson "$NEW_RELEASE" NONE
runUpdate
check "reports failure"               test "`status`" != "0"
check "explains why"                  grep -q "has no KoboRoot.tgz asset" "$Work/out.log"
check "release id not bumped"         grep -q "$OLD_RELEASE" "$Install/release"
check "no asset downloaded"           bash -c "! grep -q 'KoboRoot.tgz\"' '$CurlLog'"

# ---------------------------------------------------------------------------
echo "== 7. unusable UPDATE line is refused"
resetInstall "$OLD_RELEASE" "UPDATE:not-a-repo"
runUpdate
check "reports the problem"           grep -q "expected UPDATE:owner/repo" "$Work/out.log"
check "exits with error"              test "`status`" != "0"
check "no network access"             test ! -s "$CurlLog"

# ---------------------------------------------------------------------------
echo "== 8. --force reinstalls the same release"
makeRelease "$Work/release-v3" "MARKER_V3"
resetInstall "$NEW_RELEASE" "UPDATE:someone/KoboCloud"
writeReleaseJson "$NEW_RELEASE"
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
