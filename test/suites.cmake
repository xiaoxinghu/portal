# SPDX-License-Identifier: GPL-3.0-or-later
# The registry of automated test suites: each is a CTest test whose labels
# ./test.sh reads to plan, gate and report a run (docs/testing.md).
#
#   portal_suite(NAME CATEGORY category [FEATURES name...] [EFFECTS effect...]
#                [NEEDS need...] [TIMEOUT seconds] COMMAND command...)
#
# CATEGORY is unit, integration, gui, stress or external. FEATURES are what a
# change can affect, for `./test.sh --suite FEATURE'. EFFECTS are what a run
# needs permission for: desktop (windows, focus or system hot keys) or
# external (credentials, real requests or third-party code). NEEDS is setup
# that ./test.sh checks before running: env:NAME, a variable naming an
# existing path, or program:NAME on PATH. Unit and integration suites have no
# effects. Other suites run only in the opt-in configuration
# (ctest -C opt-in), so plain ctest stays headless; desktop suites run alone.
function(portal_suite name)
    cmake_parse_arguments(PARSE_ARGV 1 suite "" "CATEGORY;TIMEOUT"
        "FEATURES;EFFECTS;NEEDS;COMMAND")
    if(NOT suite_CATEGORY MATCHES "^(unit|integration|gui|stress|external)$")
        message(FATAL_ERROR "Test suite ${name} needs CATEGORY unit, integration, gui, stress or external")
    endif()
    if(NOT suite_FEATURES OR NOT suite_COMMAND)
        message(FATAL_ERROR "Test suite ${name} needs FEATURES and a COMMAND")
    endif()
    foreach(effect IN LISTS suite_EFFECTS)
        if(NOT effect MATCHES "^(desktop|external)$")
            message(FATAL_ERROR "Test suite ${name} has unknown effect ${effect}")
        endif()
    endforeach()
    if(suite_CATEGORY MATCHES "^(unit|integration)$" AND suite_EFFECTS)
        message(FATAL_ERROR "Headless test suite ${name} cannot have effects")
    endif()
    if(suite_CATEGORY MATCHES "^(gui|external)$" AND NOT suite_EFFECTS)
        message(FATAL_ERROR "Test suite ${name} needs its EFFECTS")
    endif()
    set(labels "${suite_CATEGORY}")
    foreach(feature IN LISTS suite_FEATURES)
        list(APPEND labels "feature=${feature}")
    endforeach()
    foreach(effect IN LISTS suite_EFFECTS)
        list(APPEND labels "effect=${effect}")
    endforeach()
    foreach(need IN LISTS suite_NEEDS)
        if(NOT need MATCHES "^(env|program):[A-Za-z0-9_.+-]+$")
            message(FATAL_ERROR "Test suite ${name} has malformed need ${need}")
        endif()
        list(APPEND labels "needs=${need}")
    endforeach()
    if(suite_CATEGORY MATCHES "^(unit|integration)$")
        add_test(NAME ${name} COMMAND ${suite_COMMAND})
    else()
        add_test(NAME ${name} CONFIGURATIONS opt-in COMMAND ${suite_COMMAND})
    endif()
    if(NOT suite_TIMEOUT)
        set(suite_TIMEOUT 30)
    endif()
    set_tests_properties(${name} PROPERTIES LABELS "${labels}" TIMEOUT ${suite_TIMEOUT}
        ENVIRONMENT "PORTAL_TEST_SUITE=${name}")
    if("desktop" IN_LIST suite_EFFECTS)
        set_tests_properties(${name} PROPERTIES RUN_SERIAL TRUE)
    endif()
endfunction()
