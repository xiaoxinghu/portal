;;; portal-launcher-daily-use-tests.el --- Launcher coexistence -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Disposable graphical Emacs only: ./test.sh gui --suite
;; launcher-daily-use-gui --allow-gui (docs/launcher-daily-use.md).

;; An optional file with only the completion and theme setup to validate,
;; loaded before the tests. Do not name the normal init: it can start
;; services or other UIs.
(let ((config (getenv "PORTAL_LAUNCHER_CONFIG")))
  (when (and config (not (string-empty-p config)))
    (load config nil t)))

(require 'portal-gui-testing)
(require 'portal-launcher-testing)
(declare-function portal--web-load "portal-web" (target url))
(declare-function portal--launcher-inspect "portal-launcher" ())
(declare-function portal--shortcuts "portal-global-shortcut" ())

(ert-deftest portal-launcher-daily-use-configured-completion ()
  ;; Unlike the stock/enhanced matrix, keep the caller's completion and theme
  ;; settings throughout. A picker records what it would launch; native input
  ;; is real.
  (portal-launcher-gui--with-panel
    (let* ((settings (list completing-read-function completion-styles
                           completion-category-defaults completion-category-overrides
                           custom-enabled-themes (bound-and-true-p vertico-mode)
                           (bound-and-true-p marginalia-mode)))
           actions
           (picker (lambda ()
                     (push (completing-read "Launch: " '("Calculator")) actions))))
      (cl-flet ((pick (strokes &optional function)
                  (portal-launcher-gui--present (or function picker) strokes nil '(:kind minibuffer))))
        (pick (append (portal-launcher-gui--text "Calculator") '((36 0 "\r"))))
        (should (equal (pop actions) "Calculator"))
        (pick '((53 0 "\e")))
        (should-not actions)
        ;; The configured reader may accept a highlighted candidate with no
        ;; text. Stock completion has no selection and returns "".
        (let ((minibuffer-history nil))
          (pick '((36 0 "\r"))))
        (should (equal (pop actions) (if (bound-and-true-p vertico-mode) "Calculator" "")))
        (should-error
         (pick (append (portal-launcher-gui--text "Calculator") '((36 0 "\r")))
               (lambda () (funcall picker) (error "Daily-use fixture: open failed"))))
        (should (equal (pop actions) "Calculator"))
        ;; Recovery must read a new prompt, not merely return a Lisp value.
        (should (equal "recovered"
                       (pick (append (portal-launcher-gui--text "recovered") '((36 0 "\r")))
                             (lambda () (interactive) (read-string "Recovery: "))))))
      (should (equal settings
                     (list completing-read-function completion-styles
                           completion-category-defaults completion-category-overrides
                           custom-enabled-themes (bound-and-true-p vertico-mode)
                           (bound-and-true-p marginalia-mode)))))))

(ert-deftest portal-launcher-daily-use-reload-and-rollback-with-live-views ()
  (portal-launcher-gui--with-panel
    (let ((frame (make-frame))
          (receipt (make-temp-file "portal-launcher-shell-"))
          terminal-buffer terminal-id web-buffer web-id pid)
      (unwind-protect
          (progn
            (select-frame-set-input-focus frame)
            (sit-for 0.1)
            (portal-terminal)
            (setq terminal-buffer (current-buffer) terminal-id (portal-view-target))
            (let ((window (selected-window)))
              (select-window (split-window-right))
              (portal-open-url "data:text/html,<title>Launcher coexistence</title><input>")
              (setq web-buffer (current-buffer) web-id (portal-view-target))
              (portal-test--wait-for-page "Launcher coexistence" web-id)
              (select-window window))
            (dolist (example '("launcher-picker" "launcher-hello"))
              (portal-launcher-gui--example example))
            (dotimes (cycle 3)
              (portal-terminal-unfocus)
              ;; Evaluate the launcher setup, then again, as a configuration
              ;; reload does: one registration per name.
              (dotimes (_ 2) (portal-launcher-gui--example "launcher-shortcuts"))
              (should (equal (mapcar #'car portal-global-shortcut--registrations)
                             '(pick-fruit hello clock)))
              (should (= 3 (length (portal--shortcuts))))
              (portal-launcher-gui--present
               (lambda () (interactive) (read-string "Coexistence: "))
               '((53 0 "\e")))
              (let ((panel portal-launcher--frame))
                (portal-launcher-mode -1)
                (portal-launcher-mode -1)
                (should-not (frame-live-p panel)))
              (should-not (plist-get (portal--launcher-inspect) :attached))
              (should-not (advice-member-p #'portal-launcher--guard-parameters
                                          'modify-frame-parameters))
              (should-not (advice-member-p #'portal-launcher--delete-frame 'delete-frame))
              ;; Disabling the panel left the shortcuts; removing them, as a
              ;; rollback does, frees their chords.
              (should (= 3 (length (portal--shortcuts))))
              (dolist (name '(pick-fruit hello clock))
                (should (portal-global-shortcut-remove name)))
              (should-not (portal--shortcuts))
              (should (eq (selected-frame) frame))
              (should (eq (current-buffer) terminal-buffer))
              ;; Both views keep their identity and accept input after rollback.
              (should (equal terminal-id (portal-view-target (get-buffer-window terminal-buffer frame))))
              (should (equal web-id (portal-view-target (get-buffer-window web-buffer frame))))
              (delete-file receipt)
              (portal-terminal-focus)
              (portal-terminal-test--paste
               (format "printf '%%s' \"$$\" > %s.tmp; /bin/mv %s.tmp %s"
                       (shell-quote-argument receipt) (shell-quote-argument receipt)
                       (shell-quote-argument receipt)) t terminal-id)
              (portal-terminal-test--wait (lambda () (file-exists-p receipt)))
              (let ((current-pid (with-temp-buffer
                                   (insert-file-contents receipt)
                                   (string-to-number (buffer-string)))))
                (should (process-attributes current-pid))
                (if pid (should (= pid current-pid)) (setq pid current-pid)))
              (portal-terminal-unfocus)
              (with-selected-window (get-buffer-window web-buffer frame)
                (portal--web-load web-id
                                  (format "data:text/html,<title>After rollback %d</title>" cycle))
                (portal-test--wait-for-page (format "After rollback %d" cycle) web-id)
                (should (portal-test--shown web-id (selected-window))))
              (should (frame-live-p (window-frame ordinary)))))
        (portal-launcher-mode -1)
        (when (buffer-live-p terminal-buffer) (kill-buffer terminal-buffer))
        (when (buffer-live-p web-buffer) (kill-buffer web-buffer))
        (when (frame-live-p frame) (delete-frame frame t))
        (when (file-exists-p receipt) (delete-file receipt))))))

(provide 'portal-launcher-daily-use-tests)
;;; portal-launcher-daily-use-tests.el ends here
