;;; portal-launcher-gui-tests.el --- Real NS panel lifecycle -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run only in a disposable graphical Emacs with the newly built module.
(require 'ert)
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

(defvar portal-launcher-gui--unsettled nil
  "Non-nil once a test has changed or deleted an ordinary frame.
AppKit can then activate another app after the test has ended.")

(defmacro portal-launcher-gui--with-panel (&rest body)
  (declare (indent 0))
  `(progn
     (skip-unless (eq window-system 'ns))
     (let ((before (frame-list))
           (front (portal-test-frontmost))
           (portal-launcher-gui--unsettled nil)
           (ordinary (selected-window))
           (ordinary-buffer (window-buffer))
           (content (generate-new-buffer " *launcher GUI*"))
           (portal-launcher-size '(720 420))
           (portal-launcher-height-limits '(100 nil))
           (portal-launcher-offset '(0 0))
           (portal-launcher-screen nil)
           finished)
       (unwind-protect
           (prog1 (progn ,@body) (setq finished t))
         (portal-launcher-mode -1)
         (portal-global-shortcut--remove-all)
         (when (buffer-live-p content) (kill-buffer content))
         (when (window-live-p ordinary) (select-window ordinary))
         (dolist (frame (frame-list))
           (unless (memq frame before)
             (setq portal-launcher-gui--unsettled t)
             (delete-frame frame t)))
         ;; Changing/deleting ordinary NS windows can asynchronously activate
         ;; the previous app. Drain that cleanup before another test starts a
         ;; session whose focus-loss observer would correctly cancel it. A
         ;; test that changed no ordinary window or app has nothing to drain.
         (when (or portal-launcher-gui--unsettled (not finished)
                   (not (eql front (portal-test-frontmost))))
           (portal-launcher-gui--settle-focus)))
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

(defun portal-launcher-gui--once-fitted (predicate function)
  "Call FUNCTION from a timer once the panel has fitted and PREDICATE holds.
Fitted: Emacs waits for input with none pending, its launcher frame at
the panel's native size. Poll every 0.05 s; after 10 s give up, leaving
the presentation's own timeout to report it."
  (let ((deadline (+ (float-time) 10)) timer)
    (setq timer
          (run-with-timer
           0.05 0.05
           (lambda ()
             (cond
              ((and (current-idle-time) (not (input-pending-p))
                    (frame-live-p portal-launcher--frame)
                    (equal (cddr (plist-get (portal--launcher-inspect) :actual))
                           (list (frame-pixel-width portal-launcher--frame)
                                 (frame-pixel-height portal-launcher--frame)))
                    (funcall predicate))
               (cancel-timer timer)
               (funcall function))
              ((> (float-time) deadline) (cancel-timer timer))))))))

(defun portal-launcher-gui--native-height ()
  (nth 3 (plist-get (portal--launcher-inspect) :actual)))

(ert-deftest portal-launcher-gui-real-buffer-and-reuse ()
  (portal-launcher-gui--with-panel
    (with-current-buffer content (insert "Real buffer in a native panel\n"))
    (portal-launcher-mode 1)
    (should (equal before (frame-list)))
    (should-not (plist-get (portal--launcher-inspect) :attached))
    (let ((frame (portal-launcher-show content)))
      (portal-launcher-gui--settle)
      (should (eq (selected-frame) frame))
      (should (eq (window-buffer (frame-selected-window frame)) content))
      (should (equal (buffer-string) "Real buffer in a native panel\n"))
      (should (plist-get (portal--launcher-inspect) :viewAttached))
      (should (plist-get (portal--launcher-inspect) :visible))
      (should (string-match-p "LauncherPanel" (plist-get (portal--launcher-inspect) :class)))
      (goto-char (point-max))
      (execute-kbd-macro "edited")
      (portal-launcher-hide)
      (should (eq (selected-window) ordinary))
      (should-not (frame-visible-p frame))
      (should-not (plist-get (portal--launcher-inspect) :visible))
      (should (eq (portal-launcher-show) frame))
      (should (string-suffix-p "edited" (buffer-string)))
      ;; One cycle proves reuse; a few show that it holds.
      (dotimes (_ 10) (portal-launcher-hide) (should (eq (portal-launcher-show) frame)))
      (portal-launcher-hide))))

(ert-deftest portal-launcher-gui-native-keyboard ()
  (skip-unless (fboundp 'portal-test-native-post-key))
  (portal-launcher-gui--with-panel
    (portal-launcher-show content)
    (portal-view--with-frame-title portal-launcher--frame #'portal-test-native-target-frame)
    (unwind-protect
        (progn
          (portal-test-native-post-key 0 0 "a")
          (should (equal (with-timeout (3 (ert-fail "Panel did not deliver input to Emacs"))
                           (read-key-sequence-vector nil)) [97])))
      (portal-test-native-target-frame nil))))

(ert-deftest portal-launcher-gui-geometry-and-appearance ()
  (portal-launcher-gui--with-panel
    (portal-launcher-show content)
    (let ((screens (plist-get (portal--launcher-inspect) :screens)) measurements)
      (dotimes (index (length screens))
        (dolist (size '((640 320) (720 420) (860 520) (713 407)))
          (dolist (offset '((0 0) (-137 81)))
            (let ((portal-launcher-screen index) (portal-launcher-size size)
                  (portal-launcher-offset offset))
              (portal-launcher-show)
              (portal-launcher-gui--settle)
              (let ((state (portal--launcher-inspect)))
                (should (equal (plist-get state :requested) (plist-get state :actual)))
                (should (equal (cddr (plist-get state :actual)) size))
                (should (equal (list (frame-pixel-width portal-launcher--frame)
                                    (frame-pixel-height portal-launcher--frame)) size))
                (push (list :screen index :size size :offset offset
                            :requested (plist-get state :requested) :actual (plist-get state :actual))
                      measurements))))))
      (message "Launcher geometry: %S; screens: %S" (nreverse measurements) screens))
    (let ((portal-launcher-size '(713 407)))
      (dolist (appearance '(dark light nil))
        (set-frame-parameter portal-launcher--frame 'ns-appearance appearance)
        (dolist (font '("Menlo 13" "Menlo 18" "Menlo 15"))
          (let ((portal-launcher-font font))
            (portal-launcher-show)
            (portal-launcher-gui--settle)
            (should (equal (cddr (plist-get (portal--launcher-inspect) :actual)) '(713 407)))))))
    (let ((portal-launcher-size '(100000 100000)) (portal-launcher-offset '(-100000 100000)))
      (portal-launcher-show)
      (portal-launcher-gui--settle)
      (let* ((state (portal--launcher-inspect)) (actual (plist-get state :actual)))
        (should (equal actual (plist-get state :requested)))
        (should (cl-some (lambda (screen) (equal actual (plist-get screen :visible)))
                         (plist-get state :screens)))))
    ;; A disconnected index falls back to the pointer screen.
    (let ((portal-launcher-screen 999)) (portal-launcher-show))))

(ert-deftest portal-launcher-gui-delete-disable-and-child ()
  (portal-launcher-gui--with-panel
    (dotimes (_ 20)
      (let ((frame (portal-launcher-show content)))
        (delete-frame frame t)
        (should-not (frame-live-p frame))
        (should-not (plist-get (portal--launcher-inspect) :attached))))
    (let* ((frame (portal-launcher-show content))
           (child (make-frame `((parent-frame . ,frame) (minibuffer . nil)
                               (undecorated . t) (width . 20) (height . 4)
                               (no-accept-focus . t) (visibility . nil)))))
      (make-frame-visible child)
      (portal-launcher-gui--settle)
      (delete-frame frame t)
      (should-not (frame-live-p child)))
    (dotimes (_ 3)
      (portal-launcher-show content)
      (portal-launcher-mode -1)
      (portal-launcher-mode -1)
      (should-not (plist-get (portal--launcher-inspect) :attached)))
    (should (eq (selected-window) ordinary))))

(ert-deftest portal-launcher-gui-rejects-mutation-and-rolls-back ()
  (portal-launcher-gui--with-panel
    (let ((initial-frames (frame-list)))
      (cl-letf (((symbol-function 'portal--launcher-attach)
                 (lambda (_title) (error "Simulated attachment failure"))))
        (should-error (portal-launcher-show content)))
      (should (equal initial-frames (frame-list)))
      (should-not (plist-get (portal--launcher-inspect) :attached)))
    (let ((frame (portal-launcher-show content)))
      (dolist (change '((undecorated . nil) (fullscreen . fullboth) (parent-frame . other)
                        (tool-bar-lines . 1) (no-focus-on-map . nil)))
        (should-error (set-frame-parameter frame (car change) (cdr change)) :type 'user-error))
      (modify-frame-parameters frame '((parent-frame . nil) (undecorated . t)))
      (should (plist-get (portal--launcher-inspect) :viewAttached))
      (portal-launcher-hide)
      ;; Ordinary Emacs frames still change their role normally.
      (setq portal-launcher-gui--unsettled t)
      (set-frame-parameter (window-frame ordinary) 'undecorated t)
      (set-frame-parameter (window-frame ordinary) 'undecorated nil)
      (should (eq (portal-launcher-show) frame)))))

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
         ;; A delayed timer must not catch up with several strokes at once.
         (timer-max-repeats 1)
         (timer (run-with-timer
                 0.05 0.05
                 (lambda ()
                   (cond
                    ;; Deeper means a prompt, or a persistent panel's buffer.
                    ;; Each stroke waits until Emacs is idle with no input
                    ;; queued, so the last one's command and post-command hook
                    ;; have finished: Vertico, for one, skips its redraw while
                    ;; input waits, and an error report discards queued input.
                    ((and strokes (> (recursion-depth) base)
                          (current-idle-time) (not (input-pending-p)))
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

(ert-deftest portal-launcher-gui-picker-selection-without-typing ()
  ;; A user's picker in a minibuffer panel, typed into with native keys.
  ;; Portal returns whatever completion returns; it adds no input policy.
  (require 'vertico)
  (require 'orderless)
  (require 'marginalia)
  (portal-launcher-gui--with-panel
    (let ((reader completing-read-function)
          (picker (lambda ()
                    (completing-read "Pick: " '("Calculator" "Calendar" "Chess")))))
      (dolist (enhanced '(nil t))
        (let ((completion-styles (if enhanced '(orderless basic) '(basic)))
              (completion-category-defaults nil)
              (vertico-sort-function #'identity)
              (minibuffer-history nil))
          (vertico-mode (if enhanced 1 -1))
          (marginalia-mode (if enhanced 1 -1))
          (unwind-protect
              (cl-flet ((pick (strokes)
                          (portal-launcher-gui--present picker strokes nil '(:kind minibuffer))))
                (should (equal "Chess" (pick (append (portal-launcher-gui--text "Chess") '((36 0 "\r"))))))
                (should (equal "Notes" (pick (append (portal-launcher-gui--text "Notes")
                                                     '((36 0 "\r"))))))
                ;; With Vertico, Return accepts the highlighted candidate
                ;; with no typed text, the first or one chosen with arrows.
                ;; Stock completion highlights nothing and returns "".
                (should (equal (if enhanced "Calculator" "") (pick '((36 0 "\r")))))
                (when enhanced
                  (should (equal "Calendar" (pick '((125 0 "\uf701") (36 0 "\r")))))
                  (should (equal "Calculator" (pick '((125 0 "\uf701") (126 0 "\uf700") (36 0 "\r"))))))
                (should-not (pick '((53 0 "\e")))))
            (vertico-mode -1)
            (marginalia-mode -1)))
        (should (eq reader completing-read-function))
        (should (eq ordinary (selected-window)))))))

;; The launcher guide's examples, as a user configures them: the same picker from
;; M-x, its key and its global shortcut through the real command loop, a
;; persistent buffer and a shortcut that presents nothing.
(ert-deftest portal-launcher-gui-user-launchers-through-command-loop ()
  (skip-unless (fboundp 'portal-test-hotkey))
  (portal-launcher-gui--with-panel
    (let ((global (current-global-map))
          (map (make-sparse-keymap))
          (suggest-key-bindings nil)
          (extended-command-suggest-shorter nil)
          (messages (with-current-buffer "*Messages*" (point-max-marker))))
      (unwind-protect
          (progn
            ;; The picker's key goes in a map of this test's own.
            (set-keymap-parent map global)
            (use-global-map map)
            (discard-input)
            (dolist (example '("launcher-picker" "launcher-hello" "launcher-shortcuts"))
              (portal-launcher-gui--example example))
            ;; Configuring set only the three shortcuts, and no panel yet.
            (should (equal (mapcar #'car portal-global-shortcut--registrations)
                           '(pick-fruit hello clock)))
            (should (= 3 (length (portal--shortcuts))))
            (should-not portal-launcher--frame)
            (cl-flet ((pick (start fruit)
                        (portal-launcher-gui--drive
                         start (append (portal-launcher-gui--text fruit) '((36 0 "\r"))) nil t)
                        (should (with-current-buffer "*Messages*"
                                  (save-excursion
                                    (goto-char messages)
                                    (search-forward (concat "Picked " fruit) nil t))))
                        (should (portal-launcher--live-p 'minibuffer))
                        (should (eq ordinary (selected-window))))
                      (queue (keys)
                        (lambda () (setq unread-command-events (listify-key-sequence (kbd keys))))))
              (pick (queue "M-x my/pick-fruit RET") "Banana")
              (pick (queue "C-c f") "Cherry")
              (pick (lambda () (portal-launcher-gui--press 'pick-fruit)) "Apple"))
            ;; The persistent buffer from its shortcut; the same chord again
            ;; dismisses it.
            (portal-launcher-gui--drive
             (lambda () (portal-launcher-gui--press 'hello))
             (append (portal-launcher-gui--text "nok") '((36 0 "\r") (30 262144 "\C-]")))
             (lambda () (portal-launcher-gui--press 'hello))
             t)
            (should (equal "Hello world!\nHello ok!" (with-current-buffer "*Hello*" (buffer-string))))
            (portal-launcher-gui--check-unwound)
            ;; A shortcut that presents nothing leaves the hidden panel alone.
            (let ((frames (frame-list)))
              (portal-launcher-gui--drive (lambda () (portal-launcher-gui--press 'clock)) nil nil t)
              (should (equal frames (frame-list)))
              (should-not (plist-get (portal--launcher-inspect) :visible))
              (should (eq ordinary (selected-window)))
              (should (with-current-buffer "*Messages*"
                        (save-excursion
                          (goto-char messages)
                          (re-search-forward "^[0-9][0-9]:[0-9][0-9]$" nil t)))))
            ;; The shortcuts outlast deleting and disabling the panel, and
            ;; evaluating the configuration again keeps one of each.
            (let ((ids (mapcar #'cadr portal-global-shortcut--registrations)))
              (delete-frame portal-launcher--frame t)
              (portal-launcher-mode -1)
              (should (equal ids (mapcar #'cadr portal-global-shortcut--registrations)))
              (portal-launcher-gui--example "launcher-shortcuts")
              (should (= 3 (length portal-global-shortcut--registrations)))
              (should (= 3 (length (portal--shortcuts))))
              (should-not (cl-intersection ids (mapcar #'cadr portal-global-shortcut--registrations))))
            (portal-launcher-gui--drive (lambda () (portal-launcher-gui--press 'pick-fruit))
                                        (append (portal-launcher-gui--text "Apple") '((36 0 "\r")))
                                        nil t)
            (should (portal-launcher--live-p 'minibuffer))
            ;; Removing one leaves the others; its hot key is gone.
            (let ((hotkey (portal-launcher-gui--hotkey 'hello)))
              (should (portal-global-shortcut-remove 'hello))
              (should-not (portal-test-hotkey hotkey t)))
            (should (equal (mapcar #'car portal-global-shortcut--registrations) '(pick-fruit clock))))
        (use-global-map global)
        (when (get-buffer "*Hello*") (kill-buffer "*Hello*"))))))

(ert-deftest portal-launcher-gui-session-stock-and-completion-stack ()
  (portal-launcher-gui--with-panel
    (require 'vertico)
    (require 'orderless)
    (require 'marginalia)
    (dolist (enhanced '(nil t))
      (let* ((completion-styles (if enhanced '(orderless basic) '(basic)))
             (completion-category-defaults nil)
             (rules display-buffer-alist)
             (maps emulation-mode-map-alists)
             frames visible
             (minibuffer-setup-hook
              (cons (lambda ()
                      (push (window-frame (active-minibuffer-window)) frames)
                      (push (and (frame-visible-p portal-launcher--frame)
                                 (plist-get (portal--launcher-inspect) :visible)) visible))
                    minibuffer-setup-hook)))
        (vertico-mode (if enhanced 1 -1))
        (marginalia-mode (if enhanced 1 -1))
        (unwind-protect
            (should
             (equal "forward-line"
                    (portal-launcher-gui--present
                     (lambda ()
                       (interactive)
                       (completing-read
                        "Command: "
                        (lambda (string predicate action)
                          (if (eq action 'metadata) '(metadata (category . command))
                            (complete-with-action action '("forward-line" "forward-char") string predicate)))
                        nil t))
                     (append (portal-launcher-gui--text (if enhanced "line for" "forward-line"))
                             '((36 0 "\r"))))))
          (vertico-mode -1)
          (marginalia-mode -1))
        (should (equal frames (list portal-launcher--frame)))
        (should (equal visible '(t)))
        (should (eq rules display-buffer-alist))
        (should (eq maps emulation-mode-map-alists))
        (should (eq (selected-window) ordinary))))))

;; Set PORTAL_LAUNCHER_SCREENSHOTS to a directory to keep pictures of the panel.
(defun portal-launcher-gui--capture (name)
  "Save the panel's Emacs drawing as NAME.png in $PORTAL_LAUNCHER_SCREENSHOTS."
  (when-let* ((directory (getenv "PORTAL_LAUNCHER_SCREENSHOTS")))
    (redisplay t)
    (portal-view--with-frame-title portal-launcher--frame #'portal-test-native-target-frame)
    (unwind-protect
        (should (portal-test-capture-target (expand-file-name (concat name ".png") directory)))
      (portal-test-native-target-frame nil))))

(defun portal-launcher-gui--minibuffer-layout ()
  "Describe the minibuffer launcher's layout, from inside its prompt."
  (redisplay t)
  (let* ((frame portal-launcher--frame)
         (mini (active-minibuffer-window))
         (state (portal--launcher-inspect)))
    (list :input (minibuffer-contents)
          :kind (portal-launcher--kind frame)
          :windows (equal (window-list frame t) (list mini))
          :root (eq (frame-root-window frame) mini)
          :top (- (cadr (window-pixel-edges mini)) (frame-internal-border-width frame))
          :spare (- (frame-pixel-height frame) (* 2 (frame-internal-border-width frame))
                    (window-pixel-height mini))
          :clipped (- (cdr (window-text-pixel-size mini nil nil nil nil t))
                      (window-pixel-height mini))
          :mode-line (window-mode-line-height mini)
          ;; Vertico starts its candidates with a newline and ends each with one.
          :candidates (and (bound-and-true-p vertico--candidates-ov)
                           (1- (cl-count ?\n (overlay-get vertico--candidates-ov 'before-string))))
          :index (bound-and-true-p vertico--index)
          :size (list (frame-pixel-width frame) (frame-pixel-height frame))
          :native (equal (plist-get state :requested) (plist-get state :actual))
          :actual (plist-get state :actual))))

(ert-deftest portal-launcher-gui-minibuffer-panel-vertico ()
  (require 'vertico)
  (portal-launcher-gui--with-panel
    (dolist (size '((720 420) (640 320)))
      (let ((portal-launcher-size size)
            (vertico-sort-function nil) (vertico-count 10)
            (completion-styles '(basic)) (completion-category-defaults nil)
            layouts)
        (vertico-mode 1)
        (unwind-protect
            (should
             (equal "al02"
                    (portal-launcher-gui--present
                     (lambda ()
                       (minibuffer-with-setup-hook
                           (lambda ()
                             (add-hook 'post-command-hook
                                       (lambda () (push (portal-launcher-gui--minibuffer-layout) layouts))
                                       90 t))
                         (completing-read
                          "Pick: " (cons "beta" (mapcar (lambda (n) (format "al%02d" n))
                                                        (number-sequence 1 15)))
                          nil t)))
                     (append (portal-launcher-gui--text "al")
                             '((125 0 "\uf701"))
                             ;; A no-op key, so the layout after Down is
                             ;; pictured once Vertico has redrawn.
                             '((30 262144 "\C-]")) '((36 0 "\r")))
                     (lambda () (portal-launcher-gui--capture (format "minibuffer-vertico-%dx%d" (car size) (cadr size))))
                     '(:kind minibuffer))))
          (vertico-mode -1))
        (let ((layout (cadr layouts)))
          (message "Launcher minibuffer layout %S: %S" size layout)
          (should (equal (plist-get layout :input) "al"))
          (should (eq (plist-get layout :kind) 'minibuffer))
          ;; The minibuffer is the panel's only window: no buffer or mode line
          ;; above it, and the prompt starts at the top of the text area.
          (should (plist-get layout :windows))
          (should (plist-get layout :root))
          (should (= 0 (plist-get layout :top)))
          (should (= 0 (plist-get layout :spare)))
          (should (= 0 (plist-get layout :mode-line)))
          ;; Ten candidates of fifteen, the second selected, none clipped.
          (should (= 10 (plist-get layout :candidates)))
          (should (= 1 (plist-get layout :index)))
          (should (<= (plist-get layout :clipped) 0))
          (should (equal (plist-get layout :size) size))
          (should (plist-get layout :native))
          (should (equal (cddr (plist-get layout :actual)) size)))))))

;; Automatic minibuffer height: `portal-launcher-size' nil or (WIDTH auto).

(declare-function portal-test-pointer "test-terminal-input" (&optional x y))
(declare-function portal-test-compose "test-terminal-input" (text &optional commit))
(declare-function portal-test-marked-text "test-terminal-input" ())
(defvar vertico-resize)

(defvar portal-launcher-gui--layouts nil
  "What `portal-launcher-gui--record' described, most recent first.")

(defvar portal-launcher-gui--row-limit 5
  "Rows that `portal-launcher-gui--inline-rows' shows at most.")

(defvar portal-launcher-gui--refresh nil
  "Update the rows that `portal-launcher-gui--inline-rows' shows.")

(defconst portal-launcher-gui--fruits '("alpha" "alpine" "alto" "also" "altar" "beta" "bet")
  "Five of these show with no input, two start with \"alp\" and none with \"alpx\".")

(defun portal-launcher-gui--inline-rows (candidates &optional trailing)
  "Show CANDIDATES starting with the input in rows below the prompt.
An end-of-buffer overlay's after-string holds them, after a space bearing
the cursor, as an inline completion UI shows them, up to
`portal-launcher-gui--row-limit'. With TRAILING, a newline ends it. The
rows change after each command and on `portal-launcher-gui--refresh'."
  (let ((overlay (make-overlay (point-max) (point-max) nil t t))
        (buffer (current-buffer)))
    (setq portal-launcher-gui--refresh
          (lambda ()
            (with-current-buffer buffer
              (let ((input (minibuffer-contents-no-properties)))
                (move-overlay overlay (point-max) (point-max))
                (overlay-put overlay 'after-string
                             (concat (propertize " " 'cursor t)
                                     (mapconcat (lambda (row) (concat "\n" row))
                                                (take portal-launcher-gui--row-limit
                                                      (seq-filter (lambda (row) (string-prefix-p input row))
                                                                  candidates))
                                                "")
                                     (and trailing "\n")))))))
    (funcall portal-launcher-gui--refresh)
    (add-hook 'post-command-hook (lambda () (funcall portal-launcher-gui--refresh)) nil t)))

(defun portal-launcher-gui--rectangle-in (rectangle area)
  "Whether the (X Y WIDTH HEIGHT) RECTANGLE's top-left corner is in AREA."
  (and (<= (nth 0 area) (nth 0 rectangle) (+ (nth 0 area) (nth 2 area) -1))
       (< (nth 1 area) (+ (nth 1 rectangle) (nth 3 rectangle)) (+ (nth 1 area) (nth 3 area) 1))))

(defun portal-launcher-gui--record ()
  "Describe the minibuffer panel from inside its prompt, once it settles.
:fitted is the native height before this command redisplayed."
  (interactive)
  (let ((fitted (nth 3 (plist-get (portal--launcher-inspect) :actual))))
    (redisplay t)
    (let* ((frame portal-launcher--frame)
           (window (active-minibuffer-window))
           (state (portal--launcher-inspect))
           (actual (plist-get state :actual))
           (screen (cl-position-if (lambda (screen)
                                     (portal-launcher-gui--rectangle-in actual (plist-get screen :visible)))
                                   (plist-get state :screens))))
      (push (list :input (minibuffer-contents-no-properties) :fitted fitted
                  :session (plist-get state :session) :key (plist-get state :key)
                  :left (nth 0 actual) :top (+ (nth 1 actual) (nth 3 actual))
                  :width (nth 2 actual) :height (nth 3 actual)
                  :native (equal (plist-get state :requested) actual)
                  :frame (list (frame-pixel-width frame) (frame-pixel-height frame))
                  :body (window-body-height window t)
                  :text (cdr (window-text-pixel-size window))
                  :line (with-current-buffer (window-buffer window) (default-line-height))
                  :border (frame-internal-border-width frame)
                  :legal (portal-launcher--legal-height frame)
                  :mini (window-pixel-height window)
                  :start (window-start window)
                  :screen screen
                  :area (plist-get (nth screen (plist-get state :screens)) :visible))
            portal-launcher-gui--layouts))))

(defun portal-launcher-gui--fit (read steps &optional setup)
  "Present READ in a minibuffer panel and return how it laid out.
SETUP runs as its first prompt starts. STEPS are native strokes, and
functions that C-] calls as commands, such as `portal-launcher-gui--record',
in order; Return then ends the prompt. Return (INITIAL . LAYOUTS): the
panel's rectangle before the prompt was displayed, and the descriptions."
  (let ((portal-launcher-gui--layouts nil) strokes actions initial)
    (dolist (step steps)
      (if (functionp step)
          (progn (push '(30 262144 "\C-]") strokes) (push step actions))
        (push step strokes)))
    (setq actions (nreverse actions))
    (portal-launcher-gui--present
     (lambda ()
       (minibuffer-with-setup-hook
           (lambda ()
             (setq initial (plist-get (portal--launcher-inspect) :actual))
             (when setup (funcall setup)))
         (funcall read)))
     (append (nreverse strokes) '((36 0 "\r")))
     (lambda () (funcall (pop actions)))
     '(:kind minibuffer))
    (should-not actions)
    (cons initial (reverse portal-launcher-gui--layouts))))

(defun portal-launcher-gui--check-fitted (result width rows &optional exact limits)
  "Check that the layouts in RESULT fit ROWS lines below their first, at WIDTH.
RESULT is what `portal-launcher-gui--fit' returned. Each layout's height
must fit its text exactly, within LIMITS, the presentation's
`portal-launcher-height-limits' (default (100 nil)), with the session,
focus, left and top edges unchanged since it opened, no taller. With
EXACT, the text must also be that many default lines high."
  (pcase-let* ((`(,initial . ,layouts) result)
               (`(,min ,max) (or limits '(100 nil)))
               (first (car layouts)))
    (should (= (length layouts) (length rows)))
    (should (<= (nth 3 initial) (apply #'min (mapcar (lambda (layout) (plist-get layout :height)) layouts))))
    (cl-loop
     for layout in layouts for count in rows do
     (should (equal (list (plist-get layout :session) (plist-get layout :key) (plist-get layout :native)
                          (plist-get layout :left) (plist-get layout :top) (plist-get layout :width))
                    (list (plist-get first :session) t t
                          (nth 0 initial) (+ (nth 1 initial) (nth 3 initial)) width)))
     ;; Emacs's frame follows the native panel; its text fills it exactly.
     (let ((border (plist-get layout :border)) (text (plist-get layout :text)))
       (should (equal (plist-get layout :frame) (list width (plist-get layout :height))))
       (should (= (plist-get layout :height)
                  (max (plist-get layout :legal) (if (eq min 'content) 0 min)
                       (min (or max most-positive-fixnum) (+ text (* 2 border))))))
       ;; Never below the legal height: the minibuffer keeps a line.
       (should (>= (plist-get layout :mini) (plist-get layout :line)))
       (should (= (plist-get layout :body) (- (plist-get layout :height) (* 2 border))))
       (when exact (should (= text (* (1+ count) (plist-get layout :line)))))))))

(defconst portal-launcher-gui--five-two-none-five
  (append (list #'portal-launcher-gui--record) (portal-launcher-gui--text "alp")
          (list #'portal-launcher-gui--record) (portal-launcher-gui--text "x")
          (list #'portal-launcher-gui--record) (make-list 4 '(51 0 "\d"))
          (list #'portal-launcher-gui--record))
  "Steps from five rows of `portal-launcher-gui--fruits' to two, none and five.")

(ert-deftest portal-launcher-gui-minibuffer-panel-fits-content ()
  ;; Five rows, then two, none and five again: the height follows, from
  ;; the first placement's top edge, in the same presentation. A numeric
  ;; size, the control, stays fixed.
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-font "Menlo 24")
          (read (lambda () (read-from-minibuffer "Fruit: ")))
          (setup (lambda () (portal-launcher-gui--inline-rows portal-launcher-gui--fruits))))
      (pcase-dolist (`(,size ,width) '((nil 720) ((640 auto) 640)))
        (let* ((portal-launcher-size size)
               (result (portal-launcher-gui--fit read portal-launcher-gui--five-two-none-five setup)))
          (message "Launcher fitted rows %S: %S" size result)
          (portal-launcher-gui--check-fitted result width '(5 2 0 5) t)
          ;; Five rows, two and none differ in height here.
          (should (equal (length (delete-dups (mapcar (lambda (layout) (plist-get layout :height))
                                                      (cdr result))))
                         3))))
      ;; Commands and redisplay that change nothing ask the panel for nothing.
      (let* ((portal-launcher-size nil) (asks 0) before after
             (count (lambda (&rest _) (cl-incf asks))))
        (advice-add 'portal--launcher-fit :before count)
        (unwind-protect
            (portal-launcher-gui--fit read
                                      (list #'portal-launcher-gui--record
                                            (lambda () (interactive) (setq before asks))
                                            (lambda () (interactive))
                                            (lambda () (interactive) (redisplay t) (redisplay t))
                                            (lambda () (interactive) (setq after asks)))
                                      setup)
          (advice-remove 'portal--launcher-fit count))
        (message "Launcher fitted idle requests: %S then %S" before after)
        (should (> before 0))
        (should (= before after)))
      (let* ((portal-launcher-size '(720 240))
             (result (portal-launcher-gui--fit read portal-launcher-gui--five-two-none-five setup)))
        (message "Launcher fixed rows: %S" result)
        (should (equal (cddr (car result)) '(720 240)))
        (dolist (layout (cdr result))
          (should (equal (list (plist-get layout :height) (plist-get layout :frame)) '(240 (720 240)))))))))

(ert-deftest portal-launcher-gui-minibuffer-panel-fits-rendered-lines ()
  ;; Line spacing, a trailing newline, a taller row and wrapped input.
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-size nil)
          (portal-launcher-font "Menlo 24")
          (read (lambda () (read-from-minibuffer "Fruit: "))))
      (pcase-dolist (`(,name ,setup ,rows ,exact)
                     `((spacing ,(lambda ()
                                   (setq-local line-spacing 6)
                                   (portal-launcher-gui--inline-rows portal-launcher-gui--fruits))
                                (5) t)
                       (trailing ,(lambda () (portal-launcher-gui--inline-rows portal-launcher-gui--fruits t))
                                 (5) t)
                       (tall ,(lambda ()
                                (portal-launcher-gui--inline-rows
                                 (cons (propertize "alpaca" 'face '(:height 1.5)) portal-launcher-gui--fruits)))
                             (5) nil)))
        (let ((result (portal-launcher-gui--fit read (list #'portal-launcher-gui--record) setup)))
          (message "Launcher fitted %S: %S" name result)
          (portal-launcher-gui--check-fitted result 720 rows exact)
          (when (eq name 'tall)
            (let ((layout (cadr result)))
              (should (> (plist-get layout :text) (* 6 (plist-get layout :line))))))))
      ;; Input wraps at the panel's width: several lines, no rows; then two,
      ;; and none with less input; then five rows.
      (let* ((result (portal-launcher-gui--fit
                      read
                      (list (lambda () (interactive) (insert (make-string 200 ?w)))
                            #'portal-launcher-gui--record
                            (lambda () (interactive) (delete-char -150))
                            #'portal-launcher-gui--record
                            (lambda () (interactive) (delete-minibuffer-contents))
                            #'portal-launcher-gui--record)
                      (lambda () (portal-launcher-gui--inline-rows portal-launcher-gui--fruits))))
             (lines (mapcar (lambda (layout) (/ (plist-get layout :text) (plist-get layout :line)))
                            (cdr result))))
        (message "Launcher fitted wrapped input: %S %S" lines result)
        (should (> (car lines) 2))
        (should (> (car lines) (cadr lines) 0))
        (portal-launcher-gui--check-fitted result 720 (list (1- (car lines)) (1- (cadr lines)) 5) t)))))

(ert-deftest portal-launcher-gui-minibuffer-panel-stops-at-the-screen ()
  ;; Content taller than the space below the top edge stops there, with the
  ;; prompt still shown and usable, then shrinks again.
  (portal-launcher-gui--with-panel
    (let* ((portal-launcher-size nil)
           (portal-launcher-font "Menlo 24")
           ;; The 100-point panel opens centred, this far down, leaving 222
           ;; points below its top on any screen: five rows fit, 300 do not.
           (portal-launcher-offset
            (list 0 (- (/ (nth 3 (frame-monitor-workarea)) 2) 172)))
           (portal-launcher-gui--row-limit 5)
           (many (mapcar (lambda (n) (format "al%03d" n)) (number-sequence 1 300)))
           (result (portal-launcher-gui--fit
                    (lambda () (read-from-minibuffer "Many: "))
                    (append (list #'portal-launcher-gui--record
                                  (lambda () (interactive) (setq portal-launcher-gui--row-limit 300))
                                  #'portal-launcher-gui--record)
                            (portal-launcher-gui--text "al1")
                            (list #'portal-launcher-gui--record
                                  (lambda () (interactive) (setq portal-launcher-gui--row-limit 5))
                                  #'portal-launcher-gui--record))
                    (lambda () (portal-launcher-gui--inline-rows many))))
           (layouts (cdr result)))
      (message "Launcher fitted at the screen's bottom: %S" result)
      (pcase-let ((`(,first ,tall ,typed ,last) layouts))
        (dolist (layout (list tall typed))
          ;; The bottom edge stops at the usable area's; the top stays.
          (should (= (- (plist-get layout :top) (plist-get layout :height))
                     (nth 1 (plist-get layout :area))))
          (should (equal (mapcar (lambda (key) (plist-get layout key)) '(:top :left :width :session :key))
                         (mapcar (lambda (key) (plist-get first key)) '(:top :left :width :session :key))))
          (should (> (plist-get layout :text) (plist-get layout :body)))
          (should (equal (plist-get layout :frame) (list 720 (plist-get layout :height))))
          ;; The prompt stays at the top.
          (should (= (plist-get layout :start) 1)))
        (should (equal (plist-get typed :input) "al1"))
        (should (equal (plist-get last :height) (plist-get first :height)))
        (portal-launcher-gui--check-fitted (cons (car result) (list first last)) 720 '(5 5) t)))))

(ert-deftest portal-launcher-gui-minibuffer-panel-height-limits ()
  ;; Menlo 24's 28-point lines and the 16-point borders make a minibuffer
  ;; frame's legal height 60 points: `content' allows it, below 100. A
  ;; maximum caps the rows, which clip below the prompt as at the screen.
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-size nil)
          (portal-launcher-font "Menlo 24")
          (read (lambda () (read-from-minibuffer "Fruit: ")))
          (setup (lambda () (portal-launcher-gui--inline-rows portal-launcher-gui--fruits))))
      (pcase-dolist (`(,limits ,heights ,clipped)
                     '(((content 144) (144 116 60 144) (t nil nil t)) ((80 nil) (200 116 80 200) (nil nil nil nil))
                       ((content nil) (200 116 60 200) (nil nil nil nil))))
        (let* ((portal-launcher-height-limits limits)
               (step 0)
               (result (portal-launcher-gui--fit
                        read
                        (mapcar (lambda (step-or-stroke)
                                  (if (not (functionp step-or-stroke)) step-or-stroke
                                    (lambda ()
                                      (interactive)
                                      (portal-launcher-gui--record)
                                      (when (equal limits '(content 144))
                                        (portal-launcher-gui--capture
                                         (format "minibuffer-limits-%d" (cl-incf step)))))))
                                portal-launcher-gui--five-two-none-five)
                        setup)))
          (message "Launcher height limits %S: %S" limits result)
          (should (equal (mapcar (lambda (layout) (plist-get layout :height)) (cdr result)) heights))
          (portal-launcher-gui--check-fitted result 720 '(5 2 0 5) t limits)
          (cl-loop
           for layout in (cdr result) for clip in clipped do
           ;; The prompt stays at the top, clipped rows or not.
           (should (= (plist-get layout :start) 1))
           (should (eq (> (plist-get layout :text) (plist-get layout :body)) clip))
           (should (= (plist-get layout :legal) 60)))
          ;; Fitting changed no setting.
          (should (equal portal-launcher-height-limits limits))))
      (should (equal (default-value 'portal-launcher-height-limits) '(100 nil))))))

(defun portal-launcher-gui--untouched ()
  "Describe what a failed presentation must leave as it was."
  (redisplay t)
  (let ((state (portal--launcher-inspect))
        (mini (active-minibuffer-window)))
    (list :frames (frame-list) :frame portal-launcher--frame
          :kind (portal-launcher--kind portal-launcher--frame)
          :shown (frame-visible-p portal-launcher--frame)
          :session portal-launcher--session :native-session (plist-get state :session)
          :visible (plist-get state :visible) :key (plist-get state :key)
          :actual (plist-get state :actual) :selected (selected-window)
          :prompt (and mini (with-current-buffer (window-buffer mini) (minibuffer-contents-no-properties)))
          :buffer (window-buffer (frame-first-window portal-launcher--frame)))))

(ert-deftest portal-launcher-gui-too-small-maximum-leaves-presentations-alone ()
  ;; A maximum below the legal height fails before an existing panel is
  ;; cancelled, hidden, replaced or loses the keyboard. With a launcher
  ;; font, that height is measured on a hidden candidate frame, made and
  ;; deleted while the prompt is active.
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-size nil)
          (portal-launcher-font "Menlo 24")
          probes)
      (should
       (equal "alpha"
              (portal-launcher-gui--present
               (lambda () (read-from-minibuffer "Fruit: "))
               (append (portal-launcher-gui--text "al") '((30 262144 "\C-]"))
                       (portal-launcher-gui--text "pha") '((36 0 "\r")))
               (lambda ()
                 ;; A failed `should' would only be reported in the prompt.
                 (let ((before (portal-launcher-gui--untouched))
                       (outcome (condition-case error
                                    (let ((portal-launcher-height-limits '(content 1)))
                                      (portal-launcher-present #'ignore :kind 'minibuffer)
                                      'presented)
                                  (user-error (cadr error)))))
                   (portal-launcher-gui--settle)
                   (push (list outcome before (portal-launcher-gui--untouched)) probes)))
               '(:kind minibuffer))))
      (pcase-let ((`((,outcome ,before ,after)) probes))
        (message "Launcher too-small maximum in a session: %S" outcome)
        (should (equal outcome "Launcher maximum height 1 is below the legal height of its panel, 60 points"))
        (should (equal before after))
        (should (equal (plist-get after :prompt) "al"))
        (should (plist-get after :key))
        (should (plist-get after :visible)))
      ;; An explicitly shown buffer panel keeps its frame, window, content,
      ;; visibility and keyboard.
      (with-current-buffer content (insert "Shown content\n"))
      (let ((frame (portal-launcher-show content)))
        (portal-launcher-gui--settle)
        (let ((before (portal-launcher-gui--untouched)))
          (let ((portal-launcher-height-limits '(content 1)))
            (should-error (portal-launcher-present #'ignore :kind 'minibuffer) :type 'user-error))
          (portal-launcher-gui--settle)
          (should (equal before (portal-launcher-gui--untouched)))
          (should (eq frame portal-launcher--frame))
          (should (eq (plist-get before :buffer) content))
          (should (plist-get before :shown))
          (should (equal "Shown content\n" (with-current-buffer content (buffer-string))))
          (portal-launcher-hide)))
      ;; A valid maximum, measured the same way, presents.
      (let ((portal-launcher-height-limits '(content 300)))
        (should (equal "ok" (portal-launcher-gui--present
                             (lambda () (read-string "Name: "))
                             (append (portal-launcher-gui--text "ok") '((36 0 "\r")))
                             nil '(:kind minibuffer))))))))

(ert-deftest portal-launcher-gui-too-small-maximum-on-a-changed-panel ()
  ;; The live minibuffer panel's internal border changes to 80 points, from
  ;; the initial 16. Presenting reuses that panel, applying the launcher
  ;; font, so its legal height is 188 points with Menlo 24, not the 60 of a
  ;; new panel: a 144-point maximum fails, in a session and outside one,
  ;; and 188 presents.
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-size nil)
          (portal-launcher-font "Menlo 24")
          (step 0)
          (expected "Launcher maximum height 144 is below the legal height of its panel, 188 points")
          probes legal)
      (cl-flet ((invalid ()
                  (condition-case error
                      (let ((portal-launcher-height-limits '(content 144)))
                        (portal-launcher-present #'ignore :kind 'minibuffer)
                        'presented)
                    (user-error (cadr error)))))
        (should
         (equal "alpha"
                (portal-launcher-gui--present
                 (lambda () (read-from-minibuffer "Fruit: "))
                 (append (portal-launcher-gui--text "al") '((30 262144 "\C-]") (30 262144 "\C-]"))
                         (portal-launcher-gui--text "pha") '((36 0 "\r")))
                 (lambda ()
                   (if (= (cl-incf step) 1)
                       (progn
                         ;; Emacs keeps the panel's size; fitting follows.
                         (let ((frame-inhibit-implied-resize t))
                           (set-frame-parameter portal-launcher--frame 'internal-border-width 80))
                         (portal-launcher-gui--settle)
                         (setq legal (portal-launcher--legal-height portal-launcher--frame)))
                     (let ((before (portal-launcher-gui--untouched))
                           (outcome (invalid)))
                       (portal-launcher-gui--settle)
                       (push (list outcome before (portal-launcher-gui--untouched)) probes))))
                 '(:kind minibuffer))))
        (message "Launcher too-small maximum on a changed panel: legal %S, %S" legal (caar probes))
        (should (= legal 188))
        (pcase-let ((`((,outcome ,before ,after)) probes))
          (should (equal outcome expected))
          (should (equal before after))
          (should (equal (plist-get after :prompt) "al"))
          (should (plist-get after :key))
          (should (plist-get after :visible)))
        ;; The hidden panel, reused by the next presentation, without a session.
        (should (portal-launcher--live-p 'minibuffer))
        (let ((before (portal-launcher-gui--untouched)))
          (should (equal (invalid) expected))
          (should (equal before (portal-launcher-gui--untouched)))
          (should-not (plist-get before :visible)))
        ;; A maximum that panel allows presents on it, at its legal height.
        (let ((portal-launcher-height-limits '(content 188)) layout)
          (should (equal "ok" (portal-launcher-gui--present
                               (lambda () (read-string "Name: "))
                               (append (portal-launcher-gui--text "ok") '((30 262144 "\C-]") (36 0 "\r")))
                               (lambda ()
                                 (redisplay t)
                                 (setq layout (list (nth 3 (plist-get (portal--launcher-inspect) :actual))
                                                    (frame-pixel-height portal-launcher--frame)
                                                    (frame-parameter portal-launcher--frame 'internal-border-width))))
                               '(:kind minibuffer))))
          (should (equal layout '(188 188 80))))))))

(defun portal-launcher-gui--frame-layout ()
  "Describe the panel's frame, its root window and its minibuffer."
  (redisplay t)
  (let* ((frame portal-launcher--frame)
         (state (portal--launcher-inspect))
         (actual (plist-get state :actual))
         (root (frame-root-window frame))
         (mini (minibuffer-window frame)))
    (list :session (plist-get state :session) :key (plist-get state :key)
          :native (equal (plist-get state :requested) actual)
          :left (nth 0 actual) :top (+ (nth 1 actual) (nth 3 actual))
          :width (nth 2 actual) :height (nth 3 actual)
          :frame (list (frame-pixel-width frame) (frame-pixel-height frame))
          :legal (portal-launcher--legal-height frame)
          :line (frame-char-height frame)
          :body (window-body-height root t) :lines (window-body-height root)
          :mode-line (window-mode-line-height root)
          :mini (window-pixel-height mini)
          :input (and (eq (active-minibuffer-window) mini) (minibuffer-contents-no-properties)))))

(ert-deftest portal-launcher-gui-buffer-panel-legal-height ()
  ;; A normal frame, a buffer window above the frame's own minibuffer,
  ;; fitting one line of content at the least height Emacs allows it: its
  ;; frame matches the panel, the line shows with the mode line, and the
  ;; minibuffer still reads input. The buffer window's least height honors
  ;; `window-min-height', whose default of 4 lines makes both panels the
  ;; same height; at 1 line, the panel is a text line, the mode line and
  ;; the minibuffer's line.
  (portal-launcher-gui--with-panel
    (with-current-buffer content (insert "Only line"))
    (pcase-dolist (`(,mode-line ,window-min-height) '((t 4) (nil 4) (t 1) (nil 1)))
      (let ((portal-launcher-size '(720 auto))
            (portal-launcher-font "Menlo 13")
            (portal-launcher-height-limits '(content 300))
            initial layouts)
        (should
         (equal "ok"
                (portal-launcher-gui--present
                 (lambda ()
                   (setq initial (portal-launcher-gui--frame-layout))
                   (switch-to-buffer content)
                   (goto-char (point-min))
                   (read-string "Name: "))
                 (append (portal-launcher-gui--text "ok") '((30 262144 "\C-]")) '((36 0 "\r")))
                 (lambda ()
                   (push (portal-launcher-gui--frame-layout) layouts)
                   (portal-launcher-gui--capture
                    (format "buffer-legal-height-%s-%d" mode-line window-min-height))
                   ;; A maximum caps tall content; nil leaves the screen's.
                   (with-current-buffer content
                     (save-excursion (goto-char (point-max)) (insert (make-string 100 ?\n))))
                   (push (portal-launcher-gui--frame-layout) layouts)
                   (with-current-buffer content
                     (delete-region (1+ (length "Only line")) (point-max))))
                 (list :mode-line mode-line))))
        (pcase-let ((`(,low ,capped) (reverse layouts)))
          (message "Launcher legal buffer height, mode line %s, window-min-height %d: %S then %S, from %S"
                   mode-line window-min-height low capped initial)
          (dolist (layout (list low capped))
            (should (equal (mapcar (lambda (key) (plist-get layout key)) '(:session :key :native :left :top :width))
                           (append (mapcar (lambda (key) (plist-get initial key)) '(:session :key))
                                   (list t)
                                   (mapcar (lambda (key) (plist-get initial key)) '(:left :top :width)))))
            ;; Emacs's frame matches the panel: nothing is cut off.
            (should (equal (plist-get layout :frame) (list 720 (plist-get layout :height))))
            (should (>= (plist-get layout :body) (plist-get layout :line)))
            (should (>= (plist-get layout :mini) (plist-get layout :line)))
            (should (eq (> (plist-get layout :mode-line) 0) mode-line))
            (should (equal (plist-get layout :input) "ok")))
          (should (= (plist-get low :height) (plist-get low :legal) (plist-get initial :height)))
          ;; The window keeps its least height, which Emacs's Lisp resizing
          ;; of the minibuffer assumes.
          (should (>= (+ (plist-get low :body) (plist-get low :mode-line))
                      (* window-min-height (plist-get low :line))))
          (when (= window-min-height 1) (should (< (plist-get low :height) 100)))
          (should (= (plist-get capped :height) 300)))))))

(ert-deftest portal-launcher-gui-buffer-panel-maximum-checks-the-panel-to-show ()
  ;; With Menlo 13 and `window-min-height' 1, a buffer panel's legal height
  ;; is 77 points with its mode line and 62 without. A maximum is checked
  ;; on a hidden candidate set up as the presentation shows its panel, not
  ;; on the live panel, which shows a buffer with a header line and stays
  ;; as it is when the check fails.
  (portal-launcher-gui--with-panel
    (with-current-buffer content
      (setq-local header-line-format "A header line")
      (insert "Shown content"))
    (let ((portal-launcher-font "Menlo 13")
          (window-min-height 1))
      (portal-launcher-show content)
      (portal-launcher-hide)
      (let ((portal-launcher-size '(720 auto))
            (frames (frame-list)))
        (cl-flet ((present (limits mode-line)
                    (condition-case error
                        (let ((portal-launcher-height-limits limits))
                          (portal-launcher-present
                           (lambda () (nth 3 (plist-get (portal--launcher-inspect) :actual)))
                           :mode-line mode-line))
                      (user-error (cadr error)))))
          (should (equal (present '(content 70) t)
                         "Launcher maximum height 70 is below the legal height of its panel, 77 points"))
          (should (eq (window-buffer (frame-first-window portal-launcher--frame)) content))
          (should (equal (list (present '(content 70) nil) (present '(content 77) t)) '(62 77)))
          (should (equal frames (frame-list))))))))

(ert-deftest portal-launcher-gui-buffer-panel-maximum-checks-the-reused-panel ()
  ;; The candidate also has what presenting keeps of the live panel: a font
  ;; set on it directly, and a split from an explicit show. Rejected
  ;; presentations leave both, and the selection, as they were.
  (portal-launcher-gui--with-panel
    (with-current-buffer content
      (setq-local header-line-format "A header line")
      (insert "Shown content"))
    (let ((window-min-height 1)
          (portal-launcher-font nil))
      (cl-flet ((present (limits)
                  (condition-case error
                      (let ((portal-launcher-height-limits limits)
                            (portal-launcher-size '(720 auto)))
                        (portal-launcher-present
                         (lambda ()
                           (list (nth 3 (plist-get (portal--launcher-inspect) :actual))
                                 (length (window-list portal-launcher--frame 'never))))))
                    (user-error (cadr error))))
                (legal (message)
                  (and (stringp message)
                       (string-match "legal height of its panel, \\([0-9]+\\) points" message)
                       (string-to-number (match-string 1 message)))))
        ;; Menlo 24 set on the live panel, not through `portal-launcher-font'.
        (portal-launcher-show content)
        (portal-launcher-hide)
        (set-frame-font "Menlo 24" nil (list portal-launcher--frame))
        (pcase-let* ((`(,height ,windows) (present '(content nil)))
                     (rejected (present (list 'content (1- height)))))
          (message "Launcher maximum with the panel's own font: %S, %S" height rejected)
          (should (= windows 1))
          (should (> height 100))
          (should (= (legal rejected) height))
          (should (equal (present (list 'content height)) (list height 1))))
        ;; A split from an explicit show, which presenting keeps.
        (let ((portal-launcher-font "Menlo 13"))
          (portal-launcher-show content)
          (split-window)
          (portal-launcher-hide)
          (let* ((frames (frame-list))
                 (rejected (present '(content 100)))
                 (height (legal rejected)))
            (message "Launcher maximum with a kept split: %S" rejected)
            (should (> height 100))
            (should (= 2 (length (window-list portal-launcher--frame 'never))))
            (should-not (eq (selected-frame) portal-launcher--frame))
            (should (equal frames (frame-list)))
            (should (equal (present (list 'content height)) (list height 2)))))))))

;; Automatic buffer panels: `portal-launcher-size' (WIDTH auto), :kind buffer.

(defun portal-launcher-gui--record-buffer ()
  "Describe the buffer panel, from a command or timer, once it settles.
:fitted is the native height before this redisplayed."
  (interactive)
  (let ((fitted (nth 3 (plist-get (portal--launcher-inspect) :actual))))
    (redisplay t)
    (let* ((frame portal-launcher--frame)
           (window (frame-root-window frame))
           (live (window-live-p window))
           (buffer (and live (window-buffer window)))
           (mini (minibuffer-window frame))
           (state (portal--launcher-inspect))
           (actual (plist-get state :actual))
           (screen (cl-position-if (lambda (screen)
                                     (portal-launcher-gui--rectangle-in actual (plist-get screen :visible)))
                                   (plist-get state :screens))))
      (push (list :fitted fitted :session (plist-get state :session) :key (plist-get state :key)
                  :native (equal (plist-get state :requested) actual)
                  :left (nth 0 actual) :top (+ (nth 1 actual) (nth 3 actual))
                  :width (nth 2 actual) :height (nth 3 actual)
                  :frame (list (frame-pixel-width frame) (frame-pixel-height frame))
                  :windows (length (window-list frame 'never))
                  :buffer buffer
                  :rows (- (frame-pixel-height frame) (window-pixel-height window) (window-pixel-height mini))
                  :text (and live (cdr (window-text-pixel-size window)))
                  ;; The empty line after a final newline, where point can be.
                  :trailing (if (and live (with-current-buffer buffer
                                            (and (< (point-min) (point-max))
                                                 (eq (char-before (point-max)) ?\n))))
                                (window-default-line-height window)
                              0)
                  :body (and live (window-body-height window t))
                  :decorations (and live (- (window-pixel-height window) (window-body-height window t)))
                  :header (and live (window-header-line-height window))
                  :least (and live (window-min-size window nil nil t))
                  :line (and live (window-default-line-height window))
                  :mini (window-pixel-height mini)
                  ;; The minibuffer's line, as resize_frame_windows sizes it.
                  :unit (+ (frame-char-height frame) (- (window-pixel-height mini) (window-body-height mini t)))
                  :prompt (and (minibufferp (window-buffer mini) t)
                               (cdr (window-text-pixel-size mini)))
                  :legal (portal-launcher--legal-height frame)
                  ;; All of the buffer shows, the empty last line included.
                  :all (and live (pos-visible-in-window-p (with-current-buffer buffer (point-min)) window)
                            (pos-visible-in-window-p (with-current-buffer buffer (point-max)) window))
                  :start (and live (window-start window)) :point (and live (window-point window))
                  :end (and live (with-current-buffer buffer (point-max)))
                  :area (plist-get (nth screen (plist-get state :screens)) :visible))
            portal-launcher-gui--layouts))))

(defun portal-launcher-gui--snap (name)
  "A command recording the buffer panel, then capturing it as NAME."
  (lambda ()
    (interactive)
    (portal-launcher-gui--record-buffer)
    (portal-launcher-gui--capture name)))

(defun portal-launcher-gui--fit-buffer (setup steps &rest options)
  "Present SETUP in a buffer panel kept open, take STEPS, then dismiss it.
STEPS are native strokes, and commands that C-] calls, such as
`portal-launcher-gui--record-buffer', in order; Escape then dismisses the
panel. OPTIONS are more `portal-launcher-present' options. Return
\(INITIAL . LAYOUTS): the panel's rectangle as SETUP started, before any
content, and what the steps recorded."
  (let ((portal-launcher-gui--layouts nil) strokes actions initial)
    (dolist (step steps)
      (if (functionp step)
          (progn (push '(30 262144 "\C-]") strokes) (push step actions))
        (push step strokes)))
    (setq actions (nreverse actions))
    ;; An earlier message would show in the panel's echo area.
    (message nil)
    (portal-launcher-gui--present
     (lambda ()
       (setq initial (plist-get (portal--launcher-inspect) :actual))
       (funcall setup))
     (append (nreverse strokes) '((53 0 "\e")))
     (lambda () (funcall (pop actions)))
     (append '(:keep-open t) options))
    (should-not actions)
    (cons initial (reverse portal-launcher-gui--layouts))))

(defun portal-launcher-gui--buffer-wanted (layout)
  "The height LAYOUT's content wants: its window's, at least its least
height, and the minibuffer's line, or its prompt's, with the frame's rows."
  (+ (plist-get layout :rows)
     (max (plist-get layout :least)
          (+ (plist-get layout :text) (plist-get layout :trailing) (plist-get layout :decorations)))
     (max (plist-get layout :unit) (or (plist-get layout :prompt) 0))))

(defun portal-launcher-gui--check-buffer-fitted (initial layouts width &optional limits)
  "Check that LAYOUTS fit their content, anchored where INITIAL opened.
Each keeps the session, keyboard, left and top edges and WIDTH, and
Emacs's frame matches its native height, which was already fitted as
it was recorded. That height is what the content wants, within LIMITS,
the presentation's `portal-launcher-height-limits' (default (100 nil)),
the legal height and the space below the top edge. Uncapped, all of
the buffer shows, with no blank line but what its least height adds,
unless `max-mini-window-height' kept the minibuffer below its prompt."
  (pcase-let ((`(,min ,max) (or limits '(100 nil)))
              (first (car layouts)))
    (should (<= (nth 3 initial) (apply #'min (mapcar (lambda (layout) (plist-get layout :height)) layouts))))
    (dolist (layout layouts)
      (should (equal (mapcar (lambda (key) (plist-get layout key)) '(:session :key :native :left :top :width))
                     (list (plist-get first :session) t t (nth 0 initial) (+ (nth 1 initial) (nth 3 initial))
                           width)))
      (should (equal (plist-get layout :frame) (list width (plist-get layout :height))))
      (should (= (plist-get layout :fitted) (plist-get layout :height)))
      (should (= (plist-get layout :windows) 1))
      (let ((wanted (portal-launcher-gui--buffer-wanted layout))
            (below (- (plist-get layout :top) (nth 1 (plist-get layout :area)))))
        (should (= (plist-get layout :height)
                   (min below (max (plist-get layout :legal) (if (eq min 'content) 0 min)
                                   (if max (min max wanted) wanted)))))
        (when (= (plist-get layout :height) wanted)
          (should (plist-get layout :all)))
        (when (and (= (plist-get layout :height) wanted)
                   (>= (plist-get layout :mini) (or (plist-get layout :prompt) 0)))
          (should (= (plist-get layout :body)
                     (max (- (plist-get layout :least) (plist-get layout :decorations))
                          (+ (plist-get layout :text) (plist-get layout :trailing))))))))))

(defun portal-launcher-gui--lines (from to)
  "Lines \"Line FROM\" to \"Line TO\", each but the last ending in a newline."
  (mapconcat (lambda (n) (format "Line %d" n)) (number-sequence from to) "\n"))

(ert-deftest portal-launcher-gui-buffer-panel-fits-content ()
  ;; Short content, long content at the maximum, scrolled to its end,
  ;; short again, another buffer and back: the panel fits each, from its
  ;; first top edge, in one presentation and native session. Scrolling and
  ;; point stay the user's.
  (portal-launcher-gui--with-panel
    (let* ((portal-launcher-size '(640 auto))
           (portal-launcher-font "Menlo 24")
           (portal-launcher-height-limits '(content 400))
           (portal-launcher-offset '(0 -150))
           (other (generate-new-buffer " *launcher GUI other*"))
           (result
            (unwind-protect
                (portal-launcher-gui--fit-buffer
                 (lambda ()
                   (with-current-buffer other
                     (insert (portal-launcher-gui--lines 1 2) "\n")
                     (setq-local header-line-format "Another buffer"))
                   (switch-to-buffer content)
                   (insert (portal-launcher-gui--lines 1 5))
                   (goto-char (point-min)))
                 (list (portal-launcher-gui--snap "buffer-fit-short")
                       (lambda () (interactive)
                         (save-excursion (goto-char (point-max)) (insert "\n" (portal-launcher-gui--lines 6 40))))
                       (portal-launcher-gui--snap "buffer-fit-capped")
                       ;; The user moves to the end: Emacs scrolls the window.
                       (lambda () (interactive) (goto-char (point-max)))
                       (portal-launcher-gui--snap "buffer-fit-scrolled")
                       (lambda () (interactive) (delete-region (point-min) (point-max))
                         (insert (portal-launcher-gui--lines 1 2)) (goto-char (point-min)))
                       (portal-launcher-gui--snap "buffer-fit-shrunk")
                       (lambda () (interactive) (switch-to-buffer other))
                       #'portal-launcher-gui--record-buffer
                       (lambda () (interactive) (switch-to-buffer content))
                       #'portal-launcher-gui--record-buffer))
              (kill-buffer other)))
           (layouts (cdr result)))
      (message "Launcher fitted buffer: %S" result)
      (portal-launcher-gui--check-buffer-fitted (car result) layouts 640 '(content 400))
      (pcase-let ((`(,short ,capped ,scrolled ,shrunk ,switched ,back) layouts))
        ;; Five lines fit; forty stop at the maximum, scrollable; the end of
        ;; the buffer shows, scrolled, at the same height.
        (should (< (plist-get short :height) 400))
        (should (plist-get short :all))
        (should (= (plist-get capped :height) (plist-get scrolled :height) 400))
        (should (> (plist-get capped :text) (plist-get capped :body)))
        (should (equal (list (plist-get capped :start) (plist-get capped :point)) '(1 1)))
        (should (> (plist-get scrolled :start) 1))
        (should (= (plist-get scrolled :point) (plist-get scrolled :end)))
        ;; Two lines: the window's least height, then the other buffer,
        ;; with a header line and a final newline, and the first again.
        (should (< (plist-get shrunk :height) (plist-get short :height)))
        (should (= (plist-get shrunk :height) (plist-get back :height)))
        (should (> (plist-get switched :height) (plist-get shrunk :height)))
        (should (> (plist-get switched :trailing) 0))
        (should (plist-get switched :all))))
    ;; Without a maximum, long content stops at the bottom of the screen.
    (let* ((portal-launcher-size '(640 auto))
           (portal-launcher-font "Menlo 24")
           (portal-launcher-height-limits '(content nil))
           (portal-launcher-offset '(0 150))
           (result (portal-launcher-gui--fit-buffer
                    (lambda ()
                      (switch-to-buffer content)
                      (erase-buffer)
                      (insert (portal-launcher-gui--lines 1 100))
                      (goto-char (point-min)))
                    (list #'portal-launcher-gui--record-buffer)))
           (layout (cadr result)))
      (message "Launcher fitted buffer at the screen's bottom: %S" result)
      (portal-launcher-gui--check-buffer-fitted (car result) (cdr result) 640 '(content nil))
      (should (= (- (plist-get layout :top) (plist-get layout :height)) (nth 1 (plist-get layout :area))))
      (should (> (plist-get layout :text) (plist-get layout :body))))))

(ert-deftest portal-launcher-gui-buffer-panel-fits-rendered-lines ()
  ;; Wrapped lines, a taller face, line spacing, overlay strings, header
  ;; lines and hidden mode lines are measured as Emacs displays them.
  (portal-launcher-gui--with-panel
    (let* ((portal-launcher-size '(640 auto))
           (portal-launcher-font "Menlo 18")
           (portal-launcher-height-limits '(content nil))
           (portal-launcher-offset '(0 -150))
           (overlay nil)
           (steps
            (list (lambda () (interactive) (insert (make-string (+ (window-body-width) 5) ?w)))
                  #'portal-launcher-gui--record-buffer
                  (lambda () (interactive)
                    (erase-buffer)
                    (insert (portal-launcher-gui--lines 1 3) "\n"
                            (propertize "Tall line" 'face '(:height 2.0)) "\n"
                            (portal-launcher-gui--lines 5 7)))
                  #'portal-launcher-gui--record-buffer
                  (lambda () (interactive) (setq-local line-spacing 8))
                  #'portal-launcher-gui--record-buffer
                  (lambda () (interactive)
                    (kill-local-variable 'line-spacing)
                    (setq overlay (make-overlay (point-max) (point-max)))
                    (overlay-put overlay 'after-string
                                 (concat "\n" (portal-launcher-gui--lines 1 6))))
                  #'portal-launcher-gui--record-buffer
                  (lambda () (interactive)
                    (overlay-put overlay 'after-string nil)
                    (overlay-put overlay 'before-string (concat "\n" (portal-launcher-gui--lines 1 2))))
                  (portal-launcher-gui--snap "buffer-fit-overlay")
                  (lambda () (interactive) (delete-overlay overlay)
                    (setq-local header-line-format "A header line"))
                  #'portal-launcher-gui--record-buffer)))
      (dolist (mode-line '(t nil))
        (let* ((portal-launcher-gui--layouts nil)
               (result (portal-launcher-gui--fit-buffer
                        (lambda () (switch-to-buffer content) (erase-buffer))
                        steps :mode-line mode-line))
               (layouts (cdr result)))
          (message "Launcher fitted rendered lines, mode line %s: %S" mode-line result)
          (portal-launcher-gui--check-buffer-fitted (car result) layouts 640 '(content nil))
          (pcase-let ((`(,wrapped ,tall ,spaced ,after ,before ,header) layouts))
            ;; Every layout fits its content, or the window's least height.
            (dolist (layout layouts)
              (should (= (plist-get layout :height) (portal-launcher-gui--buffer-wanted layout)))
              (should (plist-get layout :all)))
            (should (= (plist-get wrapped :text) (* 2 (plist-get wrapped :line))))
            (should (> (plist-get tall :text) (* 7 (plist-get tall :line))))
            (should (> (plist-get spaced :text) (plist-get tall :text)))
            (should (= (plist-get after :text) (+ (plist-get tall :text) (* 6 (plist-get after :line)))))
            (should (= (plist-get before :text) (+ (plist-get tall :text) (* 2 (plist-get after :line)))))
            (should (> (plist-get header :header) 0))
            (should (= (plist-get header :decorations)
                       (+ (plist-get before :decorations) (plist-get header :header))))
            (should (eq (> (plist-get before :decorations) 0) mode-line))))
        (with-current-buffer content (kill-all-local-variables))))))

(ert-deftest portal-launcher-gui-buffer-panel-follows-streamed-output ()
  ;; A process's output, then a timer's change, fit with no key pressed,
  ;; stop at the maximum and leave point and the view at the beginning.
  ;; After the presentation, more output resizes nothing.
  (portal-launcher-gui--with-panel
    (let* ((portal-launcher-size '(640 auto))
           (portal-launcher-font "Menlo 24")
           (portal-launcher-height-limits '(content 400))
           (portal-launcher-offset '(0 -150))
           (portal-launcher-gui--layouts nil)
           (filter (lambda (_process text)
                     (with-current-buffer content
                       (save-excursion (goto-char (point-max)) (insert text)))))
           (asks 0)
           (count (lambda (&rest _) (cl-incf asks)))
           initial process)
      (advice-add 'portal--launcher-fit :before count)
      (message nil)
      (unwind-protect
          (progn
            (portal-launcher-gui--drive
             (lambda ()
               (portal-launcher-present
                (lambda ()
                  (setq initial (plist-get (portal--launcher-inspect) :actual))
                  (switch-to-buffer content)
                  (insert "Streamed output")
                  (goto-char (point-min))
                  (setq process
                        (make-process
                         :name "launcher-stream" :noquery t :connection-type 'pipe
                         :command '("/bin/sh" "-c" "i=1; while [ $i -le 30 ]; do printf '\\nLine %d' $i; i=$((i+1)); sleep 0.03; done")
                         :filter filter
                         :sentinel
                         (lambda (_process _event)
                           (portal-launcher-gui--once-fitted
                            (lambda () (= (portal-launcher-gui--native-height) 400))
                            (lambda ()
                              (portal-launcher-gui--record-buffer)
                              (portal-launcher-gui--capture "buffer-fit-streamed")
                              ;; A timer shrinks the content, with no key.
                              (with-current-buffer content
                                (save-excursion
                                  (goto-char (point-min))
                                  (forward-line 3)
                                  (delete-region (point) (point-max))))
                              (portal-launcher-gui--once-fitted
                               (lambda () (< (portal-launcher-gui--native-height) 400))
                               (lambda ()
                                 (portal-launcher-gui--record-buffer)
                                 (setq unread-command-events
                                       (append unread-command-events '(escape)))))))))))
                :keep-open t))
             nil)
            (let ((layouts (reverse portal-launcher-gui--layouts)))
              (message "Launcher fitted streamed output: %S" layouts)
              (portal-launcher-gui--check-buffer-fitted initial layouts 640 '(content 400))
              (pcase-let ((`(,streamed ,shrunk) layouts))
                (should (= (plist-get streamed :height) 400))
                (should (> (plist-get streamed :text) (plist-get streamed :body)))
                (should (< (plist-get shrunk :height) 400))
                (dolist (layout layouts)
                  (should (equal (list (plist-get layout :start) (plist-get layout :point)) '(1 1))))))
            ;; The presentation is over: output no longer reaches the panel.
            (setq asks 0)
            (let ((native (plist-get (portal--launcher-inspect) :actual))
                  (late (make-process
                         :name "launcher-late" :noquery t :connection-type 'pipe
                         :command '("/bin/sh" "-c" "printf '\\nLate\\nLate\\nLate'")
                         :filter filter)))
              (while (process-live-p late) (accept-process-output late 0.05))
              (portal-launcher-gui--settle)
              (should (= asks 0))
              (should (equal native (plist-get (portal--launcher-inspect) :actual)))
              (should (string-suffix-p "Late" (with-current-buffer content (buffer-string))))))
        (advice-remove 'portal--launcher-fit count)
        (when (process-live-p process) (delete-process process))))))

(defvar portal-launcher-gui--echo nil
  "What the echo area test saw: a layout during a message.")

(ert-deftest portal-launcher-gui-buffer-panel-fits-the-minibuffer ()
  ;; A compact panel at its least height grows for a multi-line prompt, a
  ;; nested prompt and Vertico's rows in its minibuffer, and returns.
  ;; Completion UIs resize the minibuffer from Lisp: at that height, with
  ;; Emacs's `window-min-height' or 1, no resize fails. A prompt that the
  ;; ordinary window also shows counts once. An echo area message shows
  ;; as in any frame, without resizing the panel.
  (require 'vertico)
  (portal-launcher-gui--with-panel
    (dolist (window-min-height '(4 1))
      (let* ((portal-launcher-size '(640 auto))
             (portal-launcher-font "Menlo 18")
             (portal-launcher-height-limits '(content nil))
             (portal-launcher-offset '(0 -150))
             (vertico-sort-function nil) (vertico-count 5)
             (completion-styles '(basic)) (completion-category-defaults nil)
             (errors (with-current-buffer "*Messages*" (point-max)))
             (exhibit nil)
             (portal-launcher-gui--echo nil)
             (record #'portal-launcher-gui--record-buffer)
             result)
        (vertico-mode 1)
        (unwind-protect
            (setq result
                  (portal-launcher-gui--fit-buffer
                   (lambda () (switch-to-buffer content) (erase-buffer) (insert "One line"))
                   (append
                    (list record
                          (lambda () (interactive) (read-string "One\nTwo\nThree: ")))
                    (portal-launcher-gui--text "ok")
                    (list record
                          (lambda () (interactive) (read-string "Inner: "))
                          record
                          '(36 0 "\r")
                          record
                          ;; The outer prompt, shown in the ordinary window as well,
                          ;; with the minibuffer window at its least height, as
                          ;; vertico-buffer shows it.
                          (lambda () (interactive)
                            (let ((mini (active-minibuffer-window)))
                              (set-window-buffer (frame-root-window portal-launcher--frame)
                                                 (window-buffer mini))
                              (window-resize mini (- (window-pixel-height mini)) nil nil t)))
                          record
                          (lambda () (interactive)
                            (set-window-buffer (frame-root-window portal-launcher--frame) content))
                          '(36 0 "\r")
                          record
                          (lambda () (interactive)
                            (completing-read "Pick: " (mapcar (lambda (n) (format "al%02d" n))
                                                              (number-sequence 1 12))))
                          (lambda () (interactive)
                            (setq exhibit (and (memq 'vertico--exhibit post-command-hook) t))
                            (portal-launcher-gui--record-buffer)))
                    ;; Three candidates of twelve.
                    (portal-launcher-gui--text "al1")
                    (list (portal-launcher-gui--snap (format "buffer-fit-vertico-%d" window-min-height))
                          '(36 0 "\r")
                          record
                          ;; Eight lines of content, then a six-line message.
                          (lambda () (interactive)
                            (insert "\n" (portal-launcher-gui--lines 2 8))
                            (goto-char (point-min)))
                          record
                          (lambda () (interactive)
                            (let ((message-log-max nil))
                              (message "%s" (portal-launcher-gui--lines 1 6)))
                            (dotimes (_ 4) (redisplay t))
                            (portal-launcher-gui--record-buffer)
                            (setq portal-launcher-gui--echo (pop portal-launcher-gui--layouts)))
                          (lambda () (interactive)
                            (message nil)
                            (portal-launcher-gui--record-buffer))))))
          (vertico-mode -1))
        (message "Launcher fitted minibuffer, window-min-height %d: %S; echo %S"
                 window-min-height result portal-launcher-gui--echo)
        (pcase-let ((`(,compact ,outer ,inner ,outer-again ,twice ,after ,vertico ,filtered ,done
                                ,eight ,cleared)
                     (cdr result)))
          ;; No resize of the minibuffer failed, and Vertico kept updating.
          (should-not (with-current-buffer "*Messages*"
                        (save-excursion (goto-char errors) (search-forward "args-out-of-range" nil t))))
          (should exhibit)
          (portal-launcher-gui--check-buffer-fitted
           (car result) (list compact outer inner outer-again after vertico filtered done eight)
           640 '(content nil))
          ;; At its least height, then taller for the three-line prompt and
          ;; its typed input; Emacs's `max-mini-window-height' decides how
          ;; much of the panel the minibuffer then takes. A one-line inner
          ;; prompt keeps the minibuffer's grown height, and so the panel's.
          (should (= (plist-get compact :height) (plist-get compact :legal)))
          (should (= (plist-get outer :prompt) (* 3 (plist-get outer :line))))
          (should (= (plist-get outer :height)
                     (+ (plist-get compact :height) (* 2 (plist-get outer :line)))))
          (should (<= (plist-get inner :height) (plist-get outer :height)))
          (should (= (plist-get outer-again :height) (plist-get outer :height)))
          ;; Shown twice, the prompt counts once.
          (should (minibufferp (plist-get twice :buffer)))
          (should (> (plist-get twice :prompt) (plist-get twice :unit)))
          (should (= (plist-get twice :height)
                     (+ (plist-get twice :rows)
                        (max (plist-get twice :least) (+ (plist-get twice :text) (plist-get twice :decorations)))
                        (plist-get twice :unit))))
          (should (equal (plist-get twice :frame) (list 640 (plist-get twice :height))))
          ;; Vertico's five rows show in the grown minibuffer, and the
          ;; panel shrinks as they become three.
          (should (= (plist-get vertico :prompt) (plist-get vertico :mini) (* 6 (plist-get compact :line))))
          (should (= (plist-get filtered :prompt) (plist-get filtered :mini) (* 4 (plist-get compact :line))))
          (should (= (plist-get filtered :height) (- (plist-get vertico :height) (* 2 (plist-get compact :line)))))
          (should (= (plist-get done :height) (plist-get compact :height)))
          (should (> (plist-get eight :height) (plist-get compact :height)))
          ;; Once the message clears, the buffer shows whole again.
          (should (= (plist-get cleared :height) (plist-get eight :height)))
          (should (equal (plist-get cleared :frame) (list 640 (plist-get eight :height))))
          ;; Emacs showed the message over the buffer's last line; the
          ;; panel kept its height, and Emacs's frame matched it.
          (let ((echo portal-launcher-gui--echo))
            (should (> (plist-get echo :mini) (plist-get eight :mini)))
            (should (< (plist-get echo :body) (plist-get eight :body)))
            (should (= (plist-get echo :height) (plist-get eight :height)
                       (portal-launcher-gui--buffer-wanted echo)))
            (should (equal (plist-get echo :frame) (list 640 (plist-get echo :height))))
            (should (plist-get cleared :all))))))))

(ert-deftest portal-launcher-gui-buffer-panel-guide-example ()
  ;; The launcher guide's fitted hello panel, from its own text: at its
  ;; least height until the greetings outgrow it, then a line each.
  (portal-launcher-gui--with-panel
    (portal-launcher-gui--example "launcher-hello")
    (portal-launcher-gui--example "launcher-fitted-hello")
    (let* ((portal-launcher-font "Menlo 18")
           (portal-launcher-gui--layouts nil)
           (record '((30 262144 "\C-]")))
           (greet (lambda (name) (append (portal-launcher-gui--text (concat "n" name)) '((36 0 "\r")))))
           (actions (list #'portal-launcher-gui--record-buffer #'portal-launcher-gui--record-buffer
                          #'portal-launcher-gui--record-buffer
                          (portal-launcher-gui--snap "buffer-fit-hello")))
           initial)
      (message nil)
      (unwind-protect
          (portal-launcher-gui--drive
           (lambda ()
             (run-with-timer 0 nil (lambda () (setq initial (plist-get (portal--launcher-inspect) :actual))))
             (funcall (intern "my/hello-fitted")))
           (append record (funcall greet "Ada") record (funcall greet "Bob") (funcall greet "Cy") record
                   (funcall greet "Dee") (funcall greet "Eve") record '((53 0 "\e")))
           (lambda () (funcall (pop actions))))
        (when (get-buffer "*Hello*") (kill-buffer "*Hello*")))
      (let ((layouts (reverse portal-launcher-gui--layouts)))
        (message "Launcher guide's fitted hello: %S" layouts)
        (should-not actions)
        (portal-launcher-gui--check-buffer-fitted initial layouts 640 '(content 480))
        (pcase-let ((`(,hello ,ada ,cy ,eve) layouts))
          ;; One and two lines show at the window's least height, four lines.
          (should (= (plist-get hello :height) (plist-get ada :height) (plist-get hello :legal)))
          (should (= (plist-get cy :height) (plist-get hello :height)))
          (should (= (plist-get eve :height) (+ (plist-get cy :height) (* 2 (plist-get eve :line)))))
          (dolist (layout layouts)
            (should (plist-get layout :all))
            (should (= (plist-get layout :decorations) 0))))))))

(ert-deftest portal-launcher-gui-buffer-panel-pauses-for-splits-and-resizes ()
  ;; A caller's split keeps the panel's height, raised to the split's legal
  ;; height, until one window is left; a numeric resize fixes it for the
  ;; rest of the presentation.
  (portal-launcher-gui--with-panel
    (let* ((portal-launcher-size '(640 auto))
           (portal-launcher-font "Menlo 18")
           (portal-launcher-height-limits '(content nil))
           (portal-launcher-offset '(0 -150))
           (more (lambda () (interactive)
                   (with-current-buffer content
                     (save-excursion (goto-char (point-max)) (insert "\nMore\nMore\nMore")))))
           (split nil)
           (result
            (unwind-protect
                (portal-launcher-gui--fit-buffer
                 (lambda () (switch-to-buffer content) (erase-buffer) (insert (portal-launcher-gui--lines 1 6)))
                 (list #'portal-launcher-gui--record-buffer
                       (lambda () (interactive) (setq split (split-window)))
                       #'portal-launcher-gui--record-buffer
                       more
                       #'portal-launcher-gui--record-buffer
                       (lambda () (interactive) (delete-window split))
                       #'portal-launcher-gui--record-buffer
                       (lambda () (interactive) (portal-launcher-resize 600 300))
                       #'portal-launcher-gui--record-buffer
                       more
                       #'portal-launcher-gui--record-buffer))
              (setq portal-launcher-size '(640 auto))))
           (layouts (cdr result)))
      (message "Launcher buffer splits and resizes: %S" result)
      (pcase-let ((`(,fitted ,split ,grown ,joined ,resized ,fixed) layouts))
        (portal-launcher-gui--check-buffer-fitted (car result) (list fitted joined) 640 '(content nil))
        ;; The split panel keeps its height and session, at least the split
        ;; windows' legal height, its windows remain, and new content does
        ;; not resize it.
        (dolist (layout (list split grown))
          (should (= (plist-get layout :windows) 2))
          (should (equal (mapcar (lambda (key) (plist-get layout key)) '(:session :top))
                         (mapcar (lambda (key) (plist-get fitted key)) '(:session :top))))
          (should (= (plist-get layout :height)
                     (max (plist-get fitted :height) (plist-get split :legal))))
          (should (equal (plist-get layout :frame) (list 640 (plist-get layout :height)))))
        ;; One window again: the content's three new lines fit.
        (should (> (plist-get joined :height) (plist-get fitted :height)))
        ;; The resize's numbers hold, in its new native session.
        (dolist (layout (list resized fixed))
          (should (equal (list (plist-get layout :width) (plist-get layout :height)) '(600 300)))
          (should (equal (plist-get layout :frame) '(600 300)))
          (should (plist-get layout :key)))
        (should-not (equal (plist-get resized :session) (plist-get fitted :session)))
        (should (equal (plist-get fixed :session) (plist-get resized :session)))))))

(ert-deftest portal-launcher-gui-minibuffer-panel-follows-later-changes ()
  ;; A timer's change fits with no key pressed; an echo area message keeps
  ;; the input's height; a nested prompt fits, and its outer prompt again.
  (portal-launcher-gui--with-panel
    (let* ((portal-launcher-size nil)
           (portal-launcher-font "Menlo 24")
           (portal-launcher-gui--row-limit 5)
           (echo nil)
           (result
            (portal-launcher-gui--fit
             (lambda () (read-from-minibuffer "Fruit: "))
             (append
              (list #'portal-launcher-gui--record
                    (lambda ()
                      (interactive)
                      (run-with-timer 0.01 nil (lambda ()
                                                 (setq portal-launcher-gui--row-limit 2)
                                                 (funcall portal-launcher-gui--refresh))))
                    #'portal-launcher-gui--record
                    (lambda ()
                      (interactive)
                      (let ((set-message-function nil) (message-log-max nil)
                            (height (nth 3 (plist-get (portal--launcher-inspect) :actual))))
                        (message "%s" (string-join (make-list 12 "Echo area message") "\n"))
                        (redisplay t)
                        (redisplay t)
                        (setq echo (list (current-message) height
                                         (nth 3 (plist-get (portal--launcher-inspect) :actual))))))
                    #'portal-launcher-gui--record
                    (lambda () (interactive) (setq portal-launcher-gui--row-limit 5))
                    #'portal-launcher-gui--record
                    (lambda () (interactive) (read-string "Inner: "))
                    #'portal-launcher-gui--record)
              (portal-launcher-gui--text "ok")
              (list #'portal-launcher-gui--record '(36 0 "\r") #'portal-launcher-gui--record))
             (lambda () (portal-launcher-gui--inline-rows portal-launcher-gui--fruits)))))
      (message "Launcher fitted later changes: %S; echo %S" result (cdr echo))
      (pcase-let ((`(,first ,timed ,echoed ,regrown ,inner ,typed ,outer) (cdr result)))
        ;; The timer's rows were fitted before the next key was read.
        (should (= (plist-get timed :fitted) (plist-get timed :height)))
        (should (car echo))
        (should (= (nth 1 echo) (nth 2 echo) (plist-get timed :height)))
        (should (equal (plist-get typed :input) "ok"))
        (portal-launcher-gui--check-fitted
         (cons (car result) (list first timed echoed regrown inner typed outer))
         720 '(5 2 2 5 0 0 5) t))
      ;; Emacs's redisplay may see no change as an inner prompt ends: its
      ;; window last showed a buffer changed more than the outer one.
      (let ((result (portal-launcher-gui--fit
                     (lambda () (read-from-minibuffer "One\nTwo\nThree\nFour: "))
                     (list #'portal-launcher-gui--record
                           (lambda () (interactive) (read-string "Inner: "))
                           (lambda () (interactive) (dotimes (_ 50) (insert "x") (delete-char -1)))
                           #'portal-launcher-gui--record
                           '(36 0 "\r")
                           #'portal-launcher-gui--record))))
        (message "Launcher fitted after an inner prompt: %S" result)
        (portal-launcher-gui--check-fitted result 720 '(3 0 3) t)
        (portal-launcher-gui--check-unwound)))))

(ert-deftest portal-launcher-gui-minibuffer-panel-stays-on-its-display ()
  ;; Moving the pointer to another display while typing moves nothing.
  (skip-unless (fboundp 'portal-test-pointer))
  (portal-launcher-gui--with-panel
    (portal-launcher-mode 1)
    (let* ((screens (plist-get (portal--launcher-inspect) :screens))
           (pointer (portal-test-pointer))
           (portal-launcher-size nil)
           (portal-launcher-font "Menlo 24"))
      (skip-unless (cdr screens))
      (unwind-protect
          (let* ((result
                  (portal-launcher-gui--fit
                   (lambda () (read-from-minibuffer "Fruit: "))
                   (append (list #'portal-launcher-gui--record
                                 (lambda ()
                                   (interactive)
                                   (let* ((here (plist-get (car portal-launcher-gui--layouts) :screen))
                                          (there (plist-get (nth (if (= here 0) 1 0) screens) :visible)))
                                     (portal-test-pointer (+ (nth 0 there) (/ (nth 2 there) 2))
                                                          (+ (nth 1 there) (/ (nth 3 there) 2))))))
                           (cdr portal-launcher-gui--five-two-none-five))
                   (lambda () (portal-launcher-gui--inline-rows portal-launcher-gui--fruits))))
                 (layouts (cdr result)))
            (message "Launcher fitted with the pointer moved: %S" result)
            (should (cl-every (lambda (layout) (eql (plist-get layout :screen) (plist-get (car layouts) :screen)))
                              layouts))
            (portal-launcher-gui--check-fitted result 720 '(5 2 0 5) t))
        (portal-test-pointer (car pointer) (cdr pointer))))))

(ert-deftest portal-launcher-gui-minibuffer-panel-keeps-composition ()
  ;; Input-method marked text survives the panel resizing around it, as
  ;; Emacs's NS input client sees it, then commits. Timers drive this: with
  ;; marked text, every key would go to the input method.
  (skip-unless (fboundp 'portal-test-compose))
  (portal-launcher-gui--with-panel
    ;; At the default limits, then down to the frame's legal height.
    (dolist (limits '((100 nil) (content nil)))
      (let ((portal-launcher-size nil)
            (portal-launcher-height-limits limits)
            (portal-launcher-font "Menlo 24")
            (portal-launcher-gui--layouts nil)
            (portal-launcher-gui--row-limit 5)
            initial marked value)
        (cl-flet ((record ()
                    (with-current-buffer (window-buffer (active-minibuffer-window))
                      (portal-launcher-gui--record)))
                  (input ()
                    (with-current-buffer (window-buffer (active-minibuffer-window))
                      (minibuffer-contents-no-properties)))
                  (then (predicate function) (portal-launcher-gui--once-fitted predicate function)))
          (unwind-protect
              (setq value
                    (with-timeout (10 (error "Composition timed out"))
                      (portal-launcher-present
                       (lambda ()
                         (minibuffer-with-setup-hook
                             (lambda ()
                               (setq initial (plist-get (portal--launcher-inspect) :actual))
                               (portal-launcher-gui--inline-rows
                                '("alpha" "alpine" "alto" "also" "altar" "nihao" "nihaoma"))
                               (portal-view--with-frame-title portal-launcher--frame
                                                              #'portal-test-native-target-frame)
                               (then
                                #'always
                                (lambda ()
                                  (record)
                                  (portal-test-compose "nihao")
                                  ;; While composing, the completion UI updates
                                  ;; without a key: two rows instead of five.
                                  (then
                                   #'portal-test-marked-text
                                   (lambda ()
                                     (push (portal-test-marked-text) marked)
                                     (record)
                                     (setq portal-launcher-gui--row-limit 2)
                                     (funcall portal-launcher-gui--refresh)
                                     (then
                                      (let ((height (portal-launcher-gui--native-height)))
                                        (lambda () (< (portal-launcher-gui--native-height) height)))
                                      (lambda ()
                                        (push (portal-test-marked-text) marked)
                                        (record)
                                        (portal-test-compose "你好" t)
                                        (then
                                         (lambda () (equal (input) "你好"))
                                         (lambda ()
                                           (push (portal-test-marked-text) marked)
                                           (record)
                                           (portal-test-native-post-key 36 0 "\r"))))))))))
                           (read-from-minibuffer "Compose: ")))
                       :kind 'minibuffer)))
            (portal-test-native-target-frame nil)))
        (let ((layouts (reverse portal-launcher-gui--layouts)))
          (message "Launcher fitted composition: %S %S" (reverse marked) layouts)
          (should (equal value "你好"))
          (should (equal (reverse marked) '(t t nil)))
          ;; Emacs shows marked text in an overlay at point, not as input.
          (should (equal (mapcar (lambda (layout) (plist-get layout :input)) (take 3 layouts)) '("" "" "")))
          (portal-launcher-gui--check-fitted (cons initial (take 3 layouts)) 720 '(5 5 2) t limits)
          ;; The committed text's fallback font may set its own line height.
          (portal-launcher-gui--check-fitted (cons initial layouts) 720 '(5 5 2 0) nil limits))))))

(ert-deftest portal-launcher-gui-minibuffer-panel-fits-vertico ()
  ;; Vertico draws its rows in an end-of-buffer before-string, with group
  ;; titles here, whatever its own window policy. Its settings stay.
  (require 'vertico)
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-size nil)
          (portal-launcher-font "Menlo 24")
          (vertico-count 5) (vertico-sort-function nil)
          (completion-styles '(basic)) (completion-category-defaults nil)
          (settings (list (default-value 'vertico-resize) (default-value 'resize-mini-windows)
                          (default-value 'max-mini-window-height) resize-mini-frames))
          (grouped (lambda (string predicate action)
                     (if (eq action 'metadata)
                         `(metadata (group-function . ,(lambda (candidate transform)
                                                         (if transform candidate
                                                           (if (string-prefix-p "alp" candidate) "Peaks" "Others"))))
                                    (annotation-function . ,(lambda (_candidate) " fruit")))
                       (complete-with-action action portal-launcher-gui--fruits string predicate)))))
      (vertico-mode 1)
      (unwind-protect
          (dolist (resize '(grow-only t nil))
            (dolist (table (list portal-launcher-gui--fruits grouped))
              (let* ((vertico-resize resize)
                     (counts nil)
                     (result (portal-launcher-gui--fit
                              (lambda () (completing-read "Fruit: " table))
                              ;; Vertico draws after a command with no input
                              ;; waiting, so a no-op command comes first.
                              (cons
                               (lambda () (interactive))
                               (mapcar (lambda (step)
                                         (if (functionp step)
                                             (lambda ()
                                               (interactive)
                                               ;; A newline starts the rows, and ends each.
                                               (push (max 0 (1- (cl-count ?\n (overlay-get vertico--candidates-ov
                                                                                           'before-string))))
                                                     counts)
                                               (portal-launcher-gui--record)
                                               (when (and (eq resize 'grow-only) (functionp table))
                                                 (portal-launcher-gui--capture
                                                  (format "minibuffer-fitted-%s" (minibuffer-contents-no-properties)))))
                                           step))
                                       portal-launcher-gui--five-two-none-five)))))
                (message "Launcher fitted Vertico %S %S: %S %S" resize (functionp table) (reverse counts) result)
                (unless (functionp table) (should (equal (reverse counts) '(5 2 0 5))))
                (portal-launcher-gui--check-fitted result 720 (reverse counts) t)))
            ;; Cancelling leaves the same settings.
            (should-not (portal-launcher-gui--present
                         (lambda () (completing-read "Fruit: " portal-launcher-gui--fruits))
                         '((53 0 "\e")) nil '(:kind minibuffer))))
        (vertico-mode -1))
      (should (equal settings (list (default-value 'vertico-resize) (default-value 'resize-mini-windows)
                                    (default-value 'max-mini-window-height) resize-mini-frames))))))

(ert-deftest portal-launcher-gui-minibuffer-panel-stock-completion ()
  (portal-launcher-gui--with-panel
    ;; At a fixed size, then fitting its content.
    (dolist (portal-launcher-size '((720 420) nil))
      (let ((windows (window-list (window-frame ordinary) t))
            shown)
        ;; Tab completes and Return accepts, but *Completions* shows nowhere.
        (should
         (equal "alpha"
                (portal-launcher-gui--present
                 (lambda ()
                   (minibuffer-with-setup-hook
                       (lambda ()
                         (add-hook 'post-command-hook
                                   (lambda ()
                                     (push (list (minibuffer-contents)
                                                 (get-buffer-window "*Completions*" t))
                                           shown))
                                   90 t))
                     (completing-read "Pick: " '("alpha" "alps" "beta") nil t)))
                 (append (portal-launcher-gui--text "a") '((48 0 "\t") (48 0 "\t"))
                         (portal-launcher-gui--text "ha") '((36 0 "\r")))
                 nil '(:kind minibuffer))))
        (should (member '("alp" nil) shown))
        (should-not (cl-some #'cadr shown))
        (should (equal windows (window-list (window-frame ordinary) t)))))))

(ert-deftest portal-launcher-gui-buffer-panel-mode-lines ()
  (portal-launcher-gui--with-panel
    (let ((format (buffer-local-value 'mode-line-format ordinary-buffer))
          (ordinary-height (window-mode-line-height ordinary)))
      (should (> ordinary-height 0))
      (dolist (mode-line '(t nil))
        (let ((heights
               (portal-launcher-present
                (lambda ()
                  (cl-flet ((height (window) (redisplay t) (window-mode-line-height window)))
                    (let* ((first (selected-window))
                           (initial (height first))
                           (second (split-window first))
                           (split (height second)))
                      ;; Both launcher windows switch buffers; one shows the
                      ;; ordinary window's buffer.
                      (switch-to-buffer ordinary-buffer)
                      (set-window-buffer second content)
                      (with-current-buffer content (insert (format "Mode lines: %s\n" mode-line)))
                      (prog1 (list initial split (height first) (height second)
                                   (window-mode-line-height ordinary))
                        (portal-launcher-gui--capture (format "buffer-mode-line-%s" mode-line))))))
                :mode-line mode-line)))
          (message "Launcher mode lines %S: %S" mode-line heights)
          (should (equal (car (last heights)) ordinary-height))
          (should (cl-every (if mode-line (lambda (height) (> height 0)) #'zerop) (butlast heights)))
          ;; The call's split is gone, and the parameter and hook with it.
          (should (equal (window-list portal-launcher--frame 'never)
                         (list (frame-first-window portal-launcher--frame))))
          (should-not (window-parameter (frame-first-window portal-launcher--frame) 'mode-line-format))
          (should-not (memq #'portal-launcher--hide-mode-lines window-buffer-change-functions))
          (should (eq format (buffer-local-value 'mode-line-format ordinary-buffer)))
          (should (= ordinary-height (window-mode-line-height ordinary)))))
      ;; A window's own mode-line parameter outlasts both settings, and an
      ;; explicit show leaves it alone.
      (let ((window (frame-first-window portal-launcher--frame))
            (custom '("Custom mode line")))
        (set-window-parameter window 'mode-line-format custom)
        (dolist (mode-line '(nil t))
          (should (equal (if mode-line custom 'none)
                         (portal-launcher-present
                          (lambda () (window-parameter (selected-window) 'mode-line-format))
                          :mode-line mode-line)))
          (should (equal custom (window-parameter window 'mode-line-format))))
        (portal-launcher-show content)
        (should (equal custom (window-parameter window 'mode-line-format)))
        (portal-launcher-hide)))))

(ert-deftest portal-launcher-gui-alternating-kinds ()
  (require 'vertico)
  (portal-launcher-gui--with-panel
    (let ((settings (list display-buffer-alist display-buffer-overriding-action resize-mini-frames
                          window-buffer-change-functions emulation-mode-map-alists
                          enable-recursive-minibuffers default-minibuffer-frame pop-up-frames
                          completing-read-function))
          (frames (length (frame-list)))
          timings)
      ;; Presenting while an explicitly shown launcher is selected returns to
      ;; the window it was shown from, even when the frame is replaced.
      (dolist (kind '(buffer minibuffer))
        (portal-launcher-show content)
        (should (eq (selected-frame) portal-launcher--frame))
        (should (eq kind (portal-launcher-present (lambda () kind) :kind kind)))
        (should (eq (selected-window) ordinary)))
      ;; At fixed sizes, then with minibuffer panels fitting their content.
      (dolist (portal-launcher-size '((720 420) nil))
        (dolist (options '((:kind minibuffer) (:kind buffer :mode-line nil) (:kind minibuffer)
                           (:mode-line t) (:kind buffer :mode-line nil) (:kind minibuffer :mode-line nil)
                           (:kind minibuffer) ()))
          (let* ((kind (or (plist-get options :kind) 'buffer))
                 (start (float-time))
                 (state (portal-launcher-gui--present
                         (lambda ()
                           (push (list options (- (float-time) start)) timings)
                           (list (portal-launcher--kind portal-launcher--frame) (length (frame-list))
                                 (read-string "Name: ")))
                         (append (portal-launcher-gui--text "ok") '((36 0 "\r"))) nil options)))
            (should (equal state (list kind (1+ frames) "ok")))
            (should (= (length (frame-list)) (1+ frames)))
            (should (plist-get (portal--launcher-inspect) :attached))
            (should (portal-launcher--live-p kind))
            (when (eq kind 'buffer)
              (should (= 1 (length (window-list portal-launcher--frame 'never))))
              (should-not (window-parameter (frame-first-window portal-launcher--frame) 'mode-line-format)))
            (should (equal settings
                           (list display-buffer-alist display-buffer-overriding-action resize-mini-frames
                                 window-buffer-change-functions emulation-mode-map-alists
                                 enable-recursive-minibuffers default-minibuffer-frame pop-up-frames
                                 completing-read-function))))))
      (message "Launcher show times (s): %S" (nreverse timings))
      ;; A split made in an explicitly shown panel outlives a presentation;
      ;; the window the call creates does not.
      (portal-launcher-show content)
      (let ((kept (split-window (frame-first-window portal-launcher--frame))))
        (portal-launcher-hide)
        (portal-launcher-present (lambda () (split-window)) :mode-line nil)
        (should (window-live-p kept))
        (should (= 2 (length (window-list portal-launcher--frame 'never))))
        (should (eq (selected-window) ordinary)))
      ;; Ordinary prompts behave as before, in the ordinary frame, with stock
      ;; completion's list there and with Vertico.
      (dolist (enhanced '(nil t))
        (vertico-mode (if enhanced 1 -1))
        (unwind-protect
            (let (minibuffer-frame completions-frame)
              (should
               (equal "alpha"
                      (minibuffer-with-setup-hook
                          (lambda ()
                            (setq minibuffer-frame (window-frame (active-minibuffer-window)))
                            (add-hook 'post-command-hook
                                      (lambda ()
                                        (when-let* ((window (get-buffer-window "*Completions*" t)))
                                          (setq completions-frame (window-frame window))))
                                      nil t))
                        (let ((unread-command-events
                               (listify-key-sequence (kbd (if enhanced "a l p h a RET"
                                                            "a l TAB TAB h a RET")))))
                          (completing-read "Pick: " '("alpha" "alps") nil t)))))
              (should (eq minibuffer-frame (window-frame ordinary)))
              (unless enhanced (should (eq completions-frame (window-frame ordinary)))))
          (vertico-mode -1))))))

(ert-deftest portal-launcher-gui-session-nested-dismissal-and-reentry ()
  ;; The batch suite dismisses every kind of panel every way, on the fake
  ;; native module. These are the ways only the platform can prove: native
  ;; Escape, and the global shortcut's hot key.
  (portal-launcher-gui--with-panel
    (portal-launcher-gui--dismiss-shortcut)
    (pcase-dolist (`(,kind ,portal-launcher-size ,reason)
                   '((minibuffer nil escape) (buffer (720 420) shortcut)))
      (message "Launcher nested dismissal: %S %S %S" kind portal-launcher-size reason)
      (let (frames continued)
        (portal-launcher-gui--present
         (lambda ()
           (interactive)
           (minibuffer-with-setup-hook
               (lambda ()
                 (push (window-frame (active-minibuffer-window)) frames)
                 (minibuffer-with-setup-hook
                     (lambda () (push (window-frame (active-minibuffer-window)) frames))
                   (completing-read "Inner: " '("alpha") nil t)))
             (completing-read "Outer: " '("alpha") nil t))
           (setq continued t))
         (list (pcase reason ('escape '(53 0 "\e")) (_ '(30 262144 "\C-]"))))
         (lambda () (portal-launcher-gui--press 'portal-launcher-gui))
         (list :kind kind))
        (should-not continued)
        (should (= (length frames) 2))
        (should (eq (car frames) (cadr frames)))
        (should (eq kind (portal-launcher--kind (car frames))))
        (should (eq ordinary (selected-window)))
        (should (eq 'again (portal-launcher-present (lambda () (interactive) 'again))))))))

(ert-deftest portal-launcher-gui-session-command-error ()
  (portal-launcher-gui--with-panel
    (pcase-dolist (`(,kind ,portal-launcher-size) '((buffer (720 420)) (minibuffer (720 420)) (minibuffer nil)))
      (let (read-finished)
        (should (equal '(error "Command failed")
                       (should-error
                        (portal-launcher-gui--present
                         (lambda () (read-string "Before error: ")
                           (setq read-finished t) (error "Command failed"))
                         '((36 0 "\r")) nil (list :kind kind :mode-line nil)))))
        (should read-finished))
      (should-not (active-minibuffer-window))
      (should-not portal-launcher--session)
      (should-not (plist-get (portal--launcher-inspect) :visible))
      (should (eq ordinary (selected-window)))
      (should-not (memq #'portal-launcher--hide-mode-lines window-buffer-change-functions))
      (should (eq 'again (portal-launcher-present (lambda () (interactive) 'again) :kind kind))))))

(ert-deftest portal-launcher-gui-session-focus-loss ()
  (portal-launcher-gui--with-panel
    (pcase-dolist (`(,kind ,portal-launcher-size) '((buffer (720 420)) (minibuffer (720 420)) (minibuffer nil)))
      (let (continued)
        (portal-launcher-gui--present
         (lambda () (interactive) (read-string "Focus away: ") (setq continued t))
         '((30 262144 "\C-]"))
         (lambda ()
           (portal-view--with-frame-title (window-frame ordinary) #'portal-test-native-target-frame)
           (portal-test-native-focus-target))
         (list :kind kind))
        (should-not continued)
        (should (eq ordinary (selected-window)))))))

(defvar portal-launcher-gui--prompts nil
  "For each prompt a hello command opened, whether it was in the panel.")

(defun portal-launcher-gui--hello (&rest bindings)
  "Set up the hello-world UI, with local BINDINGS of (KEY . COMMAND).
The local command n reads a name in the minibuffer and greets it."
  (switch-to-buffer (get-buffer-create "*Hello*"))
  (let ((inhibit-read-only t)) (erase-buffer) (insert "Hello world!"))
  (special-mode)
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (current-local-map))
    (keymap-set map "n" #'portal-launcher-gui--greet)
    (pcase-dolist (`(,key . ,command) bindings) (keymap-set map key command))
    (use-local-map map)))

(defun portal-launcher-gui--greet ()
  "Greet a name read from the minibuffer."
  (interactive)
  (let ((name (minibuffer-with-setup-hook
                  (lambda ()
                    (push (eq (window-frame (active-minibuffer-window)) portal-launcher--frame)
                          portal-launcher-gui--prompts))
                (read-string "Name: ")))
        (inhibit-read-only t))
    (goto-char (point-max))
    (insert "\nHello " name "!")))

(defun portal-launcher-gui--check-unwound ()
  "Check that a persistent presentation left no hooks or session."
  (should-not portal-launcher--session)
  (should-not (memq #'portal-launcher--dismiss-if-blurred (default-value 'post-command-hook)))
  (should-not (memq #'portal-launcher--refit (default-value 'post-command-hook)))
  (should-not (memq #'portal-launcher--hide-mode-lines window-buffer-change-functions))
  (should-not (cl-find 'portal-launcher-blur unread-command-events :key #'car-safe)))

(ert-deftest portal-launcher-gui-persistent-buffer ()
  (portal-launcher-gui--with-panel
    (unwind-protect
        (let ((depth (recursion-depth)) (portal-launcher-gui--prompts nil) state)
          ;; The setup function returns at once; a local command, then its
          ;; prompt, read native keys in the panel.
          (should-not
           (portal-launcher-gui--present
            #'portal-launcher-gui--hello
            (append (portal-launcher-gui--text "nok") '((36 0 "\r") (30 262144 "\C-]") (53 0 "\e")))
            (lambda ()
              (redisplay t)
              (setq state (list :session (and portal-launcher--session t)
                                :depth (- (recursion-depth) depth)
                                :visible (and (frame-visible-p portal-launcher--frame)
                                              (plist-get (portal--launcher-inspect) :visible))
                                :key (plist-get (portal--launcher-inspect) :key)
                                :window (eq (window-frame) portal-launcher--frame)
                                :buffer (buffer-name) :text (buffer-string)
                                :mode-line (window-mode-line-height)))
              (portal-launcher-gui--capture "persistent-hello"))
            '(:kind buffer :mode-line nil :keep-open t)))
          (message "Launcher persistent buffer: %S" state)
          (should (equal state '(:session t :depth 1 :visible t :key t :window t :buffer "*Hello*"
                                 :text "Hello world!\nHello ok!" :mode-line 0)))
          (should (equal portal-launcher-gui--prompts '(t)))
          (portal-launcher-gui--check-unwound)
          (should (eq ordinary (selected-window)))
          ;; Hiding kept the buffer and its contents.
          (should (equal "Hello world!\nHello ok!" (with-current-buffer "*Hello*" (buffer-string))))
          ;; Without :keep-open the panel hides as the function returns.
          (should (eq 'closed (portal-launcher-present (lambda () (portal-launcher-gui--hello) 'closed)
                                                       :mode-line nil)))
          (should-not (plist-get (portal--launcher-inspect) :visible)))
      (kill-buffer "*Hello*"))))

(ert-deftest portal-launcher-gui-persistent-dismissal-and-reentry ()
  ;; The batch suite dismisses a persistent panel every way, from its
  ;; buffer and from a prompt. These are the ways only the platform can
  ;; prove: native Escape, the global shortcut's hot key and focus loss.
  (portal-launcher-gui--with-panel
    (portal-launcher-gui--dismiss-shortcut)
    (unwind-protect
        (pcase-dolist (`(,prompt ,reason) '((t escape) (nil shortcut) (t focus)))
          (message "Launcher persistent dismissal: %S %S" (if prompt 'prompt 'buffer) reason)
          (let ((portal-launcher-gui--prompts nil))
            (should-not
             (portal-launcher-gui--present
              #'portal-launcher-gui--hello
              (append (when prompt (portal-launcher-gui--text "na"))
                      (list (pcase reason ('escape '(53 0 "\e")) (_ '(30 262144 "\C-]")))))
              (lambda ()
                (pcase reason
                  ('shortcut (portal-launcher-gui--press 'portal-launcher-gui))
                  ('focus
                   (portal-view--with-frame-title (window-frame ordinary)
                                                  #'portal-test-native-target-frame)
                   (portal-test-native-focus-target))))
              '(:mode-line nil :keep-open t)))
            (should (equal portal-launcher-gui--prompts (and prompt '(t))))
            (portal-launcher-gui--check-unwound)
            (should (eq ordinary (selected-window)))
            (should (equal "Hello world!" (with-current-buffer "*Hello*" (buffer-string))))
            (should (eq 'again (portal-launcher-present (lambda () (interactive) 'again))))))
      (kill-buffer "*Hello*"))))

(ert-deftest portal-launcher-gui-persistent-command-errors ()
  (portal-launcher-gui--with-panel
    (unwind-protect
        (let ((messages (with-current-buffer "*Messages*" (point-max-marker))) state)
          ;; A later command's error is reported; then a command and its
          ;; prompt still work, until Escape.
          (should-not
           (portal-launcher-gui--present
            (lambda ()
              (portal-launcher-gui--hello
               (cons "e" (lambda () (interactive) (error "Later command failed")))))
            (append (portal-launcher-gui--text "enok") '((36 0 "\r") (30 262144 "\C-]") (53 0 "\e")))
            (lambda ()
              (setq state (list (and portal-launcher--session t)
                                (plist-get (portal--launcher-inspect) :visible)
                                (buffer-string))))
            '(:keep-open t)))
          (should (equal state '(t t "Hello world!\nHello ok!")))
          (should (with-current-buffer "*Messages*"
                    (save-excursion
                      (goto-char messages)
                      (search-forward "Later command failed" nil t))))
          (portal-launcher-gui--check-unwound)
          ;; Focus lost while a command runs, then discarded with the queued
          ;; input by Emacs's error report, still hides the panel, from the
          ;; buffer and from a prompt.
          (dolist (prompt '(nil t))
            (let (queued)
              (should-not
               (portal-launcher-gui--present
                #'portal-launcher-gui--hello
                (append (when prompt (portal-launcher-gui--text "n")) '((30 262144 "\C-]")))
                (lambda ()
                  (portal-view--with-frame-title (window-frame ordinary)
                                                 #'portal-test-native-target-frame)
                  (portal-test-native-focus-target)
                  (with-timeout (3 (error "The panel did not lose focus"))
                    (while (not (portal-launcher--session-blurred portal-launcher--session))
                      (accept-process-output nil 0.05)))
                  (setq queued (and (cl-find 'portal-launcher-blur unread-command-events :key #'car-safe) t))
                  (error "Failed after focus loss"))
                '(:keep-open t)))
              (should queued)
              (portal-launcher-gui--check-unwound)
              (should (eq ordinary (selected-window)))))
          (should (eq 'again (portal-launcher-present (lambda () (interactive) 'again)))))
      (kill-buffer "*Hello*"))))

(ert-deftest portal-launcher-gui-z-session-external-focus ()
  ;; Two other apps besides Emacs, whatever else runs: a fresh desktop may
  ;; have only Finder, and asking the already active app to activate changes
  ;; nothing. Calculator starts in the background, and quits if it started.
  (let ((started (not (eql 0 (call-process "pgrep" nil nil nil "-x" "Calculator")))))
    (when started (call-process "open" nil nil nil "-g" "-j" "-a" "Calculator"))
    (unwind-protect
        (progn
          (with-timeout (10 (error "Calculator did not start"))
            (while (not (eql 0 (call-process "pgrep" nil nil nil "-x" "Calculator")))
              (sit-for 0.1)))
          ;; A finishing launch can still take the focus: wait until the
          ;; frontmost app has held for a second.
          (with-timeout (10 (error "The frontmost app did not settle"))
            (let ((front (portal-test-frontmost)) (held 0))
              (while (< held 10)
                (sit-for 0.1)
                (if (eql front (portal-test-frontmost)) (setq held (1+ held))
                  (setq front (portal-test-frontmost) held 0)))))
          (portal-launcher-gui--with-panel
            ;; These are already-running, independent applications. Test both external
            ;; activation during a prompt and a command that opens an app and returns.
            (let ((previous (portal-test-frontmost)))
              (dolist (options '((:kind buffer) (:kind minibuffer) (:kind buffer) (:keep-open t)))
                (portal-launcher-gui--present
                 (if (plist-get options :keep-open) #'portal-launcher-gui--hello
                   (lambda () (interactive) (read-string "Cancel: ")))
                 '((53 0 "\e")) nil options)
                ;; Nothing reports that focus stayed: give a wrong
                ;; activation a moment to show.
                (sit-for 0.1)
                (message "Launcher %S cancellation frontmost: %S (previous %S)"
                         options (portal-test-frontmost) previous)
                (should (eql previous (portal-test-frontmost)))
                (portal-launcher-gui--check-focus-left ordinary)))
            ;; A persistent panel's command that activates another app leaves that
            ;; app in front, as the panel hides on losing focus.
            (dolist (app '("com.apple.calculator" "com.apple.finder"))
              (let (activated)
                (should app)
                (portal-launcher-gui--present
                 (lambda ()
                   (portal-launcher-gui--hello
                    (cons "o" (lambda () (interactive) (setq activated (portal-test-frontmost app))))))
                 (portal-launcher-gui--text "o") nil '(:keep-open t))
                (with-timeout (3 (error "The panel's command did not activate %S" app))
                  (while (not (eql activated (portal-test-frontmost))) (sit-for 0.05)))
                (message "Launcher persistent activation frontmost: %S (expected %S)"
                         (portal-test-frontmost) activated)
                (should (eql activated (portal-test-frontmost)))
                (portal-launcher-gui--check-focus-left ordinary)
                ;; AppKit can report the activation once the next session watches.
                (portal-launcher-gui--settle-focus)))
            (kill-buffer "*Hello*")
            (let ((destination (portal-test-frontmost -1)) continued)
              (should destination)
              (portal-launcher-gui--present
               (lambda () (interactive) (read-string "Activate another app: ") (setq continued t))
               '((30 262144 "\C-]")) (lambda () (portal-test-frontmost destination)))
              (should-not continued)
              (should (eql destination (portal-test-frontmost)))
              (portal-launcher-gui--check-focus-left ordinary))
            (let (finder)
              (portal-launcher-present
               (lambda () (interactive) (setq finder (portal-test-frontmost "com.apple.finder"))))
              (with-timeout (3 (error "Successful app launch did not activate Finder"))
                (while (not (eql finder (portal-test-frontmost))) (sit-for 0.05)))
              (message "Launcher success frontmost: %S (expected Finder %S)" (portal-test-frontmost) finder)
              (should (eql finder (portal-test-frontmost)))
              (portal-launcher-gui--check-focus-left ordinary))))
      (when started (call-process "pkill" nil nil nil "-x" "Calculator")))))

(defun portal-launcher-gui--check-focus-left (ordinary)
  "Check that a dismissed panel left ORDINARY selected and its frame unfocused.
The real command loop first reads the events the presentation queued,
such as the focus-in that AppKit gave the panel: a recursive edit that
ends once Emacs waits for input. A presentation that read no input left
that event queued, and Emacs's `handle-focus-in' then switched to the
hidden frame."
  (let* ((depth (1+ (recursion-depth)))
         (timer (run-with-timer 0.05 0.05
                                (lambda ()
                                  (when (and (= (recursion-depth) depth) (current-idle-time)
                                             (not (input-pending-p)))
                                    (exit-recursive-edit))))))
    (unwind-protect (recursive-edit) (cancel-timer timer)))
  (should (eq ordinary (selected-window)))
  (should-not (frame-focus-state portal-launcher--frame)))

(ert-deftest portal-launcher-gui-dismissal-leaves-focus ()
  ;; The batch suite checks which dismissals give the previous app its
  ;; focus back. These rows leave Emacs's own focus events to AppKit: a
  ;; panel that read no input, which leaves the panel's focus-in queued,
  ;; native Escape, the global shortcut's hot key and focus loss to
  ;; another Emacs frame.
  (portal-launcher-gui--with-panel
    (portal-launcher-gui--dismiss-shortcut)
    (pcase-dolist (`(,kind ,reason) '((buffer no-input) (minibuffer escape)
                                      (buffer shortcut) (minibuffer blur-emacs)))
      (message "Launcher dismissal focus: %S %S" kind reason)
      (portal-launcher-gui--present
       (if (eq reason 'no-input) (lambda () 'done)
         (lambda () (interactive) (read-string "Focus: ")))
       (pcase reason
         ('no-input nil)
         ('escape '((53 0 "\e")))
         (_ '((30 262144 "\C-]"))))
       (lambda ()
         (pcase reason
           ('shortcut (portal-launcher-gui--press 'portal-launcher-gui))
           ('blur-emacs
            (portal-view--with-frame-title (window-frame ordinary) #'portal-test-native-target-frame)
            (portal-test-native-focus-target))))
       (list :kind kind))
      (portal-launcher-gui--check-focus-left ordinary))
    ;; An explicitly shown panel, hidden again.
    (portal-launcher-show content)
    (portal-launcher-hide)
    (portal-launcher-gui--check-focus-left ordinary)))

(ert-deftest portal-launcher-gui-dismissal-survives-focus-hook-errors ()
  ;; Handling the frame's focus events runs the user's function; its errors
  ;; are reported, the panel still hides, and input read before the focus
  ;; event is queued again.
  (portal-launcher-gui--with-panel
    (let ((messages (with-current-buffer "*Messages*" (point-max-marker))))
      (let ((after-focus-change-function (lambda () (error "Focus hook failed")))
            (unread-command-events (list 'portal-launcher-gui-queued)))
        (should (eq 'done (portal-launcher-present (lambda () 'done))))
        (should-not (plist-get (portal--launcher-inspect) :visible))
        (should-not (frame-visible-p portal-launcher--frame))
        (should (equal unread-command-events '(portal-launcher-gui-queued))))
      (should (with-current-buffer "*Messages*"
                (save-excursion (goto-char messages)
                                (search-forward "Launcher focus event: (error \"Focus hook failed\")" nil t))))
      (portal-launcher-gui--check-focus-left ordinary)
      ;; A quit from the function is not reported but passes through, after
      ;; the panel hid and the frame's focus is gone: from a presentation,
      ;; and from an explicit hide, which still restores the selection.
      (let ((after-focus-change-function (lambda () (signal 'quit nil))))
        ;; `should-error' catches only errors.
        (should (eq 'quit (condition-case nil (portal-launcher-present (lambda () 'done)) (quit 'quit))))
        (should-not (plist-get (portal--launcher-inspect) :visible))
        (should-not (frame-visible-p portal-launcher--frame))
        (portal-launcher-gui--check-focus-left ordinary)
        (portal-launcher-show content)
        (should (eq 'quit (condition-case nil (portal-launcher-hide) (quit 'quit))))
        (should-not (plist-get (portal--launcher-inspect) :visible))
        (should-not (frame-visible-p portal-launcher--frame)))
      (portal-launcher-gui--check-focus-left ordinary)
      ;; A function that deletes the launcher frame leaves the other frames
      ;; alone, and the next presentation makes a new one.
      (let ((after-focus-change-function
             (lambda () (when (frame-live-p portal-launcher--frame)
                          (delete-frame portal-launcher--frame t)))))
        (should (eq 'done (portal-launcher-present (lambda () 'done))))
        (should-not portal-launcher--frame)
        (should-not (plist-get (portal--launcher-inspect) :attached))
        (should (frame-visible-p (window-frame ordinary)))
        (should (eq ordinary (selected-window))))
      (should (eq 'again (portal-launcher-present (lambda () 'again))))
      (portal-launcher-gui--check-focus-left ordinary))))

(provide 'portal-launcher-gui-tests)
