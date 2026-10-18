# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.29)

# Portal's C core, tested against a fake backend: the Emacs bindings, the view
# registry, input handoff, terminal views, web views' rules and bridge,
# system-wide shortcuts, the status panel, and the notification pipe. This needs only a C compiler and Emacs: no Swift, Apple
# frameworks, Bun or Ghostty. The top-level project includes it, and it can be
# configured alone to run just these tests. SwiftPM compiles the same sources
# into the production module.
project(portal-core LANGUAGES C)
set(portal_root "${CMAKE_CURRENT_SOURCE_DIR}/../..")

if(DEFINED ENV{EMACS} AND NOT DEFINED EMACS)
    set(EMACS "$ENV{EMACS}" CACHE FILEPATH "Emacs executable")
endif()
find_program(EMACS NAMES emacs REQUIRED)
set(EMACS_INCLUDE "$ENV{EMACS_INCLUDE}" CACHE PATH "Directory containing emacs-module.h")
if(NOT EMACS_INCLUDE)
    execute_process(COMMAND "${EMACS}" --batch -Q --eval
        "(princ (expand-file-name \"../include\" data-directory))"
        OUTPUT_VARIABLE emacs_include OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY)
    unset(EMACS_INCLUDE CACHE)
    find_path(EMACS_INCLUDE emacs-module.h HINTS "${emacs_include}")
endif()
if(NOT EXISTS "${EMACS_INCLUDE}/emacs-module.h")
    message(FATAL_ERROR "Set -DEMACS_INCLUDE=/path/to/include containing emacs-module.h")
endif()

include(CTest)
if(BUILD_TESTING)
    set(fake_backend "${portal_root}/test/portal-fake-backend.c")
    # The core's registry and pipe and the fake backend compile without
    # emacs-module.h, so nothing the platform calls can reach Emacs.
    add_library(portal-test-core OBJECT views.c input.c terminals.c web.c channel.c
        shortcuts.c status.c "${fake_backend}")
    target_include_directories(portal-test-core PUBLIC include . "${portal_root}/test")
    set_target_properties(portal-test-core PROPERTIES POSITION_INDEPENDENT_CODE ON)
    # The real bindings with the fake backend in place of native/Backend.swift.
    add_library(portal-test-module MODULE emacs.c)
    target_include_directories(portal-test-module PRIVATE "${EMACS_INCLUDE}")
    target_link_libraries(portal-test-module PRIVATE portal-test-core)
    add_executable(portal-channel-tests "${portal_root}/test/portal-channel-tests.c")
    target_link_libraries(portal-channel-tests PRIVATE portal-test-core)
    add_executable(portal-views-tests "${portal_root}/test/portal-views-tests.c")
    target_link_libraries(portal-views-tests PRIVATE portal-test-core)
    add_executable(portal-input-tests "${portal_root}/test/portal-input-tests.c")
    target_link_libraries(portal-input-tests PRIVATE portal-test-core)
    add_executable(portal-terminals-tests "${portal_root}/test/portal-terminals-tests.c")
    target_link_libraries(portal-terminals-tests PRIVATE portal-test-core)
    add_executable(portal-web-tests "${portal_root}/test/portal-web-tests.c")
    target_link_libraries(portal-web-tests PRIVATE portal-test-core)
    add_executable(portal-shortcuts-tests "${portal_root}/test/portal-shortcuts-tests.c")
    target_link_libraries(portal-shortcuts-tests PRIVATE portal-test-core)
    add_executable(portal-status-tests "${portal_root}/test/portal-status-tests.c")
    target_link_libraries(portal-status-tests PRIVATE portal-test-core)
    foreach(target portal-test-core portal-test-module portal-channel-tests portal-views-tests
            portal-input-tests portal-terminals-tests portal-web-tests
            portal-shortcuts-tests portal-status-tests)
        target_compile_options(${target} PRIVATE -Wall -Wextra -Werror)
        set_target_properties(${target} PROPERTIES
            C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF)
    endforeach()
    set_target_properties(portal-test-module PROPERTIES PREFIX "")
    add_test(NAME channel COMMAND portal-channel-tests)
    set_tests_properties(channel PROPERTIES TIMEOUT 30)
    add_test(NAME views COMMAND portal-views-tests)
    set_tests_properties(views PROPERTIES TIMEOUT 30)
    add_test(NAME input-core COMMAND portal-input-tests)
    set_tests_properties(input-core PROPERTIES TIMEOUT 30)
    add_test(NAME terminals COMMAND portal-terminals-tests)
    set_tests_properties(terminals PROPERTIES TIMEOUT 30)
    add_test(NAME web-core COMMAND portal-web-tests)
    set_tests_properties(web-core PROPERTIES TIMEOUT 30)
    add_test(NAME shortcuts-core COMMAND portal-shortcuts-tests)
    set_tests_properties(shortcuts-core PROPERTIES TIMEOUT 30)
    add_test(NAME status-core COMMAND portal-status-tests)
    set_tests_properties(status-core PROPERTIES TIMEOUT 30)
    add_test(NAME module
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_TEST_MODULE=$<TARGET_FILE:portal-test-module>"
            "${EMACS}" --batch -Q --module-assertions
            -l "${portal_root}/test/portal-module-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(module PROPERTIES TIMEOUT 30)
endif()
