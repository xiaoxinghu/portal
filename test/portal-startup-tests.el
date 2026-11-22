;;; portal-startup-tests.el --- Direct package loading -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in a fresh emacs --batch -Q, without -L or a fake native backend.
(require 'ert)
(defvar portal-global-shortcut--registrations)
(defvar portal-view-feature-record-handlers)
(defvar portal-build-root)
(declare-function portal-global-shortcut--remove-all "portal-global-shortcut" ())
(declare-function portal-view--load "portal-view" ())

(defconst portal-startup-test--entry
  (expand-file-name "../portal.el" (file-name-directory
                                   (or load-file-name
                                       (bound-and-true-p byte-compile-current-file)
                                       buffer-file-name))))

(ert-deftest portal-startup-loads-from-absolute-path ()
  ;; An unrelated working directory must not supply implicit sibling lookup.
  (let ((default-directory temporary-file-directory))
    (should-not (featurep 'portal))
    (load portal-startup-test--entry nil t)
    (dolist (feature '(portal portal-build portal-web portal-terminal
                      portal-excalidraw portal-global-shortcut portal-system))
      (should (featurep feature)))
    (dolist (command '(portal-hello portal-terminal portal-build portal-download-runtime))
      (should (commandp command)))
    ;; The build belongs to this checkout, not the working directory.
    (should (equal portal-build-root
                   (file-truename (file-name-directory portal-startup-test--entry))))
    (should (fboundp 'portal-global-shortcut-set))
    (should (fboundp 'portal-post-key))
    ;; Loading starts no build, download or other process, registers no
    ;; shortcut and loads no native code.
    (should-not (process-list))
    (should-not portal-global-shortcut--registrations)
    (should-not (featurep 'portal-native-module))
    (should-not (assoc "shortcut" portal-view-feature-record-handlers))
    (should-not (memq #'portal-global-shortcut--remove-all kill-emacs-hook))
    ;; Batch has no graphical frame: native use names the requirement instead.
    (should (equal (cadr (should-error (portal-view--load) :type 'user-error))
                   "Portal native views need a graphical Emacs frame; this frame is a text terminal"))
    (should-not (featurep 'portal-native-module))))

(provide 'portal-startup-tests)
;;; portal-startup-tests.el ends here
