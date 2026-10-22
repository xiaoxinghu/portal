;;; portal-input.el --- Shared input ownership for native views -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A native view is an app running in Emacs.  It gets the keys typed in it,
;; and a chord it does not use, a key that types a character pressed with
;; Control, Meta or Super, reaches Emacs: this file reads the rest of its key
;; sequence with the view's buffer's keymaps and runs the command, then gives
;; the view the keyboard back, unless Emacs still waits for keys: a prefix
;; argument, a transient keymap, or keys typed meanwhile.
;; The configured escape (Command-period by default) returns to Emacs, as
;; can Escape typed twice, with `portal-input-double-escape';
;; RET in the buffer re-enters the view.  The buffer's mode line says who
;; has the keyboard, after the major mode's name: [app] while the view has
;; it, [emacs] while Emacs does.
;; The native core decides who gets each key (native/Core/input.c).

(require 'cl-lib)
(require 'face-remap)
(require 'portal-view)

(defgroup portal-input nil "Input for Portal native views." :group 'applications)
(declare-function portal--input "portal" (target action &optional serial))
(declare-function portal--input-escape-key "portal" (character modifiers))
(declare-function portal--input-double-escape "portal" (milliseconds))
(declare-function evil-make-overriding-map "evil-core" (keymap &optional state copy))
(defvar portal-terminal--native-maps)
(defvaralias 'portal-terminal--resume 'portal-input--resume)
(defvar portal-input--resume nil)
(defvar portal-input--origin nil)
(defvar portal-input--serial nil)

(defvar portal-input-mode-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "RET" #'portal-input-focus)
    (keymap-set map "s-." #'portal-input-unfocus)
    map)
  "Keys of a Portal view's buffer while Emacs has the keyboard.")
;; Keep the wrapper controls available in Evil states as well.
(with-eval-after-load 'evil
  (evil-make-overriding-map portal-input-mode-map))

(defconst portal-input--modifiers '((shift . 1) (control . 2) (meta . 4) (super . 8))
  "The native module's value of each modifier, as its chords carry them.")

(defun portal-input--chord (value)
  "Validate VALUE, a native binding's first chord, and return it as the core
reads it: a character and a sum of `portal-input--modifiers' values."
  (let* ((keys (kbd value))
         (event (and (= (length keys) 1) (aref keys 0)))
         (basic (and event (event-basic-type event)))
         (mods (and event (event-modifiers event))))
    (unless (and (integerp basic) (<= 32 basic 126) mods
                 (cl-every (lambda (mod) (memq mod '(control meta super shift))) mods))
      (error "A native binding's first chord must be one modified ASCII key, e.g. s-t or C-c"))
    (when (and (memq 'shift mods) (/= basic 32) (not (<= ?a basic ?z)))
      (error "Use the resulting punctuation, e.g. s-! instead of s-S-1"))
    (list (downcase (char-to-string basic))
          (cl-loop for (mod . value) in portal-input--modifiers
                   when (memq mod mods) sum value))))

(defun portal-input--escape-chord (value)
  "Validate escape key VALUE and return its native character and modifiers."
  (let* ((keys (kbd value))
         (event (and (= (length keys) 1) (aref keys 0)))
         (mods (and event (event-modifiers event))))
    (unless (cl-intersection mods '(control meta super))
      (error "Portal's escape key needs Control, Meta or Super"))
    (if (eq (event-basic-type event) 'escape)
        (progn
          (unless (cl-every (lambda (mod) (memq mod '(control meta super shift))) mods)
            (error "Unsupported escape key modifiers"))
          (list "\e" (cl-loop for (mod . bit) in portal-input--modifiers
                              when (memq mod mods) sum bit)))
      (portal-input--chord value))))

(defvar portal-input--escape-installed "s-."
  "Escape key currently installed in the wrapper keymap.")

(defun portal-input--check-module ()
  "Reject a native module that cannot implement the current input contract."
  (unless (and (fboundp 'portal--input) (fboundp 'portal--input-escape-key)
               (fboundp 'portal--input-double-escape))
    (user-error "Restart Emacs to load the rebuilt Portal input bridge")))

(defun portal-input--configure-escape (value)
  "Apply escape key VALUE to the module and the wrapper keymap."
  (when (featurep 'portal-native-module)
    (portal-input--check-module))
  (let ((chord (portal-input--escape-chord value)))
    (when (fboundp 'portal--input-escape-key)
      (apply #'portal--input-escape-key chord))
    (keymap-unset portal-input-mode-map portal-input--escape-installed)
    (keymap-set portal-input-mode-map value #'portal-input-unfocus)
    (setq portal-input--escape-installed value)))

(defcustom portal-input-escape-key "s-."
  "Key that returns from any native view to Emacs and stays there.
This key is reserved before the embedded app or terminal sees it, even
while a command handoff is pending.  RET enters the view again.
Use one modified printable ASCII key or <escape>, with Control, Meta
or Super: for example \"s-.\", \"C-s-g\" or \"C-<escape>\".
Use resulting punctuation, such as \"s-!\", not \"s-S-1\".
System-wide macOS shortcuts still take precedence.  Changes apply live."
  :type 'string :group 'portal-input
  :set (lambda (symbol value)
         (portal-input--configure-escape value)
         (set-default symbol value)))

(defun portal-input--escape-changed (_symbol value operation _where)
  "Apply escape key VALUE on variable OPERATION."
  (when (memq operation '(set let unlet))
    (portal-input--configure-escape value)))
(add-variable-watcher 'portal-input-escape-key #'portal-input--escape-changed)

(defun portal-input--configure-double-escape (value)
  "Apply double escape VALUE, seconds or nil, to the module."
  (unless (or (null value) (and (numberp value) (> value 0)))
    (error "Portal's double escape needs a positive number of seconds, or nil"))
  (when (featurep 'portal-native-module)
    (portal-input--check-module))
  (when (fboundp 'portal--input-double-escape)
    (portal--input-double-escape (if value (max 1 (round (* value 1000))) 0))))

(defcustom portal-input-double-escape nil
  "Seconds within which a second Escape returns from a native view to Emacs.
With a number, Escape typed twice that quickly, with no key between,
does what `portal-input-escape-key' does, as Escape leaves Evil's insert
state; the app still gets the first Escape.  A single Escape, or two
typed more slowly, stay the app's.  Nil, the default, leaves every
Escape to the app, so Escape typed twice out of habit in a terminal's
vim stays in vim.  Changes apply live."
  :type '(choice (const :tag "Off" nil) (number :tag "Seconds"))
  :group 'portal-input
  :set (lambda (symbol value)
         (portal-input--configure-double-escape value)
         (set-default symbol value)))

(defun portal-input--double-escape-changed (_symbol value operation _where)
  "Apply double escape VALUE on variable OPERATION."
  (when (memq operation '(set let unlet))
    (portal-input--configure-double-escape value)))
(add-variable-watcher 'portal-input-double-escape #'portal-input--double-escape-changed)

(defun portal-input--initialize ()
  "Send input settings after loading the native module."
  (portal-input--configure-escape portal-input-escape-key)
  (portal-input--configure-double-escape portal-input-double-escape))
(add-hook 'portal-view-load-hook #'portal-input--initialize)
(portal-input--initialize)

(defun portal-input--event (character modifiers)
  "Return the Emacs event for CHARACTER typed with MODIFIERS, a sum of
`portal-input--modifiers' values.  Shift made CHARACTER, so it is a
modifier only on space, as in S-SPC."
  (event-convert-list
   (nconc (cl-loop for (modifier . value) in portal-input--modifiers
                   unless (or (zerop (logand modifiers value))
                              (and (eq modifier 'shift) (/= character ?\s)))
                   collect modifier)
          (list character))))

(defvar-local portal-input--focused nil
  "The target of this buffer's view while it has the keyboard, else nil.
The view's focus record sets it on every change, whatever made it: RET or
a click into the view, the escape key, a handoff to Emacs, or a click
elsewhere.  It names the view so that a view closed while it had the
keyboard, which sends no record once its target is gone, and a new view in
the same buffer, which has a new target, both count as Emacs's.")

(defun portal-input--focused-p ()
  "Whether this buffer's view has the keyboard."
  (and portal-view--target (equal portal-input--focused portal-view--target)))

(defface portal-mode-line-app
  '((t :inherit (warning mode-line-emphasis)))
  "The mode line's [app], while a view has the keyboard.
Bold in the theme's `warning' color: the state in which Emacs's own keys
may not work, as compile colors its running status."
  :group 'portal-input)

(defface portal-mode-line-emacs
  '((t :inherit mode-line-emphasis))
  "The mode line's [emacs], while Emacs has the keyboard."
  :group 'portal-input)

(defface portal-mode-line-app-line
  '((t :inherit highlight))
  "A Portal buffer's whole mode line while its view has the keyboard.
`portal-input-mode-line-tint' remaps `mode-line-active' to it in that
buffer, as solaire-mode recolors its buffers, so the pane reads as the
app's whatever package draws the mode line.  By default the theme's
`highlight', the color it gives the active item."
  :group 'portal-input)

(defvar-local portal-input--tint nil
  "The face remapping that tints this buffer's mode line, while it does.")

(defun portal-input--tint ()
  "Tint this buffer's mode line while its view has the keyboard, else not.
The tint is `portal-mode-line-app-line' in place of `mode-line-active',
while `portal-input-mode-line-tint' says so."
  (let ((wanted (and portal-input-mode-line-tint portal-input-mode (portal-input--focused-p))))
    (cond ((and wanted (not portal-input--tint))
           (setq portal-input--tint
                 (face-remap-add-relative 'mode-line-active 'portal-mode-line-app-line)))
          ((and portal-input--tint (not wanted))
           (face-remap-remove-relative portal-input--tint)
           (setq portal-input--tint nil)))
    (force-mode-line-update)))

(defcustom portal-input-mode-line-tint t
  "Whether a Portal buffer's mode line takes `portal-mode-line-app-line'.
It does while the buffer's view has the keyboard, so the whole pane says
so, not only the tag after the mode name.  Changes reach open views at
once."
  :type 'boolean :group 'portal-input
  :set (lambda (symbol value)
         (set-default symbol value)
         (dolist (buffer (portal-view-buffers))
           (with-current-buffer buffer (portal-input--tint)))))

(defun portal-input--mode-line-process ()
  "Return who has the keyboard, for `mode-line-process': [app] or [emacs].
Each in its face, `portal-mode-line-app' or `portal-mode-line-emacs'."
  (let ((focused (portal-input--focused-p)))
    (propertize (if focused "[app]" "[emacs]")
                'face (if focused 'portal-mode-line-app 'portal-mode-line-emacs)
                'help-echo (if focused
                               (format "The app has the keyboard; %s%s returns it to Emacs"
                                       portal-input-escape-key
                                       (if portal-input-double-escape " or Escape twice" ""))
                             "Emacs has the keyboard; RET enters the app"))))

(defconst portal-input-mode-line-process '(:eval (portal-input--mode-line-process))
  "Mode line construct naming who has the keyboard, after the major mode's name.
`portal-input-mode' puts it in `mode-line-process', the place Emacs keeps
for a buffer's state beside its mode name, as comint and eat use it, so the
default mode line and the packages that read `mode-line-process' all show
Ghostty[app] while the view has the keyboard and Ghostty[emacs] while Emacs
does.  The list it goes in starts with \"\": a list that starts with a
symbol is the conditional construct (SYMBOL THEN ELSE), not a sequence.
The buffer's own `mode-line-process', if it had one, follows as one
element, so a conditional or a string keeps its shape, and turning the
mode off restores it; the terminal puts its :exited there.")
(put 'portal-input-mode-line-process 'risky-local-variable t)

(define-minor-mode portal-input-mode
  "Enter a Portal view with RET; `portal-input-escape-key' returns to Emacs.
The mode line shows who has the keyboard, after the major mode's name:
[app] while the view has it, [emacs] while Emacs does, and the whole mode
line takes `portal-mode-line-app-line' while the view has it."
  :lighter nil :keymap portal-input-mode-map
  (let ((wrapped (and (consp mode-line-process) (equal (car mode-line-process) "")
                      (eq (cadr mode-line-process) 'portal-input-mode-line-process))))
    (cond ((and portal-input-mode (not wrapped))
           (setq mode-line-process (append '("" portal-input-mode-line-process)
                                           (and mode-line-process (list mode-line-process)))))
          ((and (not portal-input-mode) wrapped)
           (setq mode-line-process (nth 2 mode-line-process))))
    (portal-input--tint)))

(defun portal-input--target (&optional window)
  "Return the native target for WINDOW, defaulting to the selected window."
  (let ((window (or window (selected-window))))
    (with-current-buffer (window-buffer window)
      (when portal-input-mode (portal-view-target window)))))

(defun portal-input--action (action &optional target serial)
  "Perform ACTION on TARGET, checking handoff SERIAL when supplied."
  (when-let* ((target (or target (portal-input--target))))
    (when (fboundp 'portal--input)
      (portal--input target action (or serial 0)))))

(defun portal-input-focus ()
  "Give the selected Portal view keyboard focus."
  (interactive)
  (portal-view-focus))

(defun portal-input-unfocus ()
  "Return to Emacs and stay there; RET re-enters the selected Portal view."
  (interactive)
  (setq portal-input--resume nil)
  (portal-input--action "unfocus" portal-input--origin)
  (message "Emacs has keyboard focus; RET in a Portal buffer re-enters the app."))

(defun portal-input-send-trigger ()
  "Send the key that started this native binding's handoff to its view."
  (interactive)
  (unless portal-input--serial (user-error "No native binding key to send"))
  (portal-input--action "literal" portal-input--origin portal-input--serial))

(defun portal-input--queue (event)
  "Return a record handler that queues EVENT for the Emacs command loop.
The queued event is (EVENT (TARGET SERIAL KEY...)), with numbers."
  (lambda (target serial &rest keys)
    (setq unread-command-events
          (nconc unread-command-events
                 (list (list event (cons target (mapcar #'string-to-number
                                                        (cons serial keys)))))))))

(dolist (type '("binding" "key" "literal" "cancel"))
  (setf (alist-get type portal-view-record-handlers nil nil #'equal)
        (portal-input--queue (intern (concat "portal-input-" type)))))

(defvar-local portal-input--escaped 0
  "The serial of this view's latest handoff that the user ended, or 0.
Its escape record sets it; a view has one handoff at a time.")

(setf (alist-get "escape" portal-view-record-handlers nil nil #'equal)
      (let ((queue (portal-input--queue 'portal-input-escape)))
        (lambda (target serial &rest keys)
          (setq portal-input--escaped (max portal-input--escaped (string-to-number serial)))
          (apply queue target serial keys))))

(defun portal-input--select (event)
  "Select the pane showing the view clicked in EVENT, and give the view focus.
The click already gave the view the keyboard; this makes Emacs agree."
  (interactive "e")
  (let ((target (car (cadr event))))
    (when-let* ((window (portal-input--window target)))
      (select-window window)
      (portal-input--action "focus" target))))

(setf (alist-get "select" portal-view-record-handlers nil nil #'equal)
      (lambda (target)
        (setq unread-command-events
              (nconc unread-command-events (list (list 'portal-input-select (list target)))))))

;; The view gained or lost the keyboard: its mode line shows which.
(setf (alist-get "focus" portal-view-record-handlers nil nil #'equal)
      (lambda (target focused)
        (setq portal-input--focused (and (equal focused "1") target))
        (portal-input--tint)))
;; A view closed while it had the keyboard sends no last record.
(add-hook 'portal-view-close-hook #'portal-input--tint)

(defun portal-input--connect ()
  "Load the module, which has the input bridge."
  (portal-view--load)
  (portal-input--check-module))

(defun portal-input--read (binding trigger target serial)
  "Read BINDING, a native binding's prefix map, after TRIGGER, from TARGET's
handoff SERIAL."
  (let* ((map (copy-keymap binding))
         (inhibit-quit nil)
         (overriding-terminal-local-map map)
         (overriding-local-map nil))
    (define-key map [t] #'undefined)
    (define-key map trigger #'portal-input-send-trigger)
    (define-key map (kbd "C-g") #'keyboard-quit)
    (define-key map [portal-input-cancel] #'keyboard-quit)
    (define-key map [portal-input-literal] #'portal-input-send-trigger)
    (define-key map [portal-input-escape] #'portal-input-unfocus)
    (when (portal-input--action "ack" target serial)
      (let ((keys (read-key-sequence-vector
                   (format "%s (C-g cancels) " (key-description trigger)))))
        (cons keys (lookup-key map keys))))))

(defun portal-input--read-sequence (trigger target serial)
  "Read the key sequence TRIGGER starts, from TARGET's handoff SERIAL, with the
current buffer's keymaps, as if typed there, and return it with its command."
  (when (portal-input--action "ack" target serial)
    (let ((inhibit-quit nil))
      (setq unread-command-events (append trigger unread-command-events))
      (let* ((keys (read-key-sequence-vector nil))
             (last (aref keys (1- (length keys)))))
        (pcase (car-safe last)
          ('portal-input-cancel (signal 'quit nil))
          ('portal-input-escape (cons keys #'portal-input-unfocus))
          (_ (cons keys (key-binding keys t))))))))

(defun portal-input--run (target serial trigger binding)
  "Run the command TRIGGER starts from TARGET, preserving input ownership
through SERIAL.  BINDING is a native binding's command or prefix map, or nil
for a chord the view did not use, read with the current buffer's keymaps."
  (let ((portal-input--origin target) (portal-input--serial serial)
        (portal-input--resume t)
        (origin (portal-view--target-buffer target)))
    (unwind-protect
        (condition-case err
            (let* ((resolved (cond ((keymapp binding)
                                    (portal-input--read binding trigger target serial))
                                   (binding (when (portal-input--action "ack" target serial)
                                              (cons trigger binding)))
                                   (t (portal-input--read-sequence trigger target serial))))
                   (keys (car resolved)) (command (cdr resolved)))
              (portal-input--action "command" target serial)
              (cond
               ((not keys) (setq portal-input--resume nil))
               ((and (commandp command) (not (eq command #'undefined)))
                (setq command (or (command-remapping command) command))
                (let ((last-command-event (aref keys (1- (length keys))))
                      (this-command command) (real-this-command command))
                  (command-execute command 'record)))
               (t (message "%s is undefined" (key-description keys)))))
          (quit (message "Portal command cancelled"))
          (error (setq portal-input--resume nil)
                 (message "Portal command: %s" (error-message-string err))))
      ;; Finishing fails once the handoff has ended.  Emacs hiding the view, as
      ;; showing another buffer in its pane does, ends it silently, and the
      ;; selected view resumes all the same.  The user ending it, or a later
      ;; handoff of the same view, sends an escape record first, which a busy
      ;; command has not read yet.
      (let ((ended (not (portal-input--action "finish" target serial))))
        (when ended (portal-view--read-records))
        (when (and portal-input--resume portal-input-mode
                   (not (and ended (buffer-live-p origin)
                             (>= (buffer-local-value 'portal-input--escaped origin) serial)))
                   (memq (current-buffer) (portal-view-buffers))
                   (not (active-minibuffer-window))
                   ;; A prefix argument, or a transient keymap as isearch
                   ;; leaves, waits for the user's next key.
                   (not (or prefix-arg overriding-terminal-local-map))
                   ;; Keys typed after the trigger that the command never
                   ;; read are Emacs's next command; checking takes them in.
                   (not (input-pending-p)))
          (portal-input-focus))))))

(defun portal-input--window (target)
  "Return the window showing native view TARGET, in any frame, or nil."
  (let (origin)
    (walk-windows (lambda (window)
                    (when (equal target (portal-input--target window)) (setq origin window)))
                  'no-minibuffer t)
    origin))

(defun portal-input--dispatch (event)
  "Dispatch EVENT in its originating native view's actual Emacs window."
  (interactive "e")
  (pcase-let ((`(,target ,serial . ,keys) (cadr event)))
    (when (portal-input--action "pending" target serial)
      (let ((origin (portal-input--window target)))
        (if (not origin)
            (portal-input--action "finish" target serial)
          (select-window origin)
          (if (eq (car event) 'portal-input-binding)
              (let ((trigger (vector (car keys))))
                (portal-input--run target serial trigger
                                   (lookup-key (if (bound-and-true-p portal-terminal--quick-root)
                                                   (cdr portal-terminal--native-maps)
                                                 (car portal-terminal--native-maps))
                                               trigger)))
            (portal-input--run target serial
                               (vector (portal-input--event (car keys) (cadr keys))) nil)))))))

(define-key global-map [portal-input-key] #'portal-input--dispatch)
(define-key global-map [portal-input-binding] #'portal-input--dispatch)
(define-key global-map [portal-input-escape] #'portal-input-unfocus)
(define-key global-map [portal-input-select] #'portal-input--select)
(provide 'portal-input)
;;; portal-input.el ends here
