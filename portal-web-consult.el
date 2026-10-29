;;; portal-web-consult.el --- Consult's view of web page bookmarks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Optional; portal.el enables `portal-web-consult-mode' when Consult loads.
;; Web pages' bookmarks then join Consult's Web group of bookmarks, beside
;; EWW's and xwidget's, which `w' narrows to in `consult-bookmark'.  Without
;; it they are listed as Other.  Tested with Consult 3.10.

(require 'portal-web-bookmark)

;; Consult is optional for Portal, so this file compiles and loads without it;
;; enabling the mode requires it.
(defvar consult-bookmark-narrow)

(defun portal-web-consult--handlers (function)
  "Replace the handlers of the Web entry of `consult-bookmark-narrow'.
FUNCTION gets the entry's handlers and returns the new ones.  The entry
is the one \\`w' narrows to; without one, a new one is added before the
catch-all entry."
  (let ((rest (seq-take-while #'car consult-bookmark-narrow)))
    (setq consult-bookmark-narrow
          (if (assq ?w consult-bookmark-narrow)
              (mapcar (lambda (entry)
                        (if (eq (car entry) ?w)
                            `(,(car entry) ,(cadr entry) ,@(funcall function (cddr entry)))
                          entry))
                      consult-bookmark-narrow)
            (append rest `((?w "Web" ,@(funcall function nil)))
                    (nthcdr (length rest) consult-bookmark-narrow))))))

;;;###autoload
(define-minor-mode portal-web-consult-mode
  "List web pages' bookmarks in Consult's Web group of bookmarks.
`consult-bookmark' then narrows to them, with EWW's and xwidget's, with
\\`w', as `consult-bookmark-narrow' says."
  :global t
  :group 'portal
  (if portal-web-consult-mode
      (progn
        (require 'consult)
        (portal-web-consult--handlers
         (lambda (handlers) (append (remq 'portal-web-bookmark-jump handlers)
                                    '(portal-web-bookmark-jump)))))
    (when (featurep 'consult)
      (portal-web-consult--handlers
       (lambda (handlers) (remq 'portal-web-bookmark-jump handlers))))))

(provide 'portal-web-consult)
;;; portal-web-consult.el ends here
