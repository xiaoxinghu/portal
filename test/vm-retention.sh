#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Keep the VM's finished test runs from growing without bound.
#
#   bash test/vm-retention.sh preview | prune | pin RUN | unpin RUN
#
# From the host, the command pipes this script to the VM's /bin/bash, which
# runs it with --guest; nothing is installed there. test/vm.sh runs its own
# run's copy with --runner before each run. In the VM it is macOS's Bash 3.2,
# with BSD stat, and it touches nothing outside ~/portal-test-runs.
set -uo pipefail

# Fixed limits, not settings: SSH passes no environment to forward them in.
# Failed runs that keep their repo/, newest first; pinned ones do not count.
snapshots=5
# Days after completion before a run's directory goes, logs and all.
days=30

usage() {
    echo "Usage: bash test/vm-retention.sh preview | prune | pin RUN | unpin RUN" >&2
    exit 2
}

# Whether $1 is a run's bare name, as the runner prints it.
valid_name() { [[ $1 == run.?* && $1 != */* ]]; }

# On the host: check the command and hand it to the VM.
host() {
    case ${1:-} in
    preview | prune) [[ $# == 1 ]] || usage ;;
    pin | unpin)
        [[ $# == 2 ]] || usage
        valid_name "$2" || {
            echo "Name a run as the runner prints it: run.XXXXXXXX" >&2; exit 2;
        } ;;
    *) usage ;;
    esac
    local script=${BASH_SOURCE[0]}
    # For resolve_vm and quote; it runs nothing when sourced.
    source "$(dirname -- "$script")/vm.sh"
    resolve_vm
    ssh -T -o BatchMode=yes "$vm" "/bin/bash -s -- --guest $(quote "$@")" <"$script"
}

# In the VM, from here on.
root=$HOME/portal-test-runs
now=
mode=
current=

# A line of the report; actions first, then what was left alone.
actions=()
notes=()
act() { actions+=("$1"); }
note() { notes+=("$1"); }

plural() {
    if [[ $1 == 1 ]]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi
}

# Whether $1 names a run directory, not a symbolic link to one.
run_dir() { valid_name "$1" && [[ -d $root/$1 && ! -L $root/$1 ]]; }

# Set code to the exit status in the run $1's top-level exit-status, a
# single integer from 0 to 255. Return 1 when the file is missing, 2 when it
# holds anything else.
read_status() {
    local file=$root/$1/exit-status size text
    [[ -e $file || -L $file ]] || return 1
    [[ -f $file && ! -L $file ]] || return 2
    size=$(stat -f %z -- "$file") && [[ $size -le 4 ]] || return 2
    text=$(<"$file") || return 2
    [[ $text =~ ^(0|[1-9][0-9]?[0-9]?)$ ]] && [[ $text -le 255 ]] || return 2
    code=$text
}

# Remove $1, below the root, giving the read-only directories a build can
# leave write permission if a first attempt fails. Set error on failure.
remove_tree() {
    local path=$root/$1
    error=$(rm -rf -- "$path" 2>&1) && return
    chmod -R u+w -- "$path" 2>/dev/null
    error=$(rm -rf -- "$path" 2>&1) && return
    error=$(printf '%s\n' "$error" | head -n 1)
    error=${error:-rm failed}
    return 1
}

# Remove the run $1, its exit-status last: a removal that fails partway
# leaves a completed run, which the next prune retries, not an incomplete
# one, which retention keeps.
remove_run() {
    local entry
    for entry in "$root/$1"/* "$root/$1"/.[!.]* "$root/$1"/..?*; do
        [[ ${entry##*/} == exit-status ]] || remove_tree "$1/${entry##*/}" || return 1
    done
    remove_tree "$1"
}

# Remove (or in a preview, propose removing) $2, the run $1 or its repo/,
# for the reason $3. Return 1 on a cleanup error.
remove() {
    local kind=$1 path=$2 reason=$3 error
    if [[ $mode == preview ]]; then
        act "Would remove $path: $reason"
        return
    fi
    if [[ $kind == run ]]; then remove_run "$path"; else remove_tree "$path"; fi && {
        act "Removed $path: $reason"
        return
    }
    act "Could not remove $path: $error"
    return 1
}

# Report on every finished run, and remove what the limits leave out unless
# this is a preview. Return 1 on a cleanup error.
sweep() {
    local dir name i when order runs=0 repos=0 kept=0 pinned=0 incomplete=0
    local failures=0 errors=0 limit=$((days * 86400)) summary
    local names=() times=() dates=() codes=()
    now=$(date +%s)
    shopt -s nullglob
    for dir in "$root"/run.*; do
        name=${dir##*/}
        [[ $name == "$current" ]] && continue
        if ! run_dir "$name"; then
            note "Skipped $name: not a run directory"
            continue
        fi
        if [[ -e $dir/.keep || -L $dir/.keep ]]; then
            note "Pinned $name: kept until unpinned"
            pinned=$((pinned + 1))
            continue
        fi
        code=
        read_status "$name"
        case $? in
        1) note "Incomplete $name: no exit-status, kept"; incomplete=$((incomplete + 1)); continue ;;
        2) note "Incomplete $name: malformed exit-status, kept"; incomplete=$((incomplete + 1)); continue ;;
        esac
        when=$(stat -f '%m %Sm' -t '%Y-%m-%d %H:%M' -- "$dir/exit-status") || {
            note "Incomplete $name: unreadable exit-status, kept"
            incomplete=$((incomplete + 1))
            continue
        }
        names+=("$name")
        times+=("${when%% *}")
        dates+=("${when#* }")
        codes+=("$code")
    done
    # Newest first, by the time the top-level exit-status was written.
    order=
    if [[ ${#names[@]} -gt 0 ]]; then
        order=$(i=0; while [[ $i -lt ${#names[@]} ]]; do
                    printf '%s %s\n' "${times[i]}" "$i"; i=$((i + 1))
                done | sort -k1,1nr -k2,2n | cut -d ' ' -f 2)
    fi
    for i in $order; do
        name=${names[i]}
        if [[ $((now - times[i])) -gt $limit ]]; then
            if remove run "$name" "completed ${dates[i]}, over $days days ago"; then
                runs=$((runs + 1))
            else
                errors=$((errors + 1))
            fi
            continue
        fi
        [[ ${codes[i]} != 0 ]] || continue
        failures=$((failures + 1))
        [[ -e $root/$name/repo || -L $root/$name/repo ]] || continue
        if [[ $failures -le $snapshots ]]; then
            act "Kept $name/repo: failed ${dates[i]}, one of the $snapshots newest failures"
            kept=$((kept + 1))
        elif remove repo "$name/repo" "failed ${dates[i]}, older than the $snapshots newest failures"; then
            repos=$((repos + 1))
        else
            errors=$((errors + 1))
        fi
    done
    if [[ ${#actions[@]} -gt 0 ]]; then printf '%s\n' "${actions[@]}"; fi
    if [[ ${#notes[@]} -gt 0 ]]; then printf '%s\n' "${notes[@]}"; fi
    if [[ $mode == preview ]]; then summary="Retention preview: would remove"; else summary="Retention: removed"; fi
    summary="$summary $(plural "$runs" run) over $days days old and $(plural "$repos" snapshot)"
    summary="$summary beyond the $snapshots newest failures; kept $(plural "$kept" snapshot),"
    summary="$summary $(plural "$pinned" "pinned run") and $(plural "$incomplete" "incomplete run")"
    if [[ $errors -gt 0 ]]; then summary="$summary; $(plural "$errors" "cleanup error")"; fi
    printf '%s\n' "$summary"
    [[ $errors == 0 ]]
}

# Take the desktop lock a test run holds, saying so if it has to wait.
lock() {
    exec 9>>"$root/.desktop.lock" || exit 1
    if ! /usr/bin/lockf -t 0 9 2>/dev/null; then
        echo "Waiting for the VM desktop: a test run holds it…"
        /usr/bin/lockf 9 || exit 1
    fi
}

# The run named $1, which must exist, for pin and unpin.
named_run() {
    valid_name "$1" || {
        echo "Name a run as the runner prints it: run.XXXXXXXX" >&2; exit 2;
    }
    run_dir "$1" || { echo "No run directory $root/$1" >&2; exit 1; }
}

# A command from the host.
guest() {
    local command=${1:-} keep error
    case $command in
    preview | prune) [[ $# == 1 ]] || usage ;;
    pin | unpin) [[ $# == 2 ]] || usage; named_run "$2" ;;
    *) usage ;;
    esac
    mode=$command
    if [[ ! -d $root || -L $root ]]; then
        echo "No test runs in $root"
        return
    fi
    [[ $command == preview ]] || lock
    case $command in
    preview | prune) sweep ;;
    pin)
        # Checked again: it may have gone while waiting for the lock.
        named_run "$2"
        keep=$root/$2/.keep
        if [[ -e $keep || -L $keep ]]; then
            echo "$2 was already pinned"
        else
            : >"$keep" || exit 1
            echo "Pinned $2: retention keeps it until unpin"
        fi ;;
    unpin)
        named_run "$2"
        keep=$root/$2/.keep
        if [[ -e $keep || -L $keep ]]; then
            error=$(rm -rf -- "$keep" 2>&1) || { echo "Could not unpin $2: $error" >&2; exit 1; }
            echo "Unpinned $2"
        else
            echo "$2 was not pinned"
        fi ;;
    esac
}

# Called by test/vm.sh for its run $1, under the lock it holds on descriptor 9.
runner() {
    if [[ $# != 1 ]] || ! valid_name "$1"; then usage; fi
    { : >&9; } 2>/dev/null || {
        echo "--runner works under the desktop lock on descriptor 9" >&2; exit 2;
    }
    mode=prune current=$1
    sweep
}

main() {
    case ${1:-} in
    --guest) shift; exec </dev/null; guest "$@" ;;
    --runner) shift; exec </dev/null; runner "$@" ;;
    *) host "$@" ;;
    esac
}

main "$@"
