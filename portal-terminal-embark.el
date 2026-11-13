;;; portal-terminal-embark.el --- Embark actions for Portal terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Optional; enable `portal-terminal-embark-mode', which loads Embark.
;; Terminal candidates stay buffer candidates, so Embark's buffer actions and
;; its export to Ibuffer keep working.  A target finder turns a buffer that
;; is a live terminal into a `portal-terminal' target, whose map adds terminal
;; actions to the buffer ones; other buffers are untouched.  Tested with
;; Embark 1.2, whose `embark--targets' the finder uses.

(require 'portal-terminal)

;; Embark is optional for Portal, so this file compiles and loads without it;
;; enabling the mode requires it.
(defvar embark-buffer-map)
(defvar embark-target-finders)
(defvar embark-keymap-alist)
(defvar embark-transformer-alist)
(defvar embark-exporters-alist)
(defvar embark-default-action-overrides)
(declare-function embark--targets "embark" ())
(declare-function embark-export-ibuffer "embark" (buffers))

(defun portal-terminal-embark--buffer (name)
  "Return the live terminal buffer named NAME, or signal that it closed."
  (let ((buffer (get-buffer name)))
    (unless (and buffer (portal-terminal-metadata buffer))
      (user-error "That terminal has closed"))
    buffer))

(defun portal-terminal-embark-select (name)
  "Select the terminal named NAME where terminals of its kind are shown.
A quick terminal opens in its quick panel, and any other in the window
the minibuffer returns to."
  (portal-terminal-select (portal-terminal-embark--buffer name)))

(defun portal-terminal-embark-rename (name)
  "Rename the terminal named NAME, reading its new name."
  (with-current-buffer (portal-terminal-embark--buffer name)
    (call-interactively #'portal-terminal-rename)))

(defun portal-terminal-embark--directory (name)
  "Return the directory of the terminal named NAME, or signal that it is unknown.
A Rex block's is unknown until its buffer is first shown."
  (or (plist-get (portal-terminal-metadata (portal-terminal-embark--buffer name)) :directory)
      (user-error "Its directory is not known until it is shown")))

(defun portal-terminal-embark-dired (name)
  "Open Dired in the directory of the terminal named NAME."
  (dired (portal-terminal-embark--directory name)))

(defun portal-terminal-embark-new (name)
  "Start another shell in the directory of the terminal named NAME.
It is a new shell, not a copy of what runs there, and belongs to the
project of that directory, as any terminal started there does."
  (with-current-buffer (portal-terminal-embark--buffer name)
    (portal-terminal-new)))

(defun portal-terminal-embark-copy-directory (name)
  "Copy the directory of the terminal named NAME to the kill ring."
  (let ((directory (portal-terminal-embark--directory name)))
    (kill-new directory)
    (message "Copied %s" directory)))

(defun portal-terminal-embark-set-project (name)
  "Assign the terminal named NAME to another project, read as a directory.
With a prefix argument, it belongs to no project."
  (with-current-buffer (portal-terminal-embark--buffer name)
    (call-interactively #'portal-terminal-set-project)))

(defun portal-terminal-embark-kill (name)
  "End the terminal named NAME by killing its buffer.
Whether to ask first follows `portal-terminal-confirm-kill', as for any
way of killing it."
  (kill-buffer (portal-terminal-embark--buffer name)))

(defvar-keymap portal-terminal-embark-map
  :doc "Embark actions for Portal terminals, added to the buffer actions.
Enabling `portal-terminal-embark-mode' makes Embark's buffer map its parent."
  "RET" #'portal-terminal-embark-select
  "r" #'portal-terminal-embark-rename
  "d" #'portal-terminal-embark-dired
  "c" #'portal-terminal-embark-new
  "W" #'portal-terminal-embark-copy-directory
  "p" #'portal-terminal-embark-set-project
  "k" #'portal-terminal-embark-kill)

(defvar portal-terminal-embark--finding nil
  "Non-nil while `portal-terminal-embark-target' asks the other finders.")

(defun portal-terminal-embark-target ()
  "Return the current buffer target as a Portal terminal target, if it is one.
Embark's other finders and transformers find the target, such as a
Consult candidate or an Ibuffer line; a buffer that is a live terminal
becomes a `portal-terminal' target with the same bounds."
  (unless portal-terminal-embark--finding
    (let* ((target (let ((portal-terminal-embark--finding t)) (car (embark--targets))))
           (buffer (and (memq (plist-get target :type) '(buffer portal-terminal))
                        (get-buffer (plist-get target :target)))))
      (when (and buffer (portal-terminal-metadata buffer))
        `(portal-terminal ,(buffer-name buffer) . ,(plist-get target :bounds))))))

(defun portal-terminal-embark--refine (_type target)
  "Refine TARGET, a `portal-terminal' candidate or a terminal's name.
A candidate from `portal-terminal-choose' without Consult carries its
buffer; anything that is not a live terminal, such as a New entry, becomes
a `general' target."
  (let ((buffer (or (and (> (length target) 0) (get-text-property 0 'portal-terminal target))
                    (get-buffer target))))
    (if (and (bufferp buffer) (portal-terminal-metadata buffer))
        (cons 'portal-terminal (buffer-name buffer))
      (cons 'general target))))

;;;###autoload
(define-minor-mode portal-terminal-embark-mode
  "Offer Portal terminal actions in Embark, on top of its buffer actions.
A buffer target that is a live terminal, in any prompt or buffer list,
uses `portal-terminal-embark-map': \\`RET' selects it where terminals of
its kind are shown, and there are keys to rename it, open Dired or another
shell in its directory, copy that directory, reassign its project and end
it.  Its other keys are Embark's buffer actions.  Other buffers keep
Embark's buffer map.  Terminal candidates still export to Ibuffer."
  :global t
  :group 'portal-terminal
  (if portal-terminal-embark-mode
      (progn
        (require 'embark)
        (set-keymap-parent portal-terminal-embark-map embark-buffer-map)
        (add-hook 'embark-target-finders #'portal-terminal-embark-target -90)
        (setf (alist-get 'portal-terminal embark-keymap-alist) '(portal-terminal-embark-map)
              (alist-get 'portal-terminal embark-transformer-alist) #'portal-terminal-embark--refine
              (alist-get 'portal-terminal embark-exporters-alist) #'embark-export-ibuffer
              (alist-get 'portal-terminal embark-default-action-overrides)
              #'portal-terminal-embark-select))
    (remove-hook 'embark-target-finders #'portal-terminal-embark-target)
    (when (featurep 'embark)
      (setf (alist-get 'portal-terminal embark-keymap-alist nil 'remove) nil
            (alist-get 'portal-terminal embark-transformer-alist nil 'remove) nil
            (alist-get 'portal-terminal embark-exporters-alist nil 'remove) nil
            (alist-get 'portal-terminal embark-default-action-overrides nil 'remove) nil))))

(provide 'portal-terminal-embark)
;;; portal-terminal-embark.el ends here
