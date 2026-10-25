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

(require 'browse-url)
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
g or Command-R loads the page again, and l and r go back and forward,
whether Emacs or the page owns the keyboard, unless the page uses
Command-R itself.  The mode line shows [app] while the page has the
keyboard and [emacs] while Emacs does.  q hides the view while the page
keeps running, and killing the buffer closes it."
  (setq-local cursor-type nil)
  (portal-input-mode 1))
(keymap-set portal-web-mode-map "g" #'portal-web-reload)
(keymap-set portal-web-mode-map "l" #'portal-web-back)
(keymap-set portal-web-mode-map "r" #'portal-web-forward)
(keymap-set portal-web-mode-map "s-r" #'portal-web-reload)

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
`portal-web-inspectable' says so."
  (portal-input--connect)
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

(defun portal-web--go (step)
  "Move the selected pane's web view through its history by STEP.
STEP is \"back\" or \"forward\"; with no page to go to, nothing changes."
  (let ((target (portal-view-target)))
    (unless (and target (string-prefix-p "web:" target))
      (user-error "Select a Portal web view"))
    (portal--web-go target step)))

(defun portal-web-back ()
  "Go back to the previous page in this web view's history."
  (interactive)
  (portal-web--go "back"))

(defun portal-web-forward ()
  "Go forward to the next page in this web view's history."
  (interactive)
  (portal-web--go "forward"))

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
            "This buffer has one live view, which follows its selected pane.\n")))

(defun portal-web--visit (buffer name open)
  "Select web BUFFER and reload it, or, when BUFFER is nil, open a new one.
The new buffer is called *portal: NAME*, and OPEN opens its view.  If the
view cannot open, the new buffer is killed."
  (if buffer
      (progn (switch-to-buffer buffer) (portal-web-reload))
    (let ((buffer (generate-new-buffer (format "*portal: %s*" name))))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (portal-web--start-buffer)
            (redisplay t)
            (funcall open)
            (message "Web view opened. RET enters; %s returns to Emacs; q hides the view."
                     portal-input-escape-key))
        (unless (and (buffer-live-p buffer) (buffer-local-value 'portal-web--target buffer))
          (kill-buffer buffer))))))

;;;###autoload
(defun portal-open-url (url)
  "Open URL in a web view, in a new buffer named after its page.
Click the page or press RET to interact; `portal-input-escape-key'
returns control to Emacs.  HTTP(S), file, data and about
URLs are supported."
  (interactive (list (read-string "Open URL: " "https://")))
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
The buffer is named after the window's page and shown in a pane other than
the opener's, as a Markdown preview shows files, and its view gets the
keyboard.  A buffer that cannot take the view closes it."
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

(defun portal-web--bridge (target)
  "Pass each message waiting on TARGET's bridge to `portal-web-bridge-function'.
The view's own messages are handled here instead: \"page\" reports each
page it commits, and \"follow\" each click on a link to a local file.
Receiving the messages lets the next ones send a new record."
  (mapc (lambda (message)
          (pcase (plist-get message :type)
            ("page" (portal-web--page (plist-get message :url)))
            ("follow" (portal-web--queue 'portal-web-follow target (plist-get message :url)))
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

(provide 'portal-web)
;;; portal-web.el ends here
