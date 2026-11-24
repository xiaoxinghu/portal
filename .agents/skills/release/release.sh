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
# the one branch ever deleted is release/vX.Y.Z, and nothing published is
# ever changed. It lives here, outside tools/, because the native build
# hashes that directory.
# PORTAL_RELEASE_REMOTE and GH_REPO name another repository to release, for
# the tests and a rehearsal, PORTAL_RELEASE_DOWNLOADS where anyone downloads
# its releases' assets, PORTAL_RELEASE_RETRIES how often a download is
# tried again, and PORTAL_RELEASE_SETTLE how often GitHub is asked again
# for a change it does not list yet.
set -eu

die() { echo "release: $*" >&2; exit 1; }
# The steps of Checks, besides CTest, whose logs must count their tests.
suites="python views input launcher terminal-shell-startup package"
largest() { sort -t. -k1,1n -k2,2n -k3,3n | tail -1; }
sha256() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
# The runtimes a release attaches, an archive and its manifest each, packed
# by the candidate's run: the Mac's in its job, each Linux CPU's in its own.
targets="macos-arm64 linux-x86_64-gnu linux-aarch64-gnu"

# The directory of $work holding the logs of target $1's job: the Mac job's
# are the run's `logs`, each Linux job's its `logs-TARGET`.
logs_of() {
    case $1 in
        macos-*) echo "$work/logs" ;;
        *) echo "$work/logs-$1" ;;
    esac
}

# Set `release` to the release commit of version $1, `run` to its green Checks
# run, and put the logs of each of its jobs in $work, as logs_of names them;
# only an uncached full run is evidence, in every job.
evidence() {
    release=$(git rev-parse -q --verify "origin/release/v$1^{commit}") ||
        die "no release/v$1 on GitHub: run candidate first"
    [ "$(git diff --numstat "$release^" "$release")" = "1	1	portal.el" ] ||
        die "$release changes more than the Version: line"
    run=$(gh run list --workflow checks.yml --commit "$release" --json databaseId,conclusion \
        --jq '[.[] | select(.conclusion == "success")][0].databaseId // empty')
    [ -n "$run" ] || die "no green Checks run of $release"
    for target in $targets; do
        logs=$(logs_of "$target")
        gh run download "$run" -n "${logs#"$work/"}" -D "$logs" >&2 ||
            die "Checks run $run keeps no ${logs#"$work/"}: a run keeps its logs 14 days"
        grep -qx 'USE_CACHE=false' "$logs/environment.log" ||
            die "Checks run $run restored cached downloads: it is no evidence"
        grep -qx 'PORTAL_TEST_EXPENSIVE=1' "$logs/environment.log" ||
            die "Checks run $run left out the full set's checks: it is no evidence"
    done
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

# Put in $work/assets the runtime archives and manifests that run $run kept
# for version $1, each checked against GitHub's digest of its artifact, and
# each manifest against the release commit and its archive. A release
# attaches the archive its checks tested or none: one the workflow no longer
# keeps, after its 14 days, is never built again here.
runtimes() {
    mkdir -p "$work/assets"
    # An expired artifact is listed as expired, or not at all.
    gh api "repos/$GH_REPO/actions/runs/$run/artifacts?per_page=100" --paginate \
        --jq '.artifacts[] | select(.expired | not) | "\(.id) \(.digest) \(.name)"' \
        >"$work/artifacts" || die "cannot list the artifacts of Checks run $run"
    for target in $targets; do
        for name in "portal-runtime-v$1-$target.json" "portal-runtime-v$1-$target.tar.gz"; do
            kept=$(awk -v name="$name" '$3 == name { print $1, $2 }' "$work/artifacts")
            [ -n "$kept" ] || die "Checks run $run keeps no $name: a run keeps its archives" \
                "14 days, and a release attaches the archive its checks tested. Run Checks" \
                "again on release/v$1, uncached, then notes and publish; nothing is built here"
            # Kept unzipped, an artifact's zip is the file itself.
            gh api "repos/$GH_REPO/actions/artifacts/${kept%% *}/zip" >"$work/assets/$name" ||
                die "cannot download $name from Checks run $run"
            case ${kept#* } in
                null) ;;
                "sha256:$(sha256 "$work/assets/$name")") ;;
                *) die "$name from Checks run $run is not what GitHub kept: its digest differs" ;;
            esac
        done
        check_runtime "$work/assets" "$1" "$target"
    done
}

# Check the manifest of version $2's runtime for target $3 in directory $1,
# and the archive beside it: the manifest is the one run $run packed after
# its checks passed, a copy of which the logs of the job that packed it keep,
# so the archive's SHA-256 in it is that of the archive they tested; then the
# tag, the version, the release commit, and the archive's name, size and
# SHA-256.
check_runtime() {
    cmp -s "$1/portal-runtime-v$2-$3.json" "$(logs_of "$3")/runtime/portal-runtime-v$2-$3.json" ||
        die "$1 holds a manifest of v$2 for $3 other than the one Checks run $run packed"
    python3 -I - "$1" "$2" "$3" "$release" <<'PYTHON' || die "$1 holds no runtime of v$2 for $3"
import hashlib, json, sys
from pathlib import Path
directory, version, target, commit = Path(sys.argv[1]), *sys.argv[2:]
name = f"portal-runtime-v{version}-{target}"
manifest = json.loads((directory / f"{name}.json").read_text())
archives = manifest.get("archives") or [{}]
archive = archives[0]
wrong = [what for what, good in (
    ("format", manifest.get("format") == 1),
    ("tag", manifest.get("tag") == f"v{version}"),
    ("version", manifest.get("version") == version),
    ("commit", manifest.get("commit") == commit),
    ("archives", len(archives) == 1 and archive.get("target") == target),
    ("archive name", archive.get("name") == f"{name}.tar.gz")) if not good]
if not wrong:
    data = (directory / archive["name"]).read_bytes()
    if len(data) != archive.get("size"):
        wrong.append(f"size, {len(data)} bytes")
    elif hashlib.sha256(data).hexdigest() != archive.get("sha256"):
        wrong.append("SHA-256")
for what in wrong:
    print(f"release: {name}: not the manifest's {what}", file=sys.stderr)
sys.exit(1 if wrong else 0)
PYTHON
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
    # The last finished release, newest first: one the owner marked a
    # pre-release is abandoned, passed over; any other unfinished one stops it.
    finished=''
    for version in $(git tag -l | sed -n 's/^v\([0-9]*\.[0-9]*\.[0-9]*\)$/\1/p' |
        sort -t. -k1,1nr -k2,2nr -k3,3nr); do
        case $(gh release view "v$version" --json isDraft,isPrerelease \
            --jq '"\(.isDraft) \(.isPrerelease)"' 2>/dev/null) in
            'false false') finished=$version; break ;;
            'false true') echo "release: v$version is a pre-release: passed over as abandoned" >&2 ;;
            *) die "v$version has no published GitHub release: publish it first" ;;
        esac
    done
    if [ -n "$finished" ]; then
        [ "$(git rev-parse -q --verify origin/stable || :)" = "$(git rev-parse "v$finished^{commit}")" ] ||
            die "stable is not at v$finished: publish v$finished again to finish it, or" \
                "mark it a pre-release to abandon it"
        [ -n "$(git rev-list -1 "v$finished..$base")" ] || die "$from has nothing new since v$finished"
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
    # From the base: once publish has pushed the tag, the release commit has its own.
    previous=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$release^" 2>/dev/null || :)
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
            echo "The first native command after upgrading offers this release's runtime," \
                "below, or a build of several minutes; restart Emacs after it."
        fi
    fi
    echo
    echo "## Downloads"
    echo
    runtimes "$1"
    echo "The first native command offers to download this release's runtime where it" \
        "attaches one, checked against its manifest; elsewhere it offers a build."
    echo
    for target in $targets; do
        name=portal-runtime-v$1-$target.tar.gz
        echo "- \`$name\`, $(wc -c <"$work/assets/$name" | tr -d ' ') bytes," \
            "SHA-256 \`$(sha256 "$work/assets/$name")\`"
    done
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
    # "Test Passed."; the other steps log to a file each. Each job counts its
    # own, a Linux job's named by its target. A suite with no count stops the
    # notes: the evidence must be whole.
    for target in $targets; do
        logs=$(logs_of "$target")
        case $target in
            macos-*) label='' names=$suites ;;
            *) label="$target " names=python ;;
        esac
        awk -v label="$label" '
             /^[0-9]+\/[0-9]+ Test: / { suite = $3; counts = "" }
             /^Ran [0-9]+ tests|^[0-9]+ checks passed|Test run with [0-9]+ tests/ {
                 sub(/^[^A-Za-z0-9]+/, ""); counts = counts "; " $0 }
             /^Test Passed\./ { suites++; print "- " label "CTest " suite ": passed" counts
                 if (counts == "") { print "release: no count for the " label "CTest suite " suite >"/dev/stderr"; bad = 1 } }
             END { exit bad || !suites }' "$logs/ctest.log" ||
            die "${label}ctest.log does not count every suite's tests"
        for name in $names; do
            counts=$(sed -n "s/^Ran [0-9]* tests.*/- $label$name: &/p; s/^[0-9]* checks passed.*/- $label$name: &/p" \
                "$logs/$name.log" "$logs/$name/test.log" 2>/dev/null || :)
            [ -n "$counts" ] || die "the run's logs do not count $label$name's tests"
            echo "$counts"
        done
    done
    echo
    echo "Skipped tests, each with its reason:"
    echo
    set -- "$work/logs/ctest.log" "$work/logs/python.log" "$work"/logs/*/test.log
    for target in $targets; do
        case $target in linux-*) set -- "$@" "$(logs_of "$target")/ctest.log" "$(logs_of "$target")/python.log" ;; esac
    done
    awk 'FNR == 1 { label = ""
             if (match(FILENAME, /\/logs-[^\/]+\//)) label = substr(FILENAME, RSTART + 6, RLENGTH - 7) " "
             suite = FILENAME; sub(/.*\/logs(-[^\/]+)?\//, "", suite); sub(/(\/test)?\.log$/, "", suite)
             suite = label suite }
         /^[0-9]+\/[0-9]+ Test: / { suite = label "CTest " $3 }
         /^ +SKIPPED +| \.\.\. skipped |^ *[1-9][0-9]* skip$/ { sub(/^ +(SKIPPED +)?/, ""); print "- " suite ": " $0; found = 1 }
         END { if (!found) print "None." }' "$@"
    echo
    echo "## Checks outside CI"
    echo
    echo "Not run: the standalone AppKit checks, physical-key delivery, and the" \
        "fullscreen input tests, which skip on GitHub's runners."
}

# Print the releases of tag $1 on GitHub, drafts too, one a line: ID, draft
# and immutable.
releases_of() {
    gh api "repos/$GH_REPO/releases?per_page=100" --paginate \
        --jq '.[] | "\(.id) \(.tag_name) \(.draft) \(.immutable)"' |
        awk -v tag="$1" '$2 == tag { print $1, $3, $4 }'
}

# Write to $2 the assets of release $1, one a line: ID, size, digest, state
# and name.
assets_of() {
    gh api "repos/$GH_REPO/releases/$1/assets?per_page=100" --paginate \
        --jq '.[] | "\(.id) \(.size) \(.digest) \(.state) \(.name)"' >"$2" ||
        die "cannot list the assets of $tag"
}

# GitHub's lists catch up with a change a few seconds after it: run "$@"
# until it succeeds, PORTAL_RELEASE_SETTLE times at most, 2 s apart.
settle() {
    tries=1
    until "$@"; do
        [ "$tries" -lt "${PORTAL_RELEASE_SETTLE:-15}" ] || return 1
        tries=$((tries + 1))
        sleep 2
    done
}

# Whether GitHub lists a release of $tag, whose ID it then puts in `id`.
listed() {
    id=$(releases_of "$tag" | cut -d' ' -f1)
    [ -n "$id" ]
}

# Whether release $id is published and immutable.
published() {
    [ "$(releases_of "$tag")" = "$id false true" ]
}

# Whether release $1 holds exactly the assets $work/expected names.
holds() {
    assets_of "$1" "$work/held"
    awk '{ print $5 }' "$work/held" | sort | cmp -s "$work/expected" -
}

# Die, saying $2, unless release $1 holds exactly the assets $work/expected
# names.
whole() {
    settle holds "$1" ||
        die "$2: $tag holds $(awk '{ printf "%s ", $5 }' "$work/held")and should hold" \
            "$(tr '\n' ' ' <"$work/expected")"
}

# The release of version $1, in an order that leaves nothing half done in
# view: the tag, then a draft that gets every asset and is published only
# when whole, whereupon GitHub's immutable releases fix its tag and assets;
# then, once anyone can download each asset by the tag, stable and main. Run
# again after a failure, it finishes the release: it completes a draft, and
# checks a published release without ever changing it.
publish() {
    [ -s "$2" ] || die "no notes in $2"
    evidence "$1"
    tag=v$1
    [ "$(gh api "repos/$GH_REPO/immutable-releases" --jq .enabled 2>/dev/null)" = true ] ||
        die "immutable releases are off on $GH_REPO, so a published asset could be" \
            "replaced: turn them on (docs/releasing.md) and run publish again"
    { echo logs.zip
      for target in $targets; do
          echo "portal-runtime-$tag-$target.json"
          echo "portal-runtime-$tag-$target.tar.gz"
      done; } | sort >"$work/expected"
    found=$(releases_of "$tag")
    [ "$(echo "$found" | grep -c .)" -le 1 ] ||
        die "$tag has several releases on GitHub, which the owner must settle:" $found
    id=${found%% *}
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        [ "$(git rev-parse "$tag^{commit}")" = "$release" ] ||
            die "$tag on GitHub is not $release, the release commit"
    elif [ -n "$found" ]; then
        die "$tag has a release on GitHub but no tag"
    fi
    if [ "$(echo "$found" | cut -d' ' -f2)" = false ]; then
        echo "release: $tag is published already: checking it, changing nothing" >&2
    else
        runtimes "$1"
        # Every job's logs: the Mac's and each Linux CPU's.
        (cd "$work" && for target in $targets; do basename "$(logs_of "$target")"; done |
            xargs zip -qr assets/logs.zip)
        if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
            git tag -a "$tag" -m "Portal $1" "$release"
            git push -q origin "refs/tags/$tag"
        fi
        if [ -z "$found" ]; then
            gh release create "$tag" --verify-tag --draft --title "Portal $1" \
                --notes-file "$2" >/dev/null || die "GitHub made no draft of $tag"
            settle listed || die "GitHub shows no draft of $tag"
        else
            echo "release: finishing the draft of $tag that an earlier attempt left" >&2
            gh release edit "$tag" --notes-file "$2" >/dev/null
        fi
        # A draft is nobody's yet: what an earlier attempt left in it that is
        # not this run's goes, and every asset it lacks is uploaded.
        assets_of "$id" "$work/held"
        while read -r asset size digest state name; do
            if grep -qx "$name" "$work/expected" && [ "$state" = uploaded ] &&
                [ "$size $digest" = "$(wc -c <"$work/assets/$name" | tr -d ' ') sha256:$(sha256 "$work/assets/$name")" ]; then
                echo "$name" >>"$work/kept"
                continue
            fi
            echo "release: removing $name from the draft of $tag" >&2
            gh api -X DELETE "repos/$GH_REPO/releases/assets/$asset" ||
                die "cannot remove $name from the draft of $tag"
        done <"$work/held"
        while read -r name; do
            grep -qx "$name" "$work/kept" 2>/dev/null && continue
            gh release upload "$tag" "$work/assets/$name" ||
                die "uploading $name to the draft of $tag failed: nothing is published;" \
                    "run publish again"
        done <"$work/expected"
        whole "$id" "the draft is not whole, so nothing is published; run publish again"
        gh release edit "$tag" --draft=false >/dev/null || die "GitHub did not publish $tag"
    fi

    # Published: what anyone downloads by the tag must be what was tested.
    settle published ||
        die "$tag is published but not immutable, so stable stays: settle it with the owner"
    whole "$id" "$tag is published and stays so, but stable stays: settle it with the owner"
    rm -rf "$work/public" && mkdir "$work/public"
    while read -r name; do
        curl -fsSL --retry "${PORTAL_RELEASE_RETRIES:-5}" --retry-all-errors -o "$work/public/$name" "$downloads/$tag/$name" ||
            die "nobody can download $name by $tag from $downloads, so stable stays"
        [ "$(awk -v name="$name" '$5 == name { print $3 }' "$work/held")" = \
            "sha256:$(sha256 "$work/public/$name")" ] ||
            die "$name downloaded by $tag is not the asset GitHub holds, so stable stays"
        if [ -e "$work/assets/$name" ] && ! cmp -s "$work/assets/$name" "$work/public/$name"; then
            die "$name downloaded by $tag is not what Checks run $run tested, so stable stays"
        fi
    done <"$work/expected"
    for target in $targets; do
        check_runtime "$work/public" "$1" "$target"
    done
    gh release verify "$tag" >&2 || die "GitHub cannot verify $tag, so stable stays"

    if [ "$(git rev-parse -q --verify origin/stable || :)" != "$release" ]; then
        main=$release
        if ! git merge-base --is-ancestor origin/main "$release"; then
            git checkout -q --detach origin/main
            git merge -q --no-ff -m "release: merge Portal $1 into main" "$release"
            main=$(git rev-parse HEAD)
        fi
        git push -q --atomic origin "$release:refs/heads/stable" "$main:refs/heads/main" ||
            die "stable and main did not move: $tag is published; run publish again"
    fi
    git push -q origin --delete "release/$tag"
    echo "Portal $1: $tag published, stable at $release"
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
downloads=${PORTAL_RELEASE_DOWNLOADS:-https://github.com/$GH_REPO/releases/download}
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
