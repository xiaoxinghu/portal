# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.29)

# CMake orchestrates the native module, Bun host and integration tests.
project(portal LANGUAGES C)

if(NOT APPLE)
    message(FATAL_ERROR "Portal requires macOS with AppKit and WebKit")
endif()

include(CTest)
# The C Emacs bindings and their fake-backend tests. This locates Emacs and
# emacs-module.h for the rest of the build.
add_subdirectory(native/Core)

# Record Bun's absolute path so the Bun validated here is the one the build and
# tests run. Search again if the recorded executable was removed or moved.
if(DEFINED CACHE{BUN} AND NOT EXISTS "${BUN}")
    message(STATUS "Recorded Bun ${BUN} no longer exists; searching PATH again")
    unset(BUN CACHE)
endif()
find_program(BUN NAMES bun REQUIRED)
execute_process(COMMAND "${BUN}" -e
    "if (typeof Bun.markdown?.html !== 'function') process.exit(1)"
    RESULT_VARIABLE bun_markdown_status)
if(NOT bun_markdown_status EQUAL 0)
    message(FATAL_ERROR "Bun must support Bun.markdown.html (tested with Bun 1.3.14)")
endif()
# The executable includes Bun and all UI assets; Bun is only a build dependency.
# Publish atomically so a running host can survive a rebuild.
add_custom_command(
    OUTPUT "${CMAKE_BINARY_DIR}/portal-host"
    COMMAND "${BUN}" install --cwd "${CMAKE_SOURCE_DIR}/host" --frozen-lockfile
    COMMAND "${BUN}" run "${CMAKE_SOURCE_DIR}/host/build-editor.ts"
    # Bun 1.4 leaves a copy of its runtime in the working directory: keep it
    # in the build directory, which --prune clears, not in the sources.
    COMMAND "${CMAKE_COMMAND}" -E chdir "${CMAKE_BINARY_DIR}"
        "${BUN}" build "${CMAKE_SOURCE_DIR}/host/server.ts"
        --compile --minify --sourcemap
        --no-compile-autoload-dotenv --no-compile-autoload-bunfig
        --metafile=${CMAKE_BINARY_DIR}/portal-host.meta.json
        --outfile "${CMAKE_BINARY_DIR}/.portal-host"
    COMMAND "${CMAKE_COMMAND}" -E rename
        "${CMAKE_BINARY_DIR}/.portal-host" "${CMAKE_BINARY_DIR}/portal-host"
    # The license notices read both bundler records; rebuild if either is gone.
    BYPRODUCTS "${CMAKE_BINARY_DIR}/portal-host.meta.json"
        "${CMAKE_SOURCE_DIR}/host/.generated/editor-inputs.json"
    DEPENDS host/server.ts host/hello.html host/dialogs.html host/about.ts host/about.html
        host/markdown.ts host/markdown.css
        host/icons/portal-32.png host/icons/portal-64.png host/icons/portal-256.png
        host/package.json host/bun.lock host/tsconfig.json host/build-editor.ts
        host/editor-bootstrap.ts host/excalidraw.tsx host/excalidraw.html host/excalidraw.css "${BUN}"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    COMMENT "Compiling the standalone Bun UI host"
    VERBATIM)
add_custom_target(portal-ui-host ALL DEPENDS "${CMAKE_BINARY_DIR}/portal-host")

if(BUILD_TESTING)
    # Batch Emacs for tests. -Q skips init files, but Emacs still saves state
    # such as project.el's list in the user's Emacs directory; keep it here.
    set(test_emacs "${EMACS}" --batch -Q "--init-directory=${CMAKE_BINARY_DIR}/test-emacs.d")
    # Runs docs/launcher.md's examples; launcher.el is not needed.
    add_test(NAME launcher
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}" -L "${CMAKE_SOURCE_DIR}/test"
            -l "${CMAKE_SOURCE_DIR}/test/portal-launcher-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(launcher PROPERTIES TIMEOUT 30)
    # The Lisp module on the real C core, with the fake backend's hot keys.
    add_test(NAME global-shortcut
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_TEST_MODULE=$<TARGET_FILE:portal-test-module>"
            ${test_emacs} --module-assertions -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-global-shortcut-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(global-shortcut PROPERTIES TIMEOUT 30)
    add_test(NAME system
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_TEST_MODULE=$<TARGET_FILE:portal-test-module>"
            ${test_emacs} --module-assertions -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-system-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(system PROPERTIES TIMEOUT 30)
    # Exercise the documented absolute-path entry point in a fresh Emacs.
    # Do not add the package directory with -L: Portal must load its own siblings.
    add_test(NAME startup
        COMMAND ${test_emacs}
            -l "${CMAKE_SOURCE_DIR}/test/portal-startup-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(startup PROPERTIES TIMEOUT 30)
    # First-use setup with a stand-in build, and this build's own record.
    add_test(NAME build
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_TEST_BUILD=${CMAKE_BINARY_DIR}"
            "PORTAL_TEST_MODULE=$<TARGET_FILE:portal-test-module>"
            ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-build-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(build PROPERTIES TIMEOUT 60)
    add_test(NAME vm-runner COMMAND "${BUN}" test "${CMAKE_SOURCE_DIR}/test/vm.test.ts")
    set_tests_properties(vm-runner PROPERTIES TIMEOUT 30 ENVIRONMENT "EMACS=${EMACS}")
    add_test(NAME gui-runner COMMAND "${BUN}" test "${CMAKE_SOURCE_DIR}/test/gui-ert.test.ts")
    set_tests_properties(gui-runner PROPERTIES TIMEOUT 30)
    add_test(NAME gui-verdict
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}/test"
            -l "${CMAKE_SOURCE_DIR}/test/portal-gui-ert-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(gui-verdict PROPERTIES TIMEOUT 30)
    add_test(NAME ui-host
        COMMAND "${CMAKE_COMMAND}" -E env
            "PORTAL_TEST_HOST=${CMAKE_BINARY_DIR}/portal-host"
            ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-server-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(ui-host PROPERTIES TIMEOUT 30)
    add_test(NAME quick-terminal
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-quick-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(quick-terminal PROPERTIES TIMEOUT 30)
    add_test(NAME terminal-metadata
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-metadata-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(terminal-metadata PROPERTIES TIMEOUT 30)
    add_test(NAME terminal-choose
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-choose-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(terminal-choose PROPERTIES TIMEOUT 30)
    # The optional Consult and Embark adapters and the launcher's graphical
    # completion fixtures use the GNU ELPA releases the user guides name,
    # downloaded once and checked by hash.
    set(elpa_packages
        "elpa.gnu.org/packages/consult-3.10=68aa5daeb701958482dccab3b23a454ff9a9be6b2f4c41fbcc7a353ecfeab096"
        "elpa.gnu.org/packages/embark-1.2=65e4553e709a9619016a635c435f648add310c75601b3b0818ca71c5b46678ea"
        "elpa.gnu.org/packages/vertico-2.15=5c3492edb1e0020da711d9a4213a3878e90e7af8e2e6375757901f4b399872ff"
        "elpa.gnu.org/packages/orderless-1.8=9b4b1253bab2e1d984ad0a31028716d0eff2cd358144bb9caced3b15088e69aa"
        "elpa.gnu.org/packages/marginalia-2.13=e1b228d1d4aa4648982aa79ebb9a2e1d2824b7cd40e01d39ed541f1b7663edba")
    set(elpa_load_path "")
    set(elpa_directories "")
    foreach(entry IN LISTS elpa_packages)
        string(REPLACE "=" ";" entry "${entry}")
        list(GET entry 0 path)
        list(GET entry 1 hash)
        get_filename_component(package "${path}" NAME)
        set(directory "${CMAKE_BINARY_DIR}/elpa/${package}")
        if(NOT EXISTS "${directory}")
            file(DOWNLOAD "https://${path}.tar"
                "${CMAKE_BINARY_DIR}/elpa/${package}.tar" EXPECTED_HASH SHA256=${hash})
            file(ARCHIVE_EXTRACT INPUT "${CMAKE_BINARY_DIR}/elpa/${package}.tar"
                DESTINATION "${CMAKE_BINARY_DIR}/elpa")
            file(REMOVE "${CMAKE_BINARY_DIR}/elpa/${package}.tar")
        endif()
        list(APPEND elpa_load_path -L "${directory}")
        list(APPEND elpa_directories "${directory}")
    endforeach()
    # Install a copy of this checkout as a package, without and with the
    # optional Consult and Embark, in isolated Emacs home directories.
    list(JOIN elpa_directories ":" elpa_path)
    add_test(NAME package
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_TEST_ELPA=${elpa_path}"
            ${test_emacs}
            -l "${CMAKE_SOURCE_DIR}/test/portal-package-tests.el"
            -f ert-run-tests-batch-and-exit)
    # The longest suite by far: start it first in a parallel run, even in a
    # new build directory with no recorded timings.
    set_tests_properties(package PROPERTIES TIMEOUT 300 COST 100)
    foreach(adapter consult embark)
        add_test(NAME terminal-${adapter}
            COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}" ${elpa_load_path}
                -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-${adapter}-tests.el"
                -f ert-run-tests-batch-and-exit)
        set_tests_properties(terminal-${adapter} PROPERTIES TIMEOUT 30)
    endforeach()
    add_test(NAME view
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-view-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(view PROPERTIES TIMEOUT 30)
    add_test(NAME web
        COMMAND "${CMAKE_COMMAND}" -E env
            "PORTAL_TEST_HOST=${CMAKE_BINARY_DIR}/portal-host"
            ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-web-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(web PROPERTIES TIMEOUT 30)
    add_test(NAME input
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-input-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(input PROPERTIES TIMEOUT 30)
    add_test(NAME terminal-bindings
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-bindings-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(terminal-bindings PROPERTIES TIMEOUT 30)
    add_test(NAME excalidraw
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-excalidraw-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(excalidraw PROPERTIES TIMEOUT 30)
endif()
# SwiftPM builds the one native module: the C bindings and the Swift backend.
# Keep the bundle intact: Ghostty locates terminfo and shell integration here.
file(WRITE "${CMAKE_BINARY_DIR}/emacs-include.txt" "${EMACS_INCLUDE}\n")
set(native_package "${CMAKE_SOURCE_DIR}/native")
set(native_scratch "${CMAKE_BINARY_DIR}/swift")
set(native_bundle "${CMAKE_BINARY_DIR}/portal.bundle/Contents")
execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env "EMACS_INCLUDE=${EMACS_INCLUDE}"
        xcrun swift build --package-path "${native_package}"
        --scratch-path "${native_scratch}" -c release --show-bin-path
    OUTPUT_VARIABLE native_bin OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY)
add_custom_target(portal ALL
    COMMAND "${CMAKE_COMMAND}" -E env "EMACS_INCLUDE=${EMACS_INCLUDE}"
        xcrun swift build --package-path "${native_package}"
        --scratch-path "${native_scratch}" -c release --product portal
        --force-resolved-versions
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${native_bundle}/MacOS" "${native_bundle}/Resources"
    COMMAND "${CMAKE_COMMAND}" -E copy "${native_package}/Info.plist" "${native_bundle}/Info.plist"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
        "${native_bin}/GhosttyKit_GhosttyTerminal.bundle"
        "${native_bundle}/Resources/GhosttyKit_GhosttyTerminal.bundle"
    # Publish atomically: never overwrite a library already mapped by Emacs.
    COMMAND "${CMAKE_COMMAND}" -E copy
        "${native_bin}/libportal.dylib" "${native_bundle}/MacOS/.portal.dylib"
    COMMAND "${CMAKE_COMMAND}" -E rename
        "${native_bundle}/MacOS/.portal.dylib" "${native_bundle}/MacOS/portal.dylib"
    BYPRODUCTS "${native_bundle}/MacOS/portal.dylib"
    COMMENT "Building the Portal native module"
    VERBATIM)

# Portal's license and the notices for what both outputs contain, derived from
# the Swift pins, the host's Bun and the bundler records. See docs/licenses.md.
add_custom_target(portal-licenses ALL
    COMMAND "${BUN}" "${CMAKE_SOURCE_DIR}/licenses/notices.ts" stage "${CMAKE_BINARY_DIR}"
    COMMENT "Staging license notices"
    VERBATIM)
add_dependencies(portal-licenses portal portal-ui-host)
if(BUILD_TESTING)
    add_test(NAME licenses
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_BUILD=${CMAKE_BINARY_DIR}"
            "${BUN}" test "${CMAKE_SOURCE_DIR}/test/licenses.test.ts")
    set_tests_properties(licenses PROPERTIES TIMEOUT 60)
endif()

# portal-build.el reads the record of a complete build. Before replacing any
# output, remove it and note the identity of the sources being built.
add_custom_target(portal-build-start
    COMMAND "${EMACS}" --batch -Q -l "${CMAKE_SOURCE_DIR}/portal-build.el"
        -f portal-build--start-batch "${CMAKE_BINARY_DIR}"
    VERBATIM)
add_dependencies(portal portal-build-start)
add_dependencies(portal-ui-host portal-build-start)
# Check the module and host together, then record the build unless its sources
# changed meanwhile. The new module loads only in this disposable batch Emacs,
# never in one that uses Portal.
add_custom_target(portal-build-record ALL
    COMMAND "${EMACS}" --batch -Q -l "${CMAKE_SOURCE_DIR}/portal-build.el"
        -f portal-build--finish-batch "${CMAKE_BINARY_DIR}"
    COMMENT "Checking the Portal build"
    VERBATIM)
add_dependencies(portal-build-record portal portal-ui-host portal-licenses)
