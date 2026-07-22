#!/usr/bin/env bash
#===============================================================================
#
#          FILE: deploy_version.sh
#
#   DESCRIPTION: Single source of policy for deploy version numbers.
#                See README.md for the full picture; this header covers the
#                mechanics a reader of the code needs.
#
#                The counter lives in the project's git remote, as tags:
#
#                  deploy/<major>.<minor>       annotated, created by the build
#                                               when an image is successfully
#                                               deployed. Points at the exact
#                                               commit it was built from.
#                                               EXCLUSIVE: that number is spent.
#
#                  deploy-next/<major>.<minor>  lightweight, created by a human
#                                               to choose the next version.
#                                               INCLUSIVE: that number is the
#                                               one to be used next.
#
#                  next_minor = max( max(minor of deploy/*) + 1 ,
#                                    max(minor of deploy-next/*) )
#                  major      = major of the highest-sorting tag
#
#                The minor NEVER resets when the major is bumped: the image
#                filename carries only the minor (GMAPP_00130_...), so a reset
#                would let two different binaries claim the same name.
#
#                The remote is always the authority. Versions are computed from
#                a single `git ls-remote`; local tags are never consulted, so
#                there is no fetch to forget and no stale local tag to confuse
#                things.
#
#                Allocation is safe under concurrency for free: `git push` of a
#                new tag is an atomic compare-and-swap. The remote rejects a tag
#                that already exists, so two developers racing for the same
#                number cannot both win.
#
#   THREE FORMS: One version, three renderings, all kept in the state file:
#
#                  canonical  1.00129   tags          (padded: sorts, reads well)
#                  display    1.129     firmware      (unpadded: unchanged from
#                                                      the pre-tag scheme)
#                  minor      00129     image filename (padded, as before)
#
#         USAGE: deploy_version.sh next     [--repo <dir>]
#                deploy_version.sh list     [--repo <dir>]
#                deploy_version.sh set-next <version> [--repo <dir>]
#                deploy_version.sh allocate --out   <statefile> [--repo <dir>]
#                deploy_version.sh commit   --state <statefile> [--repo <dir>]
#                deploy_version.sh claim    --state <statefile> [--repo <dir>]
#
#     ESCAPE
#      HATCHES: DEPLOY_VERSION_ALLOW_DIRTY=1
#                   Skip the repository checks. Online. Version computed
#                   normally, marked '-dirty', never tagged, never consumed.
#
#               DEPLOY_VERSION_OVERRIDE=<version>
#                   Emergency. NO network access at all, no checks, the version
#                   is exactly what you asked for, marked '-x', never tagged.
#                   Reconcile afterwards with `claim`.
#
#===============================================================================

set -o nounset
set -o errexit
set -o pipefail

readonly NS_DEPLOY="deploy"
readonly NS_NEXT="deploy-next"
readonly MINOR_WIDTH=5
readonly SUFFIX_DIRTY="-dirty"
readonly SUFFIX_OVERRIDE="-x"

PROG=$(basename "$0")
REPO=""

#--- output -------------------------------------------------------------------

warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

banner() {
    printf '\n' >&2
    printf '%s: ***************************************************************\n' "$PROG" >&2
    for line in "$@"; do printf '%s: %s\n' "$PROG" "$line" >&2; done
    printf '%s: ***************************************************************\n' "$PROG" >&2
    printf '\n' >&2
}

die() {
    printf '\n%s: ERROR: %s\n' "$PROG" "$1" >&2
    shift
    [ $# -gt 0 ] && printf '\n' >&2
    for line in "$@"; do printf '  %s\n' "$line" >&2; done
    printf '\n' >&2
    exit 1
}

#--- repository resolution ----------------------------------------------------

# The counter belongs to the project being built, not to this repository (which
# is normally checked out as a submodule of it). CMake passes --repo explicitly;
# the fallbacks exist for running this script by hand.
resolve_repo() {
    if [ -n "$REPO" ]; then
        [ -e "$REPO/.git" ] || die "'--repo $REPO' is not a git repository"
        REPO=$(cd "$REPO" && pwd)
        return
    fi

    local here super top
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    super=$(git -C "$here" rev-parse --show-superproject-working-tree 2>/dev/null || true)
    if [ -n "$super" ]; then
        REPO="$super"
    else
        top=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null || true)
        REPO="$top"
    fi
    [ -n "$REPO" ] || die "cannot determine which repository holds the counter" \
        "Pass it explicitly: $PROG <command> --repo <dir>"
}

git_repo() { git -C "$REPO" "$@"; }

#--- version formatting -------------------------------------------------------

is_version() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+$'; }

# 10# forces base 10 so a zero-padded minor is never read as octal.
major_of() { printf '%s' "$((10#${1%%.*}))"; }
minor_of() { printf '%s' "$((10#${1#*.}))"; }

canonical() { printf '%s.%0*d' "$(major_of "$1")" "$MINOR_WIDTH" "$(minor_of "$1")"; }
display() { printf '%s.%s' "$(major_of "$1")" "$(minor_of "$1")"; }
padded_minor() { printf '%0*d' "$MINOR_WIDTH" "$(minor_of "$1")"; }

require_version_arg() {
    is_version "$1" || die "'$1' is not a valid version" \
        "Expected <major>.<minor>, for example 1.130 or 1.00130 (both mean the same)."
}

#--- reading the counter ------------------------------------------------------

# One network round trip. Annotated tags produce two lines each:
#   <tagobj-sha>  refs/tags/deploy/1.00130
#   <commit-sha>  refs/tags/deploy/1.00130^{}     <- the "peeled" line
# Lightweight tags produce only the first, already pointing at the commit.
remote_tags() {
    local out
    if ! out=$(git_repo ls-remote --tags origin \
        "refs/tags/${NS_DEPLOY}/*" "refs/tags/${NS_NEXT}/*" 2>&1); then
        die "cannot read the deploy counter from origin" \
            "$(printf '%s' "$out" | head -3)" \
            "" \
            "The counter lives on the remote, so a deploy build needs network" \
            "access. If you are offline and this is an emergency, see the" \
            "DEPLOY_VERSION_OVERRIDE escape hatch in README.md."
    fi
    printf '%s\n' "$out"
}

# versions_in <ls-remote output> <namespace>  ->  sorted unique "major.minor"
versions_in() {
    printf '%s\n' "$1" |
        sed -n "s|^[0-9a-f]\{7,\}[[:space:]]*refs/tags/$2/\([0-9][0-9]*\.[0-9][0-9]*\)\(\^{}\)\{0,1\}\$|\1|p" |
        sort -u
}

# Largest minor across the versions on stdin (0 when there are none).
max_minor() { awk -F. 'NF==2 { m=$2+0; if (m>best) best=m } END { print best+0 }'; }

compute_next() {
    local raw="$1"
    local deployed chosen all
    deployed=$(versions_in "$raw" "$NS_DEPLOY")
    chosen=$(versions_in "$raw" "$NS_NEXT")
    all=$(printf '%s\n%s\n' "$deployed" "$chosen" | sed '/^$/d' | sort -u)

    if [ -z "$all" ]; then
        canonical "1.1"
        return
    fi

    local from_deployed from_chosen next major highest
    # A deploy tag records a number already spent, so move past it.
    # A deploy-next tag names the number to use, so take it as-is.
    from_deployed=$(printf '%s\n' "$deployed" | sed '/^$/d' | max_minor)
    from_chosen=$(printf '%s\n' "$chosen" | sed '/^$/d' | max_minor)
    next=$((from_deployed + 1))
    if [ "$from_chosen" -gt "$next" ]; then
        next=$from_chosen
    fi

    highest=$(printf '%s\n' "$all" | sort -V | tail -1)
    major=$(major_of "$highest")

    canonical "${major}.${next}"
}

# If HEAD already carries a deploy tag, reuse it: rebuilding the same source
# must be idempotent rather than burning a fresh number.
version_at_head() {
    local raw="$1" head
    head=$(git_repo rev-parse HEAD)
    printf '%s\n' "$raw" |
        sed -n "s|^${head}[[:space:]]*refs/tags/${NS_DEPLOY}/\([0-9][0-9]*\.[0-9][0-9]*\)\(\^{}\)\{0,1\}\$|\1|p" |
        sort -V | tail -1
}

# The commit a deploy tag resolves to on the remote, or empty if it is free.
#
# Both refs must be requested explicitly: filtering ls-remote by "refs/tags/X"
# does NOT return the peeled "refs/tags/X^{}" companion, and for an annotated
# tag the unpeeled sha is the tag OBJECT, not the commit. Asking for only the
# former silently compares a tag sha against a commit sha, which never matches.
remote_tag_commit() {
    local tag="$1"
    git_repo ls-remote --tags origin \
        "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null |
        awk -v want="refs/tags/${tag}" '
            $2 == want "^{}" { peeled = $1 }
            $2 == want       { plain  = $1 }
            END { if (peeled != "") print peeled; else if (plain != "") print plain }'
}

#--- preconditions ------------------------------------------------------------

# Is <sha> reachable from any branch on <repo>'s origin?
commit_is_pushed() {
    local dir="$1" sha="$2" tip
    for tip in $(git -C "$dir" ls-remote --heads origin 2>/dev/null | awk '{print $1}'); do
        # The tip must exist locally for an ancestry test to be possible.
        if git -C "$dir" cat-file -e "${tip}^{commit}" 2>/dev/null &&
            git -C "$dir" merge-base --is-ancestor "$sha" "$tip" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Same question, tolerating stale local objects by refreshing once. Any
# remaining arguments are the explanation shown on failure - it differs
# meaningfully between the superproject and a submodule, see the callers.
require_pushed() {
    local dir="$1" sha="$2" what="$3"
    shift 3
    commit_is_pushed "$dir" "$sha" && return 0
    git -C "$dir" fetch --quiet origin 2>/dev/null || true
    commit_is_pushed "$dir" "$sha" && return 0
    die "$what is not on any branch on origin" "commit: $sha" "" "$@"
}

tree_is_clean() { [ -z "$(git_repo status --porcelain --ignore-submodules=none)" ]; }

require_clean_tree() {
    tree_is_clean && return 0
    die "the working tree has uncommitted changes" \
        "$(git_repo status --porcelain --ignore-submodules=none | head -10)" \
        "" \
        "A deploy image must be reproducible from a commit. Commit or stash," \
        "or see the escape hatches in README.md."
}

require_submodules_ok() {
    local line flag sha path rest
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        flag=${line:0:1}
        rest=${line:1}
        sha=$(printf '%s' "$rest" | awk '{print $1}')
        path=$(printf '%s' "$rest" | awk '{print $2}')
        case "$flag" in
        '-') die "submodule '$path' is not initialised" \
            "Run: git submodule update --init --recursive" ;;
        '+') die "submodule '$path' is checked out at $sha, which is not the" \
            "commit recorded by the superproject." \
            "" \
            "Either record the new pointer (git add $path) or restore the" \
            "old one (git submodule update -- $path)." ;;
        'U') die "submodule '$path' has unresolved merge conflicts" ;;
        esac
        # Note the asymmetry with HEAD below: a superproject tag records only
        # the submodule's commit ID, never its objects - they live in a
        # different repository. So for a submodule this really is a
        # recoverability requirement, not just a process one.
        require_pushed "$REPO/$path" "$sha" "submodule '$path'" \
            "The deploy tag records only this commit's ID, not its contents -" \
            "submodule objects live in a different repository and are not" \
            "carried along. Unpushed, this commit cannot be recovered at all." \
            "" \
            "  cd $path && git push"
    done < <(git_repo submodule status --recursive)
}

#--- state file ---------------------------------------------------------------

write_state() {
    local out="$1" version="$2" suffix="$3" dirty="$4" override="$5" reused="$6"
    local clean=0
    tree_is_clean 2>/dev/null && clean=1

    cat >"$out" <<EOF
# Generated by $PROG - build scratch, NOT state.
# The counter itself lives in git tags on the project's remote.
VERSION=$(canonical "$version")
VERSION_DISPLAY=$(display "$version")${suffix}
MAJOR=$(major_of "$version")
MINOR=$(padded_minor "$version")
DIRTY=$dirty
OVERRIDE=$override
REUSED=$reused
TREE_CLEAN=$clean
COMMIT=$(git_repo rev-parse HEAD 2>/dev/null || printf 'unknown')
EOF
}

load_state() {
    local state="$1"
    [ -f "$state" ] || die "missing state file '$state'" \
        "Was 'allocate' run? The deploy target builds the versioned image first."
    # shellcheck disable=SC1090
    . "$state"
}

#--- commands -----------------------------------------------------------------

cmd_next() { compute_next "$(remote_tags)"; }

cmd_list() {
    local raw deployed chosen
    raw=$(remote_tags)
    deployed=$(versions_in "$raw" "$NS_DEPLOY" | sort -V)
    chosen=$(versions_in "$raw" "$NS_NEXT" | sort -V)

    printf 'repository : %s\n' "$(git_repo remote get-url origin)"
    printf 'next       : %s\n\n' "$(compute_next "$raw")"

    if [ -n "$deployed" ]; then
        printf 'deployed (%s/):\n' "$NS_DEPLOY"
        printf '%s\n' "$deployed" | sed 's/^/  /'
    else
        printf 'deployed (%s/): none\n' "$NS_DEPLOY"
    fi
    if [ -n "$chosen" ]; then
        # deploy-next tags are append-only, so old ones stay visible forever.
        # Only the highest can matter, and only while deploys have not overtaken
        # it - mark which, so the others do not read as still active.
        local from_deployed highest v
        from_deployed=$(($(printf '%s\n' "$deployed" | sed '/^$/d' | max_minor) + 1))
        highest=$(printf '%s\n' "$chosen" | tail -1)

        printf '\nrequested (%s/):\n' "$NS_NEXT"
        for v in $chosen; do
            if [ "$v" = "$highest" ] && [ "$(minor_of "$v")" -ge "$from_deployed" ]; then
                printf '  %-14s <- in effect\n' "$v"
            else
                printf '  %-14s    superseded\n' "$v"
            fi
        done
    fi
}

cmd_set_next() {
    local wanted="$1"
    require_version_arg "$wanted"

    local raw current tag
    raw=$(remote_tags)
    current=$(compute_next "$raw")
    wanted=$(canonical "$wanted")

    # A lower value cannot take effect: max(deploy)+1 would still win. Say so
    # rather than pushing a tag that silently does nothing.
    if [ "$(minor_of "$wanted")" -lt "$(minor_of "$current")" ] &&
        [ "$(major_of "$wanted")" -le "$(major_of "$current")" ]; then
        die "the counter is already at $current; setting it to $wanted would have no effect" \
            "The next version is max(highest deploy tag + 1, highest deploy-next tag)," \
            "so a lower request is ignored by construction. This is deliberate:" \
            "reusing a number would let two different binaries share a filename." \
            "" \
            "To move forward, pick a value greater than or equal to $current."
    fi

    tag="${NS_NEXT}/${wanted}"
    if [ -n "$(remote_tag_commit "$tag")" ]; then
        warn "$tag already exists on origin - nothing to do"
        return 0
    fi

    git_repo tag -f "$tag" HEAD >/dev/null
    if ! git_repo push --quiet origin "refs/tags/$tag"; then
        git_repo tag -d "$tag" >/dev/null 2>&1 || true
        die "could not push $tag" "Check your access to $(git_repo remote get-url origin)."
    fi

    printf 'next deploy version for %s is now %s\n' \
        "$(git_repo remote get-url origin)" "$wanted"
}

cmd_allocate() {
    local out="$1"
    local raw version reused=0

    # --- emergency: no network, no checks, exact version ---
    if [ -n "${DEPLOY_VERSION_OVERRIDE:-}" ]; then
        require_version_arg "$DEPLOY_VERSION_OVERRIDE"

        # The marker can be suppressed when the version string itself must match
        # something external exactly. The 'override/' subfolder and OVERRIDE=1 in
        # the state file remain, so the image is still distinguishable and still
        # claimable - but the firmware no longer says how it was built.
        local suffix="$SUFFIX_OVERRIDE" marked="marked '${SUFFIX_OVERRIDE}'"
        if [ "${DEPLOY_VERSION_NO_MARK:-0}" != "0" ]; then
            suffix=""
            marked="NOT marked - the firmware is indistinguishable from a real deploy"
        fi

        banner "DEPLOY_VERSION_OVERRIDE is set." \
            "" \
            "The counter was NOT consulted and no checks were run." \
            "Version $(display "$DEPLOY_VERSION_OVERRIDE") is used exactly as given," \
            "$marked, and NOT tagged - nothing records that this" \
            "number is in use." \
            "" \
            "The image goes to the 'override/' subfolder." \
            "Once back online, run:  deploy_version.sh claim --state <statefile>"
        write_state "$out" "$DEPLOY_VERSION_OVERRIDE" "$suffix" 0 1 0
        canonical "$DEPLOY_VERSION_OVERRIDE"
        return 0
    fi

    if [ "${DEPLOY_VERSION_NO_MARK:-0}" != "0" ]; then
        die "DEPLOY_VERSION_NO_MARK only applies to DEPLOY_VERSION_OVERRIDE builds" \
            "It suppresses the '${SUFFIX_OVERRIDE}' marker on an emergency image." \
            "A normal build is tagged and needs no marker; a dirty build must keep" \
            "its '${SUFFIX_DIRTY}' marker, since it is not reproducible."
    fi

    # --- development: online, checks skipped ---
    if [ "${DEPLOY_VERSION_ALLOW_DIRTY:-0}" != "0" ]; then
        banner "DEPLOY_VERSION_ALLOW_DIRTY is set - repository checks SKIPPED." \
            "" \
            "This image is marked '${SUFFIX_DIRTY}', will NOT be tagged and does NOT" \
            "consume a version number. It goes to the 'dirty/' subfolder." \
            "Do not ship it."
        raw=$(remote_tags)
        version=$(compute_next "$raw")
        write_state "$out" "$version" "$SUFFIX_DIRTY" 1 0 0
        canonical "$version"
        return 0
    fi

    # --- normal path ---
    # Order matters for the error messages. The cheap local check goes first,
    # then the remote read - which is what turns "no network" into a message
    # naming the override hatch. Doing the pushed-ness checks first would
    # instead report "HEAD is not on origin", telling an offline developer to
    # push when pushing is not the problem.
    require_clean_tree
    raw=$(remote_tags)
    require_pushed "$REPO" "$(git_repo rev-parse HEAD)" "HEAD" \
        "Pushing the deploy tag would upload this commit, so the image would" \
        "stay reproducible - but the code would never reach a shared branch," \
        "and main would not reflect what is running in the field." \
        "" \
        "  git push                                   # publish this branch" \
        "  git switch main && git merge - && git push # or merge it first"
    require_submodules_ok
    version=$(version_at_head "$raw")
    if [ -n "$version" ]; then
        reused=1
        warn "HEAD is already deployed as $(canonical "$version") - reusing it"
    else
        version=$(compute_next "$raw")
    fi

    write_state "$out" "$version" "" 0 0 "$reused"
    canonical "$version"
}

cmd_commit() {
    local state="$1"
    load_state "$state"

    if [ "$OVERRIDE" != "0" ]; then
        warn "override build - not tagging. Reconcile later with: $PROG claim --state $state"
        return 0
    fi
    if [ "$DIRTY" != "0" ]; then
        warn "dirty build - not tagging; version $VERSION stays unallocated"
        return 0
    fi

    publish_tag "$VERSION" "$(git_repo rev-parse HEAD)"
}

cmd_claim() {
    local state="$1"
    load_state "$state"

    [ "$OVERRIDE" != "0" ] || die "state file '$state' is not from an override build" \
        "'claim' exists to reconcile a DEPLOY_VERSION_OVERRIDE image after the fact." \
        "A normal build already tagged itself."

    if [ "$TREE_CLEAN" != "1" ]; then
        # Computed up front: nesting a quoted awk program inside a die argument
        # mangles the escaping and silently yields an empty suggestion.
        local bump
        bump=$(printf '%s.%s' "$(major_of "$VERSION")" "$(($(minor_of "$VERSION") + 1))")
        die "that image was built from a modified working tree" \
            "A deploy tag points at a commit, so an image built from uncommitted" \
            "changes cannot honestly be attributed to one." \
            "" \
            "Instead, make sure the number is never reused:" \
            "  set_next_deploy_version.sh $bump"
    fi

    local head
    head=$(git_repo rev-parse HEAD)
    [ "$head" = "$COMMIT" ] || die "the repository has moved since that image was built" \
        "built at : $COMMIT" \
        "HEAD now : $head" \
        "" \
        "Check out $COMMIT and run claim again, or bump the counter past" \
        "$VERSION with set_next_deploy_version.sh."

    require_clean_tree
    require_pushed "$REPO" "$head" "HEAD"
    publish_tag "$VERSION" "$head"
}

# Create and push deploy/<version> at <commit>. Idempotent; fails loudly if the
# number was taken by someone else.
publish_tag() {
    local version="$1" head="$2"
    local tag="${NS_DEPLOY}/${version}" existing

    # Re-check the remote rather than trusting the state file: time has passed
    # since allocate, and the remote is the authority.
    existing=$(remote_tag_commit "$tag")
    if [ -n "$existing" ]; then
        if [ "$existing" = "$head" ]; then
            warn "$tag already published for this commit - nothing to do"
            return 0
        fi
        die "version $version was taken by someone else" \
            "$tag exists on origin pointing at $existing" \
            "this build is at $head" \
            "" \
            "Re-run the deploy target: it will pick up the next free number."
    fi

    if ! git_repo rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        git_repo tag -a "$tag" -m "Deploy $version" "$head"
    fi

    # This push is the allocation: the remote rejects a tag that already
    # exists, so a race can only ever have one winner.
    if ! git_repo push --quiet origin "refs/tags/$tag"; then
        git_repo tag -d "$tag" >/dev/null 2>&1 || true
        die "could not publish $tag - the number was taken while building" \
            "Re-run the deploy target: it will pick up the next free number."
    fi

    warn "published $tag -> $head"
}

#--- entry point --------------------------------------------------------------

usage() {
    cat <<EOF
$PROG - deploy version counter backed by git tags

USAGE
  $PROG <command> [options]

COMMANDS
  next                     Print the version the next deploy will use
  list                     Show everything the remote knows about this project
  set-next <version>       Choose the version the next deploy will carry
  allocate --out <file>    Read the counter, write the state file  (build step)
  commit   --state <file>  Publish the tag - the actual allocation (build step)
  claim    --state <file>  Retroactively tag an image built with OVERRIDE

OPTIONS
  --repo <dir>   The repository holding the counter. Defaults to the
                 superproject of wherever this script lives, which is what
                 you want when it is mounted as a submodule.
  -h, --help     Show this help.

ENVIRONMENT
  DEPLOY_VERSION_ALLOW_DIRTY=1
      Skip the repository checks. Online; the version is computed normally,
      marked '-dirty', never tagged and never consumed. For iterating.

  DEPLOY_VERSION_OVERRIDE=<version>
      Emergency. NO network access at all and no checks; the version is
      exactly what you ask for, marked '-x', never tagged. Reconcile once
      back online with 'claim'.

  DEPLOY_VERSION_NO_MARK=1
      Only with DEPLOY_VERSION_OVERRIDE: drop the '-x' marker, so the
      firmware string is exactly the version you asked for. Use when the
      string must match something external. The image still goes to
      'override/' and is still claimable, but nothing in the binary says
      it bypassed the counter.

  DEPLOY_NEXT_VERSION=<version>
      Used by 'set-next' when no argument is given - this is how the
      deploy_version_set_next CMake target supplies it.

VERSIONS
  Written <major>.<minor>. Padding is not significant: 1.200 and 1.00200
  mean the same thing.

EXAMPLES
  $PROG list                       # what is deployed, and what comes next
  $PROG set-next 1.200             # the next image will be 1.200

See README.md next to this script for how it works and a runbook.
EOF
    exit "${1:-0}"
}

main() {
    # No command at all is a usage error; asking for help is not.
    [ $# -ge 1 ] || usage 1
    local command="$1"
    shift
    case "$command" in
    -h | --help | help) usage 0 ;;
    esac

    local out="" state="" positional=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --repo) REPO=${2:?--repo needs a value}; shift 2 ;;
        --out) out=${2:?--out needs a value}; shift 2 ;;
        --state) state=${2:?--state needs a value}; shift 2 ;;
        -h | --help) usage 0 ;;
        -*) die "unknown option '$1'" ;;
        *) positional=$1; shift ;;
        esac
    done

    resolve_repo

    case "$command" in
    next) cmd_next ;;
    list) cmd_list ;;
    set-next)
        # The positional argument is the terminal route; DEPLOY_NEXT_VERSION is
        # how the deploy_version_set_next CMake target (and therefore an IDE)
        # supplies it, since a custom target cannot take arguments.
        [ -n "$positional" ] || positional=${DEPLOY_NEXT_VERSION:-}
        [ -n "$positional" ] || die "'set-next' needs a version" \
            "From a terminal:  $PROG set-next 1.200" \
            "                  set_next_deploy_version.sh 1.200" \
            "" \
            "From an IDE: set DEPLOY_NEXT_VERSION=1.200 in the environment" \
            "(CLion: Settings > Build > CMake > Profile > Environment, or the" \
            "'environment' section of a CMakeUserPresets.json configure preset)" \
            "and build the 'deploy_version_set_next' target."
        cmd_set_next "$positional"
        ;;
    allocate)
        [ -n "$out" ] || die "'allocate' needs --out <statefile>"
        cmd_allocate "$out"
        ;;
    commit)
        [ -n "$state" ] || die "'commit' needs --state <statefile>"
        cmd_commit "$state"
        ;;
    claim)
        [ -n "$state" ] || die "'claim' needs --state <statefile>"
        cmd_claim "$state"
        ;;
    *) die "unknown command '$command'" "Run '$PROG --help' for usage." ;;
    esac
}

main "$@"
