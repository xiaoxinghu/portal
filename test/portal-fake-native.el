;;; portal-fake-native.el --- In-memory Portal native module for batch tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Stands in for the native module at the `portal-view.el' and
;; `portal-launcher.el' seams, so batch Emacs can drive real buffers, windows
;; and frames without AppKit.  Load it before Portal; never load it into an
;; Emacs that uses the real module.

(require 'cl-lib)
(require 'subr-x)

(defvar portal-fake-native--views (make-hash-table :test #'equal)
  "Open views: target to a plist of :options, :frame, :edges, :visible
and :focused.  A web view also has the :url it loaded last, and the JSON
:messages that Emacs has not received yet: its own, and a hosted app's.")
(defvar portal-fake-native--next-id 0 "Last view ID.  IDs are never reused.")
(defvar portal-fake-native-log nil "Lifecycle calls, newest first, as (NAME ARGS...).")
(defvar portal-fake-native-channel nil
  "The pipe process that `portal--channel' connected; feed it records.")
(defvar portal-fake-native-failures nil
  "Exports that signal an error, such as `portal--open' or `portal--place'.")

(defvar portal-fake-native--launcher nil
  "The launcher panel: a plist of the attached :frame, whether it is :visible
and :key, whether it is :presenting and has :lost-focus since, and its
last :height.  nil when no frame is attached.")
(defvar portal-fake-native--launcher-session 0
  "The launcher's presentation session.
Showing, hiding and detaching start a new one, as the native module does.")

(defun portal-fake-native-reset ()
  "Forget every view, the launcher panel and logged calls."
  (clrhash portal-fake-native--views)
  (setq portal-fake-native--launcher nil)
  (setq portal-fake-native-log nil))

(defun portal-fake-native-calls (name)
  "Return the argument lists of each logged call to NAME, oldest first."
  (mapcar #'cdr (reverse (cl-remove name portal-fake-native-log :key #'car :test-not #'eq))))

(defun portal-fake-native-targets ()
  "Return the targets of the open views."
  (hash-table-keys portal-fake-native--views))

(defun portal-fake-native--call (name &rest arguments)
  "Log a call to NAME with ARGUMENTS, and fail when the test asks."
  (push (cons name arguments) portal-fake-native-log)
  (when (memq name portal-fake-native-failures)
    (error "Fake %s failure" name)))

(defun portal-fake-native--view (target)
  "Return TARGET's state, or signal as the native module does."
  (or (gethash target portal-fake-native--views)
      (error "No Portal view %s" target)))

(require 'term/xterm) ; Makes `xterm-extra-capabilities' special where the macro expands.

(defmacro portal-fake-native-with-frame (frame &rest body)
  "Run BODY with FRAME bound to a new frame, then delete FRAME.
Batch Emacs has a single frame, so FRAME is a terminal frame on a
pseudo-terminal, large enough to split.  Its terminal is suspended, because
nothing reads the pseudo-terminal and redisplay would block writing to it.
The selected frame is kept."
  (declare (indent 1))
  `(let* ((portal-fake-native--tty
           (make-process :name "portal-fake-tty" :command '("sleep" "3600")
                         :connection-type 'pty :filter #'ignore :noquery t))
          (portal-fake-native--selected (selected-frame))
          (,frame (let ((xterm-extra-capabilities nil)) ; Nothing answers queries.
                    (make-frame `((tty . ,(process-tty-name portal-fake-native--tty))
                                  (tty-type . "xterm"))))))
     (unwind-protect
         (progn
           (set-frame-size ,frame 160 50)
           (suspend-tty (frame-terminal ,frame))
           (select-frame portal-fake-native--selected)
           ,@body)
       (select-frame portal-fake-native--selected)
       (when (frame-live-p ,frame) (delete-frame ,frame))
       (delete-process portal-fake-native--tty))))

(defun portal--open (kind options)
  (portal-fake-native--call 'portal--open kind options)
  (let ((target (format "%s:%d" kind (cl-incf portal-fake-native--next-id))))
    (puthash target (list :options options :frame nil :edges nil :visible nil)
             portal-fake-native--views)
    target))

(defun portal--place (target edges title)
  (portal-fake-native--call 'portal--place target edges title)
  (let ((view (portal-fake-native--view target))
        (frame (cl-find title (frame-list)
                        :key (lambda (frame) (frame-parameter frame 'title)) :test #'equal)))
    (unless frame (error "Cannot find the requested native Emacs frame"))
    (setq view (plist-put view :frame frame))
    (setq view (plist-put view :edges (append edges nil)))
    (puthash target (plist-put view :visible t) portal-fake-native--views)
    t))

(defun portal--hide (target)
  (portal-fake-native--call 'portal--hide target)
  (let ((view (portal-fake-native--view target)))
    (portal-fake-native--focus target nil)
    (puthash target (plist-put (plist-put view :edges nil) :visible nil)
             portal-fake-native--views)
    t))

(defun portal--close (target)
  (portal-fake-native--call 'portal--close target)
  (portal-fake-native--view target)
  (remhash target portal-fake-native--views)
  t)

(defun portal--web-load (target url)
  (portal-fake-native--call 'portal--web-load target url)
  (unless (string-prefix-p "web:" target) (error "No Portal view %s" target))
  (puthash target (plist-put (portal-fake-native--view target) :url url)
           portal-fake-native--views)
  t)

(defun portal--web-go (target step)
  (portal-fake-native--call 'portal--web-go target step)
  (unless (string-prefix-p "web:" target) (error "No Portal view %s" target))
  (unless (member step '("back" "forward"))
    (error "Web history step must be \"back\" or \"forward\", not %s" step))
  t)

(defun portal--web-find (target text backward case-sensitive)
  (portal-fake-native--call 'portal--web-find target text backward case-sensitive)
  (unless (string-prefix-p "web:" target) (error "No Portal view %s" target))
  (portal-fake-native--view target)
  (when (equal text "") (error "Nothing to find"))
  t)

(defun portal--web-zoom (host percent)
  (portal-fake-native--call 'portal--web-zoom host percent)
  (unless (and (stringp host) (integerp percent)) (signal 'wrong-type-argument (list host percent)))
  (unless (<= 25 percent 500) (error "Web zoom must be from 25 to 500 percent"))
  t)

(defun portal-fake-native--hosted (target)
  "Return hosted web view TARGET's state, or signal as the native module does."
  (let ((view (portal-fake-native--view target)))
    (unless (plist-get (plist-get view :options) :hosted)
      (error "Web view %s is not a hosted app, so it has no bridge" target))
    view))

(defun portal--web-send (target json)
  (portal-fake-native--call 'portal--web-send target json)
  (portal-fake-native--hosted target)
  t)

(defun portal--web-receive (target)
  (portal-fake-native--call 'portal--web-receive target)
  (unless (string-prefix-p "web:" target) (error "No Portal view %s" target))
  (let* ((view (portal-fake-native--view target))
         (messages (plist-get view :messages)))
    (puthash target (plist-put view :messages nil) portal-fake-native--views)
    (format "[%s]" (string-join messages ","))))

(defun portal-fake-native-queue (target &rest messages)
  "Queue MESSAGES, JSON object strings, as the core does for web view TARGET.
Send the `bridge' record with `portal-fake-native-send'."
  (let ((view (portal-fake-native--view target)))
    (puthash target (plist-put view :messages (append (plist-get view :messages) messages))
             portal-fake-native--views)))

(defun portal-fake-native-post (target &rest messages)
  "Queue MESSAGES, JSON object strings, as hosted web view TARGET's app posts them.
Send the `bridge' record with `portal-fake-native-send'."
  (portal-fake-native--hosted target)
  (apply #'portal-fake-native-queue target messages))

(defun portal--web-download-directory (directory)
  (portal-fake-native--call 'portal--web-download-directory directory)
  t)

(defun portal--inspect (target)
  (copy-sequence (gethash target portal-fake-native--views)))

(defun portal-fake-native-report (target &rest facts)
  "Set FACTS, such as :title, :pwd and :exited, in terminal TARGET's state.
Then send its `terminal' record, as the native module does for a change."
  (let ((view (portal-fake-native--view target)))
    (while facts (setq view (plist-put view (pop facts) (pop facts))))
    (puthash target view portal-fake-native--views))
  (portal-fake-native-send (format "terminal %s\n" target)))

(defun portal-fake-native-open-window (opener url)
  "Open a web view for the window web view OPENER's page asked for, at URL.
Send its `opened' record, as the native module does, and return its target."
  (portal-fake-native--view opener)
  (let ((target (format "web:%d" (cl-incf portal-fake-native--next-id))))
    (puthash target (list :options (list :opener opener) :frame nil :edges nil :visible nil
                          :url url)
             portal-fake-native--views)
    (portal-fake-native-send (format "opened %s %s\n" target opener))
    target))

(defun portal-fake-native-title (target title)
  "Give web view TARGET's page TITLE, as WebKit reports it, or nil for none."
  (puthash target (plist-put (portal-fake-native--view target) :title title)
           portal-fake-native--views))

(defun portal-fake-native-commit (target url)
  "Have window TARGET's page go to URL, and send its `web' record."
  (puthash target (plist-put (portal-fake-native--view target) :url url)
           portal-fake-native--views)
  (portal-fake-native-send (format "web %s\n" target)))

(defun portal--channel (process)
  (setq portal-fake-native-channel process)
  t)

(defun portal-fake-native-send (&rest reads)
  "Send each of READS to the connected pipe as one read, as the OS may split it."
  (unless (process-live-p portal-fake-native-channel) (error "No pipe is connected"))
  (dolist (text reads)
    (funcall (process-filter portal-fake-native-channel) portal-fake-native-channel text)))

;; Input exports, so terminal commands run unchanged.  Focus needs a shown
;; view, and only one view has it at a time.  Each change sends the focus
;; record, as the native module does, where a pipe is connected.
(defun portal-fake-native--focus (target focused)
  "Note whether TARGET's view has the keyboard, sending its record on a change."
  (let ((view (gethash target portal-fake-native--views)))
    (unless (eq (and (plist-get view :focused) t) focused)
      (puthash target (plist-put view :focused focused) portal-fake-native--views)
      (when (process-live-p portal-fake-native-channel)
        (portal-fake-native-send (format "focus %s %d\n" target (if focused 1 0)))))))

(defun portal--input (target action &optional _serial)
  (let ((view (gethash target portal-fake-native--views)))
    (pcase action
      ("focus"
       (when (plist-get view :visible)
         (dolist (other (portal-fake-native-targets))
           (unless (equal other target) (portal-fake-native--focus other nil)))
         (portal-fake-native--focus target t)
         t))
      ("unfocus"
       (when view (portal-fake-native--focus target nil))
       t))))
(defun portal--input-escape-key (character modifiers)
  (portal-fake-native--call 'portal--input-escape-key character modifiers)
  t)
(defun portal--input-double-escape (milliseconds)
  (portal-fake-native--call 'portal--input-double-escape milliseconds)
  t)

;; Launcher exports.  One frame at a time lends the panel its view; showing
;; makes the panel key and starts a presentation, as native placement does.
(defun portal-fake-native--launcher-set (&rest facts)
  "Set FACTS in the attached launcher's state."
  (while facts
    (setq portal-fake-native--launcher
          (plist-put portal-fake-native--launcher (pop facts) (pop facts)))))

(defun portal-fake-native--launcher-end ()
  "End the panel's presentation, hiding it, and start a new session."
  (cl-incf portal-fake-native--launcher-session)
  (portal-fake-native--launcher-set :visible nil :key nil :presenting nil))

(defun portal--launcher-attach (title)
  (portal-fake-native--call 'portal--launcher-attach title)
  (when portal-fake-native--launcher (error "Portal launcher is already attached"))
  (let ((frame (cl-find title (frame-list)
                        :key (lambda (frame) (frame-parameter frame 'title)) :test #'equal)))
    (unless frame
      (error "Portal launcher needs a new hidden, undecorated GNU Emacs NS frame"))
    (setq portal-fake-native--launcher (list :frame frame :visible nil :key nil))
    t))

(defun portal--launcher-prepare ()
  (portal-fake-native--call 'portal--launcher-prepare)
  t)

(defun portal--launcher-show (width height dx dy screen shadow radius)
  (portal-fake-native--call 'portal--launcher-show width height dx dy screen shadow radius)
  (unless (and (integerp width) (>= width 200) (integerp height) (>= height 1)
               (integerp dx) (integerp dy) (integerp screen) (>= screen -1)
               (natnump radius))
    (error "Launcher needs width >= 200, height >= 1, screen >= -1 and radius >= 0"))
  (unless portal-fake-native--launcher (error "Portal launcher is not attached"))
  (cl-incf portal-fake-native--launcher-session)
  (portal-fake-native--launcher-set :visible t :key t :presenting t :lost-focus nil :height height)
  t)

(defun portal--launcher-fit (session height)
  (portal-fake-native--call 'portal--launcher-fit session height)
  (unless (and (natnump session) (integerp height) (>= height 1))
    (error "Launcher fit needs a session >= 0 and height >= 1"))
  ;; A stale session or a hidden panel is ignored.
  (when (and (eql session portal-fake-native--launcher-session)
             (plist-get portal-fake-native--launcher :presenting))
    (portal-fake-native--launcher-set :height height))
  t)

(defun portal--launcher-hide (&optional restore-focus)
  (portal-fake-native--call 'portal--launcher-hide restore-focus)
  (when portal-fake-native--launcher (portal-fake-native--launcher-end))
  t)

(defun portal--launcher-detach ()
  (portal-fake-native--call 'portal--launcher-detach)
  (when portal-fake-native--launcher
    (portal-fake-native--launcher-end)
    (setq portal-fake-native--launcher nil))
  t)

(defun portal--launcher-inspect ()
  (append (list :attached (and portal-fake-native--launcher t)
                :session portal-fake-native--launcher-session)
          (when portal-fake-native--launcher
            (list :visible (plist-get portal-fake-native--launcher :visible)
                  :key (plist-get portal-fake-native--launcher :key)
                  :height (plist-get portal-fake-native--launcher :height)))))

(defun portal-fake-native-launcher-frame ()
  "Return the frame whose view the launcher panel holds, or nil."
  (plist-get portal-fake-native--launcher :frame))

(defun portal-fake-native-launcher-blur ()
  "Take the keyboard from a presenting panel, as another window or app does.
Send its `launcher-blur' record, once per presentation, as the native
module does."
  (when (and (plist-get portal-fake-native--launcher :presenting)
             (not (plist-get portal-fake-native--launcher :lost-focus)))
    (portal-fake-native--launcher-set :key nil :lost-focus t)
    (portal-fake-native-send (format "launcher-blur %d\n" portal-fake-native--launcher-session))))

(defun portal--terminal-bindings (_json) t)
(defun portal--terminal-theme (_theme) t)
(defun portal--web-appearance (appearance)
  (portal-fake-native--call 'portal--web-appearance appearance)
  t)

(provide 'portal-native-module)
(provide 'portal-fake-native)
;;; portal-fake-native.el ends here
