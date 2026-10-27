;;; portal-gui-ert-tests.el --- The graphical runner's selection and verdict -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in batch with test/ on `load-path'.

(require 'ert)
(require 'portal-gui-ert)

(ert-deftest portal-gui-ert-allows-only-the-named-skips ()
  (let ((stats (ert-run-tests
                (list 'member
                      (make-ert-test :name 'passes :body #'ignore)
                      (make-ert-test :name 'one-display
                                     :body (lambda () (ert-skip "one display")))
                      (make-ert-test :name 'no-injector
                                     :body (lambda () (ert-skip "no injector"))))
                #'ignore)))
    (should-not (portal-gui-ert--verdict stats '(one-display no-injector) nil))
    (should (equal (portal-gui-ert--verdict stats '(one-display) nil)
                   "skipped no-injector"))
    (should (equal (portal-gui-ert--verdict stats nil nil)
                   "skipped one-display, no-injector"))))

(ert-deftest portal-gui-ert-tiers-leave-out-expensive-tests-unless-asked ()
  (let ((tests (list 'member
                     (make-ert-test :name 'plain :body #'ignore)
                     (make-ert-test :name 'gui :tags '(:gui) :body #'ignore)
                     (make-ert-test :name 'expensive :tags '(:expensive) :body #'ignore))))
    (cl-flet ((selected (expensive graphical)
                (with-environment-variables (("PORTAL_TEST_EXPENSIVE" expensive))
                  (let ((noninteractive (not graphical)))
                    (mapcar #'ert-test-name
                            (ert-select-tests (portal-test-tiers-selector tests) t))))))
      (should (equal (selected nil t) '(plain gui)))
      (should (equal (selected "" t) '(plain gui)))
      (should (equal (selected "1" t) '(plain gui expensive)))
      ;; Batch Emacs cannot run graphical tests.
      (should (equal (selected nil nil) '(plain)))
      (should (equal (selected "1" nil) '(plain expensive))))))

(provide 'portal-gui-ert-tests)
;;; portal-gui-ert-tests.el ends here
