;;; portal-terminal-sidebar-tests.el --- The sidebar of terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-terminal)
(require 'portal-terminal-sidebar)

;; The sidebar with Portal's own terminals, against the fake native module:
;; its rows, its window, its keys and its width.  Rex sessions and blocks,
;; folding and updates from a server's events are in test/portal-rex-tests.el,
;; against the fake Rex server.  Batch Emacs does not redisplay, so a test
;; runs what redisplay would, `window-size-change-functions', itself, and
;; waits for the sidebar's timer with `sleep-for'.

(defvar portal-sidebar-test--directory nil "This test's temporary directory.")

(defmacro portal-sidebar-test--environment (&rest body)
  "Run BODY in one window, from a file buffer in project one/app.
The directory holds projects one/app and two/app.  Kill every buffer BODY
made, the sidebar's too, and delete the directory, afterwards.  The
sidebar's width and folds are as they were."
  (declare (indent 0))
  `(let* ((portal-sidebar-test--directory (file-truename (make-temp-file "portal-sidebar-" t)))
          (context (frame-parameter nil 'portal-project-context))
          (initial-buffers (buffer-list))
          (portal-terminal-confirm-kill nil)
          (portal-terminal-sidebar-width 32)
          (portal-terminal-sidebar--folded nil)
          (display-buffer-alist nil))
     (portal-fake-native-reset)
     (dolist (folder '("one/app/.git" "two/app/.git"))
       (make-directory (portal-sidebar-test--path folder) t))
     (save-window-excursion
       (unwind-protect
           (progn (delete-other-windows)
                  (switch-to-buffer (get-buffer-create "sidebar-file.el"))
                  (setq buffer-file-name (portal-sidebar-test--path "one/app/file.el")
                        default-directory (file-name-directory buffer-file-name))
                  (portal-project--remember)
                  ,@body)
         (portal-terminal-quick-dismiss)
         (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
           (when (buffer-live-p buffer) (kill-buffer buffer)))
         (set-frame-parameter nil 'portal-project-context context)
         (delete-directory portal-sidebar-test--directory t)))
     (should-not (portal-view-buffers))
     ;; Killed, the sidebar follows nothing.
     (should-not (memq #'portal-terminal-sidebar--schedule portal-rex-status-functions))
     (should-not (memq #'portal-terminal-sidebar--buffers-changed buffer-list-update-hook))))

(defun portal-sidebar-test--path (name)
  "Return NAME in this test's directory."
  (expand-file-name name portal-sidebar-test--directory))

(defun portal-sidebar-test--open (folder &optional name)
  "Start a terminal in FOLDER, named NAME if given, and return its buffer.
It is shown in the selected window."
  (let ((default-directory (file-name-as-directory (portal-sidebar-test--path folder))))
    (portal-terminal-new)
    (when name (portal-terminal-rename name))
    (current-buffer)))

(defun portal-sidebar-test--lines ()
  "Return the sidebar's lines, as plain text with trailing spaces left out."
  (with-current-buffer portal-terminal-sidebar--name
    (mapcar #'string-trim-right
            (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t))))

(defun portal-sidebar-test--rows ()
  "Return the sidebar's lines trimmed, each run of spaces in them one space."
  (mapcar (lambda (line) (replace-regexp-in-string " +" " " (string-trim line)))
          (portal-sidebar-test--lines)))

(defun portal-sidebar-test--window ()
  "Return the window of the selected frame that shows the sidebar, or nil."
  (get-buffer-window portal-terminal-sidebar--name))

(defun portal-sidebar-test--on (text)
  "Move point in the sidebar, and its window's, to the line that holds TEXT."
  (with-current-buffer portal-terminal-sidebar--name
    (goto-char (point-min))
    (search-forward text)
    (beginning-of-line)
    (when-let* ((window (portal-sidebar-test--window)))
      (set-window-point window (point)))))

(defun portal-sidebar-test--status (buffer state &rest status)
  "Give terminal BUFFER the STATE a Rex block's program reports, with STATUS.
STATUS holds the other keys of `:status' in `portal-terminal-metadata'."
  (with-current-buffer buffer
    (setq portal-terminal--status
          (append (list :state state) status
                  (list :time (float-time) :waiting (not (eq state 'working)))))))

(defun portal-sidebar-test--resized ()
  "Run what redisplay runs for the sidebar's window after a resize."
  (let ((window (portal-sidebar-test--window)))
    (with-current-buffer (window-buffer window)
      (run-hook-with-args 'window-size-change-functions window))))

(defun portal-sidebar-test--settle ()
  "Let the sidebar's timer run, as Emacs does while it waits for input."
  (sleep-for 0.25))

(ert-deftest portal-terminal-sidebar-lists-portal-terminals-at-the-root ()
  (portal-sidebar-test--environment
    (let* ((file (current-buffer))
           (first (portal-sidebar-test--open "one/app"))
           (second (portal-sidebar-test--open "two/app" "server")))
      (portal-fake-native-report (buffer-local-value 'portal-view--target first)
                                 :program "/bin/zsh")
      ;; A quick terminal is left out.
      (switch-to-buffer file)
      (portal-terminal-toggle)
      (portal-terminal-quick-dismiss)
      (should (equal (portal-terminal-sidebar-tree) (list nil first second)))
      (should (equal (portal-terminal-sidebar-buffers) (list first second)))
      (portal-terminal-sidebar)
      ;; No Rex connection: no heading, the terminals in the order they
      ;; were made, named without the asterisks, the program at the right.
      (let ((lines (portal-sidebar-test--lines)))
        (should (equal (portal-sidebar-test--rows) '("terminal: app zsh" "server")))
        (should (string-prefix-p "   terminal: app" (car lines)))
        ;; Drawn to the window's width, less a column.
        (should (= (string-width (car lines))
                   (1- (window-max-chars-per-line (portal-sidebar-test--window))))))
      (with-current-buffer portal-terminal-sidebar--name
        (goto-char (point-min))
        (should (eq (get-text-property (+ (point) 3) 'face) 'portal-terminal-sidebar-terminal))
        (should (eq (get-text-property (- (line-end-position) 1) 'face)
                    'portal-terminal-sidebar-program))
        (should-not mode-line-format))
      ;; With none, it says so.
      (kill-buffer first)
      (kill-buffer second)
      (portal-sidebar-test--settle)
      (should (equal (portal-sidebar-test--lines) '(" No terminals"))))))

(ert-deftest portal-terminal-sidebar-marks-each-state ()
  (portal-sidebar-test--environment
    (let ((blocked (portal-sidebar-test--open "one/app" "asking"))
          (bare (portal-sidebar-test--open "one/app" "permission"))
          (failed (portal-sidebar-test--open "one/app" "failed"))
          (done (portal-sidebar-test--open "one/app" "done"))
          (working (portal-sidebar-test--open "one/app" "working"))
          (idle (portal-sidebar-test--open "one/app" "shell")))
      (ignore idle)
      (portal-sidebar-test--status blocked 'blocked :kind "question" :app "claude-code"
                                   :message (concat "Clean up the task now? " (make-string 80 ?x)))
      (portal-sidebar-test--status bare 'blocked :kind "permission")
      (portal-sidebar-test--status failed 'error :app "codex" :message "API error")
      (portal-sidebar-test--status done 'done :app "claude-code" :message "Finished")
      (portal-sidebar-test--status working 'working :app "claude-code" :message "Reading slides.ts")
      (portal-terminal-sidebar)
      (let ((lines (portal-sidebar-test--lines)))
        ;; A blocked or failed row has its message on a second line, cut
        ;; to the window; one without a message, why it is blocked.  A done
        ;; or working row has its mark alone.  The app is the program.
        (should (equal (portal-sidebar-test--rows)
                       (list "● asking claude-code"
                             (string-trim
                              (truncate-string-to-width
                               (concat "   Clean up the task now? " (make-string 80 ?x))
                               (1- (window-max-chars-per-line (portal-sidebar-test--window)))
                               nil nil t))
                             "● permission"
                             "permission"
                             "✗ failed codex"
                             "API error"
                             "✓ done claude-code"
                             "◌ working claude-code"
                             "shell")))
        (should (string-suffix-p "…" (nth 1 lines)))
        ;; The message starts under the name.
        (should (string-prefix-p "   Clean" (nth 1 lines))))
      ;; The marks and messages in the status faces.
      (with-current-buffer portal-terminal-sidebar--name
        (goto-char (point-min))
        (dolist (face '(portal-terminal-status-blocked portal-terminal-status-blocked
                        portal-terminal-status-blocked portal-terminal-status-blocked
                        portal-terminal-status-error portal-terminal-status-error
                        portal-terminal-status-done portal-terminal-status-working))
          (skip-chars-forward " ")
          (should (eq (get-text-property (point) 'face) face))
          (forward-line 1))))))

(ert-deftest portal-terminal-sidebar-shows-and-hides-beside-the-selection ()
  (portal-sidebar-test--environment
    (let* ((terminal (portal-sidebar-test--open "one/app"))
           (main (selected-window)))
      ;; Shown on the left, 32 columns, without selecting it.
      (portal-terminal-sidebar)
      (let ((window (portal-sidebar-test--window)))
        (should window)
        (should (eq (selected-window) main))
        (should (eq (window-parameter window 'window-side) 'left))
        (should (= (window-total-width window) 32))
        (should (window-parameter window 'no-delete-other-windows))
        (should (window-preserved-size window t))
        (should (eq (car (window-edges window)) 0))
        ;; C-x 1 keeps it.
        (delete-other-windows)
        (should (window-live-p window))
        ;; Point stays where it was through a hide and a show.
        (portal-sidebar-test--on "terminal")
        (with-current-buffer portal-terminal-sidebar--name
          (forward-char 2)
          (set-window-point window (point))))
      (let ((point (with-current-buffer portal-terminal-sidebar--name (point))))
        (portal-terminal-sidebar)
        (should-not (portal-sidebar-test--window))
        (should (eq (selected-window) main))
        (should (eq (window-buffer main) terminal))
        (portal-terminal-sidebar)
        (should (eq (selected-window) main))
        (should (= (window-point (portal-sidebar-test--window)) point)))
      ;; Selecting it shows it first if need be.
      (portal-terminal-sidebar)
      (portal-terminal-sidebar-select)
      (should (eq (window-buffer) (get-buffer portal-terminal-sidebar--name)))
      (portal-terminal-sidebar-select)
      (should (eq (window-buffer) (get-buffer portal-terminal-sidebar--name)))
      ;; From the sidebar itself, the toggle hides it.
      (portal-terminal-sidebar)
      (should-not (portal-sidebar-test--window))
      (should (window-live-p main))
      ;; The user's own rule wins.
      (let ((display-buffer-alist
             `((,(regexp-quote portal-terminal-sidebar--name) display-buffer-in-side-window
                (side . right) (window-width . 40)))))
        (portal-terminal-sidebar)
        (should (eq (window-parameter (portal-sidebar-test--window) 'window-side) 'right))
        (should (= (window-total-width (portal-sidebar-test--window)) 40))
        (portal-terminal-sidebar)))))

(ert-deftest portal-terminal-sidebar-keeps-the-width-given ()
  (portal-sidebar-test--environment
    (portal-fake-native-report (buffer-local-value 'portal-view--target
                                                   (portal-sidebar-test--open "one/app"))
                               :program "/bin/zsh")
    (split-window-right)
    (portal-terminal-sidebar)
    (portal-sidebar-test--resized)
    (should (= portal-terminal-sidebar-width 32))
    ;; C-x } in the sidebar, as a drag on its edge does.
    (with-selected-window (portal-sidebar-test--window)
      (enlarge-window-horizontally 6))
    (portal-sidebar-test--resized)
    (should (= portal-terminal-sidebar-width 38))
    ;; Balancing leaves it, as a preserved width.
    (balance-windows)
    (should (= (window-total-width (portal-sidebar-test--window)) 38))
    ;; Drawn afresh to the new width.
    (portal-sidebar-test--settle)
    (should (= (string-width (car (with-current-buffer portal-terminal-sidebar--name
                                    (split-string (buffer-string) "\n"))))
               (1- (window-max-chars-per-line (portal-sidebar-test--window)))))
    ;; Hidden and shown again, it comes back at that width.
    (portal-terminal-sidebar)
    (portal-terminal-sidebar)
    (should (= (window-total-width (portal-sidebar-test--window)) 38))
    (balance-windows)
    (should (= (window-total-width (portal-sidebar-test--window)) 38))
    ;; With savehist, it lasts across Emacs sessions.
    (require 'savehist)
    (should (memq 'portal-terminal-sidebar-width savehist-additional-variables))))

(ert-deftest portal-terminal-sidebar-visits-from-the-side-window ()
  (portal-sidebar-test--environment
    (let* ((file (current-buffer))
           (first (portal-sidebar-test--open "one/app" "first"))
           (second (portal-sidebar-test--open "two/app" "second"))
           (main (selected-window)))
      (switch-to-buffer file)
      (portal-terminal-sidebar-select)
      (let ((sidebar (selected-window)))
        ;; RET: in the window used last, selected.
        (portal-sidebar-test--on "first")
        (call-interactively (keymap-lookup portal-terminal-sidebar-mode-map "RET"))
        (should (eq (selected-window) main))
        (should (eq (window-buffer main) first))
        (should (eq (window-buffer sidebar) (get-buffer portal-terminal-sidebar--name)))
        ;; C-o: shown there, and the sidebar stays selected.
        (select-window sidebar)
        (portal-sidebar-test--on "second")
        (call-interactively (keymap-lookup portal-terminal-sidebar-mode-map "C-o"))
        (should (eq (selected-window) sidebar))
        (should (eq (window-buffer main) second))
        ;; o: in another window, selected.
        (portal-sidebar-test--on "first")
        (call-interactively (keymap-lookup portal-terminal-sidebar-mode-map "o"))
        (should-not (memq (selected-window) (list main sidebar)))
        (should (eq (window-buffer) first))
        (should (eq (window-buffer main) second))
        ;; c: one of Portal's own, from a row at the root, in the window used last.
        (select-window sidebar)
        (let ((used (get-mru-window nil nil t)))
          (call-interactively (keymap-lookup portal-terminal-sidebar-mode-map "c"))
          (should (eq (selected-window) used))
          (should (portal-terminal-metadata (window-buffer used)))
          (should-not (memq (window-buffer used) (list first second))))
        ;; On no row, nothing is visited.
        (select-window sidebar)
        (goto-char (point-max))
        (should-error (portal-terminal-sidebar-visit) :type 'user-error)
        (should-error (portal-terminal-sidebar-toggle-fold) :type 'user-error)))))

(ert-deftest portal-terminal-sidebar-highlights-the-terminal-in-use ()
  (portal-sidebar-test--environment
    (let* ((first (portal-sidebar-test--open "one/app" "first"))
           (second (portal-sidebar-test--open "two/app" "second"))
           (main (selected-window))
           (highlighted (lambda ()
                          (with-current-buffer portal-terminal-sidebar--name
                            (let ((overlay portal-terminal-sidebar--overlay))
                              (and (overlay-buffer overlay)
                                   (get-text-property (overlay-start overlay)
                                                      'portal-terminal-sidebar-item)))))))
      (portal-terminal-sidebar)
      (should (eq (funcall highlighted) second))
      ;; It follows the selected window, without a redraw.
      (let ((drawn portal-terminal-sidebar--drawn-at))
        (switch-to-buffer first)
        (run-hook-with-args 'window-buffer-change-functions (selected-frame))
        (should (eq (funcall highlighted) first))
        (let ((other (split-window)))
          (select-window other)
          (switch-to-buffer second)
          (run-hook-with-args 'window-selection-change-functions (selected-frame))
          (should (eq (funcall highlighted) second))
          ;; From the sidebar itself, that of the window used last.
          (select-window main)
          (portal-terminal-sidebar-select)
          (run-hook-with-args 'window-selection-change-functions (selected-frame))
          (should (eq (funcall highlighted) first))
          ;; A buffer that is no terminal highlights nothing.
          (select-window other)
          (switch-to-buffer "sidebar-file.el")
          (run-hook-with-args 'window-buffer-change-functions (selected-frame))
          (should-not (funcall highlighted)))
        (should (= portal-terminal-sidebar--drawn-at drawn))))))

(ert-deftest portal-terminal-sidebar-follows-terminals-with-no-key-pressed ()
  (portal-sidebar-test--environment
    (let ((file (current-buffer))
          (first (portal-sidebar-test--open "one/app" "first")))
      (switch-to-buffer file)
      (portal-terminal-sidebar)
      (should (equal (portal-sidebar-test--rows) '("first")))
      ;; A terminal starts, gets a program, is renamed and ends.
      (let ((second (portal-sidebar-test--open "two/app" "second")))
        (switch-to-buffer file)
        (portal-sidebar-test--settle)
        (should (equal (portal-sidebar-test--rows) '("first" "second")))
        (portal-sidebar-test--on "second")
        (portal-fake-native-report (buffer-local-value 'portal-view--target second)
                                   :program "/opt/bin/claude")
        (portal-sidebar-test--settle)
        (should (equal (portal-sidebar-test--rows) '("first" "second claude")))
        (with-current-buffer second (portal-terminal-rename "api"))
        (portal-sidebar-test--settle)
        (should (equal (portal-sidebar-test--rows) '("first" "api claude")))
        ;; Point stayed on its row.
        (with-current-buffer portal-terminal-sidebar--name
          (should (eq (get-text-property (window-point (portal-sidebar-test--window))
                                         'portal-terminal-sidebar-item)
                      second)))
        (kill-buffer first)
        (portal-sidebar-test--settle)
        (should (equal (length (portal-sidebar-test--lines)) 1)))
      ;; Hidden, it is not drawn; shown again, it is drawn first.
      (portal-terminal-sidebar)
      (let ((drawn portal-terminal-sidebar--drawn-at))
        (portal-sidebar-test--open "one/app" "third")
        (switch-to-buffer file)
        (portal-sidebar-test--settle)
        (should (= portal-terminal-sidebar--drawn-at drawn)))
      (portal-terminal-sidebar)
      (should (member "third" (portal-sidebar-test--rows))))))

(provide 'portal-terminal-sidebar-tests)
;;; portal-terminal-sidebar-tests.el ends here
