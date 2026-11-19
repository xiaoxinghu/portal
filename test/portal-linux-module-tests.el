;;; portal-linux-module-tests.el --- The built Linux module in batch Emacs -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Loads the module a Linux build made, build/portal.so: the real bindings and
;; core, linked with native/Linux/backend.c and Ghostty's library.
;; PORTAL_TEST_BUILD names the build directory; run with --module-assertions.
;; The backend has no views yet, so these tests say what the module does
;; without them, and that each missing piece fails with a message of its own.
;; Batch Emacs opens no display: what the module finds in a graphical Emacs, a
;; test there must say.

(require 'ert)
(require 'subr-x)

(defconst portal-linux-module-tests--build
  (let ((build (getenv "PORTAL_TEST_BUILD")))
    (unless build (error "Set PORTAL_TEST_BUILD to the build directory"))
    (file-name-as-directory (file-truename build)))
  "The build directory whose module these tests load.")

(defconst portal-linux-module-tests--pin
  (expand-file-name "../native/ghostty.json" (file-name-directory load-file-name))
  "The pin of the Ghostty that Portal builds.")

(defconst portal-linux-module-tests--resources (getenv "GHOSTTY_RESOURCES_DIR")
  "GHOSTTY_RESOURCES_DIR as Emacs had it before the module, as from a Ghostty terminal.")

(module-load (expand-file-name "portal.so" portal-linux-module-tests--build))

(defun portal-linux-module-tests--error (function &rest arguments)
  "Return the message of the error that FUNCTION signals for ARGUMENTS."
  (cadr (should-error (apply function arguments) :type 'error)))

(ert-deftest portal-linux-module-loads-with-its-functions ()
  (should (featurep 'portal-native-module))
  ;; One from each part of the bindings, the launcher's included.
  (dolist (function '(portal--open portal--web-load portal--terminal-themes portal--input
                      portal--launcher-inspect portal--shortcuts portal--status-show
                      portal--rex-open portal--terminal-engine))
    (should (module-function-p (symbol-function function)))))

(ert-deftest portal-linux-module-answers-what-needs-no-view ()
  ;; The core's own rules run whatever the backend lacks.
  (should-not (portal--shortcuts))
  (should (equal (portal--shortcut-chord "control-option-a") "Control-Option-A"))
  (unwind-protect
      (progn
        (should (portal--input-escape-key "\e" 2))
        (should-error (portal--input-escape-key "a" 0)))
    (portal--input-escape-key "." 8))
  (should-not (portal--inspect "terminal:1"))
  (should (equal (portal-linux-module-tests--error #'portal--hide "web:1")
                 "No Portal view web:1"))
  ;; A theme for every open terminal, of which there are none.
  (should (portal--terminal-theme nil))
  ;; A hidden status panel hides again.
  (should (portal--status-hide)))

(ert-deftest portal-linux-module-starts-portals-own-ghostty ()
  ;; The library Portal built, found by the module's rpath, with the
  ;; resources installed beside the module.
  (let* ((pin (with-temp-buffer
                (insert-file-contents portal-linux-module-tests--pin)
                (json-parse-buffer)))
         (resources (expand-file-name "ghostty-linux/share/ghostty"
                                      portal-linux-module-tests--build))
         (engine (portal--terminal-engine)))
    (should (equal (plist-get engine :engine) "ghostty"))
    (should (equal (plist-get engine :version)
                   (string-remove-prefix "v" (gethash "version" pin))))
    (should (equal (plist-get engine :mode) "ReleaseFast"))
    (should (equal (plist-get engine :resources) resources))
    (should (file-directory-p (expand-file-name "shell-integration" resources)))
    (should (file-exists-p (expand-file-name "../terminfo/x/xterm-ghostty" resources)))
    ;; Once started, it answers the same.
    (should (equal (portal--terminal-engine) engine))
    ;; Emacs's own environment, which its subprocesses get, is not changed.
    (should (equal (getenv "GHOSTTY_RESOURCES_DIR") portal-linux-module-tests--resources))))

(ert-deftest portal-linux-module-says-what-linux-lacks ()
  ;; Batch Emacs has opened no display, which the backend asks GDK.
  (should (equal (portal-linux-module-tests--error #'portal--open "web" nil)
                 "Portal's native views need a graphical Emacs frame; \
this Emacs has opened no display"))
  (should (equal (portal-linux-module-tests--error #'portal--terminal-themes)
                 "Portal has no native views on Linux yet"))
  (should (equal (portal-linux-module-tests--error #'portal--launcher-inspect)
                 "Portal's launcher needs the macOS build of Emacs"))
  (should (equal (portal-linux-module-tests--error #'portal--key-post "Control-A")
                 "Cannot post Control-A: Portal has no system-wide keys on Linux yet"))
  (should (equal (portal-linux-module-tests--error #'portal--shortcut-set 0 "Control-Option-A")
                 "Cannot register shortcut Control-Option-A: \
Portal has no system-wide keys on Linux yet"))
  (should (equal (portal-linux-module-tests--error
                  #'portal--rex-open "/tmp/portal-none.sock" "portal" "0")
                 "Portal has no Rex connections on Linux yet"))
  ;; A failed open and a refused shortcut left nothing behind.
  (should-not (portal--inspect "web:1"))
  (should-not (portal--shortcuts)))

(provide 'portal-linux-module-tests)
;;; portal-linux-module-tests.el ends here
