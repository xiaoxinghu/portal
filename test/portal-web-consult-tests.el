;;; portal-web-consult-tests.el --- Web page bookmarks in Consult -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'portal-completion-testing
         (expand-file-name "portal-completion-testing"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-web-consult)

;; `portal-completion-testing' types into a real minibuffer with Consult,
;; Vertico and Orderless on.

(defmacro portal-web-consult-test--environment (&rest body)
  "Run BODY with the adapter on and no bookmarks but those BODY makes.
They go in a bookmark file of their own, which is never saved."
  (declare (indent 0))
  `(let* ((bookmark-default-file (make-temp-name
                                  (expand-file-name "portal-bookmarks-" temporary-file-directory)))
          (bookmark-alist nil)
          (bookmark-bookmarks-timestamp nil)
          (bookmark-save-flag nil)
          (bookmark-current-bookmark nil)
          (bookmark-history nil)
          (bookmark-fringe-mark nil)
          (bookmark-automatically-show-annotations nil)
          (consult-bookmark-narrow consult-bookmark-narrow))
     (portal-completion-test--environment
       (unwind-protect
           (progn (portal-web-consult-mode)
                  (bookmark-store "Docs" '((location . "https://docs.example.org/")
                                           (handler . portal-web-bookmark-jump))
                                  nil)
                  (bookmark-store "Notes" `((filename . ,(portal-completion-test--path "notes.txt"))
                                            (position . 1))
                                  nil)
                  ,@body)
         (portal-web-consult-mode -1)))
     (should-not (file-exists-p bookmark-default-file))))

(ert-deftest portal-web-consult-auto-enables-in-either-load-order ()
  ;; Fresh Emacs processes exercise package loading, without this suite's
  ;; already-loaded adapter or explicit mode activation masking a failure.
  (let ((portal (locate-library "portal")))
    (dolist (consult-first '(nil t))
      (dolist (enabled '(nil t))
        (let ((form
               `(progn
                  (setq load-path ',load-path)
                  ,@(unless enabled '((setq portal-web-consult-auto-enable nil)))
                  ,@(when consult-first '((require 'consult)))
                  (load ,portal nil t)
                  ,@(unless consult-first
                      '((cl-assert (not (featurep 'portal-web-consult)))
                        (require 'consult)))
                  (cl-assert (eq (bound-and-true-p portal-web-consult-mode) ,enabled))
                  (let ((web (lambda () (cddr (assq ?w consult-bookmark-narrow)))))
                    (if ,enabled
                        (progn
                          ;; Reloading must enable, not toggle or duplicate the handler.
                          (load ,portal nil t)
                          (cl-assert portal-web-consult-mode)
                          (cl-assert (equal (funcall web)
                                            '(eww-bookmark-jump xwidget-webkit-bookmark-jump-handler
                                              portal-web-bookmark-jump)))
                          (portal-web-consult-mode -1)
                          (cl-assert (equal (funcall web)
                                            '(eww-bookmark-jump xwidget-webkit-bookmark-jump-handler)))
                          ;; Consult's own value is left as it was.
                          (cl-assert (equal consult-bookmark-narrow
                                            (eval (car (get 'consult-bookmark-narrow 'standard-value))))))
                      (cl-assert (not (memq 'portal-web-bookmark-jump (funcall web)))))))))
          (with-temp-buffer
            (let ((status (call-process (expand-file-name invocation-name invocation-directory)
                                        nil t nil "--batch" "-Q" "--eval"
                                        (prin1-to-string form))))
              (ert-info ((format "Consult first: %S, enabled: %S\n%s"
                                 consult-first enabled (buffer-string)))
                (should (eq status 0))))))))))

(ert-deftest portal-web-consult-bookmark-narrows-to-web-pages ()
  (portal-web-consult-test--environment
    (let ((origin (current-buffer)))
      ;; w narrows to web pages' bookmarks, and choosing one opens its page.
      (should (equal (portal-completion-test--type
                      #'consult-bookmark "<f11> w SPC <f11> RET"
                      (lambda () (mapcar #'substring-no-properties (portal-completion-test--matches))))
                     '(("Notes" "Docs") ("Docs"))))
      (portal-view-sync)
      (should (eq major-mode 'portal-web-mode))
      (should (eq (window-buffer) (current-buffer)))
      (should (equal (plist-get (portal--inspect (portal-view-target)) :url)
                     "https://docs.example.org/"))
      ;; Consult's other-window commands open it in another window.
      (switch-to-buffer origin)
      (let ((consult-buffer-sources '(consult-source-buffer consult-source-bookmark))
            (window (selected-window)))
        (portal-completion-test--type #'consult-buffer-other-window "m SPC Docs RET")
        (portal-view-sync)
        (should-not (eq (selected-window) window))
        (should (eq (window-buffer window) origin))
        (should (equal (buffer-name) "*portal: docs.example.org*<2>"))
        (should (plist-get (portal--inspect (portal-view-target)) :visible))))))

(ert-deftest portal-web-consult-address-bar-under-vertico ()
  (portal-web-consult-test--environment
    (portal-open-url "https://example.com/page")
    (let ((target (portal-view-target))
          (portal-web-search-url "https://search.example/?q=%s"))
      (dolist (case '(;; Typing replaces the URL, and RET takes the first suggestion.
                      ("d o c RET" . "https://docs.example.org/")
                      ("o r g SPC d o RET" . "https://docs.example.org/")
                      ;; Input nothing matches is a site or a search.
                      ("e x a m p l e . n e t RET" . "https://example.net")
                      ("n e w s SPC t o d a y RET" . "https://search.example/?q=news+today")
                      ;; Backspace clears the URL; RET with it selected reloads it.
                      ("DEL l o c a l h o s t RET" . "http://localhost")
                      ("RET" . "https://example.com/page")))
        (portal-fake-native-commit target "https://example.com/page")
        (setq portal-fake-native-log nil)
        (portal-completion-test--type #'portal-web-load-url (car case))
        (should (equal (portal-fake-native-calls 'portal--web-load) `((,target ,(cdr case)))))))))

(provide 'portal-web-consult-tests)
;;; portal-web-consult-tests.el ends here
