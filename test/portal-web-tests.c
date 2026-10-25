/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Web views' rules and the bridge, native/Core/web.c, with the fake
   platform.  The tests call the core as emacs.c does for Lisp, and as a
   platform does for what its pages do: post messages, navigate, commit and
   fail.  Records go to a real pipe, which the tests read as Emacs would. */
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE /* For mkdtemp. */

#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <unistd.h>

#include "channel.h"
#include "input.h"
#include "portal-core-tests.h"
#include "web.h"

static int records = -1; /* The pipe's read end. */

/* Everything the pipe holds now, valid until the next call. */
static const char *drain(void)
{
    static char buffer[8192];
    ssize_t count = read(records, buffer, sizeof buffer - 1);
    buffer[count > 0 ? count : 0] = '\0';
    return buffer;
}

/* Whether the pipe holds exactly the records FORMAT describes, with each %s
   the target TARGET. */
static bool sent(const char *target, const char *format)
{
    char expected[512];
    snprintf(expected, sizeof expected, format, target, target, target);
    const char *got = drain();
    if (strcmp(got, expected))
        fprintf(stderr, "Expected records \"%s\", got \"%s\"\n", expected, got);
    return !strcmp(got, expected);
}

/* Open a web view, hosted when HOSTED; return its target to free. */
static char *open_web(bool hosted)
{
    portal_option options[] = {{.name = text("hosted"), .flag = true}};
    portal_text target = {0}, error = {0};
    if (!portal_views_open(text("web"), options, hosted ? 1 : 0, &target, &error))
        abort();
    return target.data;
}

static bool load(const char *target, const char *url, portal_text *error)
{
    return portal_web_views_load(text(target), text(url), error);
}

/* TARGET's waiting messages, received, as a string to free. */
static char *receive(const char *target)
{
    portal_text json = {0}, error = {0};
    if (!portal_web_views_receive(text(target), &json, &error)) {
        fprintf(stderr, "Receiving failed: %s\n", error.data);
        free(error.data);
        return strdup("(failed)");
    }
    return json.data;
}

/* Whether receiving TARGET's messages returns EXPECTED. */
static bool receives(const char *target, const char *expected)
{
    char *json = receive(target);
    bool same = !strcmp(json, expected);
    if (!same)
        fprintf(stderr, "Expected messages %s, got %s\n", expected, json);
    free(json);
    return same;
}

/* The page in TARGET posts JSON of TYPE from its main frame, or another
   frame, showing URL. */
static void post(const char *target, bool main_frame, const char *url, const char *type,
                 const char *json)
{
    portal_web_posted(text(target), (portal_sender) {main_frame, text(url)}, text(type),
                      text(json));
}

static const char *const app = "http://127.0.0.1:8080/0123/app?context=1";
static const char *const app_origin = "http://127.0.0.1:8080";

/* A hosted app that Emacs loaded at APP and that committed it; its page
   message is received. */
static char *open_app(void)
{
    portal_text error = {0};
    char *target = open_web(true);
    CHECK(load(target, app, &error));
    portal_web_committed(text(target), text(app));
    drain();
    free(receive(target));
    return target;
}

static void test_loading(void)
{
    portal_text error = {0};
    char *web = open_web(false);
    struct portal_fake_calls before = portal_fake_calls();
    const char *const invalid[] = {"", "example.com", "http:example.com", "https:///path",
                                   "ftp://example.com/", "javascript:alert(1)", "1http://a/"};
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; i++) {
        CHECK(!load(web, invalid[i], &error));
        CHECK(says(&error, "Expected an absolute http, https, file, data or about URL"));
    }
    /* A new view is blank already: loading about:blank would add it to the
       history. */
    CHECK(load(web, "about:blank", &error));
    CHECK(portal_fake_calls().loaded == before.loaded);
    CHECK(load(web, "HTTPS://example.com/page#top", &error));
    CHECK(portal_fake_calls().loaded == before.loaded + 1);
    CHECK(shows(web, "\"url\":\"HTTPS://example.com/page#top\"", NULL));
    portal_web_committed(text(web), text("HTTPS://example.com/page#top"));
    /* The document on screen, whatever its fragment, reloads. */
    CHECK(load(web, "HTTPS://example.com/page#bottom", &error));
    CHECK(load(web, "HTTPS://example.com/page", &error));
    CHECK(portal_fake_calls().loaded == before.loaded + 1);
    CHECK(portal_fake_calls().went == before.went + 2);
    CHECK(shows(web, "\"history\":\"reload reload\"", NULL));
    /* Any other document loads, including about:blank once a page has shown. */
    const char *const others[] = {"HTTPS://example.com/other", "file:///tmp/a%20b.html",
                                  "data:text/html,<p>#1</p>", "about:blank"};
    for (size_t i = 0; i < sizeof others / sizeof *others; i++)
        CHECK(load(web, others[i], &error));
    CHECK(portal_fake_calls().loaded == before.loaded + 5);
    /* A platform that cannot load leaves the view as it was. */
    portal_fake_refuse(true);
    CHECK(!load(web, "https://example.org/", &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    CHECK(!load(web, "HTTPS://example.com/page", &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    CHECK(shows(web, "\"url\":\"about:blank\"", NULL));
    close_view(web);

    /* Loading checks the kind of view. */
    char *terminal = open_view("terminal", &error, "directory", "/tmp", NULL);
    CHECK(terminal != NULL);
    char message[64];
    snprintf(message, sizeof message, "No Portal view %s", terminal);
    CHECK(!load(terminal, "about:blank", &error));
    CHECK(says(&error, message));
    close_view(terminal);
}

/* The core keeps URLs as the platform's parser spells them, which is how
   the platform reports pages, so it recognizes the page on screen however
   Lisp spelled its URL. */
static void test_urls_are_the_platforms_spelling(void)
{
    portal_text error = {0};
    char *web = open_web(false);
    const struct {
        const char *loaded, *parsed;
    } spellings[] = {
        {"data:text/html,<p>a b</p>", "data:text/html,%3Cp%3Ea%20b%3C/p%3E"},
        {"file:///tmp/my notes/r\xc3\xa9sum\xc3\xa9.html#top",
         "file:///tmp/my%20notes/r%C3%A9sum%C3%A9.html#top"},
    };
    for (size_t i = 0; i < sizeof spellings / sizeof *spellings; i++) {
        size_t loads = portal_fake_calls().loaded, reloads = portal_fake_calls().went;
        char url[128];
        snprintf(url, sizeof url, "\"url\":\"%s\"", spellings[i].parsed);
        CHECK(load(web, spellings[i].loaded, &error));
        CHECK(shows(web, url, NULL));
        portal_web_committed(text(web), text(spellings[i].parsed));
        CHECK(load(web, spellings[i].loaded, &error));
        CHECK(portal_fake_calls().loaded == loads + 1 && portal_fake_calls().went == reloads + 1);
    }
    /* Spellings the platform keeps apart are different URLs. */
    size_t loads = portal_fake_calls().loaded;
    CHECK(load(web, "https://example.com/a%2Fb", &error));
    portal_web_committed(text(web), text("https://example.com/a%2Fb"));
    CHECK(load(web, "https://example.com/a/b", &error));
    CHECK(portal_fake_calls().loaded == loads + 2);
    close_view(web);
}

static void test_the_address_survives_a_failed_load(void)
{
    portal_text error = {0};
    char *web = open_app();
    portal_fake_refuse(true);
    CHECK(!load(web, "http://127.0.0.1:9090/0123/app", &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    /* The app still posts from the address it had, and still stays on its
       origin. */
    post(web, true, "http://127.0.0.1:9090/0123/app", "moved", "{\"type\":\"moved\"}");
    post(web, true, app, "stayed", "{\"type\":\"stayed\"}");
    CHECK(receives(web, "[{\"type\":\"stayed\"}]"));
    CHECK(portal_web_navigating(text(web), text("http://127.0.0.1:9090/"), true, false)
          == PORTAL_NAVIGATION_EXTERNAL);
    close_view(web);
}

static void test_messages_keep_their_order_under_one_record(void)
{
    char *web = open_app();
    CHECK(receives(web, "[]"));
    post(web, true, app, "first", "{\"type\":\"first\"}");
    CHECK(sent(web, "bridge %s\n"));
    post(web, true, app, "change", "{\"type\":\"change\",\"n\":1}");
    post(web, true, app, "", "{\"n\":2}");
    post(web, true, app, "dirty", "{\"type\":\"dirty\"}");
    /* A newer change replaces one Emacs has not received, at the end. */
    post(web, true, app, "change", "{\"type\":\"change\",\"n\":3}");
    post(web, true, app, "last", "{\"type\":\"last\",\"text\":\"\\u2713\"}");
    CHECK(sent(web, ""));
    CHECK(receives(web, "[{\"type\":\"first\"},{\"n\":2},{\"type\":\"dirty\"},"
                        "{\"type\":\"change\",\"n\":3},{\"type\":\"last\",\"text\":\"\\u2713\"}]"));
    /* Receiving drains the bridge and lets the next message send a record. */
    CHECK(receives(web, "[]"));
    post(web, true, app, "change", "{\"type\":\"change\",\"n\":4}");
    post(web, true, app, "change", "{\"type\":\"change\",\"n\":5}");
    CHECK(sent(web, "bridge %s\n"));
    CHECK(receives(web, "[{\"type\":\"change\",\"n\":5}]"));
    /* A large payload stays out of the pipe. */
    size_t size = 4 * PIPE_BUF;
    char *large = malloc(size + 32);
    int length = snprintf(large, 32, "{\"type\":\"change\",\"json\":\"");
    memset(large + length, 'x', size);
    strcpy(large + length + size, "\"}");
    post(web, true, app, "change", large);
    CHECK(sent(web, "bridge %s\n"));
    char *json = receive(web);
    CHECK(strlen(json) == strlen(large) + 2 && !strncmp(json + 1, large, strlen(large)));
    free(json);
    free(large);
    close_view(web);
}

static void test_only_the_apps_main_frame_may_post(void)
{
    portal_text error = {0};
    char *web = open_web(true);
    /* Nothing loaded yet: no page is the app. */
    post(web, true, "about:blank", "early", "{\"type\":\"early\"}");
    CHECK(load(web, app, &error));
    post(web, false, app, "frame", "{\"type\":\"frame\"}");
    /* A sender is judged by the URL the platform saw, not by what the page
       claims, and only the address matches exactly. */
    post(web, true, "http://127.0.0.1:8080/0123/app?context=2", "other",
         "{\"type\":\"other\",\"origin\":\"http://127.0.0.1:8080\"}");
    post(web, true, "http://127.0.0.1:8080/0123/app?context=1#x", "fragment",
         "{\"type\":\"fragment\"}");
    post(web, true, "http://127.0.0.1:8080/0123/app?context=%31", "encoded",
         "{\"type\":\"encoded\"}");
    /* The core's own types are reserved. */
    const char *const reserved[] = {"page", "follow"};
    for (size_t i = 0; i < sizeof reserved / sizeof *reserved; i++)
        post(web, true, app, reserved[i], "{\"type\":\"page\",\"url\":\"file:///etc/passwd\"}");
    CHECK(sent(web, ""));
    /* An app may report its own errors, as the core does. */
    post(web, true, app, "error", "{\"type\":\"error\",\"message\":\"app\"}");
    CHECK(sent(web, "bridge %s\n"));
    CHECK(receives(web, "[{\"type\":\"error\",\"message\":\"app\"}]"));
    close_view(web);

    /* The address is the platform's spelling, which is how it reports
       senders. */
    web = open_web(true);
    CHECK(load(web, "http://127.0.0.1:8080/0123/app?path=my notes.md", &error));
    post(web, true, "http://127.0.0.1:8080/0123/app?path=my notes.md", "raw",
         "{\"type\":\"raw\"}");
    post(web, true, "http://127.0.0.1:8080/0123/app?path=my%20notes.md", "spelled",
         "{\"type\":\"spelled\"}");
    CHECK(sent(web, "bridge %s\n"));
    CHECK(receives(web, "[{\"type\":\"spelled\"}]"));
    close_view(web);
}

static void test_the_core_reports_pages_and_failures(void)
{
    portal_text error = {0};
    char *web = open_web(true);
    CHECK(load(web, app, &error));
    portal_web_failed(text(web), 0, text("Could not \"connect\"\n\x01"));
    CHECK(sent(web, "bridge %s\n"));
    portal_web_committed(text(web), text(app));
    portal_web_committed(text(web), text("http://127.0.0.1:8080/0123/app?path=r%C3%A9sum%C3%A9"));
    portal_web_failed(text(web), 0, text("The page's web process stopped."));
    CHECK(sent(web, ""));
    CHECK(receives(web,
                   "[{\"type\":\"error\",\"message\":\"Could not \\\"connect\\\"\\u000a\\u0001\"},"
                   "{\"type\":\"page\",\"url\":\"http://127.0.0.1:8080/0123/app?context=1\"},"
                   "{\"type\":\"page\",\"url\":\"http://127.0.0.1:8080/0123/app?path=r%C3%A9sum%C3%A9\"},"
                   "{\"type\":\"error\",\"message\":\"The page's web process stopped.\"}]"));
    close_view(web);
}

static void test_ordinary_pages_have_no_bridge_to_their_page(void)
{
    portal_text error = {0};
    char *web = open_web(false);
    CHECK(load(web, "https://example.com/", &error));
    struct portal_fake_calls before = portal_fake_calls();
    portal_web_committed(text(web), text("https://example.com/"));
    post(web, true, "https://example.com/", "hello", "{\"type\":\"hello\"}");
    portal_web_failed(text(web), 0, text("Failed"));
    CHECK(portal_web_navigating(text(web), text("file:///etc/passwd"), true, false)
          == PORTAL_NAVIGATION_ALLOW);
    CHECK(portal_web_navigating(text(web), text("https://elsewhere.example/"), true, false)
          == PORTAL_NAVIGATION_ALLOW);
    CHECK(sent(web, ""));
    char message[128];
    snprintf(message, sizeof message, "Web view %s is not a hosted app, so it has no bridge", web);
    portal_text json = {0};
    CHECK(!portal_web_views_send(text(web), text("{}"), &error));
    CHECK(says(&error, message));
    CHECK(portal_fake_calls().posted == before.posted);
    /* Only the core's own messages wait for Emacs. */
    CHECK(receives(web, "[]"));
    close_view(web);
    CHECK(!portal_web_views_send(text("web:0"), text("{}"), &error));
    CHECK(says(&error, "No Portal view web:0"));
    CHECK(!portal_web_views_receive(text("web:0"), &json, &error));
    CHECK(says(&error, "No Portal view web:0"));
}

static void test_navigation_decisions(void)
{
    char *web = open_app();
    const struct {
        const char *url;
        bool main_frame;
        portal_navigation decision;
    } cases[] = {
        {"http://127.0.0.1:8080/0123/markdown?path=a.md", true, PORTAL_NAVIGATION_ALLOW},
        {"HTTP://127.0.0.1:8080/other#x", true, PORTAL_NAVIGATION_ALLOW},
        {"http://user@127.0.0.1:8080/", true, PORTAL_NAVIGATION_ALLOW},
        {"about:blank", true, PORTAL_NAVIGATION_ALLOW},
        {"about:srcdoc", true, PORTAL_NAVIGATION_ALLOW},
        {"https://example.com/", false, PORTAL_NAVIGATION_ALLOW},
        {"file:///etc/passwd", false, PORTAL_NAVIGATION_ALLOW},
        {"https://example.com/", true, PORTAL_NAVIGATION_EXTERNAL},
        {"http://127.0.0.1:8081/0123/app", true, PORTAL_NAVIGATION_EXTERNAL},
        {"http://127.0.0.1/0123/app", true, PORTAL_NAVIGATION_EXTERNAL},
        {"https://127.0.0.1:8080/0123/app", true, PORTAL_NAVIGATION_EXTERNAL},
        {"http://127.0.0.1:8080@evil.example/", true, PORTAL_NAVIGATION_EXTERNAL},
        {"http://[::1]:8080/", true, PORTAL_NAVIGATION_EXTERNAL},
        {"mailto:someone@example.com", true, PORTAL_NAVIGATION_EXTERNAL},
        {"data:text/html,hi", true, PORTAL_NAVIGATION_EXTERNAL},
    };
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        portal_navigation decision =
            portal_web_navigating(text(web), text(cases[i].url), cases[i].main_frame, false);
        if (decision != cases[i].decision)
            fprintf(stderr, "Navigating to %s: expected %d, got %d\n", cases[i].url,
                    cases[i].decision, decision);
        CHECK(decision == cases[i].decision);
    }
    CHECK(sent(web, ""));
    CHECK(receives(web, "[]"));
    /* A closed or unknown view's pages go nowhere special. */
    CHECK(portal_web_navigating(text("web:0"), text("file:///etc/passwd"), true, false)
          == PORTAL_NAVIGATION_ALLOW);
    close_view(web);
}

/* Emacs gets the keyboard, ending any prefix it is reading, before the
   bridge record that hands it a local link. */
static void test_local_links_go_to_emacs(void)
{
    portal_text error = {0};
    bool focused = false;
    char *web = open_app();
    CHECK(portal_views_place(text(web), (portal_edges) {0, 0, 100, 100}, text("frame"), &error));
    CHECK(portal_input_perform(text(web), text("focus"), 0, &focused, &error) && focused);
    CHECK(sent(web, "focus %s 1\n"));
    /* Longer than a record could hold. */
    char url[PIPE_BUF + 64] = "file:///tmp/";
    while (strlen(url) < PIPE_BUF)
        strcat(url, "r%C3%A9sum%C3%A9%20");
    strcat(url, "notes.ts#L4");
    /* Emacs gets the keyboard with the link, and its mode line hears first. */
    CHECK(portal_web_navigating(text(web), text(url), true, false) == PORTAL_NAVIGATION_EMACS);
    CHECK(sent(web, "focus %s 0\nbridge %s\n"));
    CHECK(portal_input_owner(text(web)) == PORTAL_OWNER_EMACS);
    /* During a handoff, Emacs stops reading its key sequence first. */
    CHECK(portal_input_perform(text(web), text("focus"), 0, &focused, &error) && focused);
    portal_fake_press((portal_chord) {'x', PORTAL_CONTROL}, false);
    portal_fake_answer(false);
    const char *got = drain();
    char prefix[64], tail[64];
    snprintf(prefix, sizeof prefix, "focus %s 1\nkey %s ", web, web);
    snprintf(tail, sizeof tail, " 120 2\nfocus %s 0\n", web);
    int64_t serial = 0;
    CHECK(!strncmp(got, prefix, strlen(prefix)));
    CHECK(sscanf(got + strlen(prefix), "%" SCNd64, &serial) == 1 && serial > 0);
    CHECK(strlen(got) > strlen(tail) && !strcmp(got + strlen(got) - strlen(tail), tail));
    CHECK(portal_web_navigating(text(web), text("file:///tmp/other.md"), true, false)
          == PORTAL_NAVIGATION_EMACS);
    char escape[64];
    snprintf(escape, sizeof escape, "escape %%s %" PRId64 " 0\n", serial);
    CHECK(sent(web, escape)); /* The first bridge record still waits. */
    CHECK(portal_input_owner(text(web)) == PORTAL_OWNER_EMACS);
    char expected[PIPE_BUF + 128];
    snprintf(expected, sizeof expected,
             "[{\"type\":\"follow\",\"url\":\"%s\"},{\"type\":\"follow\",\"url\":\"file:///tmp/other.md\"}]",
             url);
    CHECK(receives(web, expected));
    /* A local file loaded as the app itself stays. */
    char *local = open_web(true);
    CHECK(load(local, "file:///tmp/app/index.html", &error));
    CHECK(portal_web_navigating(text(local), text("file:///tmp/app/other.html"), true, false)
          == PORTAL_NAVIGATION_ALLOW);
    CHECK(sent(local, ""));
    close_view(local);
    close_view(web);
}

/* Emacs moves a page through its history by name; the platform steps. */
static void test_history_steps(void)
{
    portal_text error = {0};
    char *web = open_web(false);
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(portal_web_views_go(text(web), text("back"), &error));
    CHECK(portal_web_views_go(text(web), text("forward"), &error));
    CHECK(portal_fake_calls().went == before.went + 2);
    CHECK(shows(web, "\"history\":\"back forward\"", NULL));
    CHECK(!portal_web_views_go(text(web), text("reload"), &error));
    CHECK(says(&error, "Web history step must be \"back\" or \"forward\", not reload"));
    CHECK(!portal_web_views_go(text("web:0"), text("back"), &error));
    CHECK(says(&error, "No Portal view web:0"));
    CHECK(portal_fake_calls().went == before.went + 2);
    close_view(web);
}

static void test_messages_to_the_app_and_stale_completions(void)
{
    portal_text error = {0};
    char *web = open_app();
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(portal_web_views_send(text(web), text("{\"type\":\"load\",\"json\":\"{}\"}"), &error));
    CHECK(portal_web_views_send(text(web), text("{\"type\":\"saved\"}"), &error));
    CHECK(portal_fake_calls().posted == before.posted + 2);
    CHECK(shows(web, "\"posts\":\"{\\\"type\\\":\\\"load\\\",\\\"json\\\":\\\"{}\\\"},"
                     "{\\\"type\\\":\\\"saved\\\"}\"", NULL));
    CHECK(!portal_web_views_send(text(web), text("[]"), &error));
    CHECK(says(&error, "A bridge message must be a JSON object"));
    CHECK(portal_fake_calls().posted == before.posted + 2);
    /* The token is the page the message went to.  A failure to deliver it
       reaches Emacs while that page is on screen. */
    CHECK(shows(web, "\"token\":2", NULL));
    portal_web_failed(text(web), 2, text("No receive function"));
    CHECK(sent(web, "bridge %s\n"));
    CHECK(receives(web, "[{\"type\":\"error\",\"message\":\"No receive function\"}]"));
    /* Once the page has gone, a late failure from it is ignored, and new
       messages carry the new page's token. */
    portal_web_committed(text(web), text(app));
    CHECK(receives(web, "[{\"type\":\"page\",\"url\":\"http://127.0.0.1:8080/0123/app?context=1\"}]"));
    drain();
    portal_web_failed(text(web), 2, text("Stale"));
    portal_web_failed(text(web), 1, text("Staler"));
    CHECK(sent(web, ""));
    CHECK(receives(web, "[]"));
    CHECK(portal_web_views_send(text(web), text("{}"), &error));
    CHECK(shows(web, "\"token\":3", NULL));
    close_view(web);
}

static void test_a_closed_view_hears_nothing(void)
{
    char *web = open_app();
    char *target = strdup(web);
    post(web, true, app, "waiting", "{\"type\":\"waiting\"}");
    CHECK(sent(web, "bridge %s\n"));
    struct portal_fake_calls before = portal_fake_calls();
    close_view(web);
    /* Late calls from the platform, such as a completion finishing after
       close, reach neither Emacs nor the platform. */
    post(target, true, app, "late", "{\"type\":\"late\"}");
    portal_web_committed(text(target), text(app));
    portal_web_failed(text(target), 0, text("Late"));
    portal_web_failed(text(target), 2, text("Late"));
    CHECK(portal_web_navigating(text(target), text("file:///etc/passwd"), true, false)
          == PORTAL_NAVIGATION_ALLOW);
    CHECK(sent(target, ""));
    CHECK(portal_fake_calls().destroyed == before.destroyed + 1);
    before.destroyed++;
    struct portal_fake_calls after = portal_fake_calls();
    CHECK(!memcmp(&before, &after, sizeof before));
    char message[64];
    snprintf(message, sizeof message, "No Portal view %s", target);
    portal_text json = {0}, error = {0};
    CHECK(!portal_web_views_receive(text(target), &json, &error));
    CHECK(says(&error, message));
    free(target);
}

/* A web view whose app echoes what Emacs sends, as the Lisp module tests use. */
static void test_an_echoing_app(void)
{
    portal_option options[] = {{.name = text("hosted"), .flag = true},
                               {.name = text("echo"), .flag = true}};
    portal_text target = {0}, error = {0};
    CHECK(portal_views_open(text("web"), options, 2, &target, &error));
    CHECK(load(target.data, app, &error));
    CHECK(portal_web_views_send(text(target.data), text("{\"a\":1}"), &error));
    CHECK(sent(target.data, "bridge %s\n"));
    CHECK(receives(target.data, "[{\"a\":1}]"));
    close_view(target.data);
}

static void test_appearance_at_open(void)
{
    portal_text error = {0};
    char *dark = open_view("web", &error, "appearance", "dark", NULL);
    CHECK(dark && shows(dark, "\"appearance\":\"dark\"", NULL));
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(!open_view("web", &error, "appearance", "sepia", NULL));
    CHECK(says(&error, "Unknown web appearance: sepia"));
    portal_option flag[] = {{.name = text("appearance"), .flag = true}};
    portal_text target = {0};
    CHECK(!portal_views_open(text("web"), flag, 1, &target, &error));
    CHECK(says(&error, "Option :appearance must be \"light\", \"dark\" or nil"));
    CHECK(portal_fake_calls().created == before.created);
    /* Nil, like no option, is the system's; a later duplicate wins. */
    portal_option options[] = {{.name = text("appearance"), .is_string = true,
                                .string = text("sepia")},
                               {.name = text("appearance")}};
    CHECK(portal_views_open(text("web"), options, 2, &target, &error));
    CHECK(shows(target.data, "\"appearance\":false", NULL));
    close_view(target.data);
    close_view(dark);
}

static void test_an_appearance_reaches_every_web_view(void)
{
    portal_text error = {0};
    portal_string light = text("light"), dark = text("dark"), sepia = text("sepia");
    /* A name is checked even with no web view open. */
    CHECK(!portal_web_views_appearance(&sepia, &error));
    CHECK(says(&error, "Unknown web appearance: sepia"));
    CHECK(portal_web_views_appearance(&dark, &error));

    char *terminal = open_view("terminal", &error, "directory", "/", NULL);
    char *first = open_web(false), *second = open_web(true);
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(portal_web_views_appearance(&light, &error));
    CHECK(portal_fake_calls().appeared == before.appeared + 2);
    CHECK(shows(first, "\"appearance\":\"light\"", NULL));
    CHECK(shows(second, "\"appearance\":\"light\"", NULL));
    char *state = inspect(terminal);
    CHECK(state && !strstr(state, "\"appearance\""));
    free(state);

    /* An unknown name touches no view, and nil is the system's. */
    before = portal_fake_calls();
    CHECK(!portal_web_views_appearance(&sepia, &error));
    CHECK(says(&error, "Unknown web appearance: sepia"));
    CHECK(same_calls(portal_fake_calls(), before));
    CHECK(portal_web_views_appearance(NULL, &error));
    CHECK(shows(first, "\"appearance\":false", NULL));
    CHECK(shows(second, "\"appearance\":false", NULL));

    /* A view that fails stops the rest; the views before it keep theirs. */
    char *broken = open_view("web", &error, "broken", "WebKit is gone", NULL);
    char *third = open_web(false);
    CHECK(!portal_web_views_appearance(&dark, &error));
    CHECK(says(&error, "WebKit is gone"));
    CHECK(shows(second, "\"appearance\":\"dark\"", NULL));
    state = inspect(third);
    CHECK(state && !strstr(state, "\"appearance\""));
    free(state);
    close_view(broken);
    CHECK(portal_web_views_appearance(&dark, &error));
    CHECK(shows(third, "\"appearance\":\"dark\"", NULL));

    /* A refusing platform changes nothing. */
    portal_fake_refuse(true);
    before = portal_fake_calls();
    CHECK(!portal_web_views_appearance(&light, &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    CHECK(same_calls(portal_fake_calls(), before));
    CHECK(shows(first, "\"appearance\":\"dark\"", NULL));
    close_view(first);
    close_view(second);
    close_view(third);
    close_view(terminal);
}

/* The record a window's opening sent: its target, to free, after checking
   that it names OPENER. */
static char *opened(const char *opener)
{
    char window[32], named[32], expected[80];
    const char *got = drain();
    if (sscanf(got, "opened %31s %31s", window, named) != 2 || strcmp(named, opener)) {
        fprintf(stderr, "Expected a window of %s, got \"%s\"\n", opener, got);
        return NULL;
    }
    snprintf(expected, sizeof expected, "opened %s %s\n", window, opener);
    return strcmp(got, expected) ? NULL : strdup(window);
}

/* A page opens a window as a new web view in its own appearance, which
   Emacs hears of and which may close itself; no other view can. */
static void test_pages_open_windows(void)
{
    portal_text error = {0};
    char *page = open_view("web", &error, "appearance", "dark", NULL);
    CHECK(load(page, "https://example.com/", &error));
    char asked[] = "https://example.com/popup";
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(portal_web_window(text(page), asked));
    CHECK(portal_fake_calls().created == before.created + 1);
    char *window = opened(page);
    CHECK(window);
    char opener[64];
    snprintf(opener, sizeof opener, "\"opener\":\"%s\"", page);
    CHECK(shows(window, "\"kind\":\"web\"", "\"visible\":false", opener,
                "\"request\":\"https://example.com/popup\"", "\"appearance\":\"dark\"", NULL));
    /* It is an ordinary web view, which Lisp drives as any other. */
    CHECK(portal_web_navigating(text(window), text("file:///etc/passwd"), true, false)
          == PORTAL_NAVIGATION_ALLOW);
    CHECK(load(window, "https://example.com/next", &error));
    CHECK(shows(window, "\"url\":\"https://example.com/next\"", NULL));
    /* Its pages are announced, one record until Emacs inspects it; the
       opener's are not. */
    portal_web_committed(text(window), text("https://example.com/next"));
    portal_web_committed(text(window), text("https://example.com/last"));
    CHECK(sent(window, "web %s\n"));
    CHECK(shows(window, "\"kind\":\"web\"", NULL));
    portal_web_committed(text(window), text("https://example.com/next"));
    CHECK(sent(window, "web %s\n"));
    free(inspect(window));
    portal_web_committed(text(page), text("https://example.com/"));
    CHECK(sent(page, ""));
    /* Windows open windows too. */
    char blank[] = "about:blank";
    CHECK(portal_web_window(text(window), blank));
    char *nested = opened(window);
    CHECK(nested);
    /* Only a window closes itself. */
    portal_web_closed(text(page));
    CHECK(sent(page, ""));
    portal_web_closed(text(window));
    CHECK(sent(window, "closed %s\n"));
    close_view(window);
    portal_web_closed(text(nested));
    CHECK(sent(nested, "closed %s\n"));
    close_view(nested);
    close_view(page);
}

/* A window opens only for a page that may have one, and only when the
   platform makes it: otherwise nothing opens and Emacs hears nothing. */
static void test_windows_that_do_not_open(void)
{
    char *app_view = open_app();
    char asked[] = "http://127.0.0.1:8080/0123/other";
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(!portal_web_window(text(app_view), asked));
    CHECK(!portal_web_window(text("web:0"), asked));
    char *page = open_web(false);
    before = portal_fake_calls();
    char failing[] = "fail";
    CHECK(!portal_web_window(text(page), failing));
    portal_fake_refuse(true);
    CHECK(!portal_web_window(text(page), asked));
    portal_fake_refuse(false);
    CHECK(same_calls(before, portal_fake_calls()));
    CHECK(sent(page, ""));
    /* Closing a window that is gone, or that never opened, says nothing. */
    portal_web_closed(text("web:0"));
    CHECK(sent(page, ""));
    close_view(page);
    close_view(app_view);
}

/* Whether DOWNLOAD's file, from portal_web_download_started, is NAME in
   DIRECTORY. */
static bool saves(portal_string path, uint64_t download, const char *directory, const char *name)
{
    char expected[512];
    snprintf(expected, sizeof expected, "%s/%s", directory, name);
    bool same = download && path.length == strlen(expected) && !strcmp(path.data, expected);
    if (!same)
        fprintf(stderr, "Expected download %" PRIu64 " to save %s, got %s\n", download, expected,
                path.data);
    return same;
}

/* Whether the messages waiting for TARGET are the download messages that
   LINES describe, in order: one "STATE|FILE" or "STATE|FILE|MESSAGE" per
   line, each FILE a name in DIRECTORY or empty for none, all for the URL
   https://example.com/f. */
static bool downloads_said(const char *target, const char *directory, const char *lines)
{
    char expected[4096] = "[";
    size_t used = 1;
    for (const char *line = lines; *line;) {
        const char *bar = strchr(line, '|'), *next = strchr(line, '\n');
        if (!next)
            next = line + strlen(line);
        const char *second = memchr(bar + 1, '|', (size_t) (next - bar - 1));
        const char *file_end = second ? second : next;
        used += (size_t) snprintf(
            expected + used, sizeof expected - used,
            "%s{\"type\":\"download\",\"state\":\"%.*s\",\"url\":\"https://example.com/f\","
            "\"file\":\"%s%s%.*s\"",
            used == 1 ? "" : ",", (int) (bar - line), line, file_end > bar + 1 ? directory : "",
            file_end > bar + 1 ? "/" : "", (int) (file_end - bar - 1), bar + 1);
        if (second)
            used += (size_t) snprintf(expected + used, sizeof expected - used,
                                      ",\"message\":\"%.*s\"", (int) (next - second - 1),
                                      second + 1);
        used += (size_t) snprintf(expected + used, sizeof expected - used, "}");
        line = *next ? next + 1 : next;
    }
    snprintf(expected + used, sizeof expected - used, "]");
    return receives(target, expected);
}

/* Start a download in TARGET, and name its file NAME; return its path. */
static portal_string start(const char *target, const char *name, uint64_t *download)
{
    *download = portal_web_download_started(text(target), text("https://example.com/f"));
    return *download ? portal_web_download_destination(*download, text(name)) : text("");
}

static void test_downloads(void)
{
    portal_text error = {0};
    uint64_t download = 1;
    char *web = open_web(false);
    /* Navigations and responses that download. */
    CHECK(portal_web_navigating(text(web), text("https://example.com/f"), true, true)
          == PORTAL_NAVIGATION_DOWNLOAD);
    CHECK(portal_web_responding(text(web), true, false) == PORTAL_NAVIGATION_ALLOW);
    CHECK(portal_web_responding(text(web), false, false) == PORTAL_NAVIGATION_DOWNLOAD);
    CHECK(portal_web_responding(text(web), true, true) == PORTAL_NAVIGATION_DOWNLOAD);
    CHECK(portal_web_responding(text("web:0"), false, true) == PORTAL_NAVIGATION_ALLOW);
    /* Until Lisp names a directory, a download has nowhere to go, and its
       end is no news. */
    CHECK(start(web, "f.txt", &download).length == 0 && download);
    portal_web_download_finished(download, NULL);
    CHECK(sent(web, "bridge %s\n"));
    CHECK(downloads_said(web, "", "failed||Portal has no download directory"));
    const char *const relative[] = {"", "downloads", "~/Downloads"};
    for (size_t i = 0; i < sizeof relative / sizeof *relative; i++) {
        CHECK(!portal_web_views_download_directory(text(relative[i]), &error));
        char expected[128];
        snprintf(expected, sizeof expected,
                 "The download directory must be an absolute path, not %s", relative[i]);
        CHECK(says(&error, expected));
    }
    char directory[] = "/tmp/portal-downloads-XXXXXX";
    CHECK(mkdtemp(directory));
    char slashed[sizeof directory + 16];
    snprintf(slashed, sizeof slashed, "%s/missing/", directory);
    CHECK(portal_web_views_download_directory(text(slashed), &error));
    CHECK(start(web, "f.txt", &download).length == 0 && download);
    char missing[256];
    snprintf(missing, sizeof missing, "failed||No download directory %s", slashed);
    CHECK(downloads_said(web, "", missing));
    drain();
    snprintf(slashed, sizeof slashed, "%s/", directory);
    CHECK(portal_web_views_download_directory(text(slashed), &error));
    /* A file or a running download keeps its name taken. */
    char existing[sizeof directory + 16];
    snprintf(existing, sizeof existing, "%s/notes.txt", directory);
    FILE *file = fopen(existing, "w");
    CHECK(file && !fclose(file));
    uint64_t report, again, notes, unnamed, hidden, odd;
    portal_string path;
    path = start(web, "report.pdf", &report);
    CHECK(saves(path, report, directory, "report.pdf"));
    path = start(web, "report.pdf", &again);
    CHECK(saves(path, again, directory, "report (1).pdf"));
    CHECK(again != report);
    uint64_t shouted;
    path = start(web, "REPORT.pdf", &shouted);
    CHECK(saves(path, shouted, directory, "REPORT (2).pdf"));
    path = start(web, "notes.txt", &notes);
    CHECK(saves(path, notes, directory, "notes (1).txt"));
    /* Names are made safe. */
    path = start(web, "", &unnamed);
    CHECK(saves(path, unnamed, directory, "download"));
    path = start(web, "../.hidden", &hidden);
    CHECK(saves(path, hidden, directory, "_.hidden"));
    path = start(web, "a\nb/c.tar.gz", &odd);
    CHECK(saves(path, odd, directory, "a_b_c.tar.gz"));
    CHECK(sent(web, "bridge %s\n"));
    CHECK(downloads_said(web, directory,
                         "started|report.pdf\nstarted|report (1).pdf\nstarted|REPORT (2).pdf\n"
                         "started|notes (1).txt\n"
                         "started|download\nstarted|_.hidden\nstarted|a_b_c.tar.gz"));
    /* Long names keep their extension and whole characters. */
    char name[512] = "a", expected[512] = "a";
    for (int i = 0; i < 150; i++)
        strcat(name, "\xc3\xa9");
    strcat(name, ".txt");
    for (int i = 0; i < 97; i++)
        strcat(expected, "\xc3\xa9");
    strcat(expected, ".txt");
    uint64_t long_name;
    path = start(web, name, &long_name);
    CHECK(saves(path, long_name, directory, expected));
    CHECK(path.length - strlen(directory) - 1 <= 200);
    free(receive(web));
    drain();
    /* An ending frees the name, and Emacs hears how it went. */
    portal_string full = text("The disk is full.");
    portal_web_download_finished(report, NULL);
    portal_web_download_finished(again, &full);
    portal_web_download_finished(report, NULL); /* Once only. */
    portal_web_download_finished(0, NULL);
    CHECK(sent(web, "bridge %s\n"));
    CHECK(downloads_said(web, directory,
                         "finished|report.pdf\nfailed|report (1).pdf|The disk is full."));
    uint64_t later;
    path = start(web, "report.pdf", &later);
    CHECK(saves(path, later, directory, "report.pdf"));
    CHECK(later > long_name);
    CHECK(portal_web_download_destination(later, text("again.pdf")).length == 0);
    free(receive(web));
    drain();
    /* A download can fail before it has a file. */
    uint64_t early = portal_web_download_started(text(web), text("https://example.com/f"));
    portal_string refused = text("Could not connect to the server.");
    portal_web_download_finished(early, &refused);
    CHECK(sent(web, "bridge %s\n"));
    CHECK(downloads_said(web, "", "failed||Could not connect to the server."));
    /* A closed view's downloads end without a word, and it starts none. */
    char *target = strdup(web);
    close_view(web);
    portal_web_download_finished(later, NULL);
    portal_web_download_finished(notes, &full);
    CHECK(start(target, "late.txt", &download).length == 0 && !download);
    CHECK(!portal_web_download_started(text(target), text("https://example.com/f")));
    CHECK(sent(target, ""));
    /* A hosted app's page cannot pass for the core. */
    char *hosted = open_app();
    post(hosted, true, app, "download", "{\"type\":\"download\",\"state\":\"finished\"}");
    uint64_t own;
    path = start(hosted, "drawing.png", &own);
    CHECK(saves(path, own, directory, "drawing.png"));
    CHECK(downloads_said(hosted, directory, "started|drawing.png"));
    drain();
    close_view(hosted);
    const uint64_t rest[] = {shouted, unnamed, hidden, odd, long_name, own};
    for (size_t i = 0; i < sizeof rest / sizeof *rest; i++)
        portal_web_download_finished(rest[i], NULL);
    CHECK(!unlink(existing) && !rmdir(directory));
    free(target);
}

/* Emacs finds text in a page; only the latest find's result reaches it. */
static void test_finding(void)
{
    portal_text error = {0};
    char *web = open_web(false);
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(!portal_web_views_find(text(web), text(""), false, false, &error));
    CHECK(says(&error, "Nothing to find"));
    CHECK(!portal_web_views_find(text("web:0"), text("apple"), false, false, &error));
    CHECK(says(&error, "No Portal view web:0"));
    CHECK(same_calls(portal_fake_calls(), before));

    CHECK(portal_web_views_find(text(web), text("apple"), false, false, &error));
    CHECK(shows(web, "\"finds\":\"apple forward nocase\"", "\"find\":1", NULL));
    CHECK(sent(web, ""));
    portal_web_found(text(web), 1, true);
    CHECK(sent(web, "found %s 1\n"));

    /* The user typed on before the first find finished. */
    CHECK(portal_web_views_find(text(web), text("Apple"), true, true, &error));
    CHECK(portal_web_views_find(text(web), text("Apples"), false, true, &error));
    CHECK(shows(web, "\"finds\":\"apple forward nocase,Apple backward case,Apples forward case\"",
                "\"find\":3", NULL));
    portal_web_found(text(web), 2, true);
    CHECK(sent(web, ""));
    portal_web_found(text(web), 3, false);
    CHECK(sent(web, "found %s 0\n"));

    /* A find the platform refuses is no find: the one before stays latest. */
    portal_fake_refuse(true);
    CHECK(!portal_web_views_find(text(web), text("pear"), false, false, &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    portal_web_found(text(web), 3, true);
    CHECK(sent(web, "found %s 1\n"));

    char *closed = strdup(web);
    close_view(web);
    portal_web_found(text(closed), 3, true);
    CHECK(sent(closed, ""));
    free(closed);
}

/* Each host's pages show at its level, in every view, whatever loads them. */
static void test_zoom_per_host(void)
{
    portal_text error = {0};
    char *first = open_web(false), *second = open_web(true);
    portal_web_committed(text(first), text("https://Example.com/page"));
    portal_web_committed(text(second), text("https://other.org/"));
    drain();
    free(receive(second));
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(!portal_web_views_zoom(text("example.com"), 24, &error));
    CHECK(says(&error, "Web zoom must be from 25 to 500 percent"));
    CHECK(!portal_web_views_zoom(text("example.com"), 501, &error));
    CHECK(says(&error, "Web zoom must be from 25 to 500 percent"));
    CHECK(same_calls(portal_fake_calls(), before));

    /* Only the page on screen from that host changes, ignoring case. */
    CHECK(portal_web_views_zoom(text("example.COM"), 150, &error));
    CHECK(portal_fake_calls().zoomed == before.zoomed + 1);
    CHECK(shows(first, "\"zoom\":150", NULL));
    char *state = inspect(second);
    CHECK(state && !strstr(state, "\"zoom\""));
    free(state);
    /* Setting it again changes nothing. */
    CHECK(portal_web_views_zoom(text("example.com"), 150, &error));
    CHECK(portal_fake_calls().zoomed == before.zoomed + 1);

    /* A page commits at its host's level, with any port or user. */
    portal_web_committed(text(second), text("http://user@EXAMPLE.com:8080/other"));
    CHECK(shows(second, "\"zoom\":150", NULL));
    portal_web_committed(text(first), text("https://other.org/"));
    CHECK(shows(first, "\"zoom\":100", NULL));
    portal_web_committed(text(first), text("https://other.org/next"));
    CHECK(portal_fake_calls().zoomed == before.zoomed + 3);

    /* 100 forgets the level: a new view from that host keeps its size. */
    CHECK(portal_web_views_zoom(text("example.com"), 100, &error));
    CHECK(shows(second, "\"zoom\":100", NULL));
    char *third = open_web(false);
    portal_web_committed(text(third), text("https://example.com/"));
    state = inspect(third);
    CHECK(state && !strstr(state, "\"zoom\""));
    free(state);

    /* Pages without a host share "". */
    CHECK(portal_web_views_zoom(text(""), 200, &error));
    portal_web_committed(text(third), text("file:///tmp/page.html"));
    CHECK(shows(third, "\"zoom\":200", NULL));
    portal_web_committed(text(first), text("data:text/html,<p>"));
    CHECK(shows(first, "\"zoom\":200", NULL));

    /* A view that fails stops the rest, and the level stays set. */
    char *broken = open_view("web", &error, "broken", "WebKit is gone", NULL);
    char *fourth = open_web(false);
    portal_web_committed(text(broken), text("https://example.org/"));
    portal_web_committed(text(fourth), text("https://example.org/"));
    portal_web_committed(text(first), text("https://example.org/"));
    CHECK(!portal_web_views_zoom(text("example.org"), 50, &error));
    CHECK(says(&error, "WebKit is gone"));
    CHECK(shows(first, "\"zoom\":50", NULL));
    state = inspect(fourth);
    CHECK(state && !strstr(state, "\"zoom\""));
    free(state);
    portal_web_committed(text(fourth), text("https://example.org/next"));
    CHECK(shows(fourth, "\"zoom\":50", NULL));
    close_view(broken);

    CHECK(portal_web_views_zoom(text(""), 100, &error));
    CHECK(portal_web_views_zoom(text("example.org"), 100, &error));
    close_view(first);
    close_view(second);
    close_view(third);
    close_view(fourth);
}

/* What the page in TARGET may do when it asks to use DEVICES from FRAME, in
   a page from ORIGIN. */
static portal_permission media(const char *target, const char *origin, const char *frame,
                               unsigned devices)
{
    return portal_web_media(text(target), text(origin), text(frame), devices);
}

/* The user's grants to a page's origin and frame last until Emacs quits,
   in every view; a hosted app may use no device. */
static void test_camera_and_microphone(void)
{
    const unsigned both = PORTAL_MEDIA_CAMERA | PORTAL_MEDIA_MICROPHONE;
    const char *meet = "https://meet.example.com";
    char *web = open_web(false), *other = open_web(false), *hosted = open_app();
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(media(web, meet, meet, PORTAL_MEDIA_CAMERA) == PORTAL_PERMISSION_ASK);
    CHECK(media(hosted, app_origin, app_origin, PORTAL_MEDIA_MICROPHONE) == PORTAL_PERMISSION_DENY);
    portal_web_media_granted(text(hosted), text(app_origin), text(app_origin),
                             PORTAL_MEDIA_MICROPHONE);
    CHECK(media(hosted, app_origin, app_origin, PORTAL_MEDIA_MICROPHONE) == PORTAL_PERMISSION_DENY);
    CHECK(media("web:0", meet, meet, PORTAL_MEDIA_CAMERA) == PORTAL_PERMISSION_DENY);

    /* A grant covers what it granted, ignoring case, and grows. */
    portal_web_media_granted(text(web), text(meet), text(meet), PORTAL_MEDIA_CAMERA);
    CHECK(media(web, "https://MEET.example.com", meet, PORTAL_MEDIA_CAMERA)
          == PORTAL_PERMISSION_GRANT);
    CHECK(media(web, meet, meet, both) == PORTAL_PERMISSION_ASK);
    CHECK(media(web, meet, meet, PORTAL_MEDIA_MICROPHONE) == PORTAL_PERMISSION_ASK);
    portal_web_media_granted(text(web), text(meet), text(meet), PORTAL_MEDIA_MICROPHONE);
    CHECK(media(web, meet, meet, both) == PORTAL_PERMISSION_GRANT);

    /* Another origin, port or scheme, or another frame's, is asked. */
    CHECK(media(web, "https://meet.example.org", "https://meet.example.org", PORTAL_MEDIA_CAMERA)
          == PORTAL_PERMISSION_ASK);
    CHECK(media(web, "https://meet.example.com:8443", "https://meet.example.com:8443",
                PORTAL_MEDIA_CAMERA) == PORTAL_PERMISSION_ASK);
    CHECK(media(web, "http://meet.example.com", "http://meet.example.com", PORTAL_MEDIA_CAMERA)
          == PORTAL_PERMISSION_ASK);
    CHECK(media(web, meet, "https://ads.example.net", PORTAL_MEDIA_CAMERA) == PORTAL_PERMISSION_ASK);
    portal_web_media_granted(text(web), text(meet), text("https://ads.example.net"),
                             PORTAL_MEDIA_CAMERA);
    CHECK(media(web, meet, "https://ads.example.net", PORTAL_MEDIA_CAMERA)
          == PORTAL_PERMISSION_GRANT);
    CHECK(media(web, "https://ads.example.net", "https://ads.example.net", PORTAL_MEDIA_CAMERA)
          == PORTAL_PERMISSION_ASK);

    CHECK(same_calls(portal_fake_calls(), before));
    CHECK(sent(web, ""));

    /* Every view shares the grants, and they outlive the view granted in. */
    close_view(web);
    CHECK(media(other, meet, meet, both) == PORTAL_PERMISSION_GRANT);
    /* A view that is gone grants nothing. */
    portal_web_media_granted(text("web:0"), text("https://gone.example.com"),
                             text("https://gone.example.com"), PORTAL_MEDIA_CAMERA);
    CHECK(media(other, "https://gone.example.com", "https://gone.example.com", PORTAL_MEDIA_CAMERA)
          == PORTAL_PERMISSION_ASK);
    close_view(other);
    close_view(hosted);
}

static void test_the_shared_links_script(void)
{
    portal_string source = portal_web_links_script();
    CHECK(source.length > 100 && strlen(source.data) == source.length);
    CHECK(!strncmp(source.data, "// SPDX-License-Identifier", 26));
    CHECK(strstr(source.data, "\n(report) => {\n") && !strstr(source.data, "webkit"));
    CHECK(strstr(source.data, "file:"));
}

int main(void)
{
    int fds[2];
    if (pipe(fds) || fcntl(fds[0], F_SETFL, O_NONBLOCK) == -1)
        abort();
    records = fds[0];
    CHECK(portal_channel_connect(fds[1]));
    test_loading();
    test_urls_are_the_platforms_spelling();
    test_the_address_survives_a_failed_load();
    test_messages_keep_their_order_under_one_record();
    test_only_the_apps_main_frame_may_post();
    test_the_core_reports_pages_and_failures();
    test_ordinary_pages_have_no_bridge_to_their_page();
    test_navigation_decisions();
    test_local_links_go_to_emacs();
    test_history_steps();
    test_messages_to_the_app_and_stale_completions();
    test_a_closed_view_hears_nothing();
    test_an_echoing_app();
    test_the_shared_links_script();
    test_appearance_at_open();
    test_an_appearance_reaches_every_web_view();
    test_pages_open_windows();
    test_windows_that_do_not_open();
    test_downloads();
    test_finding();
    test_zoom_per_host();
    test_camera_and_microphone();
    CHECK(!portal_fake_calls().misused);
    portal_channel_connect(-1);
    close(records);
    if (failures) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    puts("Web views' rules and the bridge passed");
    return 0;
}
