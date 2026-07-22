# Runs at BUILD time via `cmake -P`, not at configure time, so that every build
# of the versioned target sees the current state of the counter.
#
# This only READS the counter. The number is consumed later, by
# `deploy_version.sh commit`, and only if the image is actually deployed - so an
# aborted or purely local build never burns a version.

foreach(required VERSION_TEMPLATE_FILE VERSION_SOURCE_FILE DEPLOY_VERSION_SCRIPT
                 PROJECT_ROOT STATE_FILE)
  if(NOT DEFINED ${required})
    message(FATAL_ERROR "${required} must be passed with -D${required}=...")
  endif()
endforeach()

# stderr is deliberately NOT captured: the script's warnings and errors must
# reach the terminal as they happen.
execute_process(
  COMMAND bash ${DEPLOY_VERSION_SCRIPT} allocate --repo ${PROJECT_ROOT} --out
          ${STATE_FILE}
  OUTPUT_QUIET
  RESULT_VARIABLE allocate_result)

if(NOT allocate_result EQUAL 0)
  message(
    FATAL_ERROR
      "could not determine the deploy version (see the error above).\n"
      "No version was consumed; fix the problem and build again.")
endif()

# VERSION_DISPLAY is the unpadded, backward-compatible rendering (1.129), with
# any escape-hatch suffix already applied by the script. Keeping every version
# string decision in one place stops the two languages from disagreeing.
file(STRINGS ${STATE_FILE} version_line REGEX "^VERSION_DISPLAY=")
if(NOT version_line)
  message(FATAL_ERROR "no VERSION_DISPLAY in ${STATE_FILE}")
endif()
list(GET version_line 0 version_line)
string(REGEX REPLACE "^VERSION_DISPLAY=" "" DEPLOYED_VERSION "${version_line}")

message(STATUS "DEPLOY VERSION: ${DEPLOYED_VERSION}")
configure_file(${VERSION_TEMPLATE_FILE} ${VERSION_SOURCE_FILE})
