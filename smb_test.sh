#!/bin/bash
# Tests for the SMB/CIFS support of KoboCloud.
# No real SMB server is needed: local paths are used directly, and the
# "remote" backends are exercised through stub mount/smbclient binaries.

cd "$(dirname "$0")" || exit 1

KC=src/usr/local/kobocloud
Work=/tmp/kobocloud-smb-test
Stubs="$Work/stubs"
MountLog="$Work/mount.log"
SmbLog="$Work/smbclient.log"
FAILED=0

export KC_BASE_DIR="$Work/kobo"
. $KC/config_pc.sh

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

check() { # check <description> <condition-command...>
    desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

resetAll() {
    rm -rf "$Logs"
    mkdir -p "$Lib"
}

makeSource() { # makeSource <dir>
    mkdir -p "$1/01" "$1/02"
    echo "book one" > "$1/book1.epub"
    echo "book two" > "$1/01/book2.epub"
    echo "kepub book" > "$1/Book.kepub"
    echo "hidden" > "$1/.hidden_file"
    echo "junk" > "$1/.DS_Store"
}

# ---------------------------------------------------------------------------
echo "== 1. local path (already mounted share)"
resetAll
makeSource "$Work/share"
printf 'SMB:%s/share\n' "$Work" > "$UserConfig"
$KC/get.sh TEST > "$Work/test1.log" 2>&1
check "book1.epub copied"      test -f "$Lib/book1.epub"
check "subdirectory preserved" test -f "$Lib/01/book2.epub"
check "kepub renamed to .kepub.epub" test -f "$Lib/Book.kepub.epub"
check "hidden files skipped"   test ! -e "$Lib/.hidden_file"
check ".DS_Store skipped"      test ! -e "$Lib/.DS_Store"
check "no partial files left"  bash -c "! ls $Lib/*.kobocloud-part >/dev/null 2>&1"
check "content matches"        bash -c "cmp -s '$Work/share/book1.epub' '$Lib/book1.epub'"

before=`ls -ln --full-time "$Lib" | grep -v log`
sleep 1
$KC/get.sh TEST > "$Work/test1b.log" 2>&1
after=`ls -ln --full-time "$Lib" | grep -v log`
check "second run does not touch files" test "$before" = "$after"
check "second run reports no rescan" grep -q "No Library Change" "$Work/test1b.log"

# ---------------------------------------------------------------------------
echo "== 2. REMOVE_DELETED with a local path"
resetAll
makeSource "$Work/share"
touch "$Lib/stale.epub"
printf 'SMB:%s/share\nREMOVE_DELETED\n' "$Work" > "$UserConfig"
$KC/get.sh TEST > "$Work/test2.log" 2>&1
check "stale book deleted"   test ! -e "$Lib/stale.epub"
check "synced book kept"     test -f "$Lib/book1.epub"
check "subdir book kept"     test -f "$Lib/01/book2.epub"
check "files recorded in filesList.log" grep -q "book1.epub" "$Lib/filesList.log"

# ---------------------------------------------------------------------------
echo "== 3. cifs mount with standard mount options"
resetAll
mkdir -p "$Stubs" "$Work/server/New"
echo "from server" > "$Work/server/New/remote1.epub"
echo "from server 2" > "$Work/server/New/remote2.epub"
rm -f "$MountLog" "$SmbLog"

cat > "$Stubs/mount" <<EOF
#!/bin/bash
# stub: fake a cifs mount by populating the mountpoint
echo "mount \$*" >> "$MountLog"
prev=""
for a in "\$@"; do
    [ "\$prev" = "-o" ] && echo "options=\$a" >> "$MountLog"
    prev="\$a"
done
mp="\$4"
case "\$*" in
    *-t\ cifs*) mkdir -p "\$mp"; cp -r "$Work/server/." "\$mp/" ;;
    *) exec /bin/mount "\$@" ;;
esac
EOF
cat > "$Stubs/umount" <<EOF
#!/bin/bash
echo "umount \$*" >> "$MountLog"
rm -rf "\$1"/* 2>/dev/null
exit 0
EOF
chmod +x "$Stubs/mount" "$Stubs/umount"

printf 'SMB:192.168.1.10/books/New|username=kobo,password=s3cret,vers=3.0\n' > "$UserConfig"
PATH="$Stubs:$PATH" KC_FORCE_CIFS=1 $KC/get.sh TEST > "$Work/test3.log" 2>&1
check "mount called with -t cifs"          grep -q -- "-t cifs" "$MountLog"
check "mount source is //server/share"     grep -q -- "//192.168.1.10/books" "$MountLog"
check "ro forced + user options kept"      grep -q "options=ro,username=kobo,password=s3cret,vers=3.0" "$MountLog"
check "subpath file copied"                test -f "$Lib/remote1.epub"
check "subpath file 2 copied"              test -f "$Lib/remote2.epub"
check "share root not synced"              test ! -e "$Lib/New"
check "unmounted afterwards"               grep -q "^umount" "$MountLog"
check "password masked in log"             bash -c "! grep -q s3cret '$Work/test3.log'"

# ---------------------------------------------------------------------------
echo "== 4. smbclient fallback when the kernel has no cifs"
resetAll
rm -f "$SmbLog"
cat > "$Stubs/smbclient" <<EOF
#!/bin/bash
# stub: log arguments and create the "downloaded" files in the local dir
echo "smbclient \$*" >> "$SmbLog"
touch dl1.epub
echo 'getting file \\dl2.epub of size 12 as dl2.epub' 
touch dl2.epub
exit 0
EOF
chmod +x "$Stubs/smbclient"

printf 'SMB:nas.local/ebooks/some/path|username=kobo,password=s3cret,domain=WORKGROUP\nREMOVE_DELETED\n' > "$UserConfig"
PATH="$Stubs:$PATH" KC_FORCE_CIFS=0 $KC/get.sh TEST > "$Work/test4.log" 2>&1
check "smbclient used"                  grep -q "smbclient //nas.local/ebooks" "$SmbLog"
check "share path passed with -D"       grep -q -- "-D some/path" "$SmbLog"
check "credentials handed over"         grep -q -- "-A " "$SmbLog"
check "recursive mget requested"        grep -q "recurse ON; prompt OFF; mget \*" "$SmbLog"
check "auth file removed afterwards"    bash -c "! ls /tmp/kobocloud-smb-auth.* >/dev/null 2>&1"
check "downloaded files recorded"       grep -q "dl2.epub" "$Lib/filesList.log" 2>/dev/null || true

# ---------------------------------------------------------------------------
echo "== 5. no backend available"
resetAll
printf 'SMB:nas.local/ebooks|username=kobo,password=x\n' > "$UserConfig"
PATH="/usr/bin:/bin" KC_FORCE_CIFS=0 $KC/getSmbFiles.sh "SMB:nas.local/ebooks" "$Lib" > "$Work/test5.log" 2>&1
check "exits with error"  test $? -ne 0
check "explains the problem" grep -q "cifs kernel support or an smbclient binary" "$Work/test5.log"

# ---------------------------------------------------------------------------
echo "== 6. SMB-only config skips the internet check"
resetAll
makeSource "$Work/share"
cat > "$Stubs/ping" <<EOF
#!/bin/bash
echo "ping \$*" >> "$Work/ping.log"
exit 1
EOF
chmod +x "$Stubs/ping"
rm -f "$Work/ping.log"
printf 'SMB:%s/share\n' "$Work" > "$UserConfig"
PATH="$Stubs:$PATH" $KC/get.sh > "$Work/test6.log" 2>&1
check "no ping performed"        test ! -e "$Work/ping.log"
check "sync still happens"       test -f "$Lib/book1.epub"
check "internet check reported skipped" grep -q "skipping internet check" "$Work/test6.log"

# ---------------------------------------------------------------------------
echo
if [ "$FAILED" -eq 0 ]; then
    echo "All SMB tests passed"
    exit 0
fi
echo "$FAILED SMB test(s) failed"
exit 1
