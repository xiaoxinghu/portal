;;; portal-linux-module-tests.el --- The built Linux module in batch Emacs -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Loads the module a Linux build made, build/portal.so: the real bindings and
;; core, linked with native/Linux/backend.c.  PORTAL_TEST_BUILD names the
;; build directory; run with --module-assertions.  The backend has no views
;; yet, so these tests say what the module does without them, and that each
;; missing piece fails with a message of its own.  Batch Emacs opens no
;; display: what the module finds in a graphical Emacs, a test there must say.

(require 'ert)

(let ((build (getenv "PORTAL_TEST_BUILD")))
  (unless build (error "Set PORTAL_TEST_BUILD to the build directory"))
  (module-load (expand-file-name "portal.so" build)))

(defun portal-linux-module-tests--error (function &rest arguments)
  "Return the message of the error that FUNCTION signals for ARGUMENTS."
  (cadr (should-error (apply function arguments) :type 'error)))

(ert-deftest portal-linux-module-loads-with-its-functions ()
  (should (featurep 'portal-native-module))
  ;; One from each part of the bindings, the launcher's included.
  (dolist (function '(portal--open portal--web-load portal--terminal-themes portal--input
                      portal--launcher-inspect portal--shortcuts portal--status-show
                      portal--rex-open))
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
