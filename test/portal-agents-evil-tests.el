;;; portal-agents-evil-tests.el --- Dashboard navigation under Evil -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'portal-agents-testing
         (expand-file-name "portal-agents-testing"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

(defvar evil-want-keybinding nil)
;; Evil 1.15 expects this variable from `define-globalized-minor-mode';
;; Emacs 31 no longer initializes it.  Keep its command hooks running in tests.
(defvar evil-mode-buffers nil)

(ert-deftest portal-agents-visit-works-with-evil-collection ()
  (require 'evil)
  (require 'evil-collection)
  (evil-collection-init 'tabulated-list)
  (unwind-protect
      (portal-agents-test--environment
        (evil-mode 1)
        (let ((first (portal-agents-test--open "one/app"))
              (second (portal-agents-test--open "one/app")))
          (dolist (buffer (list first second)) (portal-agents-track buffer))
          (portal-agents-test--show)
          (should (eq evil-state 'normal))
          (dolist (key '("RET" "<return>"))
            (switch-to-buffer portal-agents--buffer)
            (goto-char (point-min))
            (forward-line (portal-agents-test--line second))
            (execute-kbd-macro (kbd key))
            (portal-view-sync)
            (should (eq (window-buffer) second))
            (should (equal (portal-agents-test--focused)
                           (list (buffer-local-value 'portal-view--target second)))))
          (switch-to-buffer portal-agents--buffer)
          ;; Sorting and Evil movement retain their existing bindings.
          (should (eq (key-binding (kbd "S")) #'tabulated-list-sort))
          (should (eq (key-binding (kbd "j")) #'evil-next-line))))
    (evil-mode -1)))

;;; portal-agents-evil-tests.el ends here
