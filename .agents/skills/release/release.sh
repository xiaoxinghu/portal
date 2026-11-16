#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: sh .agents/skills/release/release.sh candidate [LEVEL|X.Y.Z] [BASE]
#          sh .agents/skills/release/release.sh notes X.Y.Z
#          sh .agents/skills/release/release.sh publish X.Y.Z NOTES
# The mechanical parts of a release: docs/releasing.md says what a release is,
# SKILL.md beside this file when each part runs. Each part works in a fresh
# clone of the repository on GitHub and deletes it when done, so the checkout
# it is started from never matters, and what one part leaves for the next is
# on GitHub: the branch release/vX.Y.Z and its Checks run. Nothing is forced;
# the one branch ever deleted is release/vX.Y.Z. It lives here, outside
# tools/, because the native build hashes that directory.
# PORTAL_RELEASE_REMOTE names another repository to release, for the tests.
set -eu

die() { echo "release: $*" >&2; exit 1; }
# The steps of Checks, besides CTest, whose logs must count their tests.
suites="python views input launcher terminal-shell-startup package"
largest() { sort -t. -k1,1n -k2,2n -k3,3n | tail -1; }

# Set `release` to the release commit of version $1, `run` to its green Checks
# run, and put that run's logs in $work/logs; only an uncached run is evidence.
evidence() {
    release=$(git rev-parse -q --verify "origin/release/v$1^{commit}") ||
        die "no release/v$1 on GitHub: run candidate first"
    [ "$(git diff --numstat "$release^" "$release")" = "1	1	portal.el" ] ||
        die "$release changes more than the Version: line"
    run=$(gh run list --workflow checks.yml --commit "$release" --json databaseId,conclusion \
        --jq '[.[] | select(.conclusion == "success")][0].databaseId // empty')
    [ -n "$run" ] || die "no green Checks run of $release"
    gh run download "$run" -n logs -D "$work/logs" >&2
    grep -qx 'USE_CACHE=false' "$work/logs/environment.log" ||
        die "Checks run $run restored cached downloads: it is no evidence"
}

# Set `hash` to the hash of what the native build reads at commit $1, as
# portal-build.el computes it: when it differs between two releases, upgrading
# rebuilds. No hash is a refusal: two that failed alike would read as no rebuild.
identity() {
    git checkout -q --detach "$1"
    hash=$("${EMACS:-emacs}" --batch -Q -l portal-build.el \
        --eval '(princ (portal-build-source-identity))') || hash=''
    case $hash in
        '' | *[!0-9a-f]*) die "no build identity at $1: put Emacs on PATH or in EMACS" ;;
    esac
}

candidate() {
    want=${1:-minor} from=${2:-main}
    base=$(git rev-parse -q --verify "origin/$from^{commit}" ||
        git rev-parse -q --verify "$from^{commit}") || die "GitHub has no commit $from"
    git checkout -q --detach "$base"
    last=$(git tag -l | sed -n 's/^v\([0-9]*\.[0-9]*\.[0-9]*\)$/\1/p' | largest)
    current=${last:-$(sed -n 's/^;; Version: //p' portal.el)}
    IFS=. read -r major minor patch <<EOF
$current
EOF
    case $want in
        major) new=$((major + 1)).0.0 ;;
        minor) new=$major.$((minor + 1)).0 ;;
        patch) new=$major.$minor.$((patch + 1)) ;;
        *) new=$want ;;
    esac
    echo "$new" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' ||
        die "$want is not major, minor, patch or a version X.Y.Z"
    if [ "$new" = "$current" ] || [ "$(printf '%s\n' "$current" "$new" | largest)" != "$new" ]; then
        die "$new is not above $current, the current version"
    fi
    if [ -n "$last" ]; then
        gh release view "v$last" >/dev/null 2>&1 ||
            die "v$last has no GitHub release: publish it first"
        [ -n "$(git rev-list -1 "v$last..$base")" ] || die "$from has nothing new since v$last"
    fi
    if git rev-parse -q --verify origin/stable >/dev/null; then
        git merge-base --is-ancestor origin/stable "$base" ||
            die "stable is not an ancestor of $from: it could not fast-forward"
    fi

    sed -i.bak "s/^;; Version: .*/;; Version: $new/" portal.el && rm portal.el.bak
    git commit -q -m "release: Portal $new" portal.el
    [ "$(git diff --numstat HEAD^ HEAD)" = "1	1	portal.el" ] ||
        die "the release commit is not the Version: line alone"
    release=$(git rev-parse HEAD) branch=release/v$new
    # An earlier attempt's candidate goes first: no user is ever on it.
    if git rev-parse -q --verify "origin/$branch" >/dev/null; then
        git push -q origin --delete "$branch"
    fi
    git push -q origin "$release:refs/heads/$branch"
    gh workflow run checks.yml --ref "$branch" -f cache=false >/dev/null
    run='' tries=0
    while [ -z "$run" ] && [ "$tries" -lt 24 ]; do
        sleep "${PORTAL_RELEASE_POLL:-5}"
        tries=$((tries + 1))
        run=$(gh run list --workflow checks.yml --commit "$release" --json databaseId \
            --jq '.[0].databaseId // empty')
    done
    echo "Portal $new: $release on $branch, from $base"
    [ -n "$run" ] || die "Checks did not start on $branch: start it by hand, uncached"
    echo "Checks run $run: gh run watch $run --exit-status"
}

notes() {
    evidence "$1"
    previous=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$release" 2>/dev/null || :)
    echo "## What is new"
    echo
    if [ -z "$previous" ]; then
        echo "The first release. [The README](https://github.com/$GH_REPO/blob/v$1/README.md)" \
            "says what Portal is."
    else
        git log --first-parent --format=%s "$previous..$release^" |
            sed -e '/^release: /d' -e 's|^portal/[^:]*: ||' -e 's/^/- /'
    fi
    echo
    echo "## What upgrading costs"
    echo
    if [ -z "$previous" ]; then
        echo "Nothing to upgrade from: the first build is the native build."
    else
        identity "$previous"
        before=$hash
        identity "$release"
        if [ "$before" = "$hash" ]; then
            echo "Lisp only, no rebuild."
        else
            echo "The first native command after upgrading offers a rebuild of several" \
                "minutes; restart Emacs after it."
        fi
    fi
    echo
    echo "## Evidence"
    echo
    echo "Commit $release, $(gh run view "$run" --json url --jq .url), without cached downloads."
    echo
    echo '```'
    cat "$work/logs/environment.log"
    grep -h '^resolve-bun: using' "$work/logs/build.log" || die "build.log does not name its Bun"
    echo '```'
    echo
    echo "| Step | Result |"
    echo "| --- | --- |"
    gh run view "$run" --json jobs --jq '.jobs[].steps[]
        | select(.name | test("^(Set up job|Complete job|Post |Run actions/)") | not)
        | "| \(.name) | \(.conclusion) |"'
    echo
    echo "Counts, as each suite printed them:"
    echo
    # CTest's own log holds every suite's output, between "N/M Test: NAME" and
    # "Test Passed."; the other steps log to a file each. A suite with no
    # count stops the notes: the evidence must be whole.
    awk '/^[0-9]+\/[0-9]+ Test: / { suite = $3; counts = "" }
         /^Ran [0-9]+ tests|^[0-9]+ checks passed|Test run with [0-9]+ tests/ {
             sub(/^[^A-Za-z0-9]+/, ""); counts = counts "; " $0 }
         /^Test Passed\./ { suites++; print "- CTest " suite ": passed" counts
             if (counts == "") { print "release: no count for the CTest suite " suite >"/dev/stderr"; bad = 1 } }
         END { exit bad || !suites }' "$work/logs/ctest.log" ||
        die "ctest.log does not count every suite's tests"
    for name in $suites; do
        counts=$(sed -n "s/^Ran [0-9]* tests.*/- $name: &/p; s/^[0-9]* checks passed.*/- $name: &/p" \
            "$work/logs/$name.log" "$work/logs/$name/test.log" 2>/dev/null || :)
        [ -n "$counts" ] || die "the run's logs do not count $name's tests"
        echo "$counts"
    done
    echo
    echo "Skipped tests, each with its reason:"
    echo
    awk 'FNR == 1 { suite = FILENAME; sub(/.*\/logs\//, "", suite); sub(/(\/test)?\.log$/, "", suite) }
         /^[0-9]+\/[0-9]+ Test: / { suite = "CTest " $3 }
         /^ +SKIPPED +| \.\.\. skipped |^ *[1-9][0-9]* skip$/ { sub(/^ +(SKIPPED +)?/, ""); print "- " suite ": " $0; found = 1 }
         END { if (!found) print "None." }' \
        "$work/logs/ctest.log" "$work/logs/python.log" "$work"/logs/*/test.log
    echo
    echo "## Checks outside CI"
    echo
    echo "Not run: the standalone AppKit checks, physical-key delivery, and the" \
        "fullscreen input tests and the four Excalidraw slide tests, which skip on" \
        "GitHub's runners."
}

publish() {
    [ -s "$2" ] || die "no notes in $2"
    evidence "$1"
    tag=v$1
    # A second run after the push went through only finishes the release.
    if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        git tag -a "$tag" -m "Portal $1" "$release"
        main=$release
        if ! git merge-base --is-ancestor origin/main "$release"; then
            git checkout -q --detach origin/main
            git merge -q --no-ff -m "release: merge Portal $1 into main" "$release"
            main=$(git rev-parse HEAD)
        fi
        git push -q --atomic origin "$tag" "$release:refs/heads/stable" "$main:refs/heads/main"
    fi
    (cd "$work" && zip -qr logs.zip logs)
    gh release create "$tag" --verify-tag --title "Portal $1" --notes-file "$2" "$work/logs.zip"
    git push -q origin --delete "release/$tag"
}

[ $# -ge 2 ] || [ "${1:-}" = candidate ] || die "see the top of $0 for the arguments"
command=$1
shift
case $command in
    candidate | notes) ;;
    publish) set -- "$1" "$(cd "$(dirname "${2:?no notes file}")" && pwd)/$(basename "$2")" ;;
    *) die "no part named $command" ;;
esac
export GH_REPO="${GH_REPO:-xiaoxinghu/portal}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q "${PORTAL_RELEASE_REMOTE:-https://github.com/xiaoxinghu/portal}" "$work/portal"
cd "$work/portal"
if [ "$command" = notes ]; then
    # All or nothing: a draft cut short by missing evidence is not the notes.
    notes "$@" >"$work/notes.md"
    cat "$work/notes.md"
else
    "$command" "$@"
fi
