;;; portal-agents-gui-tests.el --- The agent dashboard with real terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Real native terminals, windows and frames.  Redisplay runs the window hooks
;; that start and stop live updates, and the timer refreshes the dashboard
;; while the event loop waits, as it does while a person types.

(require 'portal-gui-testing)
(declare-function portal--process-snapshot "portal-view" (variable))

(ert-deftest portal-agents-gui-visit-focuses-terminals ()
  (portal-agents-gui--environment
    (let* ((window (selected-window))
           (shown (portal-agents-gui--open "agent-shown"))
           (hidden (portal-agents-gui--open "agent-hidden"))
           (quick (progn (portal-terminal-quick--show (file-name-as-directory
                                                       temporary-file-directory))
                         (current-buffer)))
           ;; It shows a terminal, but keys stay with this frame until asked.
           (frame (make-frame '((no-accept-focus . t))))
           (remote (frame-selected-window frame)))
      (portal-terminal-quick-dismiss)
      (dolist (buffer (list shown hidden quick)) (portal-agents-track buffer))
      (unwind-protect
          (progn
            (set-window-buffer remote shown)
            (select-frame-set-input-focus (window-frame window))
            (select-window window)
            (portal-agents)
            (should (equal (portal-agents-gui--view shown) (list remote nil)))
            (should (equal (portal-agents-gui--view hidden) '(nil nil)))
            ;; A hidden terminal appears here with the keyboard.
            (portal-agents-gui--visit hidden)
            (should (eq (window-buffer window) hidden))
            (should (equal (portal-agents-gui--view hidden) (list window t)))
            ;; One shown in another frame moves here with the keyboard.
            (portal-agents-gui--visit shown)
            (should (equal (portal-agents-gui--view shown) (list window t)))
            (should (equal (portal-agents-gui--view hidden) '(nil nil)))
            ;; A quick terminal opens in its panel with the keyboard.
            (portal-agents-gui--visit quick)
            (let ((panel (portal-terminal-quick--window)))
              (should panel)
              (should (eq (window-buffer window) portal-agents--buffer))
              (should (equal (portal-agents-gui--view quick) (list panel t))))
            (portal-terminal-quick-dismiss)
            ;; From the dashboard in the other frame, a terminal moves there.
            (switch-to-buffer hidden)
            (select-frame-set-input-focus frame)
            (select-window remote)
            (portal-agents-gui--visit hidden)
            (should (eq (window-buffer remote) hidden))
            (should (equal (portal-agents-gui--view hidden) (list remote t))))
        (delete-frame frame)))))

(ert-deftest portal-agents-gui-live-updates-only-while-shown ()
  (portal-agents-gui--environment
    (let* ((window (selected-window))
           (terminal (portal-agents-gui--open "agent-live"))
           (target (buffer-local-value 'portal-view--target terminal))
           (other (split-window-right)))
      (portal-agents-track terminal)
      ;; The terminal keeps the keyboard while the dashboard opens beside it.
      (portal-terminal-focus)
      (with-selected-window other (portal-agents))
      (portal-agents-gui--settle)
      (should (= (portal-agents-gui--timers) 1))
      (should (equal (portal-agents-gui--view terminal) (list window t)))
      ;; A title the program sets appears without g; the keyboard stays.
      (portal-terminal-test--paste "printf '\\033]2;PORTAL agent title\\007'; sleep 5" t target)
      (portal-terminal-test--wait
       (lambda () (equal (nth 6 (portal-agents-gui--row terminal)) "PORTAL agent title")))
      (should (eq (selected-window) window))
      (should (equal (portal-agents-gui--view terminal) (list window t)))
      ;; Ticks with nothing changed redraw nothing.
      (let ((tick (buffer-modified-tick portal-agents--buffer)))
        (portal-agents-gui--wait 1)
        (should (= (buffer-modified-tick portal-agents--buffer) tick)))
      ;; Hidden, the timer stops, and changes cost the dashboard nothing.
      (set-window-buffer other (get-buffer-create "*scratch*"))
      (portal-agents-gui--settle)
      (should (= (portal-agents-gui--timers) 0))
      (let ((tick (buffer-modified-tick portal-agents--buffer)))
        (portal-terminal-test--paste "printf '\\033]2;PORTAL hidden title\\007'; sleep 5" t target)
        (portal-terminal-test--wait
         (lambda () (equal (plist-get (portal-terminal-metadata terminal) :title)
                           "PORTAL hidden title")))
        (portal-agents-gui--wait 0.5)
        (should (= (buffer-modified-tick portal-agents--buffer) tick)))
      ;; Shown in another frame, it refreshes at once, and one timer runs.
      (let ((frame (make-frame '((no-accept-focus . t)))))
        (unwind-protect
            (progn
              (set-window-buffer (frame-selected-window frame) portal-agents--buffer)
              (portal-agents-gui--settle)
              (should (equal (nth 6 (portal-agents-gui--row terminal)) "PORTAL hidden title"))
              (should (= (portal-agents-gui--timers) 1))
              (set-window-buffer other portal-agents--buffer)
              (portal-agents-gui--settle)
              (should (= (portal-agents-gui--timers) 1))
              ;; Shown only on an invisible frame, the next tick stops it.
              (set-window-buffer other (get-buffer "*scratch*"))
              (make-frame-invisible frame t)
              (portal-agents-gui--settle)
              (portal-agents-gui--wait 0.5)
              (should (= (portal-agents-gui--timers) 0)))
          (delete-frame frame)))
      (portal-agents-gui--settle)
      (should (= (portal-agents-gui--timers) 0))
      ;; Killing the dashboard leaves no timer or hook.
      (set-window-buffer other portal-agents--buffer)
      (portal-agents-gui--settle)
      (should (= (portal-agents-gui--timers) 1))
      (kill-buffer portal-agents--buffer)
      (portal-agents-gui--settle)
      (should (= (portal-agents-gui--timers) 0))
      (should-not (memq #'portal-agents--window-changed
                        (default-value 'window-state-change-functions)))
      (should (equal (portal-agents-gui--view terminal) (list window t))))))

(ert-deftest portal-discovery-gui-inherited-tmux-marker ()
  (let ((fixture (getenv "PORTAL_TEST_PROCESS_SNAPSHOT"))
        (tmux (executable-find "tmux")))
    (skip-unless (and fixture tmux))
    (portal-agents-gui--environment
      (let* ((directory (file-truename (make-temp-file "portal-tmux-" t)))
             (program (expand-file-name "claude" directory))
             (socket (expand-file-name "socket" directory))
             ;; Identity only: no real Claude request or credentials are needed.
             (portal-agents-claude-program "/usr/bin/true")
             (direct (portal-agents-gui--open "direct-identity"))
             (nested (portal-agents-gui--open "nested-identity"))
             (marker (format "%d/%s" (emacs-pid) (buffer-local-value 'portal-view--target nested))))
        (unwind-protect
            (progn
              (copy-file fixture program)
              (set-file-modes program #o700)
              (portal-agents-gui--wait 1)
              (portal-discovery-gui--type direct (concat (shell-quote-argument program) " --wait"))
              (portal-discovery-gui--type
               nested (mapconcat #'shell-quote-argument
                                 (list tmux "-f" "/dev/null" "-S" socket "new-session" "-d"
                                       (concat (shell-quote-argument program) " --wait")) " "))
              ;; Verify the adversarial evidence really exists before asserting
              ;; its absence from the dashboard: a foreground native executable
              ;; named Claude with the exact Portal marker, on tmux's own PTY.
              (portal-discovery-gui--wait
               (lambda ()
                 (seq-find (lambda (p) (and (equal (plist-get p :executable) program)
                                            (equal (plist-get p :environment) marker)
                                            (not (eql (plist-get p :tty-parent) (emacs-pid)))))
                           (append (portal--process-snapshot "PORTAL_TERMINAL") nil))))
              (portal-agents)
              (portal-discovery-gui--wait (lambda () (portal-agents-gui--row direct)))
              (should-not (portal-agents-gui--row nested))
              ;; Attaching the tmux client still does not make its pane our TTY.
              (portal-discovery-gui--type nested
                                        (mapconcat #'shell-quote-argument
                                                   (list tmux "-S" socket "attach-session") " "))
              (portal-discovery-gui--wait
               (lambda () (equal (process-lines tmux "-S" socket "display-message" "-p"
                                                "#{session_attached}") '("1"))))
              (with-current-buffer portal-agents--buffer (revert-buffer))
              (should (portal-agents-gui--row direct))
              (should-not (portal-agents-gui--row nested)))
          (call-process tmux nil nil nil "-S" socket "kill-server")
          (delete-directory directory t))))))

(provide 'portal-agents-gui-tests)
;;; portal-agents-gui-tests.el ends here
