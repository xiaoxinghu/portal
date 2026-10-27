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

(defvar-local portal-excalidraw--ready nil)
(defvar-local portal-excalidraw--error nil)
(defvar-local portal-excalidraw--saved nil)
(defvar-local portal-excalidraw--request 0)
(defvar-local portal-excalidraw--reply nil)
(defvar-local portal-excalidraw--flushing nil)

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
The view follows this buffer's selected pane, and keeps its undo history
while hidden."
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
  (portal-input-mode 1)
  (setq portal-excalidraw--saved (unless (buffer-modified-p) (buffer-string)))
  ;; Emacs deliberately catches before-save-hook errors and may still write.
  ;; This hook must abort the write if a fresh scene cannot be obtained.
  (add-hook 'write-contents-functions #'portal-excalidraw--prepare-write nil t)
  (add-hook 'after-save-hook #'portal-excalidraw--did-save nil t)
  (add-hook 'kill-buffer-query-functions #'portal-excalidraw--query-kill nil t)
  (add-hook 'change-major-mode-hook #'portal-excalidraw--leave-mode nil t)
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
         (portal-web-send (list :type "load" :json (buffer-string)
                                :name (file-name-base (or buffer-file-name (buffer-name))))))
        ("loaded"
         (portal-excalidraw--scene (plist-get message :json) t)
         (setq portal-excalidraw--ready t portal-excalidraw--error nil))
        ("dirty" (set-buffer-modified-p t))
        ("change" (portal-excalidraw--scene (plist-get message :json)))
        ("snapshot"
         (when (eql (plist-get message :request) portal-excalidraw--request)
           (portal-excalidraw--scene (plist-get message :json))
           (setq portal-excalidraw--reply portal-excalidraw--request)))
        ("error"
         (setq portal-excalidraw--error (plist-get message :message))
         (message "Drawing: %s" portal-excalidraw--error))
        ("save"
         (setq unread-command-events
               (nconc unread-command-events
                      (list (list 'portal-excalidraw-command
                                  (list (current-buffer) (plist-get message :type))))))))
    (error (setq portal-excalidraw--error (error-message-string err))
           (message "Drawing: %s" portal-excalidraw--error))))

(defun portal-excalidraw--dispatch (event)
  "Run the command in EVENT, which a drawing's app asked for, in its buffer."
  (interactive "e")
  (pcase-let ((`(,buffer ,kind) (cadr event)))
    (when (buffer-live-p buffer)
      (pop-to-buffer buffer)
      (when (equal kind "save")
        ;; The app still has the keyboard, and saving can ask for a file name.
        (portal-input--action "unfocus" portal-web--target)
        (portal-excalidraw-save)
        (when (eq (current-buffer) buffer) (portal-view-focus))))))
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
  "Bring the buffer up to date before a new major mode closes the view."
  (when (and portal-excalidraw--ready (not portal-excalidraw--error))
    (portal-excalidraw--flush)))

(defun portal-excalidraw--close ()
  "Close the drawing's web view.  The buffer keeps the drawing."
  (portal-view-close)
  (setq portal-excalidraw--ready nil))

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
