;;; portal-agents-testing.el --- Shared fixtures of the dashboard's batch suites -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; The agent dashboard over the fake native module, for the dashboard,
;; discovery and Evil suites.  Loading this file defines no tests.

(require 'ert)
(require 'cl-lib)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-agents)

;; Tests kill live shells without asking; the prompt has its own tests.
(setq portal-terminal-confirm-kill nil)

(defvar portal-agents-test--directory nil "This test's temporary directory.")

(defmacro portal-agents-test--environment (&rest body)
  "Run BODY in one window, then kill its buffers and delete its directory.
The directory holds projects one/app and two/app.  Afterwards nothing is
tracked and no dashboard timer remains."
  (declare (indent 0))
  `(let* ((portal-agents-test--directory (file-truename (make-temp-file "portal-agents-" t)))
          (context (frame-parameter nil 'portal-project-context))
          (initial-buffers (buffer-list))
          (portal-agents-live-update t)
          (portal-agents-live-update-interval 2))
     (portal-fake-native-reset)
     (setq portal-agents--tracked nil)
     (dolist (folder '("one/app/.git" "one/app/src" "two/app/.git"))
       (make-directory (portal-agents-test--path folder) t))
     (save-window-excursion
       (unwind-protect
           (progn (delete-other-windows)
                  (switch-to-buffer (get-buffer-create "*scratch*"))
                  ,@body)
         (portal-terminal-quick-dismiss)
         (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
           (when (buffer-live-p buffer) (kill-buffer buffer)))
         (set-frame-parameter nil 'portal-project-context context)
         (delete-directory portal-agents-test--directory t)))
     (should-not (portal-view-buffers))
     (should-not portal-agents--buffer)
     (should (= (portal-agents-test--timers) 0))
     (setq portal-agents--tracked nil)))

(defun portal-agents-test--path (name)
  "Return NAME in this test's directory, as a directory name if it ends in /."
  (expand-file-name name portal-agents-test--directory))

(defun portal-agents-test--open (folder)
  "Start a terminal in FOLDER in the selected window and return its buffer."
  (let ((default-directory (file-name-as-directory (portal-agents-test--path folder))))
    (portal-terminal-new)
    (current-buffer)))

(defun portal-agents-test--report (buffer &rest facts)
  "Have BUFFER's terminal report FACTS, such as :title, :pwd and :exited."
  (apply #'portal-fake-native-report (buffer-local-value 'portal-view--target buffer) facts))

(defun portal-agents-test--timers ()
  "Return how many dashboard timers are scheduled."
  (cl-count #'portal-agents--tick timer-list :key #'timer--function))

(defun portal-agents-test--redisplay ()
  "Run the dashboard's window hook, as redisplay does after windows change."
  (portal-agents--window-changed (selected-frame)))

(defun portal-agents-test--show ()
  "Open the dashboard in the selected window, as a person does."
  (portal-agents)
  (portal-agents-test--redisplay)
  portal-agents--buffer)

(defun portal-agents-test--rows ()
  "Return the dashboard's printed rows, as (BUFFER COLUMN...)."
  (with-current-buffer portal-agents--buffer
    (save-excursion
      (goto-char (point-min))
      (let (rows)
        (while (not (eobp))
          (push (cons (car (tabulated-list-get-id)) (append (tabulated-list-get-entry) nil)) rows)
          (forward-line 1))
        (nreverse rows)))))

(defun portal-agents-test--row (buffer)
  "Return BUFFER's printed row, without the buffer."
  (cdr (assq buffer (portal-agents-test--rows))))

(defun portal-agents-test--line (buffer)
  "Return how many rows the dashboard prints before BUFFER's row."
  (cl-position buffer (portal-agents-test--rows) :key #'car))

(defun portal-agents-test--focused ()
  "Return the targets of the views that have the keyboard."
  (cl-remove-if-not (lambda (target) (plist-get (portal--inspect target) :focused))
                    (portal-fake-native-targets)))

(defmacro portal-agents-test--quietly (&rest body)
  "Run BODY, failing if it asks native code, a person or the system anything.
It must not inspect or focus a view, prompt, start a process or open a
connection, nor change the selected window, the current buffer or focus."
  (declare (indent 0))
  `(let ((window (selected-window))
         (buffer (current-buffer))
         (focused (portal-agents-test--focused))
         (processes (process-list)))
     (cl-letf* ((fail (lambda (&rest arguments) (error "Refresh called %S" arguments)))
                ((symbol-function 'portal--inspect) fail)
                ((symbol-function 'portal--input) fail)
                ((symbol-function 'portal--open) fail)
                ((symbol-function 'portal--place) fail)
                ((symbol-function 'read-from-minibuffer) fail)
                ((symbol-function 'read-string) fail)
                ((symbol-function 'completing-read) fail))
       ,@body)
     ;; No process or network connection started.
     (should (equal (process-list) processes))
     (should (eq (selected-window) window))
     (should (eq (current-buffer) buffer))
     (should (equal (portal-agents-test--focused) focused))))

(defun portal-agents-test--tick ()
  "Run the dashboard timer's callback once, as it runs every interval."
  (portal-agents-test--quietly (portal-agents--tick)))

(provide 'portal-agents-testing)
;;; portal-agents-testing.el ends here
