;;; portal-launcher-testing.el --- Shared fixtures of the graphical launcher suites -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Helpers for launcher suites that run in a disposable graphical Emacs with
;; the newly built module and the test-only event injector (docs/testing.md):
;; a panel fixture that restores frames and focus, native strokes typed into
;; the panel, and the launcher guide's examples on test chords.  Loading this
;; file defines no tests.

(require 'ert)
(require 'cl-lib)
(require 'portal-launcher)
(require 'portal-global-shortcut)
(require 'portal-launcher-examples)

(declare-function portal-test-hotkey "test-terminal-input" (hotkey pressed))
(declare-function portal--launcher-inspect "portal-launcher" ())
(declare-function portal--shortcuts "portal-global-shortcut" ())
(declare-function portal-test-native-post-key "test-terminal-input" (code flags text &optional windowless))
(declare-function portal-test-native-target-frame "test-terminal-input" (title))
(declare-function portal-test-frontmost "test-terminal-input" (&optional app))
(declare-function portal-test-native-focus-target "test-terminal-input" ())
(declare-function portal-test-capture-target "test-terminal-input" (file))
(declare-function vertico-mode "vertico" (&optional arg))
(declare-function marginalia-mode "marginalia" (&optional arg))
(defvar vertico-sort-function)
(defvar vertico-count)
(defvar vertico--candidates-ov)
(defvar vertico--index)

(defmacro portal-launcher-gui--with-panel (&rest body)
  (declare (indent 0))
  `(progn
     (skip-unless (eq window-system 'ns))
     (let ((before (frame-list))
           (ordinary (selected-window))
           (ordinary-buffer (window-buffer))
           (content (generate-new-buffer " *launcher GUI*"))
           (portal-launcher-size '(720 420))
           (portal-launcher-offset '(0 0))
           (portal-launcher-screen nil))
       (unwind-protect
           (progn ,@body)
         (portal-launcher-mode -1)
         (portal-global-shortcut--remove-all)
         (when (buffer-live-p content) (kill-buffer content))
         (when (window-live-p ordinary) (select-window ordinary))
         (dolist (frame (frame-list))
           (unless (memq frame before) (delete-frame frame t)))
         ;; Changing/deleting ordinary NS windows can asynchronously activate
         ;; the previous app. Drain that cleanup before another test starts a
         ;; session whose focus-loss observer would correctly cancel it.
         (portal-launcher-gui--settle-focus))
       (should-not portal-launcher--frame)
       (should (equal before (frame-list)))
       (should (eq (window-buffer ordinary) ordinary-buffer)))))

(defun portal-launcher-gui--settle ()
  (redisplay t)
  (accept-process-output nil 0.05)
  (redisplay t))

(defun portal-launcher-gui--settle-focus ()
  "Wait, up to 3 s, until the frontmost app has not changed for 0.5 s.
AppKit can report an activation after the next session has started to
watch focus. `sit-for' would return at once while input is pending."
  (let ((deadline (+ (float-time) 3))
        (front (portal-test-frontmost))
        (since (float-time)))
    (while (and (< (float-time) deadline) (< (- (float-time) since) 0.5))
      (accept-process-output nil 0.05)
      (let ((now (portal-test-frontmost)))
        (unless (eql now front) (setq front now since (float-time)))))))

(defun portal-launcher-gui--hotkey (name)
  "The native hot key of the global shortcut NAME, for the injector."
  (let ((id (cadr (assq name portal-global-shortcut--registrations))))
    (plist-get (cl-find id (portal--shortcuts) :key (lambda (shortcut) (plist-get shortcut :id)))
               :hotkey)))

(defun portal-launcher-gui--press (name)
  "Press and release NAME's chord, as Carbon reports it, and read the record."
  (let ((hotkey (portal-launcher-gui--hotkey name)))
    (should (portal-test-hotkey hotkey t))
    (should (portal-test-hotkey hotkey nil)))
  (portal-view--read-records))

;; A running Emacs may already have the launcher guide's chords.
(defconst portal-launcher-gui--chords
  '(("Control-Option-Command-F" . "Control-Option-Command-F17")
    ("Control-Option-Command-H" . "Control-Option-Command-F18")
    ("Control-Option-Command-K" . "Control-Option-Command-F19")
    ("Control-Option-Command-P" . "Control-Option-Command-F20"))
  "The launcher guide's chords and the ones these tests set in their place.")

(defun portal-launcher-gui--example (name)
  "Load the launcher guide's example NAME on test chords with dynamic binding.
A configuration file need not enable `lexical-binding'; the batch tests load
the examples with both bindings."
  (should-not (portal-launcher-examples-load (list name) nil portal-launcher-gui--chords)))

(defun portal-launcher-gui--dismiss-shortcut ()
  "Set the global shortcut `portal-launcher-gui', which presents a launcher.
Pressed while a panel is open, it dismisses the panel."
  (portal-global-shortcut-set 'portal-launcher-gui "Control-Option-Command-F16"
                              (lambda () (interactive) (portal-launcher-present #'ignore))))

(defvar portal-launcher-gui--action nil)

(defun portal-launcher-gui--act ()
  (interactive)
  (funcall portal-launcher-gui--action))

(defun portal-launcher-gui--drive (start strokes &optional action loop)
  "Call START with native STROKES typed into its prompts; C-] calls ACTION.
Strokes go to the panel while Emacs reads in a prompt or a persistent
panel's buffer.  With LOOP, START only queues input, which the real command
loop then reads, in a recursive edit that ends once STROKES are typed and
the command loop waits with no session.  Return START's value, or nil."
  (let* ((portal-launcher-gui--action action)
         ;; A runner may call ERT from a timer, where quit is inhibited. Real
         ;; command-loop invocation permits native C-g to unwind a minibuffer.
         (inhibit-quit nil)
         (quit-flag nil)
         (map (make-sparse-keymap))
         (global (current-global-map))
         (depth (recursion-depth))
         (base (if loop (1+ depth) depth))
         (timer (run-with-timer
                 0.1 0.1
                 (lambda ()
                   (cond
                    ;; Deeper means a prompt, or a persistent panel's buffer.
                    ((and strokes (> (recursion-depth) base))
                     (portal-view--with-frame-title portal-launcher--frame #'portal-test-native-target-frame)
                     (let ((stroke (pop strokes)))
                       ;; Synthetic AppKit C-g gets held by this Emacs build
                       ;; even in an ordinary read-string. Queue the Emacs
                       ;; event for this one key; other strokes are native.
                       (if (eq stroke 'quit)
                           (setq unread-command-events (append unread-command-events '(7)))
                         (apply #'portal-test-native-post-key stroke))))
                    ((and loop (null strokes) (= (recursion-depth) base)
                          (null unread-command-events) (not portal-launcher--session))
                     (exit-recursive-edit)))))))
    (set-keymap-parent map global)
    (keymap-set map "C-]" #'portal-launcher-gui--act)
    (use-global-map map)
    (unwind-protect
        (prog1 (with-timeout (10 (error "Launcher prompt timed out; pending input: %S" strokes))
                 (if (not loop) (funcall start)
                   (funcall start)
                   (recursive-edit)
                   nil))
          (should-not strokes)
          (should (= depth (recursion-depth)))
          (should-not (active-minibuffer-window))
          (should-not portal-launcher--session)
          (should-not (plist-get (portal--launcher-inspect) :visible))
          (when (frame-live-p portal-launcher--frame)
            (should-not (frame-visible-p portal-launcher--frame))))
      (cancel-timer timer)
      (portal-test-native-target-frame nil)
      (use-global-map global))))

(defun portal-launcher-gui--present (command strokes &optional action options)
  "Present COMMAND with native STROKES typed into its prompts; C-] calls ACTION.
OPTIONS are `portal-launcher-present' keywords and values.  With
:keep-open, STROKES also go to the panel's buffer after COMMAND returns."
  (portal-launcher-gui--drive (lambda () (apply #'portal-launcher-present command options))
                              strokes action))

(defun portal-launcher-gui--text (text)
  (let ((codes '((?a . 0) (?b . 11) (?c . 8) (?d . 2) (?e . 14) (?f . 3)
                 (?g . 5) (?h . 4) (?i . 34) (?j . 38) (?k . 40) (?l . 37)
                 (?m . 46) (?n . 45) (?o . 31) (?p . 35) (?q . 12) (?r . 15)
                 (?s . 1) (?t . 17) (?u . 32) (?v . 9) (?w . 13) (?x . 7)
                 (?y . 16) (?z . 6) (?! . 18) (?- . 27) (?\s . 49)
                 (?0 . 29) (?1 . 18) (?2 . 19) (?3 . 20) (?4 . 21)
                 (?5 . 23) (?6 . 22) (?7 . 26) (?8 . 28) (?9 . 25))))
    (mapcar (lambda (char)
              (list (alist-get (downcase char) codes) (if (or (<= ?A char ?Z) (= char ?!)) 131072 0)
                    (string char))) text)))

;; Set PORTAL_LAUNCHER_SCREENSHOTS to a directory to keep pictures of the panel.
(defun portal-launcher-gui--capture (name)
  "Save the panel's Emacs drawing as NAME.png in $PORTAL_LAUNCHER_SCREENSHOTS."
  (when-let* ((directory (getenv "PORTAL_LAUNCHER_SCREENSHOTS")))
    (redisplay t)
    (portal-view--with-frame-title portal-launcher--frame #'portal-test-native-target-frame)
    (unwind-protect
        (should (portal-test-capture-target (expand-file-name (concat name ".png") directory)))
      (portal-test-native-target-frame nil))))

(defun portal-launcher-gui--check-unwound ()
  "Check that a persistent presentation left no hooks or session."
  (should-not portal-launcher--session)
  (should-not (memq #'portal-launcher--dismiss-if-blurred (default-value 'post-command-hook)))
  (should-not (memq #'portal-launcher--refit (default-value 'post-command-hook)))
  (should-not (memq #'portal-launcher--hide-mode-lines window-buffer-change-functions))
  (should-not (cl-find 'portal-launcher-blur unread-command-events :key #'car-safe)))

(provide 'portal-launcher-testing)
;;; portal-launcher-testing.el ends here
