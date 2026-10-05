;;; portal-integration-tests.el --- Native feature coexistence -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Load the test-only event injector first.

(require 'portal-gui-testing)
(declare-function portal-test-native-focus-web "test-terminal-input" ())
(declare-function portal--inspect "portal-view" (target))

(defconst portal-integration-test--page
  (concat "data:text/html,<title>Ready</title><input autofocus>"
          "<script>let down=0,up=0;"
          "document.onkeydown=()=>down++;"
          "document.onkeyup=()=>{up++;document.title="
          "document.querySelector('input').value+':'+down+':'+up}</script>"))

(ert-deftest portal-integration-focus-and-cleanup-in-either-startup-order ()
  (skip-unless (fboundp 'portal-test-native-focus-web))
  (dolist (terminal-first '(t nil))
    (portal-test--with-web
      (unwind-protect
          (let (terminal-window web-window terminal-id web-id)
            (select-frame-set-input-focus (selected-frame))
            (sit-for 0.1)
            (if terminal-first
                (progn
                  (portal-terminal)
                  (setq terminal-window (selected-window)
                        terminal-id (portal-view-target))
                  ;; Attach the second feature while the first owns native focus.
                  (select-window (split-window-right))
                  (portal-open-url portal-integration-test--page)
                  (setq web-window (selected-window)
                        web-id (portal-view-target)))
              (portal-open-url portal-integration-test--page)
              (setq web-window (selected-window)
                    web-id (portal-view-target))
              (portal-test--wait-for-page "Ready" web-id)
              (should (portal-test-native-focus-web))
              (select-window (split-window-right))
              (portal-terminal)
              (setq terminal-window (selected-window)
                    terminal-id (portal-view-target)))
            (portal-test--wait-for-page "Ready" web-id)
            (should (featurep 'portal-native-module))
            (should (plist-get (portal-terminal-test--state terminal-id) :ready))
            (should (portal-test--shown web-id web-window))
            (select-window terminal-window)
            (portal-terminal-focus)
            (portal-test-native-key 53 (ash 1 20) "\e")
            (should-not (plist-get (portal-terminal-test--state terminal-id) :focused))
            (portal-integration-test--emacs-input)
            (portal-terminal-focus)
            (portal-test-native-key 53 (ash 1 20) "\e")
            (portal-integration-test--emacs-input)
            (select-window web-window)
            (should (portal-test-native-focus-web))
            (portal-test-native-key 0 0 "a")
            ;; A terminal must not swallow WebKit's key-up events.
            (portal-test--wait-for-page "a:1:1" web-id)
            (portal-test-native-key 53 (ash 1 20) "\e")
            (portal-integration-test--emacs-input)
            (if terminal-first
                (progn
                  (kill-buffer (window-buffer web-window))
                  (should-not (portal--inspect web-id))
                  (select-window terminal-window)
                  (portal-terminal-focus)
                  (should (plist-get (portal-terminal-test--state terminal-id) :focused))
                  (portal-test-native-key 53 (ash 1 20) "\e")
                  (portal-integration-test--emacs-input))
              (portal-terminal-close-all)
              (should-not (portal-terminal-test--state terminal-id))
              (should (portal-test-native-focus-web))
              (portal-test-native-key 11 0 "b")
              (portal-test--wait-for-page "ab:2:2" web-id)
              (portal-test-native-key 53 (ash 1 20) "\e")
              (portal-integration-test--emacs-input)))
        (portal-terminal-close-all)))))

(ert-deftest portal-integration-frame-deletion-hides-terminal-and-web-views ()
  (skip-unless (eq window-system 'ns))
  (let ((frame (make-frame))
        (receipt (make-temp-name (expand-file-name "portal-frame-shell-" temporary-file-directory)))
        terminal-id terminal-buffer web-id web-buffer pid)
    (unwind-protect
        (progn
          (select-frame-set-input-focus frame)
          (sit-for 0.1)
          (portal-terminal)
          (setq terminal-id (portal-view-target) terminal-buffer (current-buffer))
          (portal-terminal-test--paste
           (format "echo $$ > %s" (shell-quote-argument receipt)) t terminal-id)
          (portal-terminal-test--wait (lambda () (file-exists-p receipt)))
          (setq pid (with-temp-buffer (insert-file-contents receipt)
                                     (string-to-number (buffer-string))))
          (should (process-attributes pid))
          (select-window (split-window-right))
          (portal-open-url portal-integration-test--page)
          (setq web-id (portal-view-target) web-buffer (current-buffer))
          (portal-test--wait-for-page "Ready" web-id)
          (delete-frame frame)
          ;; Both views are hidden, not ended, and come back when shown.
          (should-not (plist-get (portal--inspect web-id) :visible))
          (should-not (plist-get (portal-terminal-test--state terminal-id) :visible))
          (sit-for 0.5)
          (should (process-attributes pid))
          (switch-to-buffer terminal-buffer)
          (portal-terminal-focus)
          (should (plist-get (portal-terminal-test--state terminal-id) :focused))
          (delete-file receipt)
          (portal-terminal-test--paste
           (format "echo $$ > %s" (shell-quote-argument receipt)) t terminal-id)
          (portal-terminal-test--wait (lambda () (file-exists-p receipt)))
          (should (= pid (with-temp-buffer (insert-file-contents receipt)
                                           (string-to-number (buffer-string)))))
          (portal-terminal-unfocus)
          (switch-to-buffer web-buffer)
          (should (portal-test--shown web-id (selected-window)))
          (portal-test--wait-for-page "Ready" web-id))
      (when (frame-live-p frame) (delete-frame frame))
      (portal-terminal-close-all)
      (when (buffer-live-p terminal-buffer) (kill-buffer terminal-buffer))
      (when (buffer-live-p web-buffer) (kill-buffer web-buffer))
      (when (file-exists-p receipt) (delete-file receipt)))))

(provide 'portal-integration-tests)
;;; portal-integration-tests.el ends here
