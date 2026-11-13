;;; portal-excalidraw.el --- Local drawings in the Excalidraw hosted app -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A drawing buffer holds the drawing's JSON and presents the Excalidraw
;; hosted app in its web view.  The buffer and the app keep the drawing in
;; sync over the bridge.

(require 'cl-lib)
(require 'json)
(require 'portal-view)
(require 'portal-input)
(require 'portal-web)

(declare-function portal--close "portal-view" (target))
(declare-function portal--inspect "portal-view" (target))

(defvar-local portal-excalidraw--ready nil)
(defvar-local portal-excalidraw--error nil)
(defvar-local portal-excalidraw--saved nil)
(defvar-local portal-excalidraw--request 0)
(defvar-local portal-excalidraw--reply nil)
(defvar-local portal-excalidraw--flushing nil)
(defvar-local portal-excalidraw--mode "draw"
  "The drawing page's screen, as the page last said: \"draw\", \"arrange\"
or \"present\".")
(defvar-local portal-excalidraw--slides nil
  "The buffer of the drawing's slide window while presenting, or nil.")
(defvar-local portal-excalidraw--slides-frame nil
  "The frame made to show the drawing's slide window, or nil.")

(defcustom portal-excalidraw-slides-frame-parameters
  '((minibuffer . nil) (tool-bar-lines . 0) (tab-bar-lines . 0) (menu-bar-lines . 0)
    (unsplittable . t) (left-fringe . 0) (right-fringe . 0) (internal-border-width . 0)
    (vertical-scroll-bars . nil) (horizontal-scroll-bars . nil)
    (width . 100) (height . 30))
  "Parameters of the frame that shows a drawing's slide window.
The frame shows the slide and nothing of Emacs: no minibuffer, bars or
fringes.  Add `left', `top', `width' and `height' to place it.  Its name,
unless given here, is the drawing's buffer name and \"Slides\"."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'portal)

(defvar portal-excalidraw--pixelwise 'unset
  "The value `frame-resize-pixelwise' had before a slide window opened.
It is `unset' while no drawing has a slide window.")

(defconst portal-excalidraw--empty
  "{\"type\":\"excalidraw\",\"version\":2,\"source\":\"portal\",\"elements\":[],\"appState\":{},\"files\":{}}\n")

(defun portal-excalidraw--validate (text)
  "Validate drawing TEXT without modifying the current buffer."
  (let ((scene (json-parse-string text :object-type 'plist)))
    (unless (and (equal (plist-get scene :type) "excalidraw")
                 (vectorp (plist-get scene :elements)))
      (user-error "This is not an Excalidraw drawing"))))

;;;###autoload
(define-derived-mode portal-excalidraw-mode fundamental-mode "Excalidraw"
  "Edit a local Excalidraw drawing in a web view.
The buffer contains the drawing's JSON for normal Emacs saving and auto-save.
Command-S or C-x C-s saves; a chord the drawing does not use reaches Emacs.
`portal-input-escape-key' returns to Emacs; RET returns to the drawing.
The view stays in its pane, whichever pane is selected; RET or a click
in another pane showing this buffer brings it there, as switching to the
buffer in a pane does.  It keeps its undo history while hidden.
\[portal-excalidraw-arrange] shows the drawing's slides, its frames, and
\[portal-excalidraw-draw] goes back to the editor; the mode line says
:Arrange while the slides are shown.
\[portal-excalidraw-present] presents them: the drawing's pane becomes the
console, and the slide window shows the slide in a frame of its own, to
share in a call or make fullscreen on a projector.
\[portal-excalidraw-stop-presenting], or closing that window, stops."
  (when (and buffer-file-name (file-remote-p buffer-file-name))
    (user-error "Excalidraw currently supports local files only"))
  (when (= (buffer-size) 0)
    (let ((modified (buffer-modified-p)))
      (insert portal-excalidraw--empty)
      (set-buffer-modified-p modified)))
  (portal-excalidraw--validate (buffer-string))
  (setq-local buffer-read-only t)
  (setq-local buffer-undo-list t)
  (setq-local cursor-type nil)
  (setq-local require-final-newline t)
  (setq-local buffer-file-coding-system 'utf-8-unix)
  (setq-local buffer-offer-save t)
  ;; After the light `portal-input-mode' puts first, as the terminal's :exited.
  (setq mode-line-process
        '(:eval (pcase portal-excalidraw--mode
                  ("arrange" ":Arrange")
                  ("present" ":Present"))))
  (portal-input-mode 1)
  (setq portal-excalidraw--saved (unless (buffer-modified-p) (buffer-string)))
  ;; Emacs deliberately catches before-save-hook errors and may still write.
  ;; This hook must abort the write if a fresh scene cannot be obtained.
  (add-hook 'write-contents-functions #'portal-excalidraw--prepare-write nil t)
  (add-hook 'after-save-hook #'portal-excalidraw--did-save nil t)
  (add-hook 'kill-buffer-query-functions #'portal-excalidraw--query-kill nil t)
  (add-hook 'change-major-mode-hook #'portal-excalidraw--leave-mode nil t)
  (add-hook 'kill-buffer-hook #'portal-excalidraw--end-all-slides nil t)
  ;; The slide window, the one window this page opens.
  (setq-local portal-web-window-action '(portal-excalidraw--display-slides))
  (setq-local revert-buffer-function #'portal-excalidraw--revert)
  (portal-excalidraw--start)
  (when auto-save-default (auto-save-mode 1)))

(keymap-set portal-excalidraw-mode-map "C-c C-r" #'portal-excalidraw-reopen)
(define-key portal-excalidraw-mode-map [remap save-buffer] #'portal-excalidraw-save)
(define-key portal-excalidraw-mode-map [remap undo] #'ignore)
(add-to-list 'auto-mode-alist '("\\.excalidraw\\'" . portal-excalidraw-mode))

;;;###autoload
(defun portal-excalidraw (&optional file)
  "Create a new drawing, or open local FILE with a prefix argument.
The first save of a new drawing asks for a filename."
  (interactive (list (when current-prefix-arg (read-file-name "Drawing: " nil nil nil))))
  (if file
      (find-file file)
    (switch-to-buffer (generate-new-buffer "untitled.excalidraw"))
    (portal-excalidraw-mode)))

(defun portal-excalidraw--start ()
  "Open the drawing's web view.  It loads the app once the app host is ready."
  (setq portal-web-bridge-function #'portal-excalidraw--message)
  (portal-web-open-hosted "/excalidraw/"))

(defun portal-excalidraw--scene (json &optional initial)
  "Replace the buffer with validated JSON; INITIAL establishes its baseline."
  (portal-excalidraw--validate json)
  (let* ((text (concat (string-trim-right json) "\n"))
         (modified (buffer-modified-p))
         (inhibit-read-only t))
    (unless (equal text (buffer-string))
      (erase-buffer)
      (insert text))
    (when (and initial (not modified)) (setq portal-excalidraw--saved text))
    (set-buffer-modified-p (not (equal text portal-excalidraw--saved)))))

(defun portal-excalidraw--message (message)
  "Handle MESSAGE from the drawing's app, the `portal-web-bridge-function'.
Never prompt in this function."
  (condition-case err
      (pcase (plist-get message :type)
        ("ready"
         ;; A page, new or reloaded, starts in the editor.
         (portal-excalidraw--screen "draw")
         (portal-web-send (list :type "load" :json (buffer-string)
                                :name (file-name-base (or buffer-file-name (buffer-name))))))
        ("loaded"
         (portal-excalidraw--scene (plist-get message :json) t)
         (setq portal-excalidraw--ready t portal-excalidraw--error nil))
        ("dirty" (set-buffer-modified-p t))
        ("mode" (portal-excalidraw--screen (plist-get message :mode)))
        ("change" (portal-excalidraw--scene (plist-get message :json)))
        ("snapshot"
         (when (eql (plist-get message :request) portal-excalidraw--request)
           (portal-excalidraw--scene (plist-get message :json))
           (setq portal-excalidraw--reply portal-excalidraw--request)))
        ("error"
         (setq portal-excalidraw--error (plist-get message :message))
         (message "Drawing: %s" portal-excalidraw--error))
        ("notice" (message "Drawing: %s" (plist-get message :message)))
        ("save" (portal-excalidraw--queue "save")))
    (error (setq portal-excalidraw--error (error-message-string err))
           (message "Drawing: %s" portal-excalidraw--error))))

(defun portal-excalidraw--screen (mode)
  "Record MODE as the page's screen, and show it in the mode line.
Leaving Present closes the slide window, and any the
page opened that Emacs has not shown yet: the page opened them before it
left Present, so they belong to a Present that is over."
  (if (not (member mode '("draw" "arrange" "present")))
      (message "Drawing: unknown screen %S" mode)
    (let ((was portal-excalidraw--mode))
      (setq portal-excalidraw--mode mode)
      (force-mode-line-update)
      (when (and (equal was "present") (not (equal mode "present")))
        (portal-excalidraw--end-all-slides)))))

(defun portal-excalidraw--queue (kind)
  "Queue the command KIND, such as \"save\", to run in this drawing's buffer.
The bridge's messages arrive in a process filter, which must not prompt."
  (setq unread-command-events
        (nconc unread-command-events
               (list (list 'portal-excalidraw-command (list (current-buffer) kind))))))

(defun portal-excalidraw--show (mode)
  "Ask the drawing's page to show MODE, then give it the keyboard.
The page answers with the screen it shows, which the mode line follows."
  (unless (derived-mode-p 'portal-excalidraw-mode)
    (user-error "This buffer is not a drawing"))
  (cond (portal-excalidraw--error
         (user-error "The drawing stopped; %s reopens it"
                     (substitute-command-keys "\\[portal-excalidraw-reopen]")))
        ((not portal-excalidraw--ready) (user-error "The drawing is still loading")))
  (portal-web-send (list :type "mode" :mode mode))
  (when (eq (window-buffer) (current-buffer)) (portal-view-focus)))

(defun portal-excalidraw-arrange ()
  "Show the drawing's slides: its frames, in order, each as its image.
Up and Down select a slide; Return, or a double click, edits it in the
editor; Escape goes back to the editor where it was."
  (interactive nil portal-excalidraw-mode)
  (portal-excalidraw--show "arrange"))

(defun portal-excalidraw-draw ()
  "Go back from the drawing's slides to its editor, where it was."
  (interactive nil portal-excalidraw-mode)
  (portal-excalidraw--show "draw"))

(defun portal-excalidraw-present ()
  "Present the drawing's slides, from the one Arrange selects.
From the editor, start at the slide nearest the middle of its view.  The
drawing's pane becomes the console, which keeps the keyboard, and a new
bare frame shows the slide window: the current slide, letterboxed.
Right, Down, Space or Page Down shows the next slide, in either window;
Left, Up or Page Up the previous; Home and End the first and the last.
Escape, `portal-excalidraw-stop-presenting', closing the slide window or
deleting its frame stops, back in Arrange at the slide that showed."
  (interactive nil portal-excalidraw-mode)
  (portal-excalidraw--show "present"))

(defun portal-excalidraw-stop-presenting ()
  "Stop presenting the drawing: close its slide window and show Arrange,
at the slide that showed."
  (interactive nil portal-excalidraw-mode)
  (unless (derived-mode-p 'portal-excalidraw-mode)
    (user-error "This buffer is not a drawing"))
  (unless (or (equal portal-excalidraw--mode "present") portal-excalidraw--slides)
    (user-error "The drawing is not being presented"))
  (portal-excalidraw--stop-presenting))

(defun portal-excalidraw--stop-presenting ()
  "Close the drawing's slide window, and have its page leave Present."
  (portal-excalidraw--end-slides)
  (when (and (equal portal-excalidraw--mode "present")
             portal-excalidraw--ready (not portal-excalidraw--error))
    (portal-web-send (list :type "mode" :mode "arrange"))))

(defun portal-excalidraw--display-slides (buffer alist)
  "Show slide window BUFFER in a new bare frame, as its drawing's.
This is the drawing's `display-buffer' action for the window its page
opens; ALIST's entries come first.  The drawing keeps the buffer and the
frame, and an earlier slide window of it closes.  The slide window takes
the keyboard as it opens, and a command queued here gives it back to the
console once the window is shown."
  (let* ((drawing (buffer-local-value 'portal-web-opener buffer))
         (parameters (append portal-excalidraw-slides-frame-parameters
                             `((name . ,(format "%s: Slides"
                                                (if (buffer-live-p drawing)
                                                    (buffer-name drawing)
                                                  "Drawing"))))))
         (window (display-buffer-pop-up-frame
                  buffer
                  (append alist
                          `((pop-up-frame-parameters . ,parameters)
                            (window-parameters . ((mode-line-format . none)
                                                  (header-line-format . none)
                                                  (tab-line-format . none))))))))
    (when (and window (buffer-live-p drawing))
      (with-current-buffer drawing
        (portal-excalidraw--end-slides)
        (setq portal-excalidraw--slides buffer
              portal-excalidraw--slides-frame (window-frame window))
        (portal-excalidraw--queue "console"))
      (with-current-buffer buffer
        (add-hook 'kill-buffer-hook #'portal-excalidraw--slides-killed nil t))
      (portal-excalidraw--resize-pixelwise))
    window))

(defun portal-excalidraw--end-slides ()
  "Close this drawing's slide window, if it has one: delete its frame, then
kill its buffer.  Neither goes by itself when the other does.  A slide
frame that had the keyboard gives it to the console."
  (let ((buffer portal-excalidraw--slides)
        (frame portal-excalidraw--slides-frame))
    (setq portal-excalidraw--slides nil portal-excalidraw--slides-frame nil)
    (when (frame-live-p frame)
      (when (and (eq frame (selected-frame)) (get-buffer-window (current-buffer) t))
        (portal-excalidraw--queue "console"))
      (condition-case nil
          (delete-frame frame)
        ;; The last frame left: it stays, showing another buffer.
        (error nil)))
    (when (buffer-live-p buffer) (kill-buffer buffer))
    (portal-excalidraw--resize-pixelwise)))

(defun portal-excalidraw--end-all-slides ()
  "Close the drawing's slide window, and any its page opened that Emacs has
not shown yet, whose `portal-web-opened' events still wait.  Emacs would
show them after the drawing's Present, or its view, has ended, owned by
nothing."
  (when-let* ((target portal-view--target))
    (setq unread-command-events
          (seq-remove (lambda (event)
                        (pcase event
                          (`(portal-web-opened (,window ,(pred (equal target))))
                           (when (portal--inspect window) (portal--close window))
                           t)))
                      unread-command-events)))
  (portal-excalidraw--end-slides))

(defun portal-excalidraw--slides-killed ()
  "Stop presenting the drawing whose slide window's buffer this was."
  (let ((slides (current-buffer))
        (drawing portal-web-opener))
    (when (and (buffer-live-p drawing)
               (eq (buffer-local-value 'portal-excalidraw--slides drawing) slides))
      (with-current-buffer drawing
        (setq portal-excalidraw--slides nil)
        (portal-excalidraw--stop-presenting)))))

(defun portal-excalidraw--frame-deleted (frame)
  "Stop presenting the drawing whose slide window FRAME showed.
Only Emacs hears that a frame went; the drawing's page saw it lose focus."
  (dolist (buffer (buffer-list))
    (when (eq (buffer-local-value 'portal-excalidraw--slides-frame buffer) frame)
      (with-current-buffer buffer
        (setq portal-excalidraw--slides-frame nil)
        (portal-excalidraw--stop-presenting)))))
(add-hook 'delete-frame-functions #'portal-excalidraw--frame-deleted)

(defun portal-excalidraw--resize-pixelwise ()
  "Resize frames pixelwise while any drawing has a slide window.
Otherwise a fullscreen slide frame is rounded to whole characters, short
of the display.  Afterwards, `frame-resize-pixelwise' is as it was."
  (let ((presenting (cl-some (lambda (buffer)
                                (buffer-local-value 'portal-excalidraw--slides buffer))
                              (buffer-list))))
    (cond ((and presenting (eq portal-excalidraw--pixelwise 'unset))
           (setq portal-excalidraw--pixelwise frame-resize-pixelwise
                 frame-resize-pixelwise t))
          ((and (not presenting) (not (eq portal-excalidraw--pixelwise 'unset)))
           (setq frame-resize-pixelwise portal-excalidraw--pixelwise
                 portal-excalidraw--pixelwise 'unset)))))

(defun portal-excalidraw--dispatch (event)
  "Run the command in EVENT, which a drawing's app asked for, in its buffer."
  (interactive "e")
  (pcase-let ((`(,buffer ,kind) (cadr event)))
    (when (buffer-live-p buffer)
      (pcase kind
        ("save"
         (pop-to-buffer buffer)
         ;; The app still has the keyboard, and saving can ask for a file name.
         (portal-input--action "unfocus" portal-web--target)
         (portal-excalidraw-save)
         (when (eq (current-buffer) buffer) (portal-view-focus)))
        ("console"
         ;; The console keeps the keyboard while presenting.
         (when-let* ((window (get-buffer-window buffer t)))
           (select-frame-set-input-focus (window-frame window))
           (select-window window)
           (ignore-error user-error (portal-view-focus))))))))
(define-key global-map [portal-excalidraw-command] #'portal-excalidraw--dispatch)

(defun portal-excalidraw--wait (predicate)
  "Service native events until PREDICATE succeeds, or report a bounded failure."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (not portal-excalidraw--error)
                (< (float-time) deadline))
      (accept-process-output nil 0.01)
      (redisplay t))
    (when portal-excalidraw--error (user-error "%s" portal-excalidraw--error))
    (unless (funcall predicate) (user-error "Timed out waiting for the drawing editor"))))

(defun portal-excalidraw--flush ()
  "Synchronize the current scene before Emacs saves, reverts, or closes it."
  (unless portal-excalidraw--flushing
    (let ((portal-excalidraw--flushing t))
      (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
      (cl-incf portal-excalidraw--request)
      (setq portal-excalidraw--reply nil)
      (portal-web-send (list :type "snapshot" :request portal-excalidraw--request))
      (portal-excalidraw--wait (lambda () (eql portal-excalidraw--reply portal-excalidraw--request))))))

;;;###autoload
(defun portal-excalidraw-save (&optional arg)
  "Save the latest scene through Emacs; ARG is passed to `save-buffer'."
  (interactive "p")
  (condition-case err
      (progn
        (portal-excalidraw--flush)
        (when (or (not buffer-file-name) (not (file-exists-p buffer-file-name)))
          (set-buffer-modified-p t))
        (let ((portal-excalidraw--flushing t)) (save-buffer arg)))
    (error
     (when portal-excalidraw--ready
       (portal-web-send (list :type "error" :message (error-message-string err))))
     (signal (car err) (cdr err)))))

(defun portal-excalidraw--did-save ()
  "Acknowledge only a successful Emacs file write."
  (setq portal-excalidraw--saved (buffer-string))
  (when portal-excalidraw--ready
    (portal-web-send (list :type "saved" :json portal-excalidraw--saved))))

(defun portal-excalidraw--prepare-write ()
  "Require a fresh scene, then let Emacs perform its normal file write."
  (portal-excalidraw--flush)
  nil)

(defun portal-excalidraw--query-kill ()
  "Flush edits still in flight before the buffer is killed."
  (let ((modified (buffer-modified-p)))
    (when (and portal-excalidraw--ready (not portal-excalidraw--error))
      (portal-excalidraw--flush))
    (or (not (buffer-modified-p)) (and buffer-file-name modified)
        (yes-or-no-p "Drawing has new unsaved changes; discard them? "))))

(defun portal-excalidraw--leave-mode ()
  "Bring the buffer up to date before a new major mode closes the view.
The slide window closes with it."
  (portal-excalidraw--end-all-slides)
  (when (and portal-excalidraw--ready (not portal-excalidraw--error))
    (portal-excalidraw--flush)))

(defun portal-excalidraw--close ()
  "Close the drawing's web view, and its slide window.
The buffer keeps the drawing."
  (portal-excalidraw--end-all-slides)
  (portal-view-close)
  (setq portal-excalidraw--ready nil)
  (portal-excalidraw--screen "draw"))

(defun portal-excalidraw-reopen ()
  "Reopen the drawing's web view from the buffer, resetting its undo history.
Use after an app host restart or a WebKit crash.
Unsaved changes in the buffer are kept."
  (interactive)
  (when (and portal-excalidraw--ready (not portal-excalidraw--error))
    (portal-excalidraw--flush))
  (portal-excalidraw--close)
  (setq portal-excalidraw--error nil)
  (portal-excalidraw--start))

(defun portal-excalidraw--revert (_ignore-auto noconfirm)
  "Reload the saved drawing, asking before discarding edits unless NOCONFIRM."
  (unless buffer-file-name (user-error "This drawing has no file yet"))
  (when (or noconfirm (yes-or-no-p "Replace this drawing with the file on disk? "))
    (let* ((file buffer-file-name)
           (text (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (portal-excalidraw--validate text)
      (portal-excalidraw--close)
      ;; Take the file's time first, or replacing the text asks whether to
      ;; edit a buffer whose file changed on disk.
      (set-visited-file-modtime)
      (let ((inhibit-read-only t)) (erase-buffer) (insert text))
      (set-buffer-modified-p nil)
      (setq portal-excalidraw--saved text portal-excalidraw--error nil)
      (portal-excalidraw--start))))

(provide 'portal-excalidraw)
;;; portal-excalidraw.el ends here
