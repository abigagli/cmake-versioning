# The deploy namespaces are excluded so that deploying a commit does not change
# what rebuilding that same commit produces.
#
# `--all` makes describe consider every ref, tags included, and it prefers a tag
# over a branch head. Without the excludes, the first build of a commit embeds
# "heads/<branch>-0-g<sha>" and every build after the deploy embeds
# "tags/deploy/1.00129-0-g<sha>" - a different length, so a different binary,
# with a different CRC and size in its filename. Two files would then legitimately
# claim to be the same release.
#
# Nothing is lost by hiding them: the deploy version is already in the image, via
# deploy_version(). Ordinary tags (releases, milestones) are still honoured.
execute_process(
  COMMAND git describe --abbrev=7 --dirty --always --all --long
          --exclude=deploy/* --exclude=deploy-next/*
  OUTPUT_VARIABLE CURRENT_GIT_DESCRIBE
  OUTPUT_STRIP_TRAILING_WHITESPACE)

message(STATUS "CURRENT GIT DESCRIBE: ${CURRENT_GIT_DESCRIBE}")
configure_file(${VERSION_TEMPLATE_FILE} ${VERSION_SOURCE_FILE})
