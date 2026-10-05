;;; portal-suite.el --- Run one test file as a suite -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; CMake registers each Lisp suite as one test file run by this file, and
;; ./test.sh runs them (docs/testing.md):
;;
;;   emacs --batch -Q ... -l test/portal-suite.el -f portal-suite-batch FILE
;;   emacs -Q ... -l test/portal-suite.el -f portal-suite-graphical FILE
;;
;; Either loads FILE and runs exactly the tests defined in FILE: tests that a
;; file it requires defines never join the suite.  Emacs exits with status 0
;; only when at least one test ran and every test passed, or skipped and was
;; declared with `--allow-skip NAME' after FILE.  With PORTAL_TEST_RESULTS_DIR
;; set, each test's result is written there to SUITE.json, where SUITE is
;; PORTAL_TEST_SUITE or FILE's base name.  This file defines no tests.

(require 'ert)
(require 'cl-lib)
(require 'json)

(defun portal-suite--arguments ()
  "Take the test file and its options from the remaining command line."
  (let ((file (pop command-line-args-left)) allowed)
    (unless file (error "Name the test file to run"))
    (while command-line-args-left
      (let ((option (pop command-line-args-left)))
        (unless (and (equal option "--allow-skip") command-line-args-left)
          (error "Unknown suite option: %s" option))
        (push (intern (pop command-line-args-left)) allowed)))
    (list (expand-file-name file) (nreverse allowed))))

(defun portal-suite-tests (file)
  "Return the tests that FILE defined, in definition order."
  (cl-remove-if-not (lambda (test)
                      (let ((source (ert-test-file-name test)))
                        (and source (file-equal-p source file))))
                    (ert-select-tests t t)))

(defun portal-suite--print (format &rest arguments)
  "Print FORMAT with ARGUMENTS on a line of standard error."
  (princ (concat (apply #'format-message format arguments) "\n") #'external-debugging-output))

(defun portal-suite--status (test result allowed)
  "Return TEST's RESULT as a status, given the ALLOWED skips."
  (cond ((ert-test-skipped-p result)
         (if (memq (ert-test-name test) allowed) "declared-skip" "skipped"))
        ((ert-test-result-expected-p test result) "passed")
        (t "failed")))

(defun portal-suite--write (file stats allowed)
  "Write FILE's STATS to the results directory, if there is one."
  (when-let* ((directory (getenv "PORTAL_TEST_RESULTS_DIR"))
              ((not (string-empty-p directory))))
    (let* ((suite (or (getenv "PORTAL_TEST_SUITE") (file-name-base file)))
           (tests (and stats (ert--stats-tests stats)))
           (results
            (cl-loop
             for index below (length tests)
             for test = (aref tests index)
             for result = (aref (ert--stats-test-results stats) index)
             for start = (aref (ert--stats-test-start-times stats) index)
             for end = (aref (ert--stats-test-end-times stats) index)
             collect
             `((name . ,(symbol-name (ert-test-name test)))
               (status . ,(portal-suite--status test result allowed))
               (seconds . ,(if (and start end) (float-time (time-subtract end start)) 0))
               ,@(when (ert-test-result-with-condition-p result)
                   `((message . ,(truncate-string-to-width
                                  (format "%S" (ert-test-result-with-condition-condition result))
                                  2000))))))))
      (make-directory directory t)
      (with-temp-file (expand-file-name (concat suite ".json") directory)
        (insert (json-encode `((suite . ,suite)
                               (file . ,file)
                               (allowed_skips . ,(vconcat (mapcar #'symbol-name allowed)))
                               (tests . ,(vconcat results)))))))))

(defun portal-suite-run (file allowed)
  "Run the tests FILE defined, allowing the ALLOWED skips; return an exit status."
  (let* ((tests (portal-suite-tests file))
         (unknown (cl-set-difference allowed (mapcar #'ert-test-name tests))))
    (cond
     ((null tests)
      (portal-suite--print "portal-suite: %s defines no tests" file)
      (portal-suite--write file nil allowed)
      1)
     (unknown
      (portal-suite--print "portal-suite: %s defines no test %s" file
                           (mapconcat #'symbol-name unknown ", "))
      1)
     (t
      (let* ((stats (ert-run-tests-batch `(member ,@tests)))
             (statuses (cl-loop for test across (ert--stats-tests stats)
                                for result across (ert--stats-test-results stats)
                                collect (portal-suite--status test result allowed))))
        (portal-suite--write file stats allowed)
        (portal-suite--print "portal-suite: %s: %d passed, %d failed, %d skipped, %d declared skips"
                             (file-name-nondirectory file)
                             (cl-count "passed" statuses :test #'equal)
                             (cl-count "failed" statuses :test #'equal)
                             (cl-count "skipped" statuses :test #'equal)
                             (cl-count "declared-skip" statuses :test #'equal))
        (if (cl-every (lambda (status) (member status '("passed" "declared-skip"))) statuses)
            0 1))))))

(defun portal-suite--load (file)
  "Load test FILE, or exit Emacs reporting why it failed to load."
  (condition-case err
      (load file nil t t)
    (error (portal-suite--print "portal-suite: loading %s failed: %S" file err)
           (kill-emacs 1))))

(defun portal-suite-batch ()
  "Run the test file named on the command line in batch Emacs, and exit."
  (pcase-let ((`(,file ,allowed) (portal-suite--arguments)))
    (portal-suite--load file)
    (kill-emacs (portal-suite-run file allowed))))

(defun portal-suite--echo (format-string &rest arguments)
  "Also print a `message' of FORMAT-STRING and ARGUMENTS to standard error."
  (when format-string (apply #'portal-suite--print format-string arguments)))

(defun portal-suite-graphical ()
  "Run the test file named on the command line in graphical Emacs, and exit.
The tests start in the command loop once startup finishes.  Their messages,
ERT's report among them, are also printed to standard error."
  (pcase-let ((`(,file ,allowed) (portal-suite--arguments)))
    (setq message-log-max t)
    (portal-suite--load file)
    (run-at-time
     1 nil
     (lambda ()
       (advice-add 'message :after #'portal-suite--echo)
       (kill-emacs (condition-case err
                       (portal-suite-run file allowed)
                     (error (portal-suite--print "portal-suite: %S" err) 1)))))))

(provide 'portal-suite)
;;; portal-suite.el ends here
