/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The core's terminal rules, native/Core/terminals.c, with the fake
   platform: option checks before creation, the theme catalog and applying a
   theme to every terminal, paste and Enter, reading text, what a terminal
   describes, and the records that announce its changes.  The fake counts the
   primitives the core calls, and any call naming a destroyed view or a view
   of the wrong kind.  Records go to a real pipe, which the tests read as
   Emacs would. */
#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <unistd.h>

#include "channel.h"
#include "portal-core-tests.h"
#include "terminals.h"

static int records = -1; /* The pipe's read end. */

/* Whether the pipe holds exactly EXPECTED now; read it all. */
static bool sent(const char *expected)
{
    static char buffer[1024];
    ssize_t count = read(records, buffer, sizeof buffer - 1);
    buffer[count > 0 ? count : 0] = '\0';
    if (strcmp(buffer, expected))
        fprintf(stderr, "Expected records \"%s\", got \"%s\"\n", expected, buffer);
    return !strcmp(buffer, expected);
}

static portal_option string_option(const char *name, const char *value)
{
    return (portal_option) {.name = text(name), .is_string = true, .string = text(value)};
}

static portal_option flag_option(const char *name, bool flag)
{
    return (portal_option) {.name = text(name), .flag = flag};
}

/* Open a terminal with COUNT OPTIONS; return its target to free, or NULL
   with *ERROR set. */
static char *open_terminal(const portal_option *options, size_t count, portal_text *error)
{
    portal_text target = {0};
    if (!portal_views_open(text("terminal"), options, count, &target, error))
        return NULL;
    return target.data;
}

static char *open_in(const char *directory)
{
    portal_text error = {0};
    portal_option directory_option = string_option("directory", directory);
    char *target = open_terminal(&directory_option, 1, &error);
    CHECK(target != NULL);
    free(error.data);
    return target;
}

static portal_view *handle(const char *target)
{
    return portal_views_find(text(target), PORTAL_TERMINAL, NULL);
}

static void test_options_are_checked_before_creation(void)
{
    const portal_option directory = string_option("directory", "/tmp");
    const struct {
        portal_option options[3];
        size_t count;
        const char *message;
    } cases[] = {
        {{{0}}, 0, "A terminal view needs a :directory"},
        {{flag_option("directory", false)}, 1, "A terminal view needs a :directory"},
        {{string_option("command", "ls")}, 1, "A terminal view needs a :directory"},
        {{flag_option("directory", true)}, 1, "Option :directory must be a string"},
        {{directory, flag_option("command", true)}, 2, "Option :command must be a string"},
        {{directory, flag_option("argv", true)}, 2, "Option :argv must be a string"},
        {{directory, string_option("command", "ls"), string_option("argv", "[]")},
         3, "A terminal view accepts either :command or :argv"},
        {{directory, flag_option("theme", true)}, 2, "Option :theme must be a string"},
        {{directory, string_option("theme", "Gamma")}, 2, "Unknown terminal theme: Gamma"},
        /* Names are exact. */
        {{directory, string_option("theme", "alpha")}, 2, "Unknown terminal theme: alpha"},
        {{directory, string_option("theme", "")}, 2, "Unknown terminal theme: "},
        /* A later duplicate wins. */
        {{directory, string_option("theme", "Alpha"), string_option("theme", "Gamma")},
         3,
         "Unknown terminal theme: Gamma"},
        {{directory, flag_option("directory", false)}, 2, "A terminal view needs a :directory"},
    };
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        portal_text error = {0};
        size_t created = portal_fake_calls().created;
        CHECK(!open_terminal(cases[i].options, cases[i].count, &error));
        if (!says(&error, cases[i].message))
            fprintf(stderr, "In case %zu\n", i);
        CHECK(portal_fake_calls().created == created);
    }

    /* What the core cannot check, the platform receives as given. */
    portal_text error = {0};
    const portal_option valid[] = {
        flag_option("directory", true), directory, string_option("command", "ls -l"),
        flag_option("theme", false), flag_option("quick", true), string_option("name", "x"),
    };
    struct portal_fake_calls before = portal_fake_calls();
    char *target = open_terminal(valid, sizeof valid / sizeof *valid, &error);
    CHECK(target != NULL);
    CHECK(shows(target, "\"directory\":\"/tmp\"", "\"command\":\"ls -l\"", "\"theme\":false",
                "\"quick\":true", "\"name\":\"x\"", NULL));
    /* Without a theme there is nothing to look up. */
    CHECK(portal_fake_calls().listed == before.listed);
    close_view(target);

    const portal_option argv[] = {directory, string_option("argv", "[\"/bin/ls\",\"-l\"]")};
    target = open_terminal(argv, 2, &error);
    CHECK(target && shows(target, "\"argv\":\"[\\\"/bin/ls\\\",\\\"-l\\\"]\"", NULL));
    close_view(target);

    const portal_option themed[] = {directory, string_option("theme", "Ωmega")};
    before = portal_fake_calls();
    target = open_terminal(themed, 2, &error);
    CHECK(target && shows(target, "\"theme\":\"Ωmega\"", NULL));
    CHECK(portal_fake_calls().listed == before.listed + 1);
    close_view(target);

    /* A platform that cannot list its themes creates nothing. */
    portal_fake_refuse(true);
    before = portal_fake_calls();
    CHECK(!open_terminal(themed, 2, &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    CHECK(same_calls(portal_fake_calls(), before));

    /* Web views have no such rules. */
    char *web = open_view("web", &error, NULL);
    CHECK(web != NULL);
    close_view(web);
}

static void test_the_theme_catalog_is_sorted(void)
{
    portal_text json = {0}, error = {0};
    CHECK(portal_terminals_themes(&json, &error));
    const char *expected = "[\"Alpha\",\"Back\\\\slash \\\"quoted\\\"\",\"Beta\",\"Ωmega\"]";
    CHECK(json.data && json.length == strlen(expected) && !strcmp(json.data, expected));
    if (json.data && strcmp(json.data, expected))
        fprintf(stderr, "Got %s\n", json.data);
    free(json.data);
    portal_fake_refuse(true);
    CHECK(!portal_terminals_themes(&json, &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
}

static void test_a_theme_reaches_every_terminal(void)
{
    portal_text error = {0};
    portal_string beta = text("Beta"), gamma = text("Gamma"),
                  quoted = text("Back\\slash \"quoted\"");
    /* A name is checked even with no terminal open. */
    CHECK(!portal_terminals_theme(&gamma, &error));
    CHECK(says(&error, "Unknown terminal theme: Gamma"));
    CHECK(portal_terminals_theme(&beta, &error));

    char *web = open_view("web", &error, NULL);
    char *first = open_in("/"), *second = open_in("/"), *third = open_in("/");
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(portal_terminals_theme(&beta, &error));
    CHECK(portal_fake_calls().listed == before.listed + 1);
    CHECK(portal_fake_calls().themed == before.themed + 3);
    CHECK(shows(first, "\"theme\":\"Beta\"", NULL));
    CHECK(shows(second, "\"theme\":\"Beta\"", NULL));
    CHECK(shows(third, "\"theme\":\"Beta\"", NULL));
    char *state = inspect(web);
    CHECK(state && !strstr(state, "\"theme\""));
    free(state);

    /* An unknown name touches no terminal. */
    before = portal_fake_calls();
    CHECK(!portal_terminals_theme(&gamma, &error));
    CHECK(says(&error, "Unknown terminal theme: Gamma"));
    CHECK(portal_fake_calls().themed == before.themed);
    CHECK(shows(second, "\"theme\":\"Beta\"", NULL));

    /* The default needs no lookup. */
    before = portal_fake_calls();
    CHECK(portal_terminals_theme(NULL, &error));
    CHECK(portal_fake_calls().listed == before.listed);
    CHECK(shows(first, "\"theme\":false", NULL));
    CHECK(shows(third, "\"theme\":false", NULL));
    CHECK(portal_terminals_theme(&quoted, &error));
    CHECK(shows(third, "\"theme\":\"Back\\\\slash \\\"quoted\\\"\"", NULL));

    /* A closed terminal is not themed. */
    close_view(second);
    before = portal_fake_calls();
    CHECK(portal_terminals_theme(&beta, &error));
    CHECK(portal_fake_calls().themed == before.themed + 2);

    /* A refusing platform changes nothing. */
    portal_fake_refuse(true);
    before = portal_fake_calls();
    CHECK(!portal_terminals_theme(NULL, &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    CHECK(!portal_terminals_theme(&beta, &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    CHECK(same_calls(portal_fake_calls(), before));
    CHECK(shows(first, "\"theme\":\"Beta\"", NULL));
    close_view(first);
    close_view(third);
    close_view(web);
    CHECK(!portal_fake_calls().misused);
}

static void test_a_rejected_theme_stops_at_that_terminal(void)
{
    portal_text error = {0};
    portal_string beta = text("Beta");
    const portal_option alpha[] = {string_option("directory", "/"),
                                   string_option("theme", "Alpha")};
    const portal_option broken[] = {alpha[0], alpha[1], string_option("broken", "Metal is gone")};
    char *first = open_terminal(alpha, 2, &error);
    char *second = open_terminal(broken, 3, &error);
    char *third = open_terminal(alpha, 2, &error);
    /* Terminals before it are themed, and it and those after are not. */
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(!portal_terminals_theme(&beta, &error));
    CHECK(says(&error, "Metal is gone"));
    CHECK(portal_fake_calls().themed == before.themed + 1);
    CHECK(shows(first, "\"theme\":\"Beta\"", NULL));
    CHECK(shows(third, "\"theme\":\"Alpha\"", NULL));
    close_view(second);
    CHECK(portal_terminals_theme(&beta, &error));
    CHECK(shows(third, "\"theme\":\"Beta\"", NULL));
    close_view(first);
    close_view(third);
    CHECK(!portal_fake_calls().misused);
}

static void test_paste_then_enter(void)
{
    portal_text error = {0}, scrollback = {0};
    char *terminal = open_in("/");
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(portal_terminals_paste(text(terminal), text("echo "), false, &error));
    CHECK(portal_fake_calls().entered == before.entered);
    CHECK(portal_terminals_paste(text(terminal), text("hi"), true, &error));
    CHECK(portal_fake_calls().entered == before.entered + 1);
    CHECK(portal_terminals_paste(text(terminal), (portal_string) {"", 0}, true, &error));
    CHECK(portal_terminals_text(text(terminal), &scrollback, &error));
    CHECK(scrollback.data && !strcmp(scrollback.data, "echo hi\n\n"));
    free(scrollback.data);
    /* Reading is repeatable. */
    CHECK(portal_terminals_text(text(terminal), &scrollback, &error));
    CHECK(scrollback.data && !strcmp(scrollback.data, "echo hi\n\n"));
    free(scrollback.data);

    /* A failed paste presses no Enter. */
    const portal_option broken[] = {string_option("directory", "/"),
                                    string_option("broken", "No surface")};
    char *failing = open_terminal(broken, 2, &error);
    before = portal_fake_calls();
    CHECK(!portal_terminals_paste(text(failing), text("rm -rf ~"), true, &error));
    CHECK(says(&error, "No surface"));
    CHECK(!portal_terminals_text(text(failing), &scrollback, &error));
    CHECK(says(&error, "No surface"));
    portal_fake_refuse(true);
    CHECK(!portal_terminals_paste(text(terminal), text("x"), true, &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    CHECK(!portal_terminals_text(text(terminal), &scrollback, &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    CHECK(portal_fake_calls().entered == before.entered);
    close_view(failing);
    close_view(terminal);
}

static void test_targets_must_name_open_terminals(void)
{
    portal_text error = {0}, scrollback = {0};
    char *web = open_view("web", &error, NULL);
    char *terminal = open_in("/");
    char *closed = open_in("/");
    char *stale = strdup(closed);
    close_view(closed);
    const char *targets[] = {web, stale, "terminal:0", "", "terminal"};
    struct portal_fake_calls before = portal_fake_calls();
    for (size_t i = 0; i < sizeof targets / sizeof *targets; i++) {
        char message[64];
        snprintf(message, sizeof message, "No Portal view %s", targets[i]);
        CHECK(!portal_terminals_paste(text(targets[i]), text("x"), true, &error));
        CHECK(says(&error, message));
        CHECK(!portal_terminals_text(text(targets[i]), &scrollback, &error));
        CHECK(says(&error, message));
    }
    CHECK(same_calls(portal_fake_calls(), before));
    free(stale);
    close_view(terminal);
    close_view(web);
    CHECK(!portal_fake_calls().misused);
}

static void test_a_terminal_describes_itself(void)
{
    portal_text error = {0};
    char *terminal = open_in("/");
    CHECK(shows(terminal, "\"kind\":\"terminal\",\"visible\":false", "\"ready\":true",
                "\"title\":\"Fake terminal\"", "\"pwd\":\"\"", "\"columns\":80",
                "\"rows\":24", "\"exited\":false", NULL));
    /* A process that exits leaves its view open until Lisp closes it. */
    portal_fake_exit(handle(terminal));
    char expected[64];
    snprintf(expected, sizeof expected, "terminal %s\n", terminal);
    CHECK(sent(expected));
    CHECK(shows(terminal, "\"exited\":true", "\"ready\":true", NULL));
    CHECK(portal_views_place(text(terminal), (portal_edges) {0, 0, 10, 10}, text("one"),
                             &error));
    CHECK(shows(terminal, "\"visible\":true", "\"exited\":true", NULL));
    size_t destroyed = portal_fake_calls().destroyed;
    close_view(terminal);
    CHECK(portal_fake_calls().destroyed == destroyed + 1);
}

static void test_changes_announce_once_until_inspected(void)
{
    portal_text error = {0};
    char *terminal = open_in("/"), *other = open_in("/");
    char *web = open_view("web", &error, NULL);
    char expected[64], expected_other[64];
    snprintf(expected, sizeof expected, "terminal %s\n", terminal);
    snprintf(expected_other, sizeof expected_other, "terminal %s\n", other);
    CHECK(sent(""));
    /* Text of any length stays with the platform: Emacs inspects for it. */
    portal_fake_report(handle(terminal), "vim notes.md", "/tmp/a b é");
    CHECK(sent(expected));
    /* Until Emacs inspects, later changes send nothing more. */
    portal_fake_report(handle(terminal), "zsh", "/tmp");
    portal_fake_exit(handle(terminal));
    portal_terminal_changed(text(terminal));
    CHECK(sent(""));
    CHECK(shows(terminal, "\"title\":\"zsh\"", "\"pwd\":\"/tmp\"", "\"exited\":true",
                NULL));
    portal_terminal_changed(text(terminal));
    CHECK(sent(expected));
    /* Each terminal announces its own changes. */
    portal_terminal_changed(text(other));
    CHECK(sent(expected_other));
    CHECK(shows(other, "\"exited\":false", NULL));
    /* Web views, unknown targets and closed terminals announce nothing. */
    char *closed = strdup(other);
    close_view(other);
    const char *silent[] = {web, closed, "terminal:0", "", "terminal"};
    for (size_t i = 0; i < sizeof silent / sizeof *silent; i++)
        portal_terminal_changed(text(silent[i]));
    CHECK(sent(""));
    free(closed);
    close_view(terminal);
    close_view(web);
    CHECK(!portal_fake_calls().misused);
}

int main(void)
{
    int fds[2];
    if (pipe(fds) || fcntl(fds[0], F_SETFL, O_NONBLOCK) == -1)
        abort();
    records = fds[0];
    CHECK(portal_channel_connect(fds[1]));
    test_options_are_checked_before_creation();
    test_the_theme_catalog_is_sorted();
    test_a_theme_reaches_every_terminal();
    test_a_rejected_theme_stops_at_that_terminal();
    test_paste_then_enter();
    test_targets_must_name_open_terminals();
    test_a_terminal_describes_itself();
    test_changes_announce_once_until_inspected();
    CHECK(!portal_fake_calls().misused);
    portal_channel_connect(-1);
    close(records);
    if (failures) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    puts("The terminal rules passed");
    return 0;
}
