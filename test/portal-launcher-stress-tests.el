;;; portal-launcher-stress-tests.el --- Launcher panel lifecycle churn -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A bounded stress suite, outside routine runs, in a disposable graphical
;; Emacs with the newly built module: the panel cycles that
;; portal-launcher-gui-tests.el checks a few times, many times over.

(require 'portal-launcher-testing)
(declare-function portal--launcher-inspect "portal-launcher" ())

(ert-deftest portal-launcher-stress-hide-and-show-reuse-the-panel ()
  (portal-launcher-gui--with-panel
    (with-current-buffer content (insert "Reused panel\n"))
    (let ((frame (portal-launcher-show content)))
      (dotimes (_ 100)
        (portal-launcher-hide)
        (should-not (frame-visible-p frame))
        (should (eq (portal-launcher-show) frame)))
      (should (eq (window-buffer (frame-selected-window frame)) content))
      (should (plist-get (portal--launcher-inspect) :viewAttached))
      (portal-launcher-hide)
      (should (eq (selected-window) ordinary)))))

(ert-deftest portal-launcher-stress-deleted-panels-detach ()
  (portal-launcher-gui--with-panel
    (dotimes (_ 20)
      (let ((frame (portal-launcher-show content)))
        (delete-frame frame t)
        (should-not (frame-live-p frame))
        (should-not (plist-get (portal--launcher-inspect) :attached))))
    (should (eq (selected-window) ordinary))))

(provide 'portal-launcher-stress-tests)
;;; portal-launcher-stress-tests.el ends here
