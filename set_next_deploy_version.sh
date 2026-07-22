#!/usr/bin/env bash
#===============================================================================
#
#          FILE: set_next_deploy_version.sh
#
#   DESCRIPTION: Choose the deploy version the next deployed image will carry.
#
#                Pushes a lightweight `deploy-next/<major>.<minor>` tag, which
#                the build reads as "this is the number to use next".
#
#                All the policy lives in deploy_version.sh; this is the
#                discoverable name for the one operation a human performs by
#                hand. It is a thin forwarder on purpose - there is exactly one
#                implementation of the rules.
#
#         USAGE: ./set_next_deploy_version.sh <major>.<minor> [--repo <dir>]
#
#      EXAMPLES: ./set_next_deploy_version.sh 1.200    # jump the minor forward
#                ./set_next_deploy_version.sh 2.201    # bump the major too
#
#         NOTE: the counter only moves FORWARD. A value at or below the current
#               next is refused, because reusing a number would let two
#               different binaries share an image filename.
#
#===============================================================================

set -o nounset
set -o errexit

# Answer for this script rather than forwarding, so the help text names the
# command the user actually typed.
case "${1:-}" in
-h | --help | help | "")
    cat <<EOF
$(basename "$0") - choose the version the next deployed image will carry

USAGE
  $(basename "$0") <major>.<minor> [--repo <dir>]

EXAMPLES
  $(basename "$0") 1.200      # next deploy will be 1.200
  $(basename "$0") 2.201      # bump the major too - the minor never resets

NOTES
  Padding is not significant: 1.200 and 1.00200 mean the same thing.

  The counter only moves FORWARD. A value at or below the current next is
  refused, because reusing a number would let two different binaries share
  an image filename.

  This pushes a lightweight deploy-next/<version> tag. All the policy lives
  in deploy_version.sh; run 'deploy_version.sh --help' for everything else.
EOF
    [ -n "${1:-}" ] && exit 0
    exit 1
    ;;
esac

exec "$(dirname "${BASH_SOURCE[0]}")/deploy_version.sh" set-next "$@"
