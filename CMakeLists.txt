# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.29)

# CMake orchestrates the native module, Bun host and integration tests.
project(portal LANGUAGES C)

if(NOT APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "Portal requires macOS with AppKit and WebKit, or Linux with GTK 3 and Wayland")
endif()
if(NOT APPLE)
    # For clangd: SourceKit-LSP reads native/Package.swift on macOS instead.
    set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
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
    DEPENDS host/server.ts host/app.ts host/hello.html host/dialogs.html host/about.ts host/about.html
        host/sign-in.ts
        host/markdown.ts host/markdown.css
        host/icons/portal-32.png host/icons/portal-64.png host/icons/portal-256.png
        host/package.json host/bun.lock host/tsconfig.json host/build-editor.ts
        host/editor-bootstrap.ts host/excalidraw.tsx host/excalidraw.html host/excalidraw.css host/slides.ts
        host/audience.ts host/audience.html host/present.ts
        "${BUN}"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    COMMENT "Compiling the standalone Bun UI host"
    VERBATIM)
add_custom_target(portal-ui-host ALL DEPENDS "${CMAKE_BINARY_DIR}/portal-host")

if(BUILD_TESTING)
    # Batch Emacs for tests. -Q skips init files, but Emacs still saves state
    # such as project.el's list in the user's Emacs directory; keep it here.
    set(test_emacs "${EMACS}" --batch -Q "--init-directory=${CMAKE_BINARY_DIR}/test-emacs.d")
    # Run a suite's loaded tests in their tiers: see test/portal-test-tiers.el.
    set(ert_batch -l "${CMAKE_SOURCE_DIR}/test/portal-test-tiers.el" -f portal-test-tiers-run-batch)
    # Runs docs/launcher.md's examples; launcher.el is not needed.
    add_test(NAME launcher
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}" -L "${CMAKE_SOURCE_DIR}/test"
            -l "${CMAKE_SOURCE_DIR}/test/portal-launcher-tests.el"
            ${ert_batch})
    set_tests_properties(launcher PROPERTIES TIMEOUT 30)
    # The Lisp module on the real C core, with the fake backend's hot keys.
    add_test(NAME global-shortcut
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_TEST_MODULE=$<TARGET_FILE:portal-test-module>"
            ${test_emacs} --module-assertions -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-global-shortcut-tests.el"
            ${ert_batch})
    set_tests_properties(global-shortcut PROPERTIES TIMEOUT 30)
    add_test(NAME system
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_TEST_MODULE=$<TARGET_FILE:portal-test-module>"
            ${test_emacs} --module-assertions -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-system-tests.el"
            ${ert_batch})
    set_tests_properties(system PROPERTIES TIMEOUT 30)
    # Exercise the documented absolute-path entry point in a fresh Emacs.
    # Do not add the package directory with -L: Portal must load its own siblings.
    add_test(NAME startup
        COMMAND ${test_emacs}
            -l "${CMAKE_SOURCE_DIR}/test/portal-startup-tests.el"
            ${ert_batch})
    set_tests_properties(startup PROPERTIES TIMEOUT 30)
    # First-use setup with a stand-in build, and this build's own record.
    add_test(NAME build
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_TEST_BUILD=${CMAKE_BINARY_DIR}"
            "PORTAL_TEST_MODULE=$<TARGET_FILE:portal-test-module>"
            ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-build-tests.el"
            ${ert_batch})
    set_tests_properties(build PROPERTIES TIMEOUT 60)
    # The runner of graphical checks in a macOS VM is written for macOS on
    # both ends: lockf, chflags, APFS clones.
    if(APPLE)
        add_test(NAME vm-runner COMMAND "${BUN}" test "${CMAKE_SOURCE_DIR}/test/vm.test.ts")
        set_tests_properties(vm-runner PROPERTIES TIMEOUT 30 ENVIRONMENT "EMACS=${EMACS}")
        add_test(NAME vm-retention COMMAND "${BUN}" test "${CMAKE_SOURCE_DIR}/test/vm-retention.test.ts")
        set_tests_properties(vm-retention PROPERTIES TIMEOUT 30)
    endif()
    add_test(NAME gui-runner COMMAND "${BUN}" test "${CMAKE_SOURCE_DIR}/test/gui-ert.test.ts")
    set_tests_properties(gui-runner PROPERTIES TIMEOUT 30)
    add_test(NAME gui-verdict
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}/test"
            -l "${CMAKE_SOURCE_DIR}/test/portal-gui-ert-tests.el"
            ${ert_batch})
    set_tests_properties(gui-verdict PROPERTIES TIMEOUT 30)
    # What the app host serves, tested in Bun beside its sources.
    add_test(NAME app-host
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_BUILD=${CMAKE_BINARY_DIR}"
            "${BUN}" test
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/host")
    set_tests_properties(app-host PROPERTIES TIMEOUT 30)
    # How Emacs starts, handshakes with and restarts it.
    add_test(NAME app-host-seam
        COMMAND "${CMAKE_COMMAND}" -E env
            "PORTAL_TEST_HOST=${CMAKE_BINARY_DIR}/portal-host"
            ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-server-tests.el"
            ${ert_batch})
    set_tests_properties(app-host-seam PROPERTIES TIMEOUT 30)
    add_test(NAME quick-terminal
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-quick-tests.el"
            ${ert_batch})
    set_tests_properties(quick-terminal PROPERTIES TIMEOUT 30)
    add_test(NAME terminal-metadata
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-metadata-tests.el"
            ${ert_batch})
    set_tests_properties(terminal-metadata PROPERTIES TIMEOUT 30)
    add_test(NAME terminal-choose
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-choose-tests.el"
            ${ert_batch})
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
            ${ert_batch})
    # The longest suite by far: start it first in a parallel run, even in a
    # new build directory with no recorded timings.
    set_tests_properties(package PROPERTIES TIMEOUT 300 COST 100)
    foreach(adapter consult embark)
        add_test(NAME terminal-${adapter}
            COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}" ${elpa_load_path}
                -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-${adapter}-tests.el"
                ${ert_batch})
        set_tests_properties(terminal-${adapter} PROPERTIES TIMEOUT 30)
    endforeach()
    add_test(NAME web-consult
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}" ${elpa_load_path}
            -l "${CMAKE_SOURCE_DIR}/test/portal-web-consult-tests.el"
            ${ert_batch})
    set_tests_properties(web-consult PROPERTIES TIMEOUT 30)
    add_test(NAME view
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-view-tests.el"
            ${ert_batch})
    set_tests_properties(view PROPERTIES TIMEOUT 30)
    add_test(NAME web
        COMMAND "${CMAKE_COMMAND}" -E env
            "PORTAL_TEST_HOST=${CMAKE_BINARY_DIR}/portal-host"
            ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-web-tests.el"
            ${ert_batch})
    set_tests_properties(web PROPERTIES TIMEOUT 30)
    add_test(NAME input
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-input-tests.el"
            ${ert_batch})
    set_tests_properties(input PROPERTIES TIMEOUT 30)
    add_test(NAME terminal-bindings
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-bindings-tests.el"
            ${ert_batch})
    set_tests_properties(terminal-bindings PROPERTIES TIMEOUT 30)
    # The Rex client on the built module, whose sockets need no window, against
    # test/fake-rex-server.py on sockets of its own.
    add_test(NAME rex
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_TEST_BUILD=${CMAKE_BINARY_DIR}"
            ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-rex-tests.el"
            ${ert_batch})
    set_tests_properties(rex PROPERTIES TIMEOUT 60)
    add_test(NAME excalidraw
        COMMAND ${test_emacs} -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-excalidraw-tests.el"
            ${ert_batch})
    set_tests_properties(excalidraw PROPERTIES TIMEOUT 30)
endif()
if(APPLE)
    # SwiftPM builds the one native module: the C bindings and the Swift backend.
    # Keep the bundle intact: Ghostty locates terminfo and shell integration here.
    file(WRITE "${CMAKE_BINARY_DIR}/emacs-include.txt" "${EMACS_INCLUDE}\n")
    set(native_package "${CMAKE_SOURCE_DIR}/native")
    # The Swift package builds libghostty-spm from build/libghostty-spm: its source at
    # the release native/libghostty-spm.json pins, with native/patches/libghostty-spm
    # applied. Configure again, and so make that copy again, when any of them changes.
    set(ghostty_pin "${native_package}/libghostty-spm.json")
    set(ghostty_patches "${native_package}/patches/libghostty-spm")
    set(ghostty_source "${CMAKE_BINARY_DIR}/libghostty-spm")
    file(GLOB ghostty_patch_files CONFIGURE_DEPENDS "${ghostty_patches}/*.patch")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
        "${ghostty_pin}" "${CMAKE_SOURCE_DIR}/tools/patch-libghostty-spm.sh" ${ghostty_patch_files})
    execute_process(
        COMMAND sh "${CMAKE_SOURCE_DIR}/tools/patch-libghostty-spm.sh"
            "${ghostty_pin}" "${ghostty_patches}" "${ghostty_source}"
        COMMAND_ERROR_IS_FATAL ANY)
    set(native_scratch "${CMAKE_BINARY_DIR}/swift")
    set(native_bundle "${CMAKE_BINARY_DIR}/portal.bundle/Contents")
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E env "EMACS_INCLUDE=${EMACS_INCLUDE}"
            "PORTAL_LIBGHOSTTY_SPM=${ghostty_source}"
            xcrun swift build --package-path "${native_package}"
            --scratch-path "${native_scratch}" -c release --show-bin-path
        OUTPUT_VARIABLE native_bin OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY)
    add_custom_target(portal ALL
        COMMAND "${CMAKE_COMMAND}" -E env "EMACS_INCLUDE=${EMACS_INCLUDE}"
            "PORTAL_LIBGHOSTTY_SPM=${ghostty_source}"
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
else()
    # Linux: this project compiles the one native module itself, the C bindings
    # and core with the GTK3 backend, into portal.so, linked with Ghostty's
    # library. No Swift.
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(portal_platform REQUIRED IMPORTED_TARGET gtk+-3.0 wayland-client)
    find_package(Threads REQUIRED)

    # Ghostty's embedding library, which no release ships for Linux, built by
    # tools/build-ghostty-linux.sh from the release native/ghostty.json pins
    # with native/patches/ghostty applied. It installs the library, its header
    # and the resources in build/ghostty-linux, which an installed Portal keeps
    # beside portal.so: the module finds the library by its rpath, and the
    # resources from its own place. The script runs Zig every time, so it runs
    # only when the pin, a patch, the set of patches or the script changed, or
    # an output is gone.
    # To build changes made in its copy, build/ghostty, run the script itself.
    set(ghostty_pin "${CMAKE_SOURCE_DIR}/native/ghostty.json")
    file(READ "${ghostty_pin}" ghostty_pin_json)
    string(JSON ghostty_version GET "${ghostty_pin_json}" version)
    string(JSON ghostty_zig GET "${ghostty_pin_json}" zig)
    if(DEFINED CACHE{ZIG} AND NOT EXISTS "${ZIG}")
        message(STATUS "Recorded Zig ${ZIG} no longer exists; searching again")
        unset(ZIG CACHE)
    endif()
    if(DEFINED ENV{ZIG} AND NOT DEFINED CACHE{ZIG})
        set(ZIG "$ENV{ZIG}" CACHE FILEPATH "The Zig that builds Ghostty's library")
    endif()
    find_program(ZIG NAMES zig)
    if(NOT ZIG)
        message(FATAL_ERROR "Ghostty ${ghostty_version} builds with Zig ${ghostty_zig}: \
install it, or name it with ZIG")
    endif()
    find_program(TIC NAMES tic)
    if(NOT TIC)
        message(FATAL_ERROR "Ghostty's build compiles its terminfo with tic: install ncurses")
    endif()
    pkg_check_modules(ghostty_egl QUIET IMPORTED_TARGET egl)
    if(NOT ghostty_egl_FOUND)
        message(FATAL_ERROR "Ghostty's library links EGL: install its development files, \
pkg-config's egl, such as libglvnd's")
    endif()
    file(GLOB ghostty_patch_files CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/native/patches/ghostty/*.patch")
    # The patch set by name, rewritten only when it changes: a patch removed
    # leaves every remaining dependency older than the stamp, but not this.
    list(JOIN ghostty_patch_files "\n" ghostty_patch_names)
    file(CONFIGURE OUTPUT "${CMAKE_BINARY_DIR}/ghostty-linux.patches"
        CONTENT "${ghostty_patch_names}\n" @ONLY)
    set(ghostty_prefix "${CMAKE_BINARY_DIR}/ghostty-linux")
    set(ghostty_stamp "${CMAKE_BINARY_DIR}/ghostty-linux.stamp")
    # build.sh configures on every build: an output deleted since makes the
    # next one build the library again.
    foreach(output lib/libghostty.so include/ghostty.h share/ghostty/shell-integration share/terminfo)
        if(NOT EXISTS "${ghostty_prefix}/${output}")
            file(REMOVE "${ghostty_stamp}")
        endif()
    endforeach()
    add_custom_command(
        OUTPUT "${ghostty_stamp}"
        COMMAND "${CMAKE_COMMAND}" -E env "ZIG=${ZIG}"
            sh "${CMAKE_SOURCE_DIR}/tools/build-ghostty-linux.sh"
            --pin "${ghostty_pin}" --patches "${CMAKE_SOURCE_DIR}/native/patches/ghostty"
            --source "${CMAKE_BINARY_DIR}/ghostty" --prefix "${ghostty_prefix}"
        COMMAND "${CMAKE_COMMAND}" -E touch "${ghostty_stamp}"
        BYPRODUCTS "${ghostty_prefix}/lib/libghostty.so" "${ghostty_prefix}/include/ghostty.h"
        DEPENDS "${ghostty_pin}" ${ghostty_patch_files}
            "${CMAKE_BINARY_DIR}/ghostty-linux.patches"
            "${CMAKE_SOURCE_DIR}/tools/build-ghostty-linux.sh"
        USES_TERMINAL
        COMMENT "Building Ghostty ${ghostty_version}'s library with Zig: minutes the first time"
        VERBATIM)
    add_custom_target(ghostty-linux DEPENDS "${ghostty_stamp}")
    add_library(ghostty SHARED IMPORTED)
    set_target_properties(ghostty PROPERTIES
        IMPORTED_LOCATION "${ghostty_prefix}/lib/libghostty.so"
        IMPORTED_SONAME libghostty.so)

    # The Wayland protocols the backend speaks beyond the core's: the one
    # that sizes a view's surface, and the one that shows a terminal's
    # frames as the GPU drew them.  Their C comes from wayland-protocols' XML.
    pkg_get_variable(wayland_protocols wayland-protocols pkgdatadir)
    pkg_get_variable(wayland_scanner wayland-scanner wayland_scanner)
    if(NOT wayland_protocols OR NOT wayland_scanner)
        message(FATAL_ERROR "Portal needs wayland-protocols and wayland-scanner, as pkg-config finds them")
    endif()
    set(protocols "${CMAKE_BINARY_DIR}/linux/protocols")
    file(MAKE_DIRECTORY "${protocols}")
    set(protocol_sources)
    foreach(protocol viewporter linux-dmabuf)
        if(protocol STREQUAL "viewporter")
            set(protocol_xml "${wayland_protocols}/stable/viewporter/viewporter.xml")
        else()
            set(protocol_xml "${wayland_protocols}/stable/linux-dmabuf/linux-dmabuf-v1.xml")
            set(protocol linux-dmabuf-v1)
        endif()
        add_custom_command(
            OUTPUT "${protocols}/${protocol}-client-protocol.h" "${protocols}/${protocol}-protocol.c"
            COMMAND "${wayland_scanner}" client-header "${protocol_xml}"
                "${protocols}/${protocol}-client-protocol.h"
            COMMAND "${wayland_scanner}" private-code "${protocol_xml}"
                "${protocols}/${protocol}-protocol.c"
            DEPENDS "${protocol_xml}"
            COMMENT "Generating the ${protocol} protocol"
            VERBATIM)
        list(APPEND protocol_sources
            "${protocols}/${protocol}-protocol.c" "${protocols}/${protocol}-client-protocol.h")
    endforeach()
    add_library(portal-module MODULE native/Core/emacs.c ${PORTAL_CORE_SOURCES}
        native/Linux/backend.c native/Linux/views.c native/Linux/input.c
        native/Linux/terminal.c native/Linux/presenter.c native/Linux/pattern.c
        native/Shared/message-socket.c native/Shared/fed-terminal.c
        ${protocol_sources})
    target_include_directories(portal-module PRIVATE
        native/Core/include native/Core native/Shared "${EMACS_INCLUDE}"
        "${ghostty_prefix}/include" "${protocols}")
    # EGL: a terminal's renderer draws with a display on Emacs's own
    # Wayland connection, the compositor's GPU.
    target_link_libraries(portal-module PRIVATE PkgConfig::portal_platform Threads::Threads
        PkgConfig::ghostty_egl ghostty ${CMAKE_DL_LIBS})
    add_dependencies(portal-module ghostty-linux)
    # The bindings offer portal--terminal-engine, which only this backend has.
    target_compile_definitions(portal-module PRIVATE PORTAL_TERMINAL_ENGINE)
    target_compile_options(portal-module PRIVATE -Wall -Wextra -Werror)
    # A primitive of portal.h that the backend lacks fails the link here, not a
    # call in Emacs later; and only Emacs's entry points leave the module.
    set(module_exports "${CMAKE_SOURCE_DIR}/native/Linux/portal.map")
    target_link_options(portal-module PRIVATE
        -Wl,--no-undefined "-Wl,--version-script=${module_exports}")
    # The library is found from the module's own place, build/portal.so or
    # wherever an installed Portal keeps it, never from where it was built.
    set_target_properties(portal-module PROPERTIES
        C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF
        PREFIX "" OUTPUT_NAME portal LINK_DEPENDS "${module_exports}"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/linux"
        BUILD_WITH_INSTALL_RPATH ON INSTALL_RPATH "$ORIGIN/ghostty-linux/lib")
    # Publish atomically: never overwrite a library already mapped by Emacs.
    add_custom_command(
        OUTPUT "${CMAKE_BINARY_DIR}/portal.so"
        COMMAND "${CMAKE_COMMAND}" -E copy
            "$<TARGET_FILE:portal-module>" "${CMAKE_BINARY_DIR}/.portal.so"
        COMMAND "${CMAKE_COMMAND}" -E rename
            "${CMAKE_BINARY_DIR}/.portal.so" "${CMAKE_BINARY_DIR}/portal.so"
        DEPENDS portal-module
        COMMENT "Publishing the Portal native module"
        VERBATIM)
    add_custom_target(portal ALL DEPENDS "${CMAKE_BINARY_DIR}/portal.so")
    if(BUILD_TESTING)
        # The graphical checks' pointer, which moves and clicks through the
        # compositor's virtual pointer (test/linux-gui.sh).
        set(pointer_xml "${CMAKE_SOURCE_DIR}/test/fixtures/wlr-virtual-pointer-unstable-v1.xml")
        set(pointer_header "${protocols}/wlr-virtual-pointer-unstable-v1-client-protocol.h")
        set(pointer_code "${protocols}/wlr-virtual-pointer-unstable-v1-protocol.c")
        add_custom_command(
            OUTPUT "${pointer_header}" "${pointer_code}"
            COMMAND "${wayland_scanner}" client-header "${pointer_xml}" "${pointer_header}"
            COMMAND "${wayland_scanner}" private-code "${pointer_xml}" "${pointer_code}"
            DEPENDS "${pointer_xml}"
            COMMENT "Generating the virtual pointer protocol"
            VERBATIM)
        add_executable(portal-test-pointer test/linux-pointer.c "${pointer_code}" "${pointer_header}")
        target_include_directories(portal-test-pointer PRIVATE "${protocols}")
        target_link_libraries(portal-test-pointer PRIVATE PkgConfig::portal_platform)
        target_compile_options(portal-test-pointer PRIVATE -Wall -Wextra -Werror)
        set_target_properties(portal-test-pointer PROPERTIES
            C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF
            RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/linux")
        # A fed terminal's rules, native/Shared, with a backend and a core
        # the test plays: the order of output and grids, the pane's geometry
        # and the backlog. No backend calls them yet, and the macOS module
        # still has them in Swift, native/Terminal.swift.
        add_executable(portal-fed-terminal-tests test/portal-fed-terminal-tests.c
            native/Shared/fed-terminal.c)
        target_include_directories(portal-fed-terminal-tests PRIVATE
            native/Core/include native/Shared)
        target_compile_options(portal-fed-terminal-tests PRIVATE -Wall -Wextra -Werror)
        set_target_properties(portal-fed-terminal-tests PROPERTIES
            C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF
            RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/linux")
        add_test(NAME fed-terminal COMMAND portal-fed-terminal-tests)
        set_tests_properties(fed-terminal PROPERTIES TIMEOUT 30)
        # What native/Shared holds is written for macOS too, which nothing
        # here runs: each file compiles for it, with Zig's cross-compile.
        add_test(NAME shared-macos
            COMMAND sh "${CMAKE_SOURCE_DIR}/test/shared-macos.sh" "${ZIG}" "${CMAKE_SOURCE_DIR}")
        set_tests_properties(shared-macos PROPERTIES TIMEOUT 60)
        # A fed terminal's surface, with the host-managed backend of Ghostty's
        # patched library, made, fed and read back with no window, drawn on
        # Mesa's surfaceless display. The link fails when the library lacks a
        # call; the test exits 77, skipped, where EGL itself says it cannot
        # render headless, and fails if the surface still cannot be made.
        add_executable(portal-ghostty-fed-tests test/portal-ghostty-fed-tests.c)
        target_include_directories(portal-ghostty-fed-tests PRIVATE "${ghostty_prefix}/include")
        target_link_libraries(portal-ghostty-fed-tests PRIVATE ghostty PkgConfig::ghostty_egl
            Threads::Threads)
        add_dependencies(portal-ghostty-fed-tests ghostty-linux)
        target_compile_options(portal-ghostty-fed-tests PRIVATE -Wall -Wextra -Werror)
        set_target_properties(portal-ghostty-fed-tests PROPERTIES
            C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF
            RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/linux"
            BUILD_WITH_INSTALL_RPATH ON INSTALL_RPATH "${ghostty_prefix}/lib")
        add_test(NAME ghostty-fed
            COMMAND portal-ghostty-fed-tests "${ghostty_prefix}/share/ghostty")
        set_tests_properties(ghostty-fed PROPERTIES TIMEOUT 60 SKIP_RETURN_CODE 77)
        # The built module in batch Emacs: what it answers with no view, and
        # what it says of each part the backend lacks.
        add_test(NAME linux-module
            COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_TEST_BUILD=${CMAKE_BINARY_DIR}"
                ${test_emacs} --module-assertions
                -l "${CMAKE_SOURCE_DIR}/test/portal-linux-module-tests.el"
                ${ert_batch})
        set_tests_properties(linux-module PROPERTIES TIMEOUT 30)
    endif()
endif()

# Portal's license and the notices for what both outputs contain, derived from
# the Swift pins, the host's Bun and the bundler records. See docs/licenses.md.
add_custom_target(portal-licenses ALL
    COMMAND "${BUN}" "${CMAKE_SOURCE_DIR}/licenses/notices.ts" stage "${CMAKE_BINARY_DIR}"
    COMMENT "Staging license notices"
    VERBATIM)
add_dependencies(portal-licenses portal portal-ui-host)
if(BUILD_TESTING)
    # The message socket, native/Shared, which both modules build, against a
    # server the test plays on real Unix sockets, with no Emacs and no
    # backend. The test compiles the file by including it.
    find_package(Threads REQUIRED)
    add_executable(portal-message-socket-tests test/portal-message-socket-tests.c)
    target_include_directories(portal-message-socket-tests PRIVATE
        native/Core/include native/Shared)
    target_link_libraries(portal-message-socket-tests PRIVATE Threads::Threads)
    target_compile_options(portal-message-socket-tests PRIVATE -Wall -Wextra -Werror)
    set_target_properties(portal-message-socket-tests PROPERTIES
        C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/tests")
    add_test(NAME message-socket COMMAND portal-message-socket-tests)
    set_tests_properties(message-socket PROPERTIES TIMEOUT 60)
    if(APPLE)
        # Portal's patches to libghostty-spm, tested by the package's own tests on
        # real Ghostty surfaces: those the patches add and the in-memory session's.
        add_test(NAME libghostty-spm
            COMMAND xcrun swift test --package-path "${ghostty_source}"
                --scratch-path "${CMAKE_BINARY_DIR}/libghostty-spm-tests"
                --filter "InMemoryTerminalSession")
        set_tests_properties(libghostty-spm PROPERTIES TIMEOUT 600 COST 100)
    endif()
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
if(TARGET portal-module)
    add_dependencies(portal-module portal-build-start)
endif()
# Check the module and host together, then record the build unless its sources
# changed meanwhile. The new module loads only in this disposable batch Emacs,
# never in one that uses Portal.
add_custom_target(portal-build-record ALL
    COMMAND "${EMACS}" --batch -Q -l "${CMAKE_SOURCE_DIR}/portal-build.el"
        -f portal-build--finish-batch "${CMAKE_BINARY_DIR}"
    COMMENT "Checking the Portal build"
    VERBATIM)
add_dependencies(portal-build-record portal portal-ui-host portal-licenses)
