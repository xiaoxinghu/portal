;;; portal-tasks-gui-tests.el --- The task browser in real WebKit -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Task pages run on the real app host from ./build.sh.  Load the test-only
;; event injector first.
(require 'portal-gui-testing)

(defconst portal-tasks-gui--png
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1sAAAAASUVORK5CYII="
  "A one-pixel PNG, in base64.")

(defmacro portal-tasks-gui--root (&rest body)
  "Run BODY with the task list of a task root that has both layouts.
The root is `portal-markdown-gui--directory'."
  (declare (indent 0))
  `(portal-test--with-web
     (skip-unless (file-executable-p portal-server-program))
     (let ((portal-markdown-gui--directory (file-truename (make-temp-file "portal-tasks-gui-" t)))
           (display-buffer-alist nil))
       (unwind-protect
           (let ((paragraphs (lambda (word)
                               (mapconcat (lambda (n) (format "%s %d.\n\n" word n))
                                          (number-sequence 1 120)))))
             (dotimes (n 60)
               (portal-markdown-gui--write (format "task-%02d.md" n)
                                           (format "---\nstatus: todo\n---\n# Task %d\n" n)))
             (portal-markdown-gui--write
              "fix-search.md"
              (concat "---\nstatus: todo\n---\n# Fix search\n\n"
                      "[Navigation](<markdown-navigation/content.md#next-steps>) "
                      "[Log](<assets/search log.txt#L2>)\n\n![Search](assets/search.png)\n\n"
                      (funcall paragraphs "Detail")))
             (portal-markdown-gui--write
              "markdown-navigation/content.md"
              (concat "---\nstatus: todo\n---\n# Navigation\n\n![Mockup](mockup.png)\n\n"
                      (funcall paragraphs "Step") "## Next steps\n\n"
                      "[Prototype](prototype/index.html) [Back to search](../fix-search.md)\n"))
             (portal-markdown-gui--write "markdown-navigation/prototype/index.html"
                                         "<title>Prototype</title><script>document.title = 'Ran';</script>\n")
             (portal-markdown-gui--write "shipped.md" "---\nstatus: done\n---\n# Shipped\n")
             (portal-markdown-gui--write "assets/search log.txt" "one\ntwo\nthree\n")
             (dolist (image '("assets/search.png" "markdown-navigation/mockup.png"))
               (let ((coding-system-for-write 'binary))
                 (write-region (base64-decode-string portal-tasks-gui--png)
                               nil (portal-markdown-gui--file image))))
             (select-frame-set-input-focus (selected-frame))
             (sit-for 0.1)
             (should (portal-view--with-frame-title (selected-frame)
                                                    #'portal-test-native-target-frame))
             (portal-tasks-browser portal-markdown-gui--directory)
             (portal-test--wait-for-page "Tasks")
             ,@body)
         (portal-test-native-target-frame nil)
         (setq unread-command-events nil)
         (dolist (buffer (buffer-list))
           (when (and (buffer-file-name buffer)
                      (file-in-directory-p (buffer-file-name buffer) portal-markdown-gui--directory))
             (kill-buffer buffer)))
         (delete-directory portal-markdown-gui--directory t)))))

(defun portal-tasks-gui--link (text)
  "Follow the page's link whose text contains TEXT, as a page script would."
  (portal-excalidraw-gui--js
   (format "[...document.links].find(a => a.textContent.includes(%S)).click(); return true;" text)))

(defun portal-tasks-gui--route (text)
  "Wait until the buffer's app host path contains TEXT."
  (portal-terminal-test--wait (lambda () (string-search text portal-web--hosted-path))))

(defun portal-tasks-gui--image-loaded ()
  "Return non-nil once the page's first image has loaded."
  (portal-excalidraw-gui--js
   "const image = document.querySelector('img'); return !!image && image.complete && image.naturalWidth === 1;"))

(defun portal-tasks-gui--text ()
  "Return the page's visible text."
  (portal-excalidraw-gui--js "return document.body.innerText;"))

(defun portal-tasks-gui--waits (title)
  "Return what the list row titled TITLE waits for, \"\" when ready, or :null without one."
  (portal-excalidraw-gui--js
   (format "const row = [...document.querySelectorAll('li')].find(li => li.querySelector('.title')?.textContent === %S); return row ? row.querySelector('.waits')?.textContent ?? '' : null;"
           title)))

(defun portal-tasks-gui--node (label)
  "Return JavaScript for the tree item whose row label is LABEL."
  (format "[...document.querySelectorAll('li')].find(li => li.querySelector('.title, .name')?.textContent === %S)"
          label))

(defun portal-tasks-gui--shown (label)
  "Return non-nil when the tree row labeled LABEL is on the page and rendered."
  (eq t (portal-excalidraw-gui--js
         (format "const e = %s?.querySelector('.title, .name'); return !!e && e.checkVisibility();"
                 (portal-tasks-gui--node label)))))

(defun portal-tasks-gui--left (label)
  "Return the left edge of the rendered tree row labeled LABEL."
  (should (portal-tasks-gui--shown label))
  (portal-excalidraw-gui--js
   (format "return Math.round(%s.querySelector('.row').getBoundingClientRect().left);"
           (portal-tasks-gui--node label))))

(defun portal-tasks-gui--open (label)
  "Return non-nil when the disclosure below LABEL's tree row is open."
  (eq t (portal-excalidraw-gui--js
         (format "return %s.querySelector(':scope > details').open;" (portal-tasks-gui--node label)))))

(defun portal-tasks-gui--toggle (label)
  "Press the real Return key on the disclosure below LABEL's tree row."
  (portal-input-focus)
  (should (eq t (portal-excalidraw-gui--js
                 (format "const s = %s.querySelector(':scope > details > summary'); s.focus(); return document.activeElement === s;"
                         (portal-tasks-gui--node label)))))
  (should (portal-test-native-key 36 0 "\r"))
  (portal-test-native-key 53 (ash 1 20) "\e")
  (portal-integration-test--emacs-input))

(ert-deftest portal-tasks-gui-list-and-detail-keep-history-filter-and-position ()
  (portal-tasks-gui--root
    (should-not (alist-get 'back (portal-markdown-gui--state)))
    (should-not (string-match-p "Shipped" (portal-excalidraw-gui--js "return document.body.innerText;")))
    (portal-excalidraw-gui--js "window.scrollTo(0, 800); return true;")
    (should (= (portal-markdown-gui--scroll) 800))
    (portal-tasks-gui--link "Fix search")
    (portal-test--wait-for-page "Fix search")
    (portal-tasks-gui--route "&task=fix-search")
    (portal-terminal-test--wait #'portal-tasks-gui--image-loaded)
    (portal-excalidraw-gui--js "window.scrollTo(0, 600); return true;")
    ;; Back and forward restore the list and the detail at their positions.
    (call-interactively (key-binding "l"))
    (portal-test--wait-for-page "Tasks")
    (portal-terminal-test--wait (lambda () (= (portal-markdown-gui--scroll) 800)))
    (portal-tasks-gui--route "?root=")
    (should-not (string-search "&task=" portal-web--hosted-path))
    (call-interactively (key-binding "r"))
    (portal-test--wait-for-page "Fix search")
    (portal-terminal-test--wait (lambda () (= (portal-markdown-gui--scroll) 600)))
    ;; g reloads the page on screen from the saved file.
    (portal-markdown-gui--write "fix-search.md" "---\nstatus: todo\ntitle: Fix search now\n---\nSaved.\n")
    (call-interactively (key-binding "g"))
    (portal-test--wait-for-page "Fix search now")
    ;; The filter survives list, detail and the Tasks link.
    (portal-web-back)
    (portal-test--wait-for-page "Tasks")
    (portal-tasks-gui--link "Show completed")
    (portal-tasks-gui--route "&show=all")
    (portal-test--wait-for-page "Tasks")
    (portal-tasks-gui--link "Shipped")
    (portal-test--wait-for-page "Shipped")
    (portal-tasks-gui--route "&task=shipped&show=all")
    (portal-tasks-gui--link "Tasks")
    (portal-test--wait-for-page "Tasks")
    (should (string-match-p "Hide completed" (portal-excalidraw-gui--js "return document.body.innerText;")))
    ;; A new link after going back discards the old forward branch.
    (portal-web-back)
    (portal-test--wait-for-page "Shipped")
    (should (alist-get 'forward (portal-markdown-gui--state)))
    (portal-tasks-gui--link "Tasks")
    (portal-test--wait-for-page "Tasks")
    (should-not (alist-get 'forward (portal-markdown-gui--state)))
    (should (file-exists-p (portal-markdown-gui--file "shipped.md")))))

(ert-deftest portal-tasks-gui-task-links-images-and-attachment-handoff ()
  (portal-tasks-gui--root
    (let ((tasks (current-buffer))
          (target (portal-view-target))
          (origin (selected-window)))
      (portal-tasks-gui--link "Fix search")
      (portal-test--wait-for-page "Fix search")
      ;; A task link opens its detail in the same view, at the heading.
      (portal-tasks-gui--link "Navigation")
      (portal-test--wait-for-page "Navigation")
      (portal-tasks-gui--route "&task=markdown-navigation")
      (portal-terminal-test--wait (lambda () (> (portal-markdown-gui--scroll) 1000)))
      (portal-terminal-test--wait #'portal-tasks-gui--image-loaded)
      (portal-excalidraw-gui--js "window.marker = 'kept'; return true;")
      ;; Mock-up HTML opens as source in Emacs, in one click, and never runs.
      (portal-input-focus)
      (should (portal-input--action "focused" target))
      (portal-markdown-gui--click-link "Prototype")
      (portal-markdown-gui--event 'portal-web-follow)
      (should (equal buffer-file-name (portal-markdown-gui--file "markdown-navigation/prototype/index.html")))
      (should-not (eq major-mode 'portal-web-mode))
      (should-not (eq (selected-window) origin))
      (should (eq (window-buffer origin) tasks))
      (should-not (portal-input--action "focused" target))
      (portal-integration-test--emacs-input)
      (should (equal (plist-get (portal--inspect target) :title) "Navigation"))
      (should (equal (portal-excalidraw-gui--js "return window.marker;") "kept"))
      ;; A standalone task's attachment opens at its line; history is intact.
      (select-window origin)
      (portal-web-back)
      (portal-test--wait-for-page "Fix search")
      (portal-terminal-test--wait #'portal-tasks-gui--image-loaded)
      (portal-markdown-gui--click-link "Log")
      (portal-markdown-gui--event 'portal-input-select)
      (portal-markdown-gui--event 'portal-web-follow)
      (should (equal buffer-file-name (portal-markdown-gui--file "assets/search log.txt")))
      (should (= (line-number-at-pos) 2))
      (select-window origin)
      (should (alist-get 'back (portal-markdown-gui--state)))
      (should (alist-get 'forward (portal-markdown-gui--state))))))

(ert-deftest portal-tasks-gui-dependencies-readiness-and-links ()
  (portal-tasks-gui--root
    ;; A saved task waits for one unfinished and one completed task.
    (portal-markdown-gui--write
     "release.md"
     "---\nid: release-notes\nstatus: todo\ndepends_on: [shipped, fix-search]\n---\n# Release notes\n")
    (call-interactively (key-binding "g"))
    (portal-terminal-test--wait
     (lambda () (equal (portal-tasks-gui--waits "Release notes") "after 1")))
    (should (equal (portal-tasks-gui--waits "Fix search") ""))
    ;; A blocked row is dimmed, and its title keeps a usable width.
    (should (portal-excalidraw-gui--js
             "const row = [...document.querySelectorAll('.row.blocked')].find(a => a.textContent.includes('Release notes')); return getComputedStyle(row.querySelector('.title')).color !== getComputedStyle(document.body).color && row.querySelector('.title').getBoundingClientRect().width > row.getBoundingClientRect().width / 2;"))
    ;; Its page links its prerequisites, including completed ones.
    (portal-tasks-gui--link "Release notes")
    (portal-test--wait-for-page "Release notes")
    (portal-tasks-gui--route "&task=release-notes")
    (let ((text (portal-tasks-gui--text)))
      (should (string-match-p "release-notes" text))
      (should (string-match-p "blocked" text))
      (should (string-match-p "Shipped shipped done" text))
      (should (string-match-p "Fix search fix-search todo" text)))
    (portal-tasks-gui--link "Shipped")
    (portal-test--wait-for-page "Shipped")
    (portal-tasks-gui--route "&task=shipped")
    (should-not (string-search "show=all" portal-web--hosted-path))
    ;; A completed task shows what it blocks, and no readiness.
    (should (portal-excalidraw-gui--js
             "return !document.querySelector('.readiness') && document.body.innerText.includes('Blocks');"))
    (portal-tasks-gui--link "Release notes")
    (portal-test--wait-for-page "Release notes")
    (call-interactively (key-binding "l"))
    (portal-test--wait-for-page "Shipped")
    (call-interactively (key-binding "r"))
    (portal-test--wait-for-page "Release notes")
    ;; The view and completed filter survive the list and dependency links.
    (portal-tasks-gui--link "Tasks")
    (portal-test--wait-for-page "Tasks")
    (portal-tasks-gui--link "Execution")
    (portal-tasks-gui--route "&view=execution")
    (portal-test--wait-for-page "Tasks")
    (portal-tasks-gui--link "Show completed")
    (portal-tasks-gui--route "&view=execution&show=all")
    (portal-test--wait-for-page "Tasks")
    (should (portal-excalidraw-gui--js
             "return document.querySelector('.completed h2').textContent === 'Completed' && document.querySelector('.completed').innerText.includes('Shipped');"))
    ;; A completed task's title is struck through.
    (should (portal-excalidraw-gui--js
             "const title = document.querySelector('.completed .row.done .title'); return title.textContent === 'Shipped' && getComputedStyle(title).textDecorationLine.includes('line-through');"))
    (portal-tasks-gui--link "Release notes")
    (portal-test--wait-for-page "Release notes")
    (portal-tasks-gui--route "&task=release-notes&view=execution&show=all")
    (portal-tasks-gui--link "Fix search")
    (portal-test--wait-for-page "Fix search")
    (portal-tasks-gui--route "&task=fix-search&view=execution&show=all")
    ;; Completing a prerequisite and reloading makes its dependent ready.
    (portal-web-back)
    (portal-test--wait-for-page "Release notes")
    (portal-markdown-gui--write "fix-search.md" "---\nstatus: done\n---\n# Fix search\n")
    (call-interactively (key-binding "g"))
    (portal-terminal-test--wait
     (lambda () (portal-excalidraw-gui--js "return document.querySelector('.readiness')?.textContent === 'ready';")))
    (portal-tasks-gui--route "&task=release-notes&view=execution&show=all")
    (portal-tasks-gui--link "Tasks")
    (portal-test--wait-for-page "Tasks")
    (portal-terminal-test--wait (lambda () (equal (portal-tasks-gui--waits "Release notes") "")))
    (should (portal-excalidraw-gui--js
             "return document.querySelector('.completed').innerText.includes('Fix search');"))))

(ert-deftest portal-tasks-gui-reload-after-an-app-host-restart ()
  (portal-tasks-gui--root
    (portal-tasks-gui--link "Execution")
    (portal-tasks-gui--route "&view=execution")
    (portal-test--wait-for-page "Tasks")
    (portal-tasks-gui--link "Fix search")
    (portal-test--wait-for-page "Fix search")
    (portal-tasks-gui--route "&task=fix-search&view=execution")
    (let ((old (portal-server-url)))
      (portal-restart-server)
      (portal-terminal-test--wait (lambda () (and (portal-server-url)
                                                  (not (equal (portal-server-url) old)))))
      ;; The page stays; g loads the same route from the new host.
      (should (equal (plist-get (portal--inspect (portal-view-target)) :title) "Fix search"))
      (call-interactively (key-binding "g"))
      (portal-test--wait-for-page "Fix search")
      (should (string-prefix-p (portal-server-url)
                               (plist-get (portal--inspect (portal-view-target)) :url)))
      (should (string-search "&task=fix-search&view=execution" portal-web--hosted-path)))))

(ert-deftest portal-tasks-gui-nested-tree-disclosure-views-and-moves ()
  (portal-tasks-gui--root
    (portal-markdown-gui--write "big refactor/extract.md" "---\nid: extract-c\nstatus: todo\n---\n# Extract C\n")
    (portal-markdown-gui--write "big refactor/implement/content.md"
                                "---\nstatus: todo\ndepends_on: [extract-c]\n---\n# Implement\n")
    (portal-markdown-gui--write "big refactor/implement/notes.md" "# Notes\n")
    (portal-markdown-gui--write "epic/content.md" "---\nstatus: done\n---\n# Epic\n")
    (portal-markdown-gui--write "epic/open.md" "---\nstatus: todo\n---\n# Open child\n")
    (call-interactively (key-binding "g"))
    (portal-terminal-test--wait (lambda () (portal-tasks-gui--shown "Open child")))
    ;; Each level is indented, and a completed parent stays above its
    ;; unfinished task while other completed tasks are hidden.
    (should (> (portal-tasks-gui--left "Extract C") (+ (portal-tasks-gui--left "big refactor") 10)))
    (should (= (portal-tasks-gui--left "Extract C") (portal-tasks-gui--left "Implement")))
    (should (> (portal-tasks-gui--left "Open child") (+ (portal-tasks-gui--left "Epic") 10)))
    (should (equal (portal-excalidraw-gui--js
                    (format "return %s.querySelector('.status').textContent;" (portal-tasks-gui--node "Epic")))
                   "done"))
    (should-not (portal-tasks-gui--shown "Shipped"))
    (should-not (portal-tasks-gui--shown "Notes"))
    ;; A parent task's link, its buttons and its disclosure are separate
    ;; keyboard stops.
    (portal-input-focus)
    (portal-excalidraw-gui--js
     (format "%s.querySelector('a.row').focus(); return true;" (portal-tasks-gui--node "Epic")))
    (dolist (label '("Reopen Epic" "Edit Epic in Emacs" "Tasks in Epic"))
      (should (portal-test-native-key 48 0 "\t"))
      (portal-terminal-test--wait
       (lambda () (equal (portal-excalidraw-gui--js "return document.activeElement.getAttribute('aria-label');")
                         label))))
    (portal-test-native-key 53 (ash 1 20) "\e")
    (portal-integration-test--emacs-input)
    ;; Real keys operate the disclosures of groups and parent tasks.
    (portal-tasks-gui--toggle "big refactor")
    (portal-terminal-test--wait (lambda () (not (portal-tasks-gui--shown "Extract C"))))
    (should (portal-tasks-gui--shown "big refactor"))
    (portal-tasks-gui--toggle "Epic")
    (portal-terminal-test--wait (lambda () (not (portal-tasks-gui--shown "Open child"))))
    (should (portal-tasks-gui--shown "Epic"))
    (should-not (string-search "&task=" portal-web--hosted-path))
    (portal-tasks-gui--toggle "Epic")
    (portal-terminal-test--wait (lambda () (portal-tasks-gui--shown "Open child")))
    (portal-tasks-gui--toggle "Epic")
    (portal-terminal-test--wait (lambda () (not (portal-tasks-gui--shown "Open child"))))
    ;; Back returns to the list as it was left; g expands it again.
    (portal-tasks-gui--link "Epic")
    (portal-test--wait-for-page "Epic")
    (portal-tasks-gui--route "&task=epic")
    (call-interactively (key-binding "l"))
    (portal-test--wait-for-page "Tasks")
    (portal-terminal-test--wait (lambda () (portal-tasks-gui--shown "Epic")))
    (should-not (portal-tasks-gui--open "big refactor"))
    (should-not (portal-tasks-gui--open "Epic"))
    (call-interactively (key-binding "g"))
    (portal-terminal-test--wait (lambda () (portal-tasks-gui--shown "Extract C")))
    (should (portal-tasks-gui--open "Epic"))
    ;; The execution view orders work across folders and shows where it is.
    (portal-tasks-gui--link "Execution")
    (portal-tasks-gui--route "&view=execution")
    (portal-test--wait-for-page "Tasks")
    (should (equal (portal-excalidraw-gui--js
                    "return [...document.querySelectorAll('ol.tasks .title')].slice(0, 4).map(e => e.textContent + '@' + (e.nextElementSibling?.classList.contains('folder') ? e.nextElementSibling.textContent : '')).join('|');")
                   "Open child@Epic|Extract C@big refactor|Implement@big refactor|Fix search@"))
    ;; The view and filter survive task, dependency and folder links.
    (portal-tasks-gui--link "Show completed")
    (portal-tasks-gui--route "&view=execution&show=all")
    (portal-test--wait-for-page "Tasks")
    (portal-tasks-gui--link "Implement")
    (portal-test--wait-for-page "Implement")
    (portal-tasks-gui--route "implement&view=execution&show=all")
    (portal-tasks-gui--link "Extract C")
    (portal-test--wait-for-page "Extract C")
    (portal-tasks-gui--route "&task=extract-c&view=execution&show=all")
    (portal-tasks-gui--link "big refactor")
    (portal-test--wait-for-page "Tasks")
    (portal-terminal-test--wait (lambda () (not (string-search "&task=" portal-web--hosted-path))))
    (portal-tasks-gui--route "&view=execution&show=all")
    (should (equal (portal-excalidraw-gui--js "return location.hash;") ""))
    (call-interactively (key-binding "l"))
    (portal-test--wait-for-page "Extract C")
    (call-interactively (key-binding "l"))
    (portal-test--wait-for-page "Implement")
    (call-interactively (key-binding "r"))
    (portal-test--wait-for-page "Extract C")
    (portal-tasks-gui--route "&task=extract-c&view=execution&show=all")
    ;; A saved move shows on reload; the task keeps its page and dependents.
    (make-directory (portal-markdown-gui--file "later"))
    (rename-file (portal-markdown-gui--file "big refactor/extract.md")
                 (portal-markdown-gui--file "later/extract.md"))
    (call-interactively (key-binding "g"))
    (portal-terminal-test--wait
     (lambda () (equal (portal-excalidraw-gui--js "return document.querySelector('.breadcrumbs').textContent;")
                       "Tasks › later")))
    (portal-tasks-gui--link "Tasks")
    (portal-test--wait-for-page "Tasks")
    (portal-tasks-gui--link "Tree")
    (portal-tasks-gui--route "&show=all")
    (portal-terminal-test--wait (lambda () (portal-tasks-gui--shown "later")))
    (should-not (string-search "view=" portal-web--hosted-path))
    (should (> (portal-tasks-gui--left "Extract C") (+ (portal-tasks-gui--left "later") 10)))
    ;; In the tree view, a group's breadcrumb leads to its row, whose ID is
    ;; percent-encoded like the fragment that names it.
    (portal-tasks-gui--link "Implement")
    (portal-test--wait-for-page "Implement")
    (portal-tasks-gui--link "big refactor")
    (portal-test--wait-for-page "Tasks")
    (portal-terminal-test--wait
     (lambda () (equal (portal-excalidraw-gui--js "return document.querySelector(':target')?.id ?? '';")
                       "folder-big%20refactor")))
    (should (> (portal-markdown-gui--scroll) 0))
    (should (string-search "&show=all" portal-web--hosted-path))
    (should (equal (portal-tasks-gui--waits "Implement") "after 2"))
    (should (portal-tasks-gui--shown "Shipped"))))


;; Operations.

(defun portal-tasks-gui--run (type)
  "Wait for a queued event of TYPE, then run the queued events up to it, in order.
The test holds the command loop, which would otherwise run them, and then
make the selected pane's buffer current."
  (condition-case err
      (portal-terminal-test--wait
       (lambda () (seq-find (lambda (event) (eq (car-safe event) type)) unread-command-events)))
    (error (message "No %s event; queued %S; page notice %S" type unread-command-events
                    (portal-tasks-gui--notice))
           (signal (car err) (cdr err))))
  ;; Other input, such as keys, stays queued.
  (let (event)
    (while (not (eq (car-safe event) type))
      (setq event (seq-find (lambda (event) (memq (car-safe event) (list type 'portal-input-select)))
                            unread-command-events))
      (setq unread-command-events (delq event unread-command-events))
      (funcall (lookup-key global-map (vector (car event))) event)))
  (set-buffer (window-buffer (selected-window))))

(defun portal-tasks-gui--button (task op)
  "Return JavaScript for TASK's OP button, status or edit."
  (format "document.querySelector('button[data-op=%S][data-task=%S]')" op task))

(defun portal-tasks-gui--click (task op)
  "Click TASK's OP button with the real mouse, scrolling it into view first."
  (let ((point (portal-excalidraw-gui--js
                (format "const b = %s; b.scrollIntoView({block: 'center'}); const r = b.getBoundingClientRect(); return [Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2)];"
                        (portal-tasks-gui--button task op)))))
    (should (portal-test-native-click (aref point 0) (aref point 1)))))

(defun portal-tasks-gui--focused ()
  "Return a description of the page's focused element."
  (portal-excalidraw-gui--js
   "const e = document.activeElement; return e.dataset.op ? e.dataset.op + ' ' + e.dataset.task + ' ' + e.textContent : (e.querySelector('.title')?.textContent ?? e.tagName);"))

(defun portal-tasks-gui--notice ()
  "Return the page's notice of what the last action did, or \"\"."
  (portal-excalidraw-gui--js "return document.querySelector('.task-notice')?.textContent ?? '';"))

(defun portal-tasks-gui--status (name)
  "Return the saved status of task file NAME in the test root."
  (with-temp-buffer
    (insert-file-contents (portal-markdown-gui--file name))
    (and (re-search-forward "^status: \\([a-z]+\\)" nil t) (match-string 1))))

(ert-deftest portal-tasks-gui-complete-and-reopen-in-place-by-mouse-and-keyboard ()
  (portal-tasks-gui--root
    (let ((target (portal-view-target))
          (path portal-web--hosted-path)
          (history (portal-excalidraw-gui--js "return history.length;")))
      ;; A real click completes a row; the page refreshes in place, and the
      ;; filter hides the row, leaving focus on the row that took its place.
      (portal-tasks-gui--click "task-10" "status")
      (let ((scroll (portal-markdown-gui--scroll)))
        (should (> scroll 0))
        (portal-tasks-gui--run 'portal-action)
        (portal-terminal-test--wait (lambda () (not (portal-tasks-gui--shown "Task 10"))))
        (should (equal (portal-tasks-gui--status "task-10.md") "done"))
        (should (= (portal-markdown-gui--scroll) scroll)))
      (portal-terminal-test--wait
       (lambda () (string-search "Completed “Task 10”." (portal-tasks-gui--notice))))
      (should (equal (portal-tasks-gui--focused) "Task 11"))
      (should (portal-input--action "focused" target))
      (should (equal portal-web--hosted-path path))
      (should (equal (portal-excalidraw-gui--js "return history.length;") history))
      ;; Tab reaches the row's buttons, and Return runs one without opening the task.
      (should (portal-test-native-key 48 0 "\t"))
      (portal-terminal-test--wait
       (lambda () (equal (portal-tasks-gui--focused) "status task-11 Complete")))
      (should (portal-test-native-key 36 0 "\r"))
      (portal-tasks-gui--run 'portal-action)
      (portal-terminal-test--wait (lambda () (not (portal-tasks-gui--shown "Task 11"))))
      (should (equal (portal-tasks-gui--status "task-11.md") "done"))
      (should (equal (portal-tasks-gui--focused) "Task 12"))
      (should (equal portal-web--hosted-path path))
      ;; A completed task's page reopens it in place, keeping focus on its button.
      (portal-tasks-gui--link "Show completed")
      (portal-test--wait-for-page "Tasks")
      (portal-tasks-gui--link "Task 10")
      (portal-test--wait-for-page "Task 10")
      (setq history (portal-excalidraw-gui--js "return history.length;"))
      (should (equal (portal-excalidraw-gui--js "return document.querySelector('.task-state .status').textContent;") "done"))
      (portal-excalidraw-gui--js (format "%s.focus(); return true;" (portal-tasks-gui--button "task-10" "status")))
      (should (equal (portal-tasks-gui--focused) "status task-10 Reopen"))
      (should (portal-test-native-key 36 0 "\r"))
      (portal-tasks-gui--run 'portal-action)
      (portal-terminal-test--wait
       (lambda () (equal (portal-excalidraw-gui--js "return document.querySelector('.task-state .status').textContent;") "todo")))
      (should (equal (portal-tasks-gui--status "task-10.md") "todo"))
      (should (equal (portal-tasks-gui--focused) "status task-10 Complete"))
      (should (string-search "Reopened “Task 10”." (portal-tasks-gui--notice)))
      (should (equal (portal-excalidraw-gui--js "return history.length;") history))
      (should (portal-input--action "focused" target))
      (portal-test-native-key 53 (ash 1 20) "\e")
      (portal-integration-test--emacs-input))))

(ert-deftest portal-tasks-gui-edit-save-refresh-and-revalidate-history ()
  (portal-tasks-gui--root
    (let ((tasks (current-buffer))
          (target (portal-view-target))
          (origin (selected-window))
          (source (portal-markdown-gui--file "fix-search.md")))
      ;; Edit in Emacs opens the source beside the page, with the keyboard.
      (portal-input-focus)
      (portal-tasks-gui--click "fix-search" "edit")
      (portal-tasks-gui--run 'portal-action)
      (should (equal buffer-file-name source))
      (should-not (eq (selected-window) origin))
      (should (eq (window-buffer origin) tasks))
      (should-not (portal-input--action "focused" target))
      (portal-integration-test--emacs-input)
      ;; Saving it refreshes the page in place; Emacs keeps the keyboard.
      (goto-char (point-min))
      (re-search-forward "^# Fix search$")
      (insert " soon")
      (save-buffer)
      (portal-terminal-test--wait
       (lambda () (with-selected-window origin (portal-tasks-gui--shown "Fix search soon"))))
      (should (equal buffer-file-name source))
      (should-not (portal-input--action "focused" target))
      (portal-integration-test--emacs-input)
      (should-not (alist-get 'back (with-selected-window origin (portal-markdown-gui--state))))
      ;; A hidden page shows saved changes once it is shown again.
      (with-selected-window origin (switch-to-buffer "*scratch*"))
      (with-current-buffer (find-file-noselect (portal-markdown-gui--file "task-05.md"))
        (goto-char (point-max))
        (insert "# Task 5 renamed\n")
        (goto-char (point-min))
        (flush-lines "^# Task 5$")
        (save-buffer)
        (kill-buffer))
      (with-selected-window origin (switch-to-buffer tasks))
      (portal-terminal-test--wait
       (lambda () (with-selected-window origin (portal-tasks-gui--shown "Task 5 renamed"))))
      (portal-preview-return)
      (should (eq (current-buffer) tasks))
      ;; Completing a task on its page leaves no stale list behind Back.
      (portal-tasks-gui--link "Fix search soon")
      (portal-test--wait-for-page "Fix search soon")
      (portal-excalidraw-gui--js (format "%s.click(); return true;" (portal-tasks-gui--button "fix-search" "status")))
      (portal-tasks-gui--run 'portal-action)
      (portal-terminal-test--wait
       (lambda () (equal (portal-excalidraw-gui--js "return document.querySelector('.task-state .status').textContent;") "done")))
      (portal-web-back)
      (portal-test--wait-for-page "Tasks")
      (portal-terminal-test--wait (lambda () (not (portal-tasks-gui--shown "Fix search soon"))))
      ;; Unsaved changes in Emacs stop an action, which says why.
      (portal-web-forward)
      (portal-test--wait-for-page "Fix search soon")
      (with-current-buffer (get-file-buffer source)
        (goto-char (point-max))
        (insert "Unsaved.\n"))
      (portal-excalidraw-gui--js (format "%s.click(); return true;" (portal-tasks-gui--button "fix-search" "status")))
      (portal-tasks-gui--run 'portal-action)
      (portal-terminal-test--wait
       (lambda () (string-search "unsaved changes" (portal-tasks-gui--notice))))
      (should (equal (portal-excalidraw-gui--js "return document.querySelector('.task-notice').classList.contains('action-error') && document.querySelector('.task-state .status').textContent;") "done"))
      (should (equal (portal-tasks-gui--status "fix-search.md") "done"))
      (with-current-buffer (get-file-buffer source)
        (should (buffer-modified-p))
        (set-buffer-modified-p nil)))))

(ert-deftest portal-tasks-gui-implement-post-starts-a-native-terminal ()
  (portal-test--with-web
    (let* ((directory (file-truename (make-temp-file "portal-launch ' é " t)))
           (root (expand-file-name "tasks" directory))
           (source (expand-file-name "nested dir/task ' é.md" root))
           (program (expand-file-name "claude probe" directory))
           (receipt (expand-file-name "launch.json" directory))
           (portal-tasks-claude-program program)
           (display-buffer-alist nil))
      (unwind-protect
          (progn
            (make-directory (expand-file-name ".git" directory))
            (make-directory (file-name-directory source) t)
            (with-temp-file source (insert "---\nid: launch-test\nstatus: todo\n---\n# Launch task\n"))
            ;; A local stand-in captures argv/cwd from the actual Ghostty PTY.
            ;; No Claude invocation or model request is made by this test.
            (with-temp-file program
              (insert "#!/usr/bin/python3\nimport json,os,sys,time\n"
                      "with open('launch.json','w') as f: json.dump({'cwd':os.getcwd(),'args':sys.argv[1:],'terminal':os.isatty(0)},f)\n"
                      "print('PORTAL_LAUNCH_OK',flush=True)\ntime.sleep(60)\n"))
            (set-file-modes program #o700)
            (select-frame-set-input-focus (selected-frame))
            (sit-for 0.1)
            (should (portal-view--with-frame-title (selected-frame) #'portal-test-native-target-frame))
            (portal-tasks-browser root)
            (portal-test--wait-for-page "Tasks")
            (portal-tasks-gui--link "Launch task")
            (portal-test--wait-for-page "Launch task")
            (let* ((page (current-buffer))
                   (target portal-view--target)
                   (point (portal-excalidraw-gui--js
                           "const b=document.querySelector('.task-action button'); b.scrollIntoView(); const r=b.getBoundingClientRect(); return [Math.round(r.left+r.width/2), Math.round(r.top+r.height/2)];")))
              (should (portal-test-native-click (aref point 0) (aref point 1)))
              (condition-case err
                  (portal-terminal-test--wait
                   (lambda () (seq-find (lambda (event) (eq (car-safe event) 'portal-action))
                                        unread-command-events)))
                (error (message "Action page: %s" (portal-tasks-gui--text))
                       (signal (car err) (cdr err))))
              (let ((event (seq-find (lambda (event) (eq (car-safe event) 'portal-action))
                                     unread-command-events)))
                (setq unread-command-events (delq event unread-command-events))
                (portal-actions--dispatch event))
              (condition-case err
                  (portal-terminal-test--wait (lambda () (file-exists-p receipt)))
                (error (message "Terminal launch output: %s"
                                (portal--terminal-text
                                 (buffer-local-value 'portal-view--target
                                                     (car (portal-view-buffers 'terminal)))))
                       (message "Action result: %s" (portal-tasks-gui--text))
                       (signal (car err) (cdr err))))
              (let ((launch (with-temp-buffer (insert-file-contents receipt)
                                              (json-parse-buffer :object-type 'plist)))
                    (terminal (car (portal-view-buffers 'terminal))))
                (should (file-equal-p (plist-get launch :cwd) directory))
                (should (eq (plist-get launch :terminal) t))
                (should (equal (plist-get launch :args)
                               ["--dangerously-skip-permissions" "implement @\"tasks/nested dir/task ' é.md\""]))
                (should (eq (window-buffer (selected-window)) terminal))
                (should (plist-get (portal--inspect (buffer-local-value 'portal-view--target terminal)) :focused))
                (portal-test--wait-for-page "Launch task" target)
                (should (get-buffer-window page))
                (should (string-search "Claude terminal opened" (portal-tasks-gui--text)))
                ;; The form redirects to GET. Reloading the result never launches again.
                (with-current-buffer page (portal-web-reload))
                (portal-test--wait-for-page "Launch task" target)
                (should (= (length (portal-view-buffers 'terminal)) 1)))))
        (portal-test-native-target-frame nil)
        (setq unread-command-events nil)
        (dolist (buffer (portal-view-buffers 'terminal)) (kill-buffer buffer))
        (delete-directory directory t)))))

(provide 'portal-tasks-gui-tests)
;;; portal-tasks-gui-tests.el ends here
