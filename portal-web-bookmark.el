;;; portal-web-bookmark.el --- Bookmarks for web views -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A web page's bookmark is an ordinary `bookmark.el' record, kept in the
;; user's bookmark file: its name is the page's title, its `location' the
;; page's URL and its handler `portal-web-bookmark-jump'.  So `bookmark-set',
;; `bookmark-jump', `bookmark-bmenu-list' and the packages built on them,
;; such as Consult, Embark and Marginalia, work on web pages as on files.
;; Jumping opens a new web buffer and leaves showing it to the caller, so
;; other-window and other-frame jumps put it there.  Bookmarks are also the
;; address bar's suggestions: see `portal-web-read-url'.

(require 'bookmark)
(require 'portal-web)

(declare-function portal--inspect "portal-view" (target))

(defvar portal-web-bookmark--reuse nil
  "The web buffer that `portal-web-bookmark-jump' loads its page in, or nil.
While nil, a jump opens a new web buffer.")

;;;###autoload
(defun portal-web-bookmark-make-record ()
  "Return a bookmark record for the page this buffer's web view shows.
It is named after the page's title, or its host when it has none.
A hosted app, such as a Markdown preview, cannot be bookmarked."
  (unless portal-web--target (user-error "No web view in this buffer"))
  (when portal-web--hosted-path (user-error "Only web pages can be bookmarked, not hosted apps"))
  (let* ((state (portal--inspect portal-web--target))
         (url (or (plist-get state :url) portal-web--url (user-error "This window shows no page yet")))
         (title (string-trim (replace-regexp-in-string "[[:cntrl:]]" " " (or (plist-get state :title) "")))))
    `(,(if (string-empty-p title) (portal-web--page-name url) title)
      (location . ,url)
      (handler . portal-web-bookmark-jump))))

;;;###autoload
(defun portal-web-bookmark-jump (bookmark)
  "Open BOOKMARK's page in a new web buffer, and leave that buffer current.
The caller shows the buffer, as `bookmark-jump' does.  While
`portal-web-bookmark--reuse' names a web buffer, load the page there
instead, as `portal-web-load-url' does."
  (let ((url (bookmark-prop-get bookmark 'location)))
    (portal-web--check-url url)
    (if (buffer-live-p portal-web-bookmark--reuse)
        (progn (set-buffer portal-web-bookmark--reuse)
               (portal-web-load-url url))
      (set-buffer (portal-web--create (portal-web--page-name url)
                                      (lambda () (portal-web-open url)))))))

;;;###autoload
(put 'portal-web-bookmark-jump 'bookmark-handler-type "Web")

(defun portal-web-bookmark--records ()
  "Return the bookmarks of web pages, as `bookmark-alist' orders them."
  (bookmark-maybe-load-default-file)
  (seq-filter (lambda (record) (eq (bookmark-get-handler record) 'portal-web-bookmark-jump))
              bookmark-alist))

(defun portal-web-bookmark--read (prompt)
  "Read the name of a web page's bookmark with PROMPT.
Its candidates are bookmarks, as for `bookmark-jump', annotated with
their URLs, so packages that act on bookmarks act on them."
  (let* ((records (or (portal-web-bookmark--records)
                      (user-error "No web pages are bookmarked; Command-D bookmarks one")))
         (completion-ignore-case bookmark-completion-ignore-case)
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      `(metadata
                        (category . bookmark)
                        (annotation-function
                         . ,(lambda (name)
                              (when-let* ((url (bookmark-prop-get (assoc name records) 'location)))
                                (propertize (concat "  " url) 'face 'completions-annotations)))))
                    (complete-with-action action records string predicate)))))
    (completing-read prompt table nil t nil 'bookmark-history)))

(defun portal-web-bookmark-set (name)
  "Bookmark the page this buffer's web view shows, as NAME.
Interactively, read NAME, starting from the page's title.  A bookmark
already called NAME is replaced, as `bookmark-set' does."
  (interactive
   (list (read-string "Bookmark page as: "
                      (car (portal-web-bookmark-make-record)) 'bookmark-history)))
  (let ((bookmark-make-record-function #'portal-web-bookmark-make-record)
        (name (if (string-blank-p name) (car (portal-web-bookmark-make-record)) name)))
    (bookmark-set name)
    (message "Bookmarked %s" name)))

;;;###autoload
(defun portal-web-bookmark-open (bookmark)
  "Open web page BOOKMARK in a new web buffer, from any buffer."
  (interactive (list (portal-web-bookmark--read "Open bookmark: ")))
  (bookmark-jump bookmark))

(defun portal-web-bookmark-load (bookmark)
  "Load web page BOOKMARK in this buffer's web view.
A hosted app never leaves the app host, so its buffer opens BOOKMARK in a
new buffer, as `portal-web-bookmark-open' does."
  (interactive
   (progn
     (unless portal-web--target (user-error "No web view in this buffer"))
     (list (portal-web-bookmark--read "Load bookmark: "))))
  (unless portal-web--target (user-error "No web view in this buffer"))
  (let ((portal-web-bookmark--reuse (and (not portal-web--hosted-path) (current-buffer))))
    (bookmark-jump bookmark)))

(defun portal-web-bookmark--suggestions ()
  "Return the address bar's suggestions from bookmarks, as (STRING . URL).
Each string holds the bookmark's name and URL, so either matches, and
carries the URL as its `portal-web-url' property."
  (mapcar (lambda (record)
            (let ((url (bookmark-prop-get record 'location)))
              (cons (propertize (concat (car record) "  "
                                        (propertize url 'face 'completions-annotations))
                                'portal-web-url url)
                    url)))
          (portal-web-bookmark--records)))

(provide 'portal-web-bookmark)
;;; portal-web-bookmark.el ends here
