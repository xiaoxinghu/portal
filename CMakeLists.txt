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
    COMMAND "${BUN}" build "${CMAKE_SOURCE_DIR}/host/server.ts"
        --compile --minify --sourcemap
        --no-compile-autoload-dotenv --no-compile-autoload-bunfig
        --outfile "${CMAKE_BINARY_DIR}/.portal-host"
    COMMAND "${CMAKE_COMMAND}" -E rename
        "${CMAKE_BINARY_DIR}/.portal-host" "${CMAKE_BINARY_DIR}/portal-host"
    DEPENDS host/actions.ts host/server.ts host/hello.html host/markdown.ts host/markdown.css
        host/tasks.ts host/tasks-client.ts host/tasks.css
        host/package.json host/bun.lock host/tsconfig.json host/build-editor.ts
        host/editor-bootstrap.ts host/excalidraw.tsx host/excalidraw.html host/excalidraw.css "${BUN}"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    COMMENT "Compiling the standalone Bun UI host"
    VERBATIM)
add_custom_target(portal-ui-host ALL DEPENDS "${CMAKE_BINARY_DIR}/portal-host")

if(BUILD_TESTING)
    # The optional Consult and Embark adapters, the task view, agent dashboard
    # and input under Evil and the launcher's graphical completion fixtures use
    # the GNU and NonGNU ELPA releases the user guides name, downloaded once
    # and checked by hash.
    set(elpa_packages
        "elpa.gnu.org/packages/consult-3.10=68aa5daeb701958482dccab3b23a454ff9a9be6b2f4c41fbcc7a353ecfeab096"
        "elpa.gnu.org/packages/embark-1.2=65e4553e709a9619016a635c435f648add310c75601b3b0818ca71c5b46678ea"
        "elpa.gnu.org/packages/vertico-2.15=5c3492edb1e0020da711d9a4213a3878e90e7af8e2e6375757901f4b399872ff"
        "elpa.gnu.org/packages/orderless-1.8=9b4b1253bab2e1d984ad0a31028716d0eff2cd358144bb9caced3b15088e69aa"
        "elpa.gnu.org/packages/marginalia-2.13=e1b228d1d4aa4648982aa79ebb9a2e1d2824b7cd40e01d39ed541f1b7663edba"
        "elpa.gnu.org/packages/dash-2.20.0=28f84b0905f84520163f5dd2087e47cac042bd27b7ec34eeb293f1ada7d36cb2"
        "elpa.nongnu.org/nongnu/evil-1.15.0=1840cc67172a0d7cfbc58dc25eca95dff1375e6a06ddf7bc0ce9034c5ba32f32"
        "elpa.nongnu.org/nongnu/goto-chg-1.7.5=5e6dbb79355e0db5e3b5e5b8643da0738a7b69b9c0b787982b06edc0369abbc8")
    set(elpa_load_path "")
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
    endforeach()
    # The task view is tested with org-ql 0.8.10 and the other libraries it
    # loads that Emacs lacks, and with evil-collection, from their release
    # tags: MELPA Stable keeps only each package's latest release.  Dash and
    # Evil come from GNU and NonGNU ELPA above.
    set(github_packages
        "alphapapa/org-ql=v0.8.10=1a0b416f47bcfb1f45345f62ad5fa89f15c7758941adeb0076db76217078607d"
        "alphapapa/org-super-agenda=v1.3=0ef83a5c42188d571ff977edd54415f09bc833e048b087f1781d492d05a853f7"
        "alphapapa/ts.el=0.3=c79efa802fde5c84fecca01f7b80fbb54b29b792067b5f1a1e517181f2176cc6"
        "emacsorphanage/ov=1.0.6=f2a8bb7bd5077542fa31de38323a9cc31142df0c7864a0f43196cde2722fe336"
        "magnars/s.el=1.13.1=807b9a29f26b5b3ded8e9bba979201b6714cb275286306c32fb72b8098073999"
        "Wilfred/ht.el=2.3=1a85a4659f603f7e2199f82198e7be2f78c32a195cbdd8402435c22f3b233a4b"
        "emacs-evil/evil-collection=3.0.3=d2fddb2689bded204f4ad1b24a06e3c41af12cbb59c1f8b6a2fee1d8ad68d333")
    foreach(entry IN LISTS github_packages)
        string(REPLACE "=" ";" entry "${entry}")
        list(GET entry 0 repository)
        list(GET entry 1 tag)
        list(GET entry 2 hash)
        # GitHub names the folder after the repository and the tag, without a v.
        get_filename_component(name "${repository}" NAME)
        string(REGEX REPLACE "^v" "" version "${tag}")
        set(directory "${CMAKE_BINARY_DIR}/elpa/${name}-${version}")
        if(NOT EXISTS "${directory}")
            file(DOWNLOAD "https://codeload.github.com/${repository}/tar.gz/refs/tags/${tag}"
                "${directory}.tar.gz" EXPECTED_HASH SHA256=${hash})
            file(ARCHIVE_EXTRACT INPUT "${directory}.tar.gz" DESTINATION "${CMAKE_BINARY_DIR}/elpa")
            file(REMOVE "${directory}.tar.gz")
        endif()
        list(APPEND elpa_load_path -L "${directory}")
    endforeach()

    # Suites are registered with portal_suite (test/suites.cmake); ./test.sh
    # selects them and builds what they need first (docs/testing.md). Each
    # Lisp suite is one test file run by test/portal-suite.el.
    set(source "${CMAKE_SOURCE_DIR}")
    set(lisp_suite -l "${source}/test/portal-suite.el" -f portal-suite-batch)
    set(host_env "${CMAKE_COMMAND}" -E env "PORTAL_TEST_HOST=${CMAKE_BINARY_DIR}/portal-host")
    find_package(Python3 3.9 REQUIRED COMPONENTS Interpreter)

    # Unit: pure logic, the real C core with the fake platform, and batch Lisp.
    # Runs docs/launcher.md's examples; launcher.el is not needed.
    portal_suite(launcher CATEGORY unit FEATURES launcher
        COMMAND "${EMACS}" --batch -Q -L "${source}" -L "${source}/test" ${elpa_load_path}
            ${lisp_suite} "${source}/test/portal-launcher-tests.el")
    # The Lisp module on the real C core, with the fake backend's hot keys.
    portal_suite(global-shortcut CATEGORY unit FEATURES global-shortcut
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_TEST_MODULE=$<TARGET_FILE:portal-test-module>"
            "${EMACS}" --batch -Q --module-assertions -L "${source}"
            ${lisp_suite} "${source}/test/portal-global-shortcut-tests.el")
    # Exercise the documented absolute-path entry point in a fresh Emacs.
    # Do not add the package directory with -L: Portal must load its own siblings.
    portal_suite(startup CATEGORY unit FEATURES startup
        COMMAND "${EMACS}" --batch -Q ${lisp_suite} "${source}/test/portal-startup-tests.el")
    portal_suite(pi-extension CATEGORY unit FEATURES agents
        COMMAND "${BUN}" test "${source}/test/portal-pi.test.ts")
    portal_suite(host-actions CATEGORY unit FEATURES host tasks
        COMMAND "${BUN}" test "${source}/host/actions.test.ts")
    portal_suite(host-tasks CATEGORY unit FEATURES host tasks
        COMMAND "${BUN}" test "${source}/host/tasks.test.ts")
    portal_suite(todo-tasks CATEGORY unit FEATURES tasks
        COMMAND "${BUN}" test "${source}/test/list-todo-tasks.test.ts")
    foreach(suite IN ITEMS quick-terminal=terminal-quick terminal-metadata=terminal-metadata
            terminal-choose=terminal-choose terminal-bindings=terminal-bindings)
        string(REPLACE "=" ";" suite "${suite}")
        list(GET suite 0 name)
        list(GET suite 1 file)
        portal_suite(${name} CATEGORY unit FEATURES terminal
            COMMAND "${EMACS}" --batch -Q -L "${source}" ${lisp_suite} "${source}/test/portal-${file}-tests.el")
    endforeach()
    portal_suite(agents CATEGORY unit FEATURES agents
        COMMAND "${EMACS}" --batch -Q -L "${source}" ${lisp_suite} "${source}/test/portal-agents-tests.el")
    portal_suite(agents-evil CATEGORY unit FEATURES agents
        COMMAND "${EMACS}" --batch -Q -L "${source}" ${elpa_load_path}
            ${lisp_suite} "${source}/test/portal-agents-evil-tests.el")
    portal_suite(tasks-view CATEGORY unit FEATURES org-tasks
        COMMAND "${EMACS}" --batch -Q -L "${source}" ${elpa_load_path}
            ${lisp_suite} "${source}/test/portal-tasks-view-tests.el")
    foreach(adapter consult embark)
        portal_suite(terminal-${adapter} CATEGORY unit FEATURES terminal
            COMMAND "${EMACS}" --batch -Q -L "${source}" ${elpa_load_path}
                ${lisp_suite} "${source}/test/portal-terminal-${adapter}-tests.el")
    endforeach()
    portal_suite(view CATEGORY unit FEATURES view
        COMMAND "${EMACS}" --batch -Q -L "${source}" ${lisp_suite} "${source}/test/portal-view-tests.el")
    portal_suite(toolbar CATEGORY unit FEATURES toolbar
        COMMAND "${EMACS}" --batch -Q -L "${source}" ${lisp_suite} "${source}/test/portal-toolbar-tests.el")
    # Evil comes from build/elpa, so its two cases run rather than skip.
    portal_suite(input CATEGORY unit FEATURES input
        COMMAND "${EMACS}" --batch -Q -L "${source}" ${elpa_load_path}
            ${lisp_suite} "${source}/test/portal-input-tests.el")
    portal_suite(excalidraw CATEGORY unit FEATURES excalidraw
        COMMAND "${EMACS}" --batch -Q -L "${source}" ${lisp_suite} "${source}/test/portal-excalidraw-tests.el")
    # This runner, its Lisp suite runner and the helper files' isolation.
    portal_suite(test-runner CATEGORY unit FEATURES test-tools TIMEOUT 120
        COMMAND "${CMAKE_COMMAND}" -E env "EMACS=${EMACS}" "PORTAL_TEST_ELPA=${CMAKE_BINARY_DIR}/elpa"
            "PORTAL_TEST_BUILD_DIR=${CMAKE_BINARY_DIR}"
            "${Python3_EXECUTABLE}" -B -m unittest discover -s "${source}/test" -p test_runner.py)

    # Integration: the compiled host, processes, PTYs and a headless browser.
    add_executable(portal-process-tests test/portal-process-tests.c)
    target_include_directories(portal-process-tests PRIVATE native/Core/include)
    target_compile_options(portal-process-tests PRIVATE -Wall -Wextra -Werror)
    portal_suite(processes CATEGORY integration FEATURES agents COMMAND portal-process-tests)
    portal_suite(agent-discovery CATEGORY integration FEATURES agents
        COMMAND "${CMAKE_COMMAND}" -E env
            "PORTAL_TEST_PROCESS_SNAPSHOT=$<TARGET_FILE:portal-process-tests>"
            "${EMACS}" --batch -Q -L "${source}" ${lisp_suite} "${source}/test/portal-agent-discovery-tests.el")
    portal_suite(actions CATEGORY integration FEATURES host tasks terminal
        COMMAND ${host_env} "${EMACS}" --batch -Q -L "${source}" -L "${source}/test"
            ${lisp_suite} "${source}/test/portal-actions-tests.el")
    portal_suite(ui-host CATEGORY integration FEATURES host markdown
        COMMAND ${host_env} "${EMACS}" --batch -Q -L "${source}"
            ${lisp_suite} "${source}/test/portal-server-tests.el")
    portal_suite(web CATEGORY integration FEATURES web host
        COMMAND ${host_env} "${EMACS}" --batch -Q -L "${source}" ${lisp_suite} "${source}/test/portal-web-tests.el")
    portal_suite(tasks CATEGORY integration FEATURES tasks host
        COMMAND ${host_env} "${EMACS}" --batch -Q -L "${source}" ${lisp_suite} "${source}/test/portal-tasks-tests.el")
    portal_suite(native-check-helpers CATEGORY integration FEATURES test-tools TIMEOUT 120
        COMMAND "${Python3_EXECUTABLE}" -B -m unittest discover -s "${source}/test" -p test_native_checks.py)
    portal_suite(benchmark-tool CATEGORY integration FEATURES terminal test-tools TIMEOUT 120
        COMMAND "${Python3_EXECUTABLE}" -B -m unittest discover -s "${source}/test" -p test_benchmark.py)
    # The task browser's page script in Playwright's headless WebKit, pinned
    # by host/bun.lock and installed under the build directory. The host's
    # build installs the locked packages; a second install at once would race.
    set(browsers "${CMAKE_BINARY_DIR}/playwright")
    add_custom_command(
        OUTPUT "${browsers}/installed"
        COMMAND "${CMAKE_COMMAND}" -E env "PLAYWRIGHT_BROWSERS_PATH=${browsers}"
            "${BUN}" "${source}/host/node_modules/playwright-core/cli.js" install webkit
        COMMAND "${CMAKE_COMMAND}" -E touch "${browsers}/installed"
        DEPENDS host/bun.lock "${CMAKE_BINARY_DIR}/portal-host"
        COMMENT "Installing Playwright's WebKit for headless browser tests"
        VERBATIM)
    add_custom_target(portal-test-browser DEPENDS "${browsers}/installed")
    portal_suite(tasks-page CATEGORY integration FEATURES tasks web TIMEOUT 120
        COMMAND "${CMAKE_COMMAND}" -E env "PLAYWRIGHT_BROWSERS_PATH=${browsers}"
            "${BUN}" test "${source}/host/tasks-client.test.ts")

    # Test-only native code: the event injector the graphical suites load and
    # the standalone AppKit checks, built only for runs that use them.
    set(injector "${CMAKE_BINARY_DIR}/test-terminal-input.dylib")
    add_custom_command(
        OUTPUT "${injector}"
        COMMAND xcrun clang -fobjc-arc -Wall -Wextra -Werror -bundle
            -I "${EMACS_INCLUDE}" "${source}/test/terminal-input.m"
            -framework AppKit -framework WebKit -framework Carbon -framework IOSurface
            -o "${injector}"
        DEPENDS test/terminal-input.m
        COMMENT "Building the test-only event injector"
        VERBATIM)
    add_custom_target(portal-test-injector DEPENDS "${injector}")
    add_library(portal-check-core OBJECT EXCLUDE_FROM_ALL
        native/Core/views.c native/Core/input.c native/Core/terminals.c native/Core/web.c
        native/Core/toolbar.c native/Core/channel.c native/Core/shortcuts.c)
    target_include_directories(portal-check-core PRIVATE native/Core/include)
    target_compile_options(portal-check-core PRIVATE -Wall -Wextra -Werror)
    set_target_properties(portal-check-core PROPERTIES
        C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF)
    set(check_sources
        native/Backend.swift native/CoreCalls.swift native/NativeHost.swift native/NativeInput.swift
        native/Launcher.swift native/Hotkeys.swift native/Views.swift native/Toolbar.swift
        native/WebToolbar.swift native/WebView.swift
        test/native-checks.swift test/native-terminal-stub.swift test/native-views.swift)
    foreach(check focus toolbar launcher shortcuts launcher-geometry)
        add_custom_command(
            OUTPUT "${CMAKE_BINARY_DIR}/check-${check}"
            COMMAND xcrun swiftc -swift-version 6 -warnings-as-errors
                -I native/Core/include -import-objc-header test/native-core.h
                ${check_sources} test/native-${check}.swift $<TARGET_OBJECTS:portal-check-core>
                -framework AppKit -framework WebKit -framework Carbon
                -o "${CMAKE_BINARY_DIR}/check-${check}"
            DEPENDS ${check_sources} test/native-${check}.swift test/native-core.h
                $<TARGET_OBJECTS:portal-check-core>
            WORKING_DIRECTORY "${source}"
            COMMENT "Building the standalone ${check} check"
            COMMAND_EXPAND_LISTS
            VERBATIM)
    endforeach()
    add_custom_target(portal-native-checks DEPENDS "${CMAKE_BINARY_DIR}/check-focus"
        "${CMAKE_BINARY_DIR}/check-toolbar" "${CMAKE_BINARY_DIR}/check-launcher"
        "${CMAKE_BINARY_DIR}/check-shortcuts")
    # The launcher's placement arithmetic needs no application or window.
    add_custom_target(portal-geometry-check DEPENDS "${CMAKE_BINARY_DIR}/check-launcher-geometry")
    portal_suite(launcher-geometry CATEGORY unit FEATURES launcher
        COMMAND "${CMAKE_BINARY_DIR}/check-launcher-geometry")

    # Native GUI: disposable graphical Emacs with this build's module, app
    # host and injector (PORTAL_TEST_BUILD, read by test/portal-suite.el),
    # and the standalone checks. They open windows and take focus.
    set(gui_suite "${CMAKE_COMMAND}" -E env "PORTAL_TEST_BUILD=${CMAKE_BINARY_DIR}"
        "${EMACS}" -Q --module-assertions -L "${source}" -L "${source}/test" ${elpa_load_path}
        -l "${source}/portal.el" -l "${source}/test/portal-suite.el" -f portal-suite-graphical)
    portal_suite(web-gui CATEGORY gui FEATURES web EFFECTS desktop TIMEOUT 120
        COMMAND ${gui_suite} "${source}/test/portal-tests.el")
    portal_suite(terminal-gui CATEGORY gui FEATURES terminal input EFFECTS desktop TIMEOUT 300
        COMMAND ${gui_suite} "${source}/test/portal-terminal-tests.el")
    # A minimal environment and fixture dotfiles: the shell supplies PATH.
    portal_suite(terminal-startup-gui CATEGORY gui FEATURES terminal EFFECTS desktop TIMEOUT 120
        COMMAND "${CMAKE_COMMAND}" -E env "EMACS=${EMACS}" "PORTAL_TEST_BUILD=${CMAKE_BINARY_DIR}"
            sh "${source}/test/terminal-shell-startup.sh")
    portal_suite(coexistence-gui CATEGORY gui FEATURES coexistence web terminal input EFFECTS desktop TIMEOUT 120
        COMMAND ${gui_suite} "${source}/test/portal-integration-tests.el")
    portal_suite(excalidraw-gui CATEGORY gui FEATURES excalidraw web input EFFECTS desktop TIMEOUT 300
        COMMAND ${gui_suite} "${source}/test/portal-excalidraw-gui-tests.el")
    portal_suite(input-gui CATEGORY gui FEATURES input web EFFECTS desktop TIMEOUT 120
        COMMAND ${gui_suite} "${source}/test/portal-input-gui-tests.el")
    portal_suite(markdown-gui CATEGORY gui FEATURES markdown web input host EFFECTS desktop TIMEOUT 300
        COMMAND ${gui_suite} "${source}/test/portal-markdown-gui-tests.el")
    portal_suite(tasks-gui CATEGORY gui FEATURES tasks web input host terminal EFFECTS desktop TIMEOUT 300
        COMMAND ${gui_suite} "${source}/test/portal-tasks-gui-tests.el")
    portal_suite(toolbar-gui CATEGORY gui FEATURES toolbar coexistence web terminal excalidraw
        EFFECTS desktop TIMEOUT 300
        COMMAND ${gui_suite} "${source}/test/portal-toolbar-gui-tests.el")
    portal_suite(terminal-choose-gui CATEGORY gui FEATURES terminal input EFFECTS desktop TIMEOUT 120
        COMMAND ${gui_suite} "${source}/test/portal-terminal-choose-gui-tests.el")
    # Without tmux, the case whose nested PTY needs it is a declared skip.
    portal_suite(agents-gui CATEGORY gui FEATURES agents terminal EFFECTS desktop TIMEOUT 180
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_TEST_PROCESS_SNAPSHOT=$<TARGET_FILE:portal-process-tests>"
            ${gui_suite} "${source}/test/portal-agents-gui-tests.el"
            --allow-skip portal-discovery-gui-inherited-tmux-marker)
    portal_suite(global-shortcut-gui CATEGORY gui FEATURES global-shortcut EFFECTS desktop TIMEOUT 120
        COMMAND ${gui_suite} "${source}/test/portal-global-shortcut-gui-tests.el")
    portal_suite(tasks-view-gui CATEGORY gui FEATURES org-tasks EFFECTS desktop TIMEOUT 120
        COMMAND ${gui_suite} "${source}/test/portal-tasks-view-gui-tests.el")
    # With one display, the case that moves the pointer between displays is a
    # declared skip.
    portal_suite(launcher-gui CATEGORY gui FEATURES launcher input EFFECTS desktop TIMEOUT 600
        COMMAND ${gui_suite} "${source}/test/portal-launcher-gui-tests.el"
            --allow-skip portal-launcher-gui-minibuffer-panel-stays-on-its-display)
    portal_suite(launcher-daily-use-gui CATEGORY gui FEATURES launcher coexistence terminal web
        EFFECTS desktop TIMEOUT 300
        COMMAND ${gui_suite} "${source}/test/portal-launcher-daily-use-tests.el")
    foreach(check focus toolbar launcher shortcuts)
        set(features "${check}")
        if(check STREQUAL "focus")
            set(features input web)
        elseif(check STREQUAL "shortcuts")
            set(features global-shortcut)
        endif()
        portal_suite(native-${check} CATEGORY gui FEATURES ${features} EFFECTS desktop TIMEOUT 120
            COMMAND "${CMAKE_BINARY_DIR}/check-${check}")
    endforeach()

    # Stress: bounded lifecycle churn, outside routine runs.
    portal_suite(launcher-stress-gui CATEGORY stress FEATURES launcher EFFECTS desktop TIMEOUT 600
        COMMAND ${gui_suite} "${source}/test/portal-launcher-stress-tests.el")
    portal_suite(native-launcher-stress CATEGORY stress FEATURES launcher EFFECTS desktop TIMEOUT 120
        COMMAND "${CMAKE_BINARY_DIR}/check-launcher" 20)

    # External: real agents with credentials, and the third-party launcher.el
    # recipe, each with its configured prerequisites.
    portal_suite(agent-discovery-live CATEGORY external FEATURES agents terminal
        EFFECTS desktop external TIMEOUT 900
        NEEDS env:PORTAL_TEST_CLAUDE_DIRECTORY env:PORTAL_TEST_CODEX_DIRECTORY
            env:PORTAL_TEST_PI_AGENT_DIR program:claude program:codex program:pi
        COMMAND ${gui_suite} "${source}/test/portal-agent-discovery-gui-tests.el")
    portal_suite(launcher-recipe CATEGORY external FEATURES launcher EFFECTS desktop external TIMEOUT 300
        NEEDS env:PORTAL_LAUNCHER_EL
        COMMAND ${gui_suite} "${source}/test/portal-launcher-recipe-tests.el")

    # What each category's suites need built; ./test.sh builds these alone,
    # never the native module for headless runs.
    add_custom_target(portal-test-unit)
    add_dependencies(portal-test-unit portal-test-module portal-channel-tests portal-views-tests
        portal-input-tests portal-terminals-tests portal-web-tests portal-toolbar-tests
        portal-shortcuts-tests portal-geometry-check)
    add_custom_target(portal-test-integration)
    add_dependencies(portal-test-integration portal-ui-host portal-process-tests portal-test-browser)
    add_custom_target(portal-test-desktop)
    add_dependencies(portal-test-desktop portal portal-ui-host portal-process-tests
        portal-test-injector portal-native-checks)
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
