# git_watcher.cmake
# https://raw.githubusercontent.com/andrew-hardin/cmake-git-version-tracking/master/git_watcher.cmake
#
# Released under the MIT License.
# https://raw.githubusercontent.com/andrew-hardin/cmake-git-version-tracking/master/LICENSE


# This file defines a target that monitors the state of a git repo.
# If the state changes (e.g. a commit is made), then a file gets reconfigured.
# Here are the primary variables that control script behavior:
#
#   PRE_CONFIGURE_FILE (REQUIRED)
#   -- The path to the file that'll be configured.
#
#   POST_CONFIGURE_FILE (REQUIRED)
#   -- The path to the configured PRE_CONFIGURE_FILE.
#
#   GIT_STATE_FILE (OPTIONAL)
#   -- The path to the file used to store the previous build's git state.
#      Defaults to the current binary directory.
#
#   GIT_WORKING_DIR (OPTIONAL)
#   -- The directory from which git commands will be run.
#      Defaults to the directory with the top level CMakeLists.txt.
#
#   GIT_EXECUTABLE (OPTIONAL)
#   -- The path to the git executable. It'll automatically be set if the
#      user doesn't supply a path.
#
# DESIGN
#   - This script was designed similar to a Python application
#     with a Main() function. I wanted to keep it compact to
#     simplify "copy + paste" usage.
#
#   - This script is invoked under two CMake contexts:
#       1. Configure time (when build files are created).
#       2. Build time (called via CMake -P).
#     The first invocation is what registers the script to
#     be executed at build time.
#
# MODIFICATIONS
#   You may wish to track other git properties like when the last
#   commit was made. There are three sections you need to modify,
#   and they're tagged with a ">>>" header.

# Short hand for converting paths to absolute.
macro(PATH_TO_ABSOLUTE var_name)
    get_filename_component(${var_name} "${${var_name}}" ABSOLUTE)
endmacro()

# Check that a required variable is set.
macro(CHECK_REQUIRED_VARIABLE var_name)
    if(NOT DEFINED ${var_name})
        message(FATAL_ERROR "The \"${var_name}\" variable must be defined.")
    endif()
    PATH_TO_ABSOLUTE(${var_name})
endmacro()

# Check that an optional variable is set, or, set it to a default value.
macro(CHECK_OPTIONAL_VARIABLE var_name default_value)
    if(NOT DEFINED ${var_name})
        set(${var_name} ${default_value})
    endif()
    PATH_TO_ABSOLUTE(${var_name})
endmacro()

CHECK_REQUIRED_VARIABLE(PRE_CONFIGURE_FILE)
CHECK_REQUIRED_VARIABLE(POST_CONFIGURE_FILE)
CHECK_OPTIONAL_VARIABLE(GIT_STATE_FILE "${CMAKE_BINARY_DIR}/git-state")
CHECK_OPTIONAL_VARIABLE(GIT_WORKING_DIR "${CMAKE_SOURCE_DIR}")

# Check the optional git variable.
# If it's not set, we'll try to find it using the CMake packaging system.
if(NOT DEFINED GIT_EXECUTABLE)
    find_package(Git QUIET REQUIRED)
endif()
CHECK_REQUIRED_VARIABLE(GIT_EXECUTABLE)



# Function: GetGitState
# Description: gets the current state of the git repo.
# Args:
#   _working_dir (in)  string; the directory from which git commands will be executed.
#   _state       (out) list; a collection of variables representing the state of the
#                            repository (e.g. commit SHA).
function(GetGitState _working_dir _state)

    # Get the hash for HEAD.
    set(_success "true")
    execute_process(COMMAND
        "${GIT_EXECUTABLE}" rev-parse --verify HEAD
        WORKING_DIRECTORY "${_working_dir}"
        RESULT_VARIABLE res
        OUTPUT_VARIABLE _hashvar
        ERROR_QUIET
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(NOT res EQUAL 0)
        set(_success "false")
        set(_hashvar "GIT-NOTFOUND")
    endif()

    # Get whether or not the working tree is dirty.
    execute_process(COMMAND
        "${GIT_EXECUTABLE}" status --porcelain
        WORKING_DIRECTORY "${_working_dir}"
        RESULT_VARIABLE res
        OUTPUT_VARIABLE out
        ERROR_QUIET
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(NOT res EQUAL 0)
        set(_success "false")
        set(_dirty "false")
    else()
        if(NOT "${out}" STREQUAL "")
            set(_dirty "true")
        else()
            set(_dirty "false")
        endif()
    endif()

    # >>>
    # 1. Additional git properties can be added here via the
    #    "execute_process()" command.

    # Return the state as a list in the parent scope.
    set(${_state}
            ${_success}
            ${_hashvar}
            ${_dirty}
            # >>>
            # 2. New git properties must be added to this list as part of
            #    the "state".
        PARENT_SCOPE)
endfunction()



# Function: GitStateChangedAction
# Description: this function is executed when the state of the git
#              repository changes (e.g. a commit is made).
# Args:
#   _state_as_list (in)  list; state variables from the git repository, and
#                              order depends on what was set by "GetGitState".
function(GitStateChangedAction _state_as_list)
    LIST(GET _state_as_list 0 GIT_RETRIEVED_STATE)
    LIST(GET _state_as_list 1 GIT_HEAD_SHA1)
    LIST(GET _state_as_list 2 GIT_IS_DIRTY)
    # >>>
    # 3. Any new git properties need to be retrieved from the state before we
    #    can configure the target file.
    configure_file("${PRE_CONFIGURE_FILE}" "${POST_CONFIGURE_FILE}" @ONLY)
endfunction()



# Function: CheckGit
# Description: check if the git repo has changed. If so, update the state file.
# Args:
#   _working_dir    (in)  string; the directory from which git commands will be ran.
#   _state_changed (out)    bool; whether or no the state of the repo has changed.
#   _state         (out)    list; the repository state as a list (e.g. commit SHA).
function(CheckGit _working_dir _state_changed _state)

    # Get the current state of the repo.
    GetGitState("${_working_dir}" state)

    # Set the output _state variable.
    # (Passing by reference in CMake is awkward...)
    set(${_state} ${state} PARENT_SCOPE)

    # Check if the state has changed compared to the backup on disk.
    if(EXISTS "${GIT_STATE_FILE}")
        file(READ "${GIT_STATE_FILE}" OLD_HEAD_CONTENTS)
        if(OLD_HEAD_CONTENTS STREQUAL "${state}")
            # State didn't change.
            set(${_state_changed} "false" PARENT_SCOPE)
            return()
        endif()
    endif()

    # The state has changed.
    # We need to update the state file on disk.
    # Future builds will compare their state to this file.
    file(WRITE "${GIT_STATE_FILE}" "${state}")
    set(${_state_changed} "true" PARENT_SCOPE)
endfunction()



# Function: SetupGitMonitoring
# Description: this function sets up custom commands that make the build system
#              check the state of git before every build. If the state has
#              changed, then a file is configured.
function(SetupGitMonitoring)
    add_custom_target(check_git
        ALL
        DEPENDS ${PRE_CONFIGURE_FILE}
        BYPRODUCTS ${POST_CONFIGURE_FILE}
        COMMENT "Checking the git repository for changes..."
        COMMAND
            ${CMAKE_COMMAND}
            -D_BUILD_TIME_CHECK_GIT=TRUE
            -DGIT_WORKING_DIR=${GIT_WORKING_DIR}
            -DGIT_EXECUTABLE=${GIT_EXECUTABLE}
            -DGIT_STATE_FILE=${GIT_STATE_FILE}
            -DPRE_CONFIGURE_FILE=${PRE_CONFIGURE_FILE}
            -DPOST_CONFIGURE_FILE=${POST_CONFIGURE_FILE}
            -P "${CMAKE_CURRENT_LIST_FILE}")
endfunction()



# Function: Main
# Description: primary entry-point to the script. Functions are selected based
#              on whether it's configure or build time.
function(Main)
    if(_BUILD_TIME_CHECK_GIT)
        # Check if the repo has changed.
        # If so, run the change action.
        CheckGit("${GIT_WORKING_DIR}" did_change state)
        if(did_change)
            GitStateChangedAction("${state}")
        endif()
    else()
        # >> Executes at configure time.
        SetupGitMonitoring()
    endif()
endfunction()

# And off we go...
Main()
