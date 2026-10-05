;;; portal-terminal-startup-gui-tests.el --- Shell startup of native terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; test/terminal-shell-startup.sh runs these in a fresh graphical Emacs with a
;; minimal environment and fixture dotfiles: the shell supplies PATH and
;; startup values, not Emacs.

(require 'portal-gui-testing)
(declare-function portal--terminal-text "portal-terminal" (target))

(ert-deftest portal-terminal-start-uses-shell-startup ()
  (skip-unless (eq window-system 'ns))
  ;; test/terminal-shell-startup.sh launches a fresh native process with these
  ;; dotfiles. Lisp-side setenv cannot change the native parent's environment.
  (skip-unless (getenv "PORTAL_TEST_SHELL_DIRECTORY"))
  (let* ((directory (file-truename (make-temp-file "portal-shell-launch-" t)))
         (receipt (expand-file-name "receipt.json" directory))
         (process-environment (copy-sequence process-environment))
         (exec-path '("/usr/bin" "/bin"))
         (arguments '("implement @tasks/space ' é.md" "$(touch SHOULD_NOT_EXIST)" "`pwd`"
                      "" "a\\b" "line\nnext")))
    (unwind-protect
        (save-window-excursion
          (setenv "PATH" "/usr/bin:/bin")
          (setenv "PORTAL_LISP_ONLY" "must-not-be-exported")
          (setenv "PORTAL_SHELL_PROFILE" "wrong")
          (setenv "PORTAL_SHELL_RC" "wrong")
          (should-not (executable-find "portal-startup-cli"))
          (dolist (program (list "portal-startup-cli"
                                 (expand-file-name "tools/portal ' é\\tool" (getenv "PORTAL_TEST_SHELL_DIRECTORY"))))
            (let ((buffer (portal-terminal-start directory program (cons receipt arguments))))
              (unwind-protect
                  (progn
                    (portal-terminal-test--wait (lambda () (file-exists-p receipt)))
                    (let ((result (with-temp-buffer
                                    (insert-file-contents receipt)
                                    (json-parse-buffer :object-type 'plist :array-type 'list :null-object nil))))
                      (should (equal (plist-get result :args) arguments))
                      (should (equal (plist-get result :cwd) directory))
                      (should (equal (plist-get result :profile) "login-loaded"))
                      (should (equal (plist-get result :rc) "interactive-loaded"))
                      (should-not (plist-get result :lisp))
                      (should (equal (plist-get result :term) "xterm-ghostty"))
                      (should (equal (plist-get result :inside) "portal-ghostty")))
                    (should-not (file-exists-p (expand-file-name "SHOULD_NOT_EXIST" directory))))
                (kill-buffer buffer)
                (when (file-exists-p receipt) (delete-file receipt))))))
      (delete-directory directory t))))

(ert-deftest portal-terminal-start-missing-program-is-reported-in-terminal ()
  (skip-unless (eq window-system 'ns))
  (save-window-excursion
    (let* ((buffer (portal-terminal-start temporary-file-directory "portal-no-such-program-4817" nil))
           (target (buffer-local-value 'portal-view--target buffer)))
      (unwind-protect
          (portal-terminal-test--wait
           (lambda () (string-search "portal-no-such-program-4817" (portal--terminal-text target))))
        (kill-buffer buffer)))))

(provide 'portal-terminal-startup-gui-tests)
;;; portal-terminal-startup-gui-tests.el ends here
