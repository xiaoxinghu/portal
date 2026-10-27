;;; portal-gui-ert.el --- Run graphical ERT suites with live progress -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Loaded by test/gui-ert.sh.  A graphical Emacs keeps messages in
;; *Messages*, so this prints them to standard error as each test starts and
;; ends, and appends a record of each to the watchdog's progress file.  A
;; stuck native call can stop every Lisp timer, so the watchdog, not Lisp,
;; bounds each test.

(require 'ert)
(require 'portal-test-tiers)

(defvar portal-gui-ert--printed nil
  "Marker in *Messages* up to which text has reached standard error.")

(defun portal-gui-ert--flush ()
  "Print what *Messages* gained since the last flush to standard error."
  (with-current-buffer (messages-buffer)
    (unless portal-gui-ert--printed
      (setq portal-gui-ert--printed (copy-marker (point-min))))
    (princ (buffer-substring-no-properties portal-gui-ert--printed (point-max))
           #'external-debugging-output)
    (set-marker portal-gui-ert--printed (point-max))))

(defun portal-gui-ert--record (event &optional test)
  "Append EVENT about TEST, a symbol, to the watchdog's progress file."
  (when-let* ((file (getenv "PORTAL_GUI_PROGRESS")))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (format "%d %s %s\n" (floor (float-time)) event (or test ""))
                    nil file t 'silent))))

(defun portal-gui-ert--listener (listener)
  "Return LISTENER, an ERT listener, reporting progress as it goes."
  (lambda (event &rest args)
    (when (eq event 'test-started)
      (let ((stats (car args)) (test (cadr args)))
        (portal-gui-ert--record "start" (ert-test-name test))
        (message "  started  %d/%d  %s (%s)"
                 (1+ (ert--stats-test-pos stats test))
                 (length (ert--stats-tests stats))
                 (ert-test-name test) (format-time-string "%T"))))
    (apply listener event args)
    (when (eq event 'test-ended)
      (portal-gui-ert--record "end" (ert-test-name (cadr args))))
    (portal-gui-ert--flush)))

(defun portal-gui-ert--wrap (args)
  "Wrap the listener in ARGS, the arguments of `ert-run-tests'."
  (cons (car args) (cons (portal-gui-ert--listener (cadr args)) (cddr args))))

(defun portal-gui-ert--skipped (stats)
  "Return the names of the tests that STATS records as skipped."
  (let (names)
    (dotimes (i (length (ert--stats-tests stats)))
      (when (ert-test-skipped-p (aref (ert--stats-test-results stats) i))
        (push (ert-test-name (aref (ert--stats-tests stats) i)) names)))
    (nreverse names)))

(defun portal-gui-ert--verdict (stats allow-skips expected)
  "Why STATS fail the run given ALLOW-SKIPS and EXPECTED, or nil."
  (let ((passed (ert-stats-completed-expected stats))
        (skipped (seq-difference (portal-gui-ert--skipped stats) allow-skips)))
    (cond ((> (ert-stats-completed-unexpected stats) 0) "unexpected results")
          (skipped (format "skipped %s" (mapconcat #'symbol-name skipped ", ")))
          ((and expected (/= passed expected))
           (format "%d expected results, not %d" passed expected))
          ((= passed 0) "no test ran"))))

(defun portal-gui-ert--run (selector allow-skips expected)
  "Run SELECTOR's tests and exit Emacs; see `portal-gui-ert-start'."
  (let ((status 1))
    (unwind-protect
        (condition-case err
            (let ((stats (progn (advice-add 'ert-run-tests :filter-args #'portal-gui-ert--wrap)
                                (unwind-protect (ert-run-tests-batch
                                                 (portal-test-tiers-selector selector))
                                  (advice-remove 'ert-run-tests #'portal-gui-ert--wrap)))))
              (if-let* ((failure (portal-gui-ert--verdict stats allow-skips expected)))
                  (message "GUI checks failed: %s" failure)
                (setq status 0)))
          (error (message "GUI checks failed: %S" err)))
      (portal-gui-ert--record "exit" status)
      (portal-gui-ert--flush)
      (kill-emacs status))))

(defun portal-gui-ert-start (selector &optional allow-skips expected)
  "Run the ERT tests SELECTOR once the command loop runs, then exit.
SELECTOR leaves out tests tagged :expensive unless PORTAL_TEST_EXPENSIVE
is set; see `portal-test-tiers-selector'.
Exit 0 if every test ran as expected, none skipped but those that
ALLOW-SKIPS, a list of test names, permits, and EXPECTED tests, or at
least one, passed."
  (setq message-log-max t)
  (portal-gui-ert--record "loaded")
  (portal-gui-ert--flush)
  (run-at-time 1 nil #'portal-gui-ert--run selector allow-skips expected))

(provide 'portal-gui-ert)
;;; portal-gui-ert.el ends here
