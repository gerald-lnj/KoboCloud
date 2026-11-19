#!/bin/sh
# Kobocloud SMB/CIFS getter
#
# Configuration line format (in kobocloudrc):
#
#   SMB:server/share/path|mount-options
#   SMB:/path/to/already/mounted/share
#
# Examples:
#   SMB:192.168.1.10/books/New|username=kobo,password=secret,vers=3.0
#   SMB:nas.local/ebooks|credentials=/mnt/onboard/.add/kobocloud/smbcred,vers=2.1
#   SMB:/mnt/onboard/.add/kobocloud/smb
#
# The part before the '|' is host/share/path inside the share. The part after
# the '|' is passed verbatim as mount -o options ("standard smb options").
# A target starting with '/' is a directory that is already mounted (or a
# plain local directory): nothing is mounted, its content is just copied.
#
# Two transfer backends are supported:
#   - kernel cifs mount (mount -t cifs). Needs cifs support in the kernel.
#   - userspace smbclient (samba). Used when the kernel has no cifs support
#     or when the mount fails, if an smbclient binary is available in PATH or
#     next to the other KoboCloud scripts.

line="$1"
outDir="$2"

#load config
. $(dirname $0)/config.sh

[ -z "$SMBMOUNT" ] && SMBMOUNT="$Logs/smb"

# credentials and smbclient output live in /tmp; remove them if interrupted
authFile=""
logFile=""
cleanupSmb() {
    [ -n "$authFile" ] && rm -f "$authFile" 2>/dev/null
    [ -n "$logFile" ] && rm -f "$logFile" 2>/dev/null
}
trap 'cleanupSmb; exit 1' INT TERM

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# hide passwords in the log
maskOptions() {
    printf '%s' "$1" | sed -e 's/password=[^,]*/password=***/g' -e 's/pass=[^,]*/pass=***/g'
}

historyFile="$Lib/filesList.log"

recordFile() {
    if grep -q "^REMOVE_DELETED" "$UserConfig" 2>/dev/null; then
        echo "$1" >> "$historyFile"
    fi
}

spec=`trim "$1" | sed 's/^SMB://'`
target="$spec"
smbOpts=""
case "$spec" in
    *\|*)
        target=${spec%%|*}
        smbOpts=${spec#*|}
        ;;
esac
target=`trim "$target"`
smbOpts=`trim "$smbOpts"`

echo "SMB target: $target"
if [ -n "$smbOpts" ]; then
    echo "SMB mount options: `maskOptions "$smbOpts"`"
fi

if [ -z "$target" ]; then
    echo "Error: empty SMB target"
    exit 1
fi

mode=remote
sub=""
case "$target" in
    //*) ;;                      # //server/share/... -> remote
    /*)  mode=local ;;           # /local/path -> already available locally
esac

srcRoot=""
host=""
share=""

if [ "$mode" = "local" ]; then
    srcRoot="$target"
    if [ ! -d "$srcRoot" ]; then
        echo "Error: $srcRoot is not a directory"
        exit 1
    fi
    echo "Using local path $srcRoot (no mount performed)"
else
    host=`printf '%s' "$target" | sed -e 's@^//@@' | cut -d/ -f1`
    share=`printf '%s' "$target" | sed -e 's@^//@@' | cut -d/ -f2`
    sub=`printf '%s' "$target" | sed -e 's@^//@@' | cut -d/ -f3-`
    if [ -z "$host" ] || [ -z "$share" ]; then
        echo "Error: cannot parse '$target'. Expected SMB:server/share[/path]"
        exit 1
    fi
    echo "Server: $host, share: $share, path: ${sub:-/}"

    # never write to the share: mount read-only unless the user asked otherwise
    case ",$smbOpts," in
        *,ro,*|*,rw,*) ;;
        "") smbOpts="ro" ;;
        *)  smbOpts="ro,$smbOpts" ;;
    esac
fi

# ---------------------------------------------------------------------------
# local file copy
# ---------------------------------------------------------------------------

copyFile() {
    local src rel name dest
    src="$1"
    rel="$2"
    name=`basename "$src"`
    dest="$outDir/$rel$name"

    # add the epub extension to kepub files, like getRemoteFile.sh does
    case "$name" in
        *.kepub) dest="$dest.epub" ;;
    esac

    if [ -f "$dest" ]; then
        local srcSize dstSize
        srcSize=`wc -c < "$src"`
        dstSize=`wc -c < "$dest"`
        if [ "$srcSize" = "$dstSize" ] && [ ! "$src" -nt "$dest" ]; then
            echo "Unchanged: $dest"
            recordFile "$dest"
            return 0
        fi
    fi

    local destDir tmp
    destDir=`dirname "$dest"`
    [ ! -d "$destDir" ] && mkdir -p "$destDir"

    # copy to a temporary name first so a partial file never shows up in the library
    tmp="$dest.kobocloud-part"
    if cp -p "$src" "$tmp"; then
        mv "$tmp" "$dest"
        echo "Copied: $dest"
        recordFile "$dest"
        return 0
    fi
    rm -f "$tmp"
    echo "Error: failed to copy $src to $dest"
    return 1
}

syncDir() {
    local srcDir rel entry name
    srcDir="$1"
    rel="$2"
    for entry in "$srcDir"/* "$srcDir"/.[!.]*; do
        [ -e "$entry" ] || continue
        name=`basename "$entry"`
        case "$name" in
            .*) echo "Skipping hidden entry: $name"; continue ;;
        esac
        if [ -d "$entry" ]; then
            syncDir "$entry" "$rel$name/"
        else
            copyFile "$entry" "$rel" || return 1
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# userspace fallback through smbclient
# ---------------------------------------------------------------------------

findSmbclient() {
    if command -v smbclient >/dev/null 2>&1; then
        command -v smbclient
    elif [ -x "$KC_HOME/smbclient" ]; then
        echo "$KC_HOME/smbclient"
    fi
}

syncWithSmbclient() {
    client=`findSmbclient`
    if [ -z "$client" ]; then
        echo "Error: smbclient not found. Install a cifs-capable kernel or an smbclient binary."
        return 1
    fi

    user=""
    pass=""
    domain=""
    port=""
    creds=""
    oldIFS=$IFS
    IFS=,
    for opt in $smbOpts; do
        case "$opt" in
            username=*|user=*)   user=`printf '%s' "$opt" | sed 's/^[^=]*=//'` ;;
            password=*|pass=*)   pass=`printf '%s' "$opt" | sed 's/^[^=]*=//'` ;;
            domain=*)            domain=`printf '%s' "$opt" | sed 's/^[^=]*=//'` ;;
            port=*)              port=`printf '%s' "$opt" | sed 's/^[^=]*=//'` ;;
            credentials=*|cred=*) creds=`printf '%s' "$opt" | sed 's/^[^=]*=//'` ;;
        esac
    done
    IFS=$oldIFS

    authFile=""
    if [ -z "$creds" ] && { [ -n "$user" ] || [ -n "$pass" ]; }; then
        authFile="/tmp/kobocloud-smb-auth.$$"
        {
            echo "username = $user"
            echo "password = $pass"
            [ -n "$domain" ] && echo "domain = $domain"
        } > "$authFile"
        chmod 600 "$authFile" 2>/dev/null
    fi

    set -- "//$host/$share"
    [ -n "$port" ] && set -- "$@" "-p" "$port"
    if [ -n "$creds" ]; then
        set -- "$@" "-A" "$creds"
    elif [ -n "$authFile" ]; then
        set -- "$@" "-A" "$authFile"
    fi
    if [ -n "$sub" ]; then
        set -- "$@" "-D" "$sub"
    fi
    set -- "$@" "-c" "recurse ON; prompt OFF; mget *"

    echo "Using smbclient: $client $1"
    logFile="/tmp/kobocloud-smb.$$.log"
    ( cd "$outDir" && "$client" "$@" ) > "$logFile" 2>&1
    status=$?
    if [ -n "$creds" ] || [ -n "$authFile" ]; then
        grep -q "NT_STATUS_LOGON_FAILURE" "$logFile" && echo "Error: SMB authentication failed"
    fi
    # record downloaded files for REMOVE_DELETED. smbclient's mget flattens the
    # tree into $outDir, so the local name is the basename of the remote path.
    # Best effort: smbclient prints "getting file \path\name of size ...".
    if grep -q "^REMOVE_DELETED" "$UserConfig" 2>/dev/null; then
        grep -i "getting file" "$logFile" |
            sed -e 's/.*getting file \\\([^ ]*\) of size.*/\1/' -e 's@\\@/@g' |
            while read dl; do
                [ -n "$dl" ] || continue
                name=`basename "$dl"`
                echo "$outDir/$name" >> "$historyFile"
            done
    fi
    if [ "$status" -ne 0 ]; then
        echo "smbclient output:"
        cat "$logFile"
    fi
    rm -f "$logFile" "$authFile"
    return $status
}

# ---------------------------------------------------------------------------
# kernel cifs mount
# ---------------------------------------------------------------------------

mounted=0

unmountSmb() {
    [ "$mounted" = "1" ] || return 0
    umount "$SMBMOUNT" 2>/dev/null || umount -l "$SMBMOUNT" 2>/dev/null || {
        echo "Warning: could not unmount $SMBMOUNT"
        return 1
    }
    mounted=0
}

if [ "$mode" = "remote" ]; then
    if [ "$KC_FORCE_CIFS" = "1" ] || { [ "$KC_FORCE_CIFS" != "0" ] && grep -q cifs /proc/filesystems 2>/dev/null; }; then
        [ ! -d "$SMBMOUNT" ] && mkdir -p "$SMBMOUNT"
        echo "Mounting //$host/$share on $SMBMOUNT"
        if mount -t cifs "//$host/$share" "$SMBMOUNT" -o "$smbOpts"; then
            mounted=1
            srcRoot="$SMBMOUNT"
            [ -n "$sub" ] && srcRoot="$SMBMOUNT/$sub"
        else
            echo "Mount failed, trying smbclient instead"
        fi
    else
        echo "Kernel has no cifs support, trying smbclient instead"
    fi

    if [ "$mounted" = "0" ]; then
        if syncWithSmbclient; then
            echo "SMB sync through smbclient done"
            exit 0
        fi
        echo "Error: could not read //$host/$share. KoboCloud needs either cifs kernel support or an smbclient binary."
        exit 1
    fi
fi

if [ ! -d "$srcRoot" ]; then
    echo "Error: $srcRoot does not exist (wrong path inside the share?)"
    unmountSmb
    exit 1
fi

syncDir "$srcRoot" ""
status=$?

unmountSmb

echo "SMB sync ended with status $status"
exit $status
