;;; portal-global-shortcut.el --- Named system-wide shortcuts that call Lisp -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A global shortcut calls a Lisp function when its chord is pressed in any
;; application, without activating Emacs, selecting a frame or showing a
;; panel.  The native module registers each chord with macOS and sends a
;; "shortcut ID" record through Portal's notification pipe for each press.
;; The process filter only queues an input event; the command loop runs the
;; function.  Functions stay in Lisp: native code knows a shortcut only by its
;; ID, which changes on every set, so a press from before a set or a removal
;; is ignored.  Loading this file registers nothing.

(require 'cl-lib)
(require 'portal-view)

(declare-function portal--shortcut-chord "portal-global-shortcut" (chord))
(declare-function portal--shortcut-set "portal-global-shortcut" (replacing chord))
(declare-function portal--shortcut-remove "portal-global-shortcut" (id))

(defvar portal-global-shortcut--registrations nil
  "Each global shortcut, oldest first, as (NAME ID CHORD FUNCTION).
ID is its native registration's, and CHORD as the native module writes it.")

(defun portal-global-shortcut--find (id)
  "Return the registration whose native ID is ID, or nil."
  (cl-find id portal-global-shortcut--registrations :key #'cadr))

(defun portal-global-shortcut--check-function (function)
  "Signal a `user-error' unless FUNCTION is a command or takes no arguments.
An autoloaded function is not loaded to count its arguments."
  (unless (and (functionp function)
               (or (commandp function)
                   (autoloadp (indirect-function function))
                   (zerop (car (func-arity function)))))
    (user-error "A global shortcut needs a command or a function of no arguments, not %S"
                function)))

(defun portal-global-shortcut--hooks (install)
  "INSTALL the record handler and the exit hook, or remove them if nil."
  (if install
      (setf (alist-get "shortcut" portal-view-feature-record-handlers nil nil #'equal)
            #'portal-global-shortcut--queue)
    (setq portal-view-feature-record-handlers
          (assoc-delete-all "shortcut" portal-view-feature-record-handlers)))
  (if install
      (add-hook 'kill-emacs-hook #'portal-global-shortcut--remove-all)
    (remove-hook 'kill-emacs-hook #'portal-global-shortcut--remove-all)))

(defun portal-global-shortcut-set (name chord function)
  "Call FUNCTION whenever CHORD is pressed, in any application.
NAME is a symbol that identifies the shortcut.  Setting a NAME that is
already set replaces its chord and function, and releases its old chord.

CHORD names physical keys: hyphen-separated modifiers, Control, Option,
Command and Shift, each at most once and at least one of the first three,
then A-Z, 0-9, Space, Escape or F1-F20, such as \"Control-Option-Command-P\".
Case does not matter, and Shift is never implied.  Letters and digits are
positions on a US keyboard, whatever the input source or Emacs's modifier
settings.  Fn, Caps Lock, punctuation,
left and right modifiers and key sequences are unsupported.

FUNCTION is an interactive command, run with `call-interactively', or any
other function of no arguments, run with `funcall', such as a lambda that
captures what it needs.  It runs from the command loop, like a key bound to
it; neither the press nor the call activates Emacs or selects a frame.
Emacs must be running, and a busy Emacs calls FUNCTION once it reads input.
Holding the chord calls it once, and a press while an earlier press of
NAME still waits for the command loop is ignored, as is a press from
before NAME was last set.  An error in FUNCTION is shown as a message
naming NAME; it leaves every shortcut set, and unlike other commands'
errors, it discards no input, such as another shortcut's press.  With
`debug-on-error', the debugger shows it instead.

Return NAME.  Signal an error and change nothing if NAME is not a non-nil
symbol, CHORD is invalid or another NAME's chord, FUNCTION is neither a
command nor a function of no arguments, or macOS refuses the chord because
the system or another application has it."
  (unless (and name (symbolp name))
    (user-error "A global shortcut's name must be a non-nil symbol, not %S" name))
  (unless (stringp chord)
    (user-error "A global shortcut's chord must be a string, not %S" chord))
  (portal-global-shortcut--check-function function)
  (portal-view--load)
  (unless (fboundp 'portal--shortcut-set)
    (user-error "Rebuild Portal and restart Emacs for global shortcuts"))
  (let* ((chord (portal--shortcut-chord chord))
         (registration (assq name portal-global-shortcut--registrations))
         (owner (car (cl-find chord portal-global-shortcut--registrations
                              :key #'caddr :test #'equal))))
    (when (and owner (not (eq owner name)))
      (user-error "Global shortcut %s is already set as `%s'" chord owner))
    (let ((id (portal--shortcut-set (cadr registration) chord)))
      (if registration
          (setcdr registration (list id chord function))
        (setq portal-global-shortcut--registrations
              (append portal-global-shortcut--registrations
                      (list (list name id chord function)))))
      (portal-global-shortcut--hooks t))
    name))

(defun portal-global-shortcut-remove (name)
  "Release the global shortcut NAME, if it is set.
Return t if NAME was set and nil if not.  A press of NAME that has not run
yet is ignored.  If the system cannot release the chord, signal an error
and keep NAME."
  (when-let* ((registration (assq name portal-global-shortcut--registrations)))
    (portal--shortcut-remove (cadr registration))
    (setq portal-global-shortcut--registrations
          (delq registration portal-global-shortcut--registrations))
    (unless portal-global-shortcut--registrations
      (portal-global-shortcut--hooks nil))
    t))

(defun portal-global-shortcut--remove-all ()
  "Release every global shortcut, reporting failures, for exit and unloading."
  (dolist (name (mapcar #'car portal-global-shortcut--registrations))
    (with-demoted-errors "Portal global shortcut: %S"
      (portal-global-shortcut-remove name))))

(defun portal-global-shortcut--queue (id &rest fields)
  "Queue a press of the shortcut whose native ID is ID for the command loop.
This runs in the process filter: it calls no shortcut's function."
  (when (and (stringp id) (null fields) (string-match-p "\\`[0-9]+\\'" id))
    ;; The ID is in a list: the command loop reads an event's second element,
    ;; when it is a number, as a buffer position.
    (let ((event (list 'portal-global-shortcut (list (string-to-number id)))))
      (when (and (portal-global-shortcut--find (car (cadr event)))
                 (not (member event unread-command-events)))
        (setq unread-command-events (append unread-command-events (list event)))))))

(defun portal-global-shortcut--run (event)
  "Call the function of the shortcut pressed in EVENT, if it is still set.
Report its error here: the command loop's report would discard the input
waiting to be read, such as another shortcut's press."
  (interactive "e")
  (when-let* ((registration (portal-global-shortcut--find (car (cadr event)))))
    (pcase-let ((`(,name ,_id ,_chord ,function) registration))
      (condition-case-unless-debug error
          (if (commandp function)
              (call-interactively function)
            (funcall function))
        (error (message "Global shortcut `%s': %s" name (error-message-string error)))))))

;; Like Portal's input handoffs, a press reaches the command loop as an event.
(define-key global-map [portal-global-shortcut] #'portal-global-shortcut--run)

(defun portal-global-shortcut-unload-function ()
  "Release every global shortcut before unloading this feature.
If a chord cannot be released, signal an error so that the feature stays
loaded: unloading would leave the chord registered with nothing to run."
  (portal-global-shortcut--remove-all)
  (when portal-global-shortcut--registrations
    (error "Cannot release global shortcuts %S, so `portal-global-shortcut' stays loaded"
           (mapcar #'car portal-global-shortcut--registrations)))
  (define-key global-map [portal-global-shortcut] nil t)
  nil)

(provide 'portal-global-shortcut)
;;; portal-global-shortcut.el ends here
