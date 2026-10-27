;;; portal-test-tiers.el --- Which tests a run selects -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Tests carry ERT tags: :gui for those that need graphical Emacs, and
;; :expensive for long soaks and matrices.  Every runner narrows its selector
;; here, so a run leaves :expensive tests out unless PORTAL_TEST_EXPENSIVE is
;; set and not empty, and batch Emacs never selects :gui tests.

(require 'ert)

(defun portal-test-tiers-expensive-p ()
  "Return non-nil if this run includes tests tagged :expensive."
  (not (member (getenv "PORTAL_TEST_EXPENSIVE") '(nil ""))))

(defun portal-test-tiers-selector (selector)
  "Return SELECTOR, an ERT selector, narrowed to this run's tiers."
  `(and ,selector
        ,@(unless (portal-test-tiers-expensive-p) '((not (tag :expensive))))
        ,@(when noninteractive '((not (tag :gui))))))

(defun portal-test-tiers-run-batch ()
  "Run this run's tiers of the loaded tests in batch Emacs, then exit.
Use it in place of `ert-run-tests-batch-and-exit'."
  (ert-run-tests-batch-and-exit (portal-test-tiers-selector t)))

(provide 'portal-test-tiers)
;;; portal-test-tiers.el ends here
