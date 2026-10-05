;;; portal-toolbar-gui-tests.el --- Toolbar through the real module -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'portal-gui-testing)

(defun portal-toolbar-gui--state (key)
  "Return KEY of the selected pane's toolbar state."
  (alist-get key (portal-toolbar--action "state")))

(ert-deftest portal-toolbar-web-state-survives-buffer-switch-and-reload ()
  (portal-test--with-web
    (portal-open-url "data:text/html,<title>Toolbar</title><h1>Heading</h1>")
    (portal-test--wait-for-page "Toolbar")
    (should (= (portal-zoom-in) 110))
    (let ((buffer (current-buffer)))
      (switch-to-buffer (get-buffer-create "*scratch*"))
      (redisplay t)
      (switch-to-buffer buffer)
      (redisplay t)
      (should (= (alist-get 'value (portal-toolbar--action "state")) 110)))
    (portal-toolbar--action "reload")
    (portal-test--wait-for-page "Toolbar")
    (should (= (alist-get 'value (portal-toolbar--action "state")) 110))
    ;; A theme sends its colors live, and the toolbar keeps its state.
    (unwind-protect
        (progn (load-theme 'tsdh-dark t)
               (should (= (alist-get 'value (portal-toolbar--action "state")) 110)))
      (disable-theme 'tsdh-dark))
    ;; The navigation toolbar has find, but no table of contents.
    (portal-find)
    (should (alist-get 'find (portal-toolbar--action "state")))
    (portal-toolbar--action "close-find")
    (should-error (portal-toggle-toc))
    (should (= (portal-zoom-reset) 100))))

(ert-deftest portal-toolbar-terminal-grid-and-text-size ()
  (portal-terminal-test--session
    (portal-terminal-test--wait (lambda () (> (plist-get (portal-terminal-test--state) :rows) 0)))
    (let* ((initial (portal-terminal-test--state))
           (rows (plist-get initial :rows))
           (columns (plist-get initial :columns))
           (default (alist-get 'value (portal-toolbar--action "state" t))))
      (should (= (portal-terminal-text-size-increase) (1+ default)))
      (portal-terminal-test--wait (lambda () (< (plist-get (portal-terminal-test--state) :columns) columns)))
      (should (= (portal-terminal-text-size-reset) default))
      (portal-terminal-test--wait (lambda () (= (plist-get (portal-terminal-test--state) :rows) rows)))
      (let ((portal-toolbar nil))
        (portal-terminal-test--wait (lambda () (> (plist-get (portal-terminal-test--state) :rows) rows))))
      (portal-terminal-test--wait (lambda () (= (plist-get (portal-terminal-test--state) :rows) rows))))))

(ert-deftest portal-toolbar-preview-toc-survives-reload ()
  (portal-test--with-web
    (portal-preview-html "data:text/html,<title>Contents</title><h1>Main</h1><h2>Detail</h2>")
    (portal-test--wait-for-page "Contents")
    (portal-terminal-test--wait
     (lambda () (alist-get 'headings (portal-toolbar--action "state"))))
    (should (portal-toggle-toc))
    (call-interactively (key-binding "g"))
    (portal-test--wait-for-page "Contents")
    (should (alist-get 'toc (portal-toolbar--action "state")))))

(ert-deftest portal-toolbar-find-edits-natively-and-keeps-the-users-focus ()
  (skip-unless (fboundp 'portal-test-native-key))
  (portal-test--with-web
    (select-frame-set-input-focus (selected-frame))
    (portal-open-url "data:text/html,<title>Find</title><p>needle one needle two needle three</p>")
    (portal-test--wait-for-page "Find")
    (let ((target (portal-view-target)))
      (portal-find)
      ;; The field has the keyboard, which is the view's.
      (should (portal-toolbar-gui--state 'find))
      (should (portal-input--action "focused" target))
      (dolist (key '((45 "n") (14 "e") (14 "e") (2 "d") (37 "l") (14 "e")))
        (should (portal-test-native-key (car key) 0 (cadr key))))
      (portal-terminal-test--wait (lambda () (eql (portal-toolbar-gui--state 'matches) 3)))
      (should (equal (portal-toolbar-gui--state 'query) "needle"))
      (should (= (portal-toolbar-gui--state 'match) 1))
      ;; Return and Shift-Return step through the matches.
      (should (portal-test-native-post-key 36 0 "\r"))
      (portal-terminal-test--wait (lambda () (eql (portal-toolbar-gui--state 'match) 2)))
      (should (portal-test-native-post-key 36 (ash 1 17) "\r"))
      (portal-terminal-test--wait (lambda () (eql (portal-toolbar-gui--state 'match) 1)))
      ;; Command-V pastes into the field, which has the keyboard.
      (let ((saved (gui-get-selection 'CLIPBOARD)))
        (unwind-protect
            (progn
              (gui-set-selection 'CLIPBOARD " two")
              (should (portal-test-native-key 9 (ash 1 20) "v"))
              (portal-terminal-test--wait
               (lambda () (equal (portal-toolbar-gui--state 'query) "needle two")))
              (portal-terminal-test--wait (lambda () (eql (portal-toolbar-gui--state 'matches) 1)))
              (dotimes (_ 4) (should (portal-test-native-post-key 51 0 "\d")))
              (portal-terminal-test--wait (lambda () (eql (portal-toolbar-gui--state 'matches) 3))))
          (when saved (gui-set-selection 'CLIPBOARD saved))))
      ;; Escape closes find, and the page keeps the keyboard.
      (should (portal-test-native-post-key 53 0 "\e"))
      (portal-terminal-test--wait (lambda () (not (portal-toolbar-gui--state 'find))))
      (should (portal-input--action "focused" target))
      ;; Closing find after the user returned to Emacs leaves Emacs the keyboard.
      (portal-find)
      (should (portal-test-native-key 53 (ash 1 20) "\e"))
      (should-not (portal-input--action "focused" target))
      (portal-toolbar--action "close-find")
      (should-not (portal-toolbar-gui--state 'find))
      (should-not (portal-input--action "focused" target)))))

(ert-deftest portal-toolbar-excalidraw-has-no-strip ()
  (portal-excalidraw-gui--document
    (let ((edges (window-inside-pixel-edges)))
      (should (= (portal-excalidraw-gui--js "return window.innerHeight;")
                 (- (nth 3 edges) (nth 1 edges))))
      (should (equal (should-error (portal-toolbar--action "state"))
                     '(error "No toolbar controls for this native view"))))))

(ert-deftest portal-toolbar-quick-terminal-has-no-strip ()
  (portal-terminal-test--session
    (portal-terminal-quick--show (file-name-as-directory temporary-file-directory))
    (let ((quick (current-buffer))
          (target (portal-view-target)))
      (unwind-protect
          (progn
            (portal-terminal-test--wait
             (lambda () (> (plist-get (portal-terminal-test--state target) :rows) 0)))
            (should (equal (should-error (portal--toolbar-action target "state"))
                           '(error "No toolbar controls for this native view")))
            (let ((rows (plist-get (portal-terminal-test--state target) :rows))
                  (regular (plist-get (portal-terminal-test--state) :rows)))
              ;; Hiding toolbars grows the regular terminal, but not the quick one.
              (let ((portal-toolbar nil))
                (portal-terminal-test--wait
                 (lambda () (> (plist-get (portal-terminal-test--state) :rows) regular)))
                (should (= (plist-get (portal-terminal-test--state target) :rows) rows)))
              (portal-terminal-test--wait
               (lambda () (= (plist-get (portal-terminal-test--state) :rows) regular)))
              (should (= (plist-get (portal-terminal-test--state target) :rows) rows))))
        (kill-buffer quick)))))
