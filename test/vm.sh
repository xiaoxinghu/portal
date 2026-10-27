#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copy this checkout to a macOS VM, build it, and run a test command.
set -euo pipefail

# What a build adds to the sources, all ignored by Git: a run that reuses the
# previous run's build takes these.
build_outputs=(build host/node_modules host/.generated)
# The logs a run copies back: its own and those of each suite in a directory.
log_files=(--exclude=/repo/ --include='/*/' --include='/*.log' --include='/*/*.log'
    --include=/exit-status --include='/*/exit-status' --exclude='*' --prune-empty-dirs)

quote() { printf '%q ' "$@"; }

source_files() {
    git ls-files --cached --others --exclude-standard --deduplicate -z |
        while IFS= read -r -d '' file; do
            if [[ -e "$file" || -L "$file" ]]; then printf '%s\0' "$file"; fi
        done
}

run_stage() (
    log=$1; shift
    echo "Running $(quote "$@") (limit ${timeout}s)"
    # Bash job control gives each background job its own process group.
    set -m
    child= watchdog=
    cleanup() {
        for pid in "$child" "$watchdog"; do
            if [[ -n "$pid" ]]; then kill -KILL -- "-$pid" 2>/dev/null || :; fi
        done
        wait 2>/dev/null || :
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    "$@" </dev/null >"$log" 2>&1 & child=$!
    (
        set +m
        sleep "$timeout"
        touch "$log.timeout"
        echo "Timed out after ${timeout}s" >>"$log"
        kill -KILL -- "-$child" 2>/dev/null || :
    ) & watchdog=$!
    status=0
    wait "$child" 2>/dev/null || status=$?
    if [[ -f "$log.timeout" ]]; then status=124; fi
    exit "$status"
)

# Whether the build in the work tree $2 is complete and was built from the
# sources in $1: by the rule Portal applies before loading its module, and
# with the license files its notices were staged from, which that rule omits.
build_current() {
    diff -rq -- "$1/licenses" "$2/licenses" >/dev/null 2>&1 &&
        cmp -s -- "$1/LICENSE" "$2/LICENSE" &&
        PORTAL_REUSED_BUILD=$2/build "$EMACS" --batch -Q -l "$1/portal-build.el" --eval \
            '(kill-emacs (let ((portal-build-directory (getenv "PORTAL_REUSED_BUILD")))
                           (if (portal-build-problem) 1 0)))' >/dev/null 2>&1
}

# Move the sources in $1 to the work tree $2, replacing the previous run's.
# Keep that run's build when it is current for them, setting reused.
# Every run builds at the same path: CMake's build directory records it.
take_work_tree() {
    local sources=$1 work=$2 output
    reused=
    if [[ -d $work/build ]] && build_current "$sources" "$work"; then
        reused=1
        for output in "${build_outputs[@]}"; do
            if [[ -e $work/$output && ! -e $sources/$output ]]; then
                mv -- "$work/$output" "$sources/$output"
            fi
        done
    fi
    rm -rf -- "$work"
    mv -- "$sources" "$work"
}

guest() {
    run=$(cd -- "$1" && pwd -P); shift
    [[ $(dirname "$run") == "$HOME/portal-test-runs" && ${run##*/} == run.* ]]
    trap 'printf "%s\n" "$?" >"$run/exit-status"' EXIT
    export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
    export EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
    # Keep the same inode; inherited descriptor 9 also protects child jobs.
    exec 9>"$HOME/portal-test-runs/.desktop.lock"
    echo "Waiting for the VM desktop…"
    /usr/bin/lockf 9
    [[ $(stat -f %Su /dev/console) == "$USER" ]] || {
        echo "Log in to the VM desktop as the SSH user first" >&2; exit 1;
    }
    [[ $(df -Pk "$run" | awk 'END {print $4}') -ge 5242880 ]] || {
        echo "The VM needs at least 5 GiB free for a fresh build" >&2; exit 1;
    }
    caffeinate -disu -w "$$" 9>&- &
    work=$HOME/portal-test-runs/work
    status=0
    take_work_tree "$run/repo" "$work"
    cd -- "$work"
    if [[ -n $reused ]]; then
        echo "Skipping ./build.sh: the previous run's build is current for these sources" |
            tee "$run/build.log"
    else
        run_stage "$run/build.log" ./build.sh || status=$?
    fi
    if [[ $status == 0 ]]; then
        # Direct SSH launches miss the Homebrew app's compiler environment.
        export LIBRARY_PATH
        LIBRARY_PATH=$(/usr/libexec/PlistBuddy -c Print:LSEnvironment:LIBRARY_PATH \
            /Applications/Emacs.app/Contents/Info.plist)
        # Commands save diagnostics here as *.log files; they copy back.
        export PORTAL_TEST_LOGS="$run"
        run_stage "$run/test.log" "$@" || status=$?
    fi
    # The next run replaces the work tree, so a failed run keeps a copy; APFS
    # clones it without copying data.
    if [[ $status != 0 ]]; then cp -Rc -- "$work" "$run/repo" || :; fi
    exit "$status"
}

main() {
    timeout=${PORTAL_TEST_TIMEOUT:-1200}
    [[ $timeout =~ ^[1-9][0-9]*$ ]] || {
        echo "PORTAL_TEST_TIMEOUT must be a positive number of seconds" >&2; exit 2;
    }
    if [[ ${1:-} == --guest ]]; then shift; guest "$@"; fi
    if [[ ${1:-} == -- ]]; then shift; fi
    if [[ $# == 0 ]]; then set -- sh test/launcher-daily-use.sh; fi
    vm=${PORTAL_TEST_VM:-$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" \
        config --local --get portal.testVm || :)}
    [[ -n $vm ]] || {
        echo "Name the VM's SSH alias: git config portal.testVm ALIAS" >&2; exit 2;
    }
    [[ $vm != -* && ! $vm =~ [[:space:]] ]] || {
        echo "Use an SSH host alias or user@hostname" >&2; exit 2;
    }
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
    ssh_vm=(ssh -T -o BatchMode=yes "$vm")
    run=$("${ssh_vm[@]}" 'umask 077; mkdir -p "$HOME/portal-test-runs" &&
        mktemp -d "$HOME/portal-test-runs/run.XXXXXXXX"')
    [[ $run == /*/portal-test-runs/run.* && $run != *$'\n'* ]]
    logs="$PWD/.cache/vm/${run##*/}"
    mkdir -p -- "${logs%/*}"
    mkdir -- "$logs"
    printf '%s:%s\n' "$vm" "$run" >"$logs/remote.txt"
    printf 'VM run: %s:%s\nLocal logs: %s\n' "$vm" "$run" "$logs"
    source_files >"$logs/files"
    rsync -a --from0 --files-from="$logs/files" -e 'ssh -o BatchMode=yes' \
        ./ "$vm:$(quote "$run/repo/")"
    collect_logs() {
        rsync -a -e 'ssh -o BatchMode=yes' "${log_files[@]}" \
            "$vm:$(quote "$run/")" "$logs/" ||
            echo "Could not fetch logs; retained at $vm:$run" >&2
        echo "Logs: $logs"
    }
    trap collect_logs EXIT
    status=0
    "${ssh_vm[@]}" "$(quote env "PORTAL_TEST_TIMEOUT=$timeout" /bin/bash \
        "$run/repo/test/vm.sh" --guest "$run" "$@")" || status=$?
    exit "$status"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
