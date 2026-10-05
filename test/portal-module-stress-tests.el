;;; portal-module-stress-tests.el --- View lifecycle churn through the bindings -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A bounded stress suite, outside routine runs: the real Emacs bindings and
;; core with the fake backend, as in portal-module-tests.el, open, place, hide
;; and close views many times.  Run with --module-assertions, which checks
;; every crossing of the module boundary.

(require 'ert)
(declare-function portal--open "portal-module" (kind options))
(declare-function portal--place "portal-module" (target edges frame))
(declare-function portal--hide "portal-module" (target))
(declare-function portal--close "portal-module" (target))
(declare-function portal--inspect "portal-module" (target))

(let ((file (getenv "PORTAL_TEST_MODULE")))
  (unless (and file (file-exists-p file))
    (error "Set PORTAL_TEST_MODULE to the fake-backend module"))
  (module-load file))

(defconst portal-module-stress--cycles 2000
  "How many times each kind of view goes through its lifecycle.")

(ert-deftest portal-module-stress-view-lifecycle-churn ()
  (let ((closed nil))
    (dotimes (cycle portal-module-stress--cycles)
      (dolist (kind '("web" "terminal"))
        (let ((target (portal--open kind '(:directory "/"))))
          (should (eq (portal--place target (vector cycle 0 (+ cycle 100) 100) "frame ✓") t))
          (should (equal (plist-get (portal--inspect target) :edges) (list cycle 0 (+ cycle 100) 100)))
          (should (eq (portal--hide target) t))
          (should-not (plist-get (portal--inspect target) :visible))
          (should (eq (portal--close target) t))
          (should-not (portal--inspect target))
          (when (zerop (% cycle 500)) (push target closed)))))
    ;; Closed targets stay closed, and the registry still opens views.
    (dolist (target closed)
      (should-not (portal--inspect target))
      (should-error (portal--close target)))
    (let ((target (portal--open "web" nil)))
      (should (plist-get (portal--inspect target) :id))
      (portal--close target))))

(provide 'portal-module-stress-tests)
;;; portal-module-stress-tests.el ends here
