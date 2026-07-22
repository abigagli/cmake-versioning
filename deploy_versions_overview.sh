#!/usr/bin/env bash
#===============================================================================
#
#          FILE: deploy_versions_overview.sh
#
#   DESCRIPTION: One table showing the deploy version state of every project.
#
#                This is the "dashboard" - built from `git ls-remote` against
#                each repository, so there is no service to run and nothing that
#                can drift from the truth. The tags ARE the state.
#
#         USAGE: ./deploy_versions_overview.sh [projects-file]
#
#                The projects file lists one git remote per line; blank lines
#                and #-comments are ignored:
#
#                  git@github.com:your-org/project-one.git
#                  git@github.com:your-org/project-two.git
#
#                It is looked for in this order:
#
#                  1. the path given as an argument
#                  2. $DEPLOY_VERSIONS_PROJECTS
#                  3. ~/.config/deploy-versions/projects.txt
#
#                Deliberately NOT next to this script. This repository is
#                public, and the list names private repositories - it must
#                never be committed here. It cannot live beside the script for
#                a second reason too: this directory is a submodule of the
#                consuming project, and a superproject records only a
#                submodule's commit ID, never its working-tree contents, so a
#                file placed here cannot be committed anywhere at all.
#
#                Keep it outside any repository (the default), or point
#                $DEPLOY_VERSIONS_PROJECTS at a private repo you do control.
#
#===============================================================================

set -o nounset
set -o errexit
set -o pipefail

readonly NS_DEPLOY="deploy"
readonly NS_NEXT="deploy-next"

default_projects_file="${XDG_CONFIG_HOME:-$HOME/.config}/deploy-versions/projects.txt"
projects_file=${1:-${DEPLOY_VERSIONS_PROJECTS:-$default_projects_file}}

if [ ! -f "$projects_file" ]; then
    printf 'no project list at %s\n\n' "$projects_file" >&2
    printf 'Create it with one git remote per line:\n\n' >&2
    printf '  mkdir -p %s\n' "$(dirname "$default_projects_file")" >&2
    printf '  cat >> %s <<EOF\n' "$default_projects_file" >&2
    printf '  git@github.com:your-org/project-one.git\n' >&2
    printf '  git@github.com:your-org/project-two.git\n' >&2
    printf '  EOF\n\n' >&2
    printf 'Or pass a path, or set $DEPLOY_VERSIONS_PROJECTS.\n' >&2
    exit 1
fi

# minor_max <ls-remote output> <namespace>  ->  largest minor, or 0
minor_max() {
    printf '%s\n' "$1" |
        sed -n "s|^[0-9a-f]\{7,\}[[:space:]]*refs/tags/$2/\([0-9][0-9]*\.[0-9][0-9]*\)\(\^{}\)\{0,1\}\$|\1|p" |
        awk -F. '{ m=$2+0; if (m>best) best=m } END { print best+0 }'
}

highest_version() {
    printf '%s\n' "$1" |
        sed -n "s|^[0-9a-f]\{7,\}[[:space:]]*refs/tags/[a-z-]*/\([0-9][0-9]*\.[0-9][0-9]*\)\(\^{}\)\{0,1\}\$|\1|p" |
        sort -V | tail -1
}

printf '%-45s %12s %12s %8s\n' "PROJECT" "DEPLOYED" "NEXT" "COUNT"
printf '%-45s %12s %12s %8s\n' "-------" "--------" "----" "-----"

while IFS= read -r remote || [ -n "$remote" ]; do
    remote=${remote%%#*}
    remote=$(printf '%s' "$remote" | tr -d '[:space:]')
    [ -n "$remote" ] || continue

    name=$(basename "$remote" .git)

    if ! raw=$(git ls-remote --tags "$remote" \
        "refs/tags/${NS_DEPLOY}/*" "refs/tags/${NS_NEXT}/*" 2>/dev/null); then
        printf '%-45s %12s %12s %8s\n' "$name" "unreachable" "-" "-"
        continue
    fi

    deployed_max=$(minor_max "$raw" "$NS_DEPLOY")
    chosen_max=$(minor_max "$raw" "$NS_NEXT")
    highest=$(highest_version "$raw")
    major=${highest%%.*}
    [ -n "$major" ] || major=1

    next=$((deployed_max + 1))
    [ "$chosen_max" -gt "$next" ] && next=$chosen_max

    count=$(printf '%s\n' "$raw" |
        grep -c "refs/tags/${NS_DEPLOY}/.*\^{}\$" || true)

    if [ "$deployed_max" -eq 0 ]; then
        last="none"
    else
        last=$(printf '%s.%05d' "$major" "$deployed_max")
    fi

    printf '%-45s %12s %12s %8s\n' \
        "$name" "$last" "$(printf '%s.%05d' "$major" "$next")" "$count"
done <"$projects_file"
