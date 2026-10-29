;;; portal-web-consult.el --- Consult's view of web pages -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Optional; portal.el enables `portal-web-consult-mode' when Consult loads.
;; Web pages' bookmarks then join Consult's Web group of bookmarks, beside
;; EWW's and xwidget's, which `w' narrows to in `consult-bookmark'.  Without
;; it they are listed as Other.  `consult-buffer' gains a Web group of web
;; buffers, hidden until narrowed with `w'.  Tested with Consult 3.10.  The
;; buffer helpers used here, such as `consult--buffer-query', are Consult's
;; internal API, so they stay in this file.

(require 'portal-web-bookmark)

;; Consult is optional for Portal, so this file compiles and loads without it;
;; enabling the mode requires it.
(defvar consult-bookmark-narrow)
(defvar consult-buffer-sources)
(declare-function consult--buffer-query "consult" (&rest options))
(declare-function consult--buffer-pair "consult" (buffer))
(declare-function consult--buffer-state "consult" ())

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

;;; Web buffers

(defun portal-web-consult--annotation (buffer)
  "Return the URL of web BUFFER's page, or nil."
  (when-let* ((url (and (buffer-live-p buffer)
                        (with-current-buffer buffer (portal-web--current-url)))))
    (propertize (concat "  " url) 'face 'completions-annotations)))

(defvar portal-web-consult-source
  `( :name     "Web"
     :narrow   ?w
     :hidden   t
     :category buffer
     :face     consult-buffer
     :history  buffer-name-history
     :state    ,#'consult--buffer-state
     :annotate ,#'portal-web-consult--annotation
     :items
     ,(lambda () (consult--buffer-query :sort 'visibility
                                        :mode 'portal-web-mode
                                        :as #'consult--buffer-pair)))
  "Consult source for web buffers, ordered as Consult orders buffers.
`portal-web-consult-mode' adds it to `consult-buffer-sources', hidden
until narrowed with its key.  Set its `:narrow' and `:name' with
`consult-customize'.")

;;;###autoload
(define-minor-mode portal-web-consult-mode
  "List web pages and their bookmarks in Consult.
`consult-bookmark' narrows to web pages' bookmarks, with EWW's and
xwidget's, with \\`w', as `consult-bookmark-narrow' says.
`consult-buffer' gains a Web group of web buffers, hidden until narrowed
with \\`w'; customize it with `consult-customize' on
`portal-web-consult-source'."
  :global t
  :group 'portal
  (if portal-web-consult-mode
      (progn
        (require 'consult)
        (portal-web-consult--handlers
         (lambda (handlers) (append (remq 'portal-web-bookmark-jump handlers)
                                    '(portal-web-bookmark-jump))))
        (add-to-list 'consult-buffer-sources 'portal-web-consult-source t))
    (when (featurep 'consult)
      (portal-web-consult--handlers
       (lambda (handlers) (remq 'portal-web-bookmark-jump handlers)))
      (setq consult-buffer-sources (remq 'portal-web-consult-source consult-buffer-sources)))))

(provide 'portal-web-consult)
;;; portal-web-consult.el ends here
