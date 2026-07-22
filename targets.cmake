# Versioning targets. Include this once from the project's top-level
# CMakeLists.txt:
#
#   include(cmake/versioning/targets.cmake)
#
# See README.md for the whole design.

# CMAKE_CURRENT_LIST_DIR inside a macro resolves against the CALLER's list file,
# so capture this directory now, while it still means "where this file lives".
set(DEPLOY_VERSIONING_DIR ${CMAKE_CURRENT_LIST_DIR})
set(DEPLOY_VERSION_SCRIPT ${DEPLOY_VERSIONING_DIR}/deploy_version.sh)

# Build scratch, not state: the counter itself lives in git tags on the remote.
set(DEPLOY_VERSION_STATE_FILE ${CMAKE_BINARY_DIR}/allocated_deploy_version.txt)

# Determine build type for both single and multi-config generators
if(CMAKE_CONFIGURATION_TYPES)
  # Multi-configuration generator (e.g. Ninja Multi-Config, Visual Studio, Xcode)
  # CMAKE_BUILD_TYPE is not used; we need a generator expression.
  set(CURRENT_BUILD_TYPE $<CONFIG>)

  # For direct use in non-generator expressions (commands like message()).
  # Use this variable only for debugging or where generator expressions do not work.
  set(CURRENT_BUILD_TYPE_STATIC "MultiConfig")
else()
  # Single-configuration generator (e.g. Makefiles)
  if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE
        "Debug"
        CACHE STRING "Build type" FORCE)
    message(STATUS "No build type specified, defaulting to Debug")
  endif()

  set(CURRENT_BUILD_TYPE "${CMAKE_BUILD_TYPE}")
  set(CURRENT_BUILD_TYPE_STATIC "${CMAKE_BUILD_TYPE}")
endif()

add_custom_target(
  _generate_git_sha
  COMMAND ${CMAKE_COMMAND} -DVERSION_TEMPLATE_FILE=${DEPLOY_VERSIONING_DIR}/version_git_only.c.in
          -DVERSION_SOURCE_FILE=version_git_only.c -P
          ${DEPLOY_VERSIONING_DIR}/generate_git_describe.cmake
  BYPRODUCTS version_git_only.c)

# Reads the counter and bakes the version into version_deploy.c. Does NOT
# consume a number - that happens in the deploy target, on success only.
#
# USES_TERMINAL so the script's warnings (reused version, escape hatches in
# effect) reach the developer unbuffered instead of being swallowed by ninja.
add_custom_target(
  _generate_deploy_version
  COMMAND
    ${CMAKE_COMMAND} -DVERSION_TEMPLATE_FILE=${DEPLOY_VERSIONING_DIR}/version_deploy.c.in
    -DVERSION_SOURCE_FILE=version_deploy.c
    -DDEPLOY_VERSION_SCRIPT=${DEPLOY_VERSION_SCRIPT}
    -DPROJECT_ROOT=${CMAKE_SOURCE_DIR}
    -DSTATE_FILE=${DEPLOY_VERSION_STATE_FILE} -P
    ${DEPLOY_VERSIONING_DIR}/generate_deploy_version.cmake
  BYPRODUCTS version_deploy.c
  USES_TERMINAL)

# --- convenience targets ------------------------------------------------------
#
# Thin forwarders to deploy_version.sh, for developers who work entirely inside
# an IDE. They contain no logic: each runs exactly the command you would type.
# The scripts remain the primary interface and work standalone.
#
# None of these are part of ALL, so they only run when explicitly requested.

add_custom_target(
  deploy_version_list
  COMMAND bash "${DEPLOY_VERSION_SCRIPT}" list --repo "${CMAKE_SOURCE_DIR}"
  COMMENT "Deploy versions on origin"
  USES_TERMINAL VERBATIM)

# A custom target cannot take an argument, so the version comes from the
# environment: DEPLOY_NEXT_VERSION=1.200. Set it in CLion under
# Settings > Build > CMake > Profile > Environment, or in the "environment"
# block of a CMakeUserPresets.json configure preset.
#
# Safe to re-run with a stale value: set-next is idempotent and refuses to move
# the counter backwards.
add_custom_target(
  deploy_version_set_next
  COMMAND bash "${DEPLOY_VERSION_SCRIPT}" set-next --repo "${CMAKE_SOURCE_DIR}"
  COMMENT "Setting the next deploy version from DEPLOY_NEXT_VERSION"
  USES_TERMINAL VERBATIM)

# Reconciles an image built with DEPLOY_VERSION_OVERRIDE once back online.
add_custom_target(
  deploy_version_claim
  COMMAND bash "${DEPLOY_VERSION_SCRIPT}" claim --repo "${CMAKE_SOURCE_DIR}"
          --state "${DEPLOY_VERSION_STATE_FILE}"
  COMMENT "Claiming the version of the last override build"
  USES_TERMINAL VERBATIM)

# ADD_DEPLOY_TARGET_FOR(<target> <origin_file> <image_basename> <images_folder> <script>)
#
# Creates deploy_<target>, which consumes a deploy version and then produces the
# named image.
#
# The two COMMANDs are deliberately separate and ordered: the build tool runs
# them in sequence and stops at the first failure, so a rejected tag push means
# no image is ever written. It also keeps the project's CRC/naming script free
# of versioning policy - it just reads the state file.
macro(ADD_DEPLOY_TARGET_FOR target_name origin_file image_basename images_folder
      script)
  if(CMAKE_HOST_WIN32)
    # Special case for Windows: invoking the bash script through "cmake -E"
    # doesn't work, but luckily we don't need to pass any environment variables
    # to the script so we can just run it directly
    add_custom_target(
      deploy_${target_name}
      COMMAND bash "${DEPLOY_VERSION_SCRIPT}" commit --repo "${CMAKE_SOURCE_DIR}"
              --state "${DEPLOY_VERSION_STATE_FILE}"
      COMMAND "${script}" "${images_folder}" "${origin_file}"
              "${image_basename}" "${DEPLOY_VERSION_STATE_FILE}"
      DEPENDS ${target_name}
      USES_TERMINAL VERBATIM)
  else()
    add_custom_target(
      deploy_${target_name}
      COMMAND bash "${DEPLOY_VERSION_SCRIPT}" commit --repo "${CMAKE_SOURCE_DIR}"
              --state "${DEPLOY_VERSION_STATE_FILE}"
      COMMAND ${CMAKE_COMMAND} -E env "ARM_GCC_DIR=$ENV{ARM_GCC_DIR}" "${script}"
              "${images_folder}" "${origin_file}" "${image_basename}"
              "${DEPLOY_VERSION_STATE_FILE}"
      DEPENDS ${target_name}
      USES_TERMINAL VERBATIM)
  endif()
endmacro()
