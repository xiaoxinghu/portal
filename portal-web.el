;;; portal-web.el --- Web views -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A web buffer presents one web view, which follows the buffer as
;; `portal-view.el' describes.  Pages and previews each get their own buffer.
;; Hosted apps open at once, at about:blank, and load once the app host is
;; ready.  After that they keep their page while the app host stops or restarts.
;; A hosted app and its buffer exchange JSON messages over the bridge.
;; A Markdown preview follows links to other Markdown files itself, and hands
;; links to other local files to Emacs, which visits them in another pane.
;; Its view reports the pages it shows, and those links, over the bridge.
;; Every web view saves downloads in `portal-web-download-directory' and
;; reports how they go over the same queue, which Emacs reports in turn.

(require 'browse-url)
(require 'delsel)
(require 'json)
(require 'seq)
(require 'url-parse)
(require 'url-util)
(require 'portal-view)
(require 'portal-input)
(require 'portal-server)

(declare-function portal--web-load "portal-web" (target url))
(declare-function portal--web-send "portal-web" (target json))
(declare-function portal--web-receive "portal-web" (target))
(declare-function portal--web-go "portal-web" (target step))
(declare-function portal--web-appearance "portal-web" (appearance))
(declare-function portal--inspect "portal-view" (target))
(declare-function portal--close "portal-view" (target))
(declare-function portal--web-download-directory "portal-web" (directory))
(declare-function portal--web-find "portal-web" (target text backward case-sensitive))
(declare-function portal--web-zoom "portal-web" (host percent))

;; Bookmarks of web pages: `portal-web-bookmark.el' loads when first used,
;; however this file was loaded, as by an autoloaded command.
(autoload 'portal-web-bookmark-make-record "portal-web-bookmark")
(autoload 'portal-web-bookmark--suggestions "portal-web-bookmark")
(autoload 'portal-web-bookmark-set "portal-web-bookmark" nil t)
(autoload 'portal-web-bookmark-load "portal-web-bookmark" nil t)
(autoload 'portal-web-bookmark-open "portal-web-bookmark" nil t)
(defvar bookmark-make-record-function)

(defun portal-web--appearance-changed (_symbol value operation _where)
  "Check appearance VALUE and show every web view in it, on OPERATION `set'."
  (when (eq operation 'set)
    (unless (memq value '(nil light dark))
      (error "Web view appearance must be nil, `light' or `dark'"))
    (when (fboundp 'portal--web-appearance)
      (portal--web-appearance (and value (symbol-name value))))))

(defcustom portal-web-appearance nil
  "Whether web views, such as Markdown previews, look light or dark.
Nil follows the system's light or dark appearance as it changes, even when
Emacs frames force their own with the `ns-appearance' frame parameter.
`light' or `dark' keeps every web view so.  A page sees it as CSS's
prefers-color-scheme.  Changes with `setq', `setopt' or Customize, or with
`portal-web-set-appearance', apply to open web views without reloading."
  :type '(choice (const :tag "System appearance" nil)
                 (const :tag "Light" light)
                 (const :tag "Dark" dark))
  :group 'portal)
(add-variable-watcher 'portal-web-appearance #'portal-web--appearance-changed)

;;;###autoload
(defun portal-web-set-appearance (appearance)
  "Show every web view in APPEARANCE: `light', `dark', or nil for the system's.
This sets `portal-web-appearance'."
  (interactive
   (list (cdr (assoc (completing-read "Web view appearance: " '("system" "light" "dark") nil t)
                     '(("light" . light) ("dark" . dark))))))
  (setq portal-web-appearance appearance))

(defcustom portal-web-inspectable t
  "Whether Safari's Web Inspector may attach to web views.
Non-nil lists each web view opened afterwards, hosted apps and previews
included, under Safari's Develop menu, in this Mac's Emacs entry, once
\"Show features for web developers\" is on in Safari's Advanced settings.
It only allows attaching: nothing opens until Safari's menu is used.
It needs macOS 13.3 or later; earlier versions ignore it."
  :type 'boolean
  :group 'portal)

(defun portal-web--download-directory-changed (_symbol value operation _where)
  "Save downloads in directory VALUE from now on, on OPERATION `set'."
  (when (eq operation 'set)
    (unless (stringp value)
      (error "The web download directory must be a directory name"))
    (when (fboundp 'portal--web-download-directory)
      (portal--web-download-directory (expand-file-name value)))))

(defcustom portal-web-download-directory "~/Downloads/"
  "Directory where web views save the files they download.
A download keeps the name the site suggests, numbered as in \"report (1).pdf\"
when a file there already has it.  Emacs says when each download starts,
finishes or fails.  Changes apply to downloads that start afterwards."
  :type 'directory
  :group 'portal)
(add-variable-watcher 'portal-web-download-directory #'portal-web--download-directory-changed)

(defvar-local portal-web--target nil "This buffer's web view target, or nil.")
(defvar-local portal-web--url nil
  "The URL this buffer's web view loaded last.
It is nil while a hosted app waits for the app host.")
(defvar-local portal-web--preview nil "The URL this buffer previews, in a `portal-render-html' buffer.")
(defvar-local portal-web--hosted-path nil "The app host path of this buffer's hosted app, or nil.")
(defvar-local portal-web--markdown nil "The Markdown file this preview shows, or nil.")
(defvar-local portal-web-bridge-function nil
  "Function called with each message this buffer's hosted app sends, in order.
Each message is a JSON object parsed into a plist.  The function runs with
the buffer current, inside a process filter, so it must never prompt; it
queues commands through `unread-command-events'.")

(define-derived-mode portal-web-mode special-mode "Portal Web"
  "Major mode for a buffer presenting a web view.
RET or a click enters the page; `portal-input-escape-key' returns to Emacs.
A chord the page does not use reaches Emacs, which runs it in this buffer.
g or Command-R loads the page again, Command-L loads another URL or
searches the web, Command-T does so in a new buffer, and l and r or
Command-[ and Command-] go back and forward, whether Emacs or the page
owns the keyboard, unless the page uses those Command keys itself.
Command-D bookmarks the page, b or Command-B loads a bookmarked page
here, and B or Command-Shift-B opens one in a new buffer; `bookmark-jump'
and the other bookmark commands open them too.  C-s or Command-F finds
text in the page, and Command-G and Command-Shift-G find it again;
+ or Command-= zooms in, - or Command-- zooms out and 0 or Command-0
resets, for every page from the same site.  The mode line's light is
lit while the page has the keyboard and dimmed while Emacs has it.
q hides the view while the page keeps running, and killing the buffer
closes it."
  (setq-local cursor-type nil)
  (setq-local bookmark-make-record-function #'portal-web-bookmark-make-record)
  (portal-input-mode 1))
(keymap-set portal-web-mode-map "g" #'portal-web-reload)
(keymap-set portal-web-mode-map "l" #'portal-web-back)
(keymap-set portal-web-mode-map "r" #'portal-web-forward)
(keymap-set portal-web-mode-map "s-r" #'portal-web-reload)
(keymap-set portal-web-mode-map "s-l" #'portal-web-load-url)
(keymap-set portal-web-mode-map "s-t" #'portal-open-url)
(keymap-set portal-web-mode-map "s-d" #'portal-web-bookmark-set)
(keymap-set portal-web-mode-map "b" #'portal-web-bookmark-load)
(keymap-set portal-web-mode-map "s-b" #'portal-web-bookmark-load)
(keymap-set portal-web-mode-map "B" #'portal-web-bookmark-open)
(keymap-set portal-web-mode-map "s-B" #'portal-web-bookmark-open)
(keymap-set portal-web-mode-map "s-[" #'portal-web-back)
(keymap-set portal-web-mode-map "s-]" #'portal-web-forward)
(keymap-set portal-web-mode-map "C-s" #'portal-web-find)
(keymap-set portal-web-mode-map "C-r" #'portal-web-find-backward)
(keymap-set portal-web-mode-map "s-f" #'portal-web-find)
(keymap-set portal-web-mode-map "s-g" #'portal-web-find-next)
(keymap-set portal-web-mode-map "s-G" #'portal-web-find-previous)
(dolist (key '("+" "=" "s-+" "s-="))
  (keymap-set portal-web-mode-map key #'portal-web-zoom-in))
(dolist (key '("-" "s--"))
  (keymap-set portal-web-mode-map key #'portal-web-zoom-out))
(dolist (key '("0" "s-0"))
  (keymap-set portal-web-mode-map key #'portal-web-zoom-reset))

(defun portal-web--check-url (url)
  "Signal a user error unless URL is a URL a web view can load."
  (unless (and (stringp url)
               (string-match-p "\\`\\(?:https?://[^/[:space:]]+\\|file:///\\|data:\\|about:\\)" url))
    (user-error "Enter an absolute http, https, file, data or about URL")))

(defun portal-web-open (url)
  "Open a web view for the current buffer, load URL in it and return its target.
URL is an absolute http, https, file, data or about URL.
Once URL starts loading, this turns on `portal-input-mode', keeping the
buffer's major mode.  If the view cannot open or load URL, it is closed."
  (portal-web--check-url url)
  (portal-web--open url nil))

(defun portal-web-open-hosted (path)
  "Open a hosted web view for the current buffer and return its target.
The view opens at once, at about:blank, and loads PATH from the app host,
such as \"/hello\", as soon as the host is ready.  This starts the host if
needed; if it cannot start, the view stays at about:blank and
`portal-web-reload' tries again.
The view keeps no cookies or storage between Emacs sessions, and a page
outside the app host opens in the default browser instead."
  (prog1 (portal-web--open "about:blank" (list :hosted t))
    (setq portal-web--hosted-path path)
    (portal-web--load-hosted)))

(defun portal-web--open (url options)
  "Open a web view with OPTIONS for the current buffer, and load URL in it.
The view starts in `portal-web-appearance', inspectable when
`portal-web-inspectable' says so, and saves downloads in
`portal-web-download-directory'."
  (portal-input--connect)
  (portal--web-download-directory (expand-file-name portal-web-download-directory))
  (let ((target (portal-view-open
                 'web (append (and portal-web-appearance
                                   (list :appearance (symbol-name portal-web-appearance)))
                              (and portal-web-inspectable (list :inspectable t))
                              options)))
        ready)
    (unwind-protect
        (progn
          (portal--web-load target url)
          (setq ready t))
      (unless ready (portal-view-close)))
    (setq portal-web--target target
          portal-web--url url)
    (portal-input-mode 1)
    target))

(defun portal-web-reload ()
  "Load this buffer's page again.
A hosted app loads from the app host, which starts first if needed.
A window that a page opened loads the page it shows."
  (interactive)
  (unless portal-web--target (user-error "No web view in this buffer"))
  (if portal-web--hosted-path
      (portal-web--load-hosted)
    (portal--web-load portal-web--target
                      (or portal-web--url
                          (plist-get (portal--inspect portal-web--target) :url)
                          (user-error "This window shows no page yet")))))

(defun portal-web-load-url (url)
  "Load URL in this buffer's web view, as a browser's address bar does.
Interactively, read it with `portal-web-read-url', starting from the page
on screen.  The buffer takes the page's name, and `portal-web-reload'
loads URL from then on.  A hosted app never leaves the app host, so its
buffer opens URL in a new buffer, as `portal-open-url' does."
  (interactive
   (progn
     (unless portal-web--target (user-error "No web view in this buffer"))
     (list (portal-web-read-url "Load URL or search: " (portal-web--current-url)))))
  (unless portal-web--target (user-error "No web view in this buffer"))
  (portal-web--check-url url)
  (if portal-web--hosted-path
      (portal-open-url url)
    (portal--web-load portal-web--target url)
    (setq portal-web--url url
          portal-web--preview nil)
    (let ((name (format "*portal: %s*" (portal-web--page-name url))))
      (unless (string-prefix-p name (buffer-name))
        (rename-buffer name t)))))

;; The omnibox: the minibuffer as a browser's address bar.

(defcustom portal-web-search-url "https://www.google.com/search?q=%s"
  "The URL that searches the web for what the address bar reads.
Its one %s becomes the words read, each percent-encoded, joined by +."
  :type 'string
  :group 'portal)

(defvar portal-web-omnibox-sources '(("Bookmark" . portal-web-bookmark--suggestions))
  "Where the address bar's suggestions come from, as (GROUP . FUNCTION).
FUNCTION returns a list of (STRING . URL) pairs, shown under the heading
GROUP in that order.  STRING is what completion matches, such as a page's
title and URL, and must be unique.")

(defun portal-web--current-url ()
  "Return the URL of this buffer's page, or nil when it has none."
  (and portal-web--target
       (or (plist-get (portal--inspect portal-web--target) :url) portal-web--url)))

(defun portal-web--address (input)
  "Return the URL that address bar INPUT names, or nil if INPUT is a search.
A URL with a scheme stands as typed.  A host, such as example.com,
localhost:3000 or 192.168.1.1, and a host with a path, such as
en.wikipedia.org/wiki/Emacs, gain https://, or http:// for localhost."
  (cond ((string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*://\\|\\`\\(?:about\\|data\\|file\\):" input)
         input)
        ((string-match-p "\\`localhost\\(?:[:/]\\|\\'\\)" input)
         (concat "http://" (string-replace " " "%20" input)))
        ((string-match-p (concat "\\`[[:alnum:]_-]+\\(?:\\(?:\\.[[:alnum:]_-]+\\)+\\(?::[0-9]+\\)?"
                                 "\\|:[0-9]+\\)\\(?:[/?#].*\\)?\\'")
                         input)
         (concat "https://" (string-replace " " "%20" input)))))

(defun portal-web--search-url (input)
  "Return the URL that searches the web for the words in INPUT."
  (format portal-web-search-url (mapconcat #'url-hexify-string (split-string input) "+")))

(defun portal-web--resolve (input candidates)
  "Return the URL that address bar INPUT asks for, given CANDIDATES.
That is a chosen candidate's URL, the URL INPUT names, or a search."
  (let ((input (string-trim input)))
    (when (string-empty-p input) (user-error "Enter a URL or words to search for"))
    (or (cdr (assoc input candidates))
        (get-text-property 0 'portal-web-url input)
        (portal-web--address input)
        (portal-web--search-url input))))

(defun portal-web--select-input ()
  "Select the minibuffer's input, as a browser selects its address bar's URL.
Until another command deselects it, the next key decides what happens to it:
see `portal-web--selected-input-command'."
  (when (> (point-max) (minibuffer-prompt-end))
    ;; Without Transient Mark mode, the selection lasts as a shifted one does.
    (unless transient-mark-mode
      (setq-local transient-mark-mode (cons 'only nil)))
    (goto-char (point-max))
    (push-mark (minibuffer-prompt-end) t t)
    (add-hook 'pre-command-hook #'portal-web--selected-input-command nil t)))

(defun portal-web--selected-input-command ()
  "Apply the command about to run to the selected input, once.
Typing or yanking replaces it, and deleting or killing clears it, as in
`delete-selection-mode'.  Left and Right deselect it, with the cursor at
its start or end.  Any other command deselects it and runs as usual, so
RET with the input still selected loads it."
  (remove-hook 'pre-command-hook #'portal-web--selected-input-command t)
  (when (region-active-p)
    (cond ((and (symbolp this-command) (get this-command 'delete-selection))
           (let ((delete-selection-mode t))
             (delete-selection-pre-hook)))
          ((or (memq this-command '(delete-backward-char delete-forward-char delete-char
                                    backward-delete-char-untabify kill-line kill-whole-line))
               (member (this-command-keys-vector) '([?\d] [backspace] [deletechar] [delete])))
           (delete-region (region-beginning) (region-end))
           (setq this-command 'ignore))
          ((memq this-command '(left-char backward-char))
           (goto-char (region-beginning))
           (setq this-command 'ignore))
          ((memq this-command '(right-char forward-char))
           (goto-char (region-end))
           (setq this-command 'ignore)))
    (deactivate-mark)))

;; Match any part of a suggestion, its title or URL, without extra packages.
(add-to-list 'completion-category-defaults '(portal-web-url (styles basic substring)))

(defun portal-web-read-url (prompt &optional current)
  "Read a URL with PROMPT, as a browser's address bar does, and return it.
The minibuffer starts with CURRENT, the page on screen, selected: typing
replaces it, Backspace clears it, and Left or Right edits it.  RET with
it selected loads it again.  Suggestions from `portal-web-omnibox-sources',
such as bookmarks, match their title or URL.  A suggestion gives its URL;
otherwise input that looks like a URL gives that URL, and other input
searches the web with `portal-web-search-url'."
  (let* ((groups (mapcar (lambda (source)
                           (cons (car source) (funcall (cdr source))))
                         portal-web-omnibox-sources))
         (candidates (apply #'append (mapcar #'cdr groups)))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      `(metadata
                        (category . portal-web-url)
                        (display-sort-function . identity)
                        (cycle-sort-function . identity)
                        (group-function
                         . ,(lambda (candidate transform)
                              (if transform
                                  candidate
                                (car (seq-find (lambda (group) (assoc candidate (cdr group)))
                                               groups))))))
                    (complete-with-action action candidates string predicate))))
         (input (minibuffer-with-setup-hook #'portal-web--select-input
                  (completing-read prompt table nil nil current nil current))))
    (portal-web--resolve input candidates)))

(defun portal-web--selected ()
  "Return the target of the selected pane's web view, or signal a user error."
  (let ((target (portal-view-target)))
    (unless (and target (string-prefix-p "web:" target))
      (user-error "Select a Portal web view"))
    target))

(defun portal-web--go (step)
  "Move the selected pane's web view through its history by STEP.
STEP is \"back\" or \"forward\"; with no page to go to, nothing changes."
  (portal--web-go (portal-web--selected) step))

(defun portal-web-back ()
  "Go back to the previous page in this web view's history."
  (interactive)
  (portal-web--go "back"))

(defun portal-web-forward ()
  "Go forward to the next page in this web view's history."
  (interactive)
  (portal-web--go "forward"))

;; Finding text in the page.  WebKit finds and highlights; Emacs keeps the
;; keyboard, and the minibuffer reads the text.

(defvar portal-web-find-history nil "Texts found in web views, newest first.")
(defvar-local portal-web--finding nil "The text this buffer's view looked for last.")
(defvar portal-web--find-window nil
  "The pane whose web view `portal-web-find' reads text for, while it reads.")
(defvar portal-web--found nil
  "The text `portal-web-find''s minibuffer last found, while it reads.")

(defvar portal-web-find-minibuffer-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map minibuffer-local-map)
    (keymap-set map "C-s" #'portal-web-find-next)
    (keymap-set map "C-r" #'portal-web-find-previous)
    map)
  "Keys of the minibuffer that `portal-web-find' reads text in.")

(defun portal-web--case-sensitive (text)
  "Whether finding TEXT minds case, as isearch decides.
It does while `case-fold-search' is off, or when TEXT has an upper-case
letter and `search-upper-case' is on."
  (not (and case-fold-search
            (or (not search-upper-case) (isearch-no-upper-case-p text nil)))))

(defun portal-web--search (text backward)
  "Find TEXT in the selected pane's web view, BACKWARD or forward."
  (portal--web-find (portal-web--selected) text backward (portal-web--case-sensitive text))
  (with-current-buffer (window-buffer)
    (setq portal-web--finding text)))

(defun portal-web-find (&optional backward)
  "Find text in this buffer's page, reading it in the minibuffer.
RET finds the text after the page's selection, or before it with
BACKWARD, wrapping around, and the page highlights the match.  While
reading, \\<portal-web-find-minibuffer-map>\\[portal-web-find-next] and \\[portal-web-find-previous] move to the next and previous match,
and RET then stays on the match shown.  Empty input finds the last text
again.  Case matters as in isearch: while `case-fold-search' is off, or
when the text has an upper-case letter.  The page never takes the
keyboard, so Emacs keeps it once the text is found."
  (interactive)
  (portal-web--selected)
  (let* ((last (car portal-web-find-history))
         (portal-web--find-window (selected-window))
         (portal-web--found nil)
         (text (read-from-minibuffer (format-prompt (if backward "Find backward" "Find") last)
                                     nil portal-web-find-minibuffer-map nil
                                     'portal-web-find-history last)))
    (when (string-empty-p text)
      (setq text (or last (user-error "Nothing to find"))))
    (unless (equal text portal-web--found)
      (portal-web--search text backward))))

(defun portal-web-find-backward ()
  "Find text before the selection in this buffer's page, as `portal-web-find' does."
  (interactive)
  (portal-web-find t))

(defun portal-web-find-next (&optional backward)
  "Move to the next match of the last text found in this buffer's page.
With BACKWARD, move to the previous one.  In `portal-web-find''s
minibuffer, find the text being read, or the last text if it is empty.
With no text found yet, read one as `portal-web-find' does."
  (interactive)
  (if (and portal-web--find-window (minibufferp))
      (let ((text (minibuffer-contents)))
        (when (string-empty-p text)
          (insert (setq text (or (car portal-web-find-history) (user-error "Nothing to find")))))
        (with-selected-window portal-web--find-window
          (portal-web--search text backward))
        (setq portal-web--found text))
    (if-let* ((text (car portal-web-find-history)))
        (portal-web--search text backward)
      (portal-web-find backward))))

(defun portal-web-find-previous ()
  "Move to the previous match of the last text found.
This is `portal-web-find-next' going backward."
  (interactive)
  (portal-web-find-next t))

;; The view's latest find ended without a match.
(setf (alist-get "found" portal-view-record-handlers nil nil #'equal)
      (lambda (_target found)
        (unless (equal found "1")
          (message "No match for %S" portal-web--finding))))

;; Zoom, remembered per site.

(defcustom portal-web-zoom-steps '(50 75 85 100 115 125 150 175 200 250 300)
  "The zoom levels, in percent, that the zoom commands step through.
`portal-web-zoom-in' and `portal-web-zoom-out' move to the next one.
Each is from 25 to 500, in increasing order."
  :type '(repeat integer) :group 'portal)

(defvar portal-web-zoom-levels nil
  "The zoom level of each site not at 100%, as (HOST . PERCENT).
Every page from HOST shows at PERCENT, in every web view, and each page
a view goes to shows at its own host's level.  HOST is in lower case, as
`url-host' has it, and \"\" stands for pages without a host, such as
local files.  The zoom commands set this.  With `savehist-mode' on, it is
kept from one Emacs session to the next.")
(defvar savehist-additional-variables)
(with-eval-after-load 'savehist
  (add-to-list 'savehist-additional-variables 'portal-web-zoom-levels))

(defun portal-web--send-zoom-levels ()
  "Give the native module every site's zoom level."
  (when (fboundp 'portal--web-zoom)
    (pcase-dolist (`(,host . ,percent) portal-web-zoom-levels)
      (with-demoted-errors "Portal web zoom: %S"
        (portal--web-zoom host percent)))))
(add-hook 'portal-view-load-hook #'portal-web--send-zoom-levels)

(defun portal-web--host (target)
  "Return the host of web view TARGET's page, as `portal-web-zoom-levels' has it."
  (let ((url (plist-get (portal--inspect target) :url)))
    (or (and url (url-host (url-generic-parse-url url))) "")))

(defun portal-web--zoom (choose)
  "Zoom the selected pane's site to the level CHOOSE returns.
CHOOSE gets the site's level now, in percent."
  (let* ((target (portal-web--selected))
         (host (portal-web--host target))
         (others (seq-remove (lambda (entry) (equal (car entry) host)) portal-web-zoom-levels))
         (percent (funcall choose (alist-get host portal-web-zoom-levels 100 nil #'equal))))
    (portal--web-zoom host percent)
    (setq portal-web-zoom-levels (if (= percent 100) others (cons (cons host percent) others)))
    (message "Zoom %d%% for %s" percent (if (string-empty-p host) "local pages" host))))

(defun portal-web-zoom-in ()
  "Show every page from this page's site larger.
It moves to the next level in `portal-web-zoom-steps'."
  (interactive)
  (portal-web--zoom (lambda (current)
                      (or (seq-find (lambda (step) (> step current)) portal-web-zoom-steps)
                          current))))

(defun portal-web-zoom-out ()
  "Show every page from this page's site smaller.
It moves to the previous level in `portal-web-zoom-steps'."
  (interactive)
  (portal-web--zoom (lambda (current)
                      (or (seq-find (lambda (step) (< step current)) (reverse portal-web-zoom-steps))
                          current))))

(defun portal-web-zoom-reset ()
  "Show every page from this page's site at its own size again."
  (interactive)
  (portal-web--zoom (lambda (_current) 100)))

(defun portal-web--find (variable value)
  "Return the web buffer whose buffer-local VARIABLE is VALUE, or nil."
  (seq-find (lambda (buffer) (equal (buffer-local-value variable buffer) value))
            (portal-view-buffers 'web)))

(defun portal-web--page-name (url)
  "Name URL's page: its host, its file name, or the URL itself."
  (let ((parsed (url-generic-parse-url url)))
    (pcase (url-type parsed)
      ((or "http" "https") (url-host parsed))
      ;; Decode as `browse-url-file-url' encodes.
      ("file" (file-name-nondirectory
               (decode-coding-string (url-unhex-string (url-filename parsed))
                                     (or file-name-coding-system
                                         default-file-name-coding-system))))
      ("data" "data")
      (_ url))))

(defun portal-web--start-buffer ()
  "Put the current buffer, new, in `portal-web-mode', with its help text."
  (portal-web-mode)
  (let ((inhibit-read-only t))
    (insert "Web view\n\n"
            "RET or a click enters the page. The configured escape returns to Emacs.\n"
            "See M-x customize-option RET portal-input-escape-key for that key.\n"
            "g loads the page again. q hides it; killing the buffer closes it.\n"
            "Command-L loads another URL or searches; Command-T opens one in a new buffer.\n"
            "l and r go back and forward.\n"
            "Command-D bookmarks the page; b loads a bookmark here, B in a new buffer.\n"
            "C-s finds text in the page; + and - zoom, and 0 resets.\n"
            "This buffer has one live view, which follows its selected pane.\n")))

(defun portal-web--create (name open &optional show)
  "Return a new web buffer called *portal: NAME*, whose view OPEN opens.
No pane shows the buffer yet, so its view stays hidden until one does,
as a hidden view does.  Then SHOW, if non-nil, is called with the
buffer, even when OPEN signals once the view is open, as when a hosted
app's host cannot start.  If the view cannot open, the buffer is killed."
  (let ((buffer (generate-new-buffer (format "*portal: %s*" name))))
    (unwind-protect
        (with-current-buffer buffer
          (portal-web--start-buffer)
          (funcall open))
      (if (and (buffer-live-p buffer) (buffer-local-value 'portal-web--target buffer))
          (when show (funcall show buffer))
        (kill-buffer buffer)))
    buffer))

(defun portal-web--visit (buffer name open)
  "Select web BUFFER and reload it, or, when BUFFER is nil, open a new one.
The new buffer is called *portal: NAME*, and OPEN opens its view.  If the
view cannot open, the new buffer is killed."
  (if buffer
      (progn (switch-to-buffer buffer) (portal-web-reload))
    (portal-web--create name open
                        (lambda (buffer)
                          (switch-to-buffer buffer)
                          ;; Place the view now rather than at the next redisplay.
                          (portal-view-sync)))
    (message "Web view opened. RET enters; %s returns to Emacs; q hides the view."
             portal-input-escape-key)))

;;;###autoload
(defun portal-open-url (url)
  "Open URL in a web view, in a new buffer named after its page.
Click the page or press RET to interact; `portal-input-escape-key'
returns control to Emacs.  HTTP(S), file, data and about
URLs are supported.  Interactively, read it with `portal-web-read-url',
starting from the page on screen in a web buffer, as a browser opens a tab."
  (interactive (list (portal-web-read-url "Open URL or search: " (portal-web--current-url))))
  (portal-web--check-url url)
  (portal-web--visit nil (portal-web--page-name url)
                     (lambda () (portal-web-open url))))

;;;###autoload
(defun portal-render-html (file-or-url)
  "Preview local HTML FILE-OR-URL, or a URL, in a web view.
Use the current buffer's file when its extension is .html or .htm;
otherwise prompt for a path or URL.  With a prefix argument, always prompt.
Local paths are relative to `default-directory'.  Only saved contents are
shown; unsaved edits are not included.  Relative assets can load from the
file's containing directory.  URLs supported by `portal-open-url' are accepted.
Previewing the same file or URL again reuses its buffer and reloads it."
  (interactive
   (list
    (if (and (not current-prefix-arg) buffer-file-name
             (let ((case-fold-search t))
               (string-match-p "\\.html?\\'" buffer-file-name)))
        buffer-file-name
      (read-string "Open HTML file or URL: "))))
  (unless (and (stringp file-or-url) (not (string-empty-p file-or-url)))
    (user-error "Enter a local HTML path or URL"))
  (let ((url (if (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" file-or-url)
                 file-or-url
               (let ((path (expand-file-name file-or-url)))
                 (when (file-remote-p path)
                   (user-error "Choose a local HTML file or an HTTP(S) URL"))
                 (unless (and (file-regular-p path) (file-readable-p path))
                   (user-error "Choose a readable regular file: %s" path))
                 (browse-url-file-url path)))))
    (portal-web--check-url url)
    (portal-web--visit (portal-web--find 'portal-web--preview url)
                       (portal-web--page-name url)
                       (lambda () (portal-web-open url)))
    (setq portal-web--preview url)))

;;;###autoload
(defun portal-hello ()
  "Open Hello World, starting the bundled app host on first use."
  (interactive)
  (portal-web--visit-hosted "/hello" "hello"))

;;;###autoload
(defun portal-about ()
  "Show Portal's versions and contact details, starting the app host if needed."
  (interactive)
  (portal-web--visit-hosted
   (format "/about?portal=%s&emacs=%s"
           (url-hexify-string (or (portal-build-version) "unknown"))
           (url-hexify-string emacs-version))
   "about"))

;;;###autoload
(defun portal-render-markdown (file)
  "Preview the saved contents of local Markdown FILE using the app host.
Use the current buffer's file when it has a Markdown mode or extension;
otherwise prompt for FILE.  With a prefix argument, always prompt.
Previewing the same file again reuses its buffer.  Press g in the preview
buffer to reread the file from disk.  Unsaved edits are not included.
A link to another Markdown file opens it in the same preview, and l and r
go back and forward.  A link to any other local file opens it in another
pane, as does `portal-render-open-in-emacs' for the file on screen;
`portal-render-return' comes back."
  (interactive
   (list
    (if (and (not current-prefix-arg) buffer-file-name
             (or (derived-mode-p 'markdown-mode 'gfm-mode 'markdown-ts-mode)
                 (let ((case-fold-search t))
                   (string-match-p "\\.\\(?:md\\|markdown\\|mdown\\|mkd\\|mkdn\\)\\'"
                                   buffer-file-name))))
        buffer-file-name
      (read-file-name "Preview Markdown file: " nil buffer-file-name t))))
  (let ((path (expand-file-name file)))
    (when (file-remote-p path)
      (user-error "Choose a local Markdown file"))
    (unless (and (file-regular-p path) (file-readable-p path))
      (user-error "Choose a readable regular file: %s" path))
    (portal-web--visit-hosted (portal-web--markdown-path path)
                              (file-name-nondirectory path))
    (setq portal-web--markdown path)))

(defun portal-web--markdown-path (file)
  "Return the app host path that previews Markdown FILE."
  (concat "/markdown?path=" (url-hexify-string file)))

(defun portal-web--unhex (text)
  "Decode percent-encoded UTF-8 TEXT."
  (decode-coding-string (url-unhex-string text) 'utf-8))

(defun portal-web--queue (event &rest arguments)
  "Queue EVENT with ARGUMENTS as input, for its command to run in the command loop.
Visiting a file can prompt, which a process filter must never do."
  (setq unread-command-events (nconc unread-command-events (list (list event arguments)))))

(defun portal-web--page (url)
  "Note that this buffer's hosted app shows percent-encoded URL now.
A page of the same app becomes the app host path to load, so g reloads
the page on screen, even after the app host restarts with a new token.
A Markdown preview that shows another Markdown file takes that file's
identity, so previewing the file finds this buffer."
  (let* ((parsed (url-generic-parse-url url))
         (route (and (equal (url-type parsed) "http") (equal (url-host parsed) "127.0.0.1")
                     (string-match "\\`/[[:xdigit:]]+\\(/[^?#]*\\)\\([^#]*\\)" (url-filename parsed))
                     (list (match-string 1 (url-filename parsed))
                           (match-string 2 (url-filename parsed))))))
    (when (and route portal-web--hosted-path
               (equal (car route) (car (split-string portal-web--hosted-path "?"))))
      (setq portal-web--hosted-path (apply #'concat route)))
    (when (and portal-web--markdown
               (equal (url-type parsed) "http") (equal (url-host parsed) "127.0.0.1")
               (string-match "\\`/[[:xdigit:]]+/markdown\\?\\(?:[^#]*&\\)?path=\\([^&#]*\\)"
                             (url-filename parsed)))
      (let* ((file (portal-web--unhex (match-string 1 (url-filename parsed))))
             (name (format "*portal: %s*" (file-name-nondirectory file))))
        (setq portal-web--markdown file
              portal-web--hosted-path (portal-web--markdown-path file))
        (unless (string-prefix-p name (buffer-name))
          (rename-buffer name t))))))

(defun portal-web--display-elsewhere (buffer alist)
  "Display BUFFER in a window other than the selected one, reusing one if possible.
This is a `display-buffer' action function.  Rules in `display-buffer-alist'
come first, and ALIST keeps them free to use the selected window."
  (let ((alist (cons '(inhibit-same-window . t) alist)))
    (or (display-buffer-reuse-window buffer alist)
        (display-buffer-use-some-window buffer alist)
        (display-buffer-pop-up-window buffer alist))))

(defun portal-web--hand-off (file &optional line)
  "Visit FILE in a pane other than this hosted page's, at LINE if non-nil.
The page is a Markdown preview.  Select that pane with
Emacs owning the keyboard, and remember this page's buffer for
`portal-render-return' in both frames involved."
  (let ((preview (current-buffer))
        (origin (selected-window))
        (buffer (find-file-noselect file)))
    (portal-input--action "unfocus" portal-web--target)
    (setq portal-input--resume nil)
    (pop-to-buffer buffer '(portal-web--display-elsewhere))
    (when line
      (goto-char (point-min))
      (forward-line (1- line)))
    (dolist (frame (list (window-frame origin) (selected-frame)))
      (set-frame-parameter frame 'portal-render-return preview))))

(defun portal-web--from-view (target function)
  "Call FUNCTION with web view TARGET's buffer current, in the pane showing it.
With no such pane, FUNCTION runs in the selected pane."
  (when-let* ((buffer (portal-view--target-buffer target)))
    (when-let* ((window (portal-input--window target)))
      (select-window window))
    (set-buffer buffer)
    (funcall function)))

(defun portal-web--follow (event)
  "Visit the local file whose link EVENT's hosted page followed.
A fragment such as #L42 or #L42-L50 moves to line 42."
  (interactive "e")
  (pcase-let ((`(,target ,url) (cadr event)))
    (portal-web--from-view
     target
     (lambda ()
       (let* ((parsed (url-generic-parse-url url))
              (fragment (or (url-target parsed) "")))
         (portal-web--hand-off
          (portal-web--unhex (url-filename parsed))
          (and (string-match "\\`L\\([0-9]+\\)\\(?:-L[0-9]+\\)?\\'" fragment)
               (string-to-number (match-string 1 fragment)))))))))

(define-key global-map [portal-web-follow] #'portal-web--follow)

;; Windows that pages open, as window.open and links to target=_blank do.
(defun portal-web--opened (event)
  "Give the window that EVENT's page opened, a new web view, a buffer.
The buffer is named after the window's page, and renamed as the window
goes to other pages.  It is shown in a pane other than the opener's, as a
Markdown preview shows files, and its view gets the keyboard.  A buffer
that cannot take the view closes it."
  (interactive "e")
  (pcase-let* ((`(,target ,opener) (cadr event))
               (state (portal--inspect target)))
    (when state ; Closed already, as when Emacs could not keep up.
      (let ((buffer (generate-new-buffer
                     (format "*portal: %s*"
                             (portal-web--page-name (or (plist-get state :url) "about:blank")))))
            (show (lambda (buffer) (pop-to-buffer buffer '(portal-web--display-elsewhere))))
            ready)
        (unwind-protect
            (progn
              (with-current-buffer buffer
                (portal-web--start-buffer)
                (setq portal-web--target (portal-view-adopt target)))
              (if (portal-view--target-buffer opener)
                  (portal-web--from-view opener (lambda () (funcall show buffer)))
                (funcall show buffer))
              (setq ready t))
          (unless ready
            (when (buffer-live-p buffer) (kill-buffer buffer))
            (when (portal--inspect target) (portal--close target))))
        (with-current-buffer buffer
          (ignore-error user-error (portal-view-focus)))))))

(defun portal-web--closed (event)
  "Kill the buffer of the window whose page closed it, as EVENT reports.
Each pane showing it goes back to what it showed before, as `quit-window'
does."
  (interactive "e")
  (when-let* ((buffer (portal-view--target-buffer (car (cadr event)))))
    (quit-windows-on buffer t)
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(setf (alist-get "opened" portal-view-feature-record-handlers nil nil #'equal)
      (lambda (target opener) (portal-web--queue 'portal-web-opened target opener)))
(defun portal-web--renamed (target)
  "Name window TARGET's buffer, current, after the page it shows now.
Inspecting the view lets its next page send a new record."
  (when-let* ((url (plist-get (portal--inspect target) :url))
              (name (format "*portal: %s*" (portal-web--page-name url))))
    (unless (string-prefix-p name (buffer-name))
      (rename-buffer name t))))

(setf (alist-get "web" portal-view-record-handlers nil nil #'equal) #'portal-web--renamed)
;; A page may close its window before Emacs has given it a buffer, so this
;; queues, after the window's opening, whether or not the target has one.
(setf (alist-get "closed" portal-view-feature-record-handlers nil nil #'equal)
      (lambda (target) (portal-web--queue 'portal-web-closed target)))
(define-key global-map [portal-web-opened] #'portal-web--opened)
(define-key global-map [portal-web-closed] #'portal-web--closed)

;;;###autoload
(defun portal-render-open-in-emacs ()
  "Visit the Markdown file this preview shows, in another pane.
Emacs gets the keyboard, and `portal-render-return' comes back here."
  (interactive)
  (unless portal-web--markdown (user-error "This buffer is not a Markdown preview"))
  (portal-web--hand-off portal-web--markdown))

;;;###autoload
(defun portal-render-return ()
  "Return to the Markdown preview this frame last opened a file from.
Select a pane showing it, in this frame or any other, or show it again
if it is hidden, and give its view the keyboard.  The page stays as it was."
  (interactive)
  (let ((preview (frame-parameter nil 'portal-render-return)))
    (unless (memq preview (portal-view-buffers 'web))
      (user-error "No live Markdown preview to return to"))
    ;; A handoff can select another frame, leaving the preview shown in the first.
    (if-let* ((window (or (get-buffer-window preview) (get-buffer-window preview t))))
        (progn (select-frame-set-input-focus (window-frame window))
               (select-window window))
      (pop-to-buffer preview))
    (portal-view-focus)))

;; Hosted apps.
(defun portal-web-send (plist)
  "Send PLIST to the current buffer's hosted app, as a JSON object over the bridge.
The app receives it through `window.portalBridge.receive'."
  (portal--web-send portal-web--target (json-serialize plist)))

(defun portal-web--download (message)
  "Say how the download that bridge MESSAGE reports goes."
  (let ((file (plist-get message :file)))
    (pcase (plist-get message :state)
      ("started" (message "Downloading %s..." (abbreviate-file-name file)))
      ("finished" (message "Downloaded %s" (abbreviate-file-name file)))
      ("failed" (message "Could not download %s: %s"
                         (if (string-empty-p file)
                             (plist-get message :url)
                           (abbreviate-file-name file))
                         (plist-get message :message))))))

(defun portal-web--bridge (target)
  "Pass each message waiting on TARGET's bridge to `portal-web-bridge-function'.
The view's own messages are handled here instead: \"page\" reports each
page it commits, \"follow\" each click on a link to a local file, and
\"download\" how each download goes, in any web view.
Receiving the messages lets the next ones send a new record."
  (mapc (lambda (message)
          (pcase (plist-get message :type)
            ("page" (portal-web--page (plist-get message :url)))
            ("follow" (portal-web--queue 'portal-web-follow target (plist-get message :url)))
            ("download" (portal-web--download message))
            (_ (when portal-web-bridge-function (funcall portal-web-bridge-function message)))))
        (json-parse-string (portal--web-receive target) :object-type 'plist)))

(setf (alist-get "bridge" portal-view-record-handlers nil nil #'equal) #'portal-web--bridge)

(defun portal-web--visit-hosted (path name)
  "Show the buffer for hosted app PATH, opening one called *portal: NAME*."
  (portal-web--visit (portal-web--find 'portal-web--hosted-path path) name
                     (lambda () (portal-web-open-hosted path))))

(defun portal-web--load-hosted ()
  "Load this buffer's hosted app from the app host, starting the host if needed.
The view keeps its page until the host is ready."
  (setq portal-web--url nil)
  (portal-start-server)
  (when (portal-server-url) (portal-web--host-ready)))

(defun portal-web--host-ready ()
  "Load each hosted app that waits for the app host, which is now ready.
Hosted apps that have already loaded keep their page."
  (dolist (buffer (portal-view-buffers 'web))
    (with-current-buffer buffer
      (when (and portal-web--hosted-path (not portal-web--url))
        (setq portal-web--url (concat (portal-server-url) portal-web--hosted-path))
        (portal--web-load portal-web--target portal-web--url)))))

(add-hook 'portal-server-ready-hook #'portal-web--host-ready)
(portal-web--send-zoom-levels)

(provide 'portal-web)
;;; portal-web.el ends here
