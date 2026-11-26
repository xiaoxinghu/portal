;;; portal-view-tests.el --- Portal view lifecycle against the fake module -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Real buffers and windows drive `portal-view.el'; only the native module is
;; replaced.  Batch Emacs never runs window change hooks, so tests sync.
(require 'ert)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-terminal)
(require 'portal-web)

;; Tests kill live shells without asking; the prompt has its own tests.
(setq portal-terminal-confirm-kill nil)

(defmacro portal-view-test--environment (&rest body)
  "Run BODY in one fresh window, then kill its buffers and check cleanup."
  (declare (indent 0))
  `(let ((initial-buffers (buffer-list))
         (title (frame-parameter nil 'title)))
     (portal-fake-native-reset)
     (save-window-excursion
       (unwind-protect
           (progn
             (delete-other-windows)
             (switch-to-buffer (get-buffer-create "*scratch*"))
             ,@body)
         (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
           (kill-buffer buffer))))
     (should-not (portal-view-buffers))
     (should-not (portal-fake-native-targets))
     (should-not (memq #'portal-view-sync window-state-change-functions))
     (should (equal (frame-parameter nil 'title) title))))

(defun portal-view-test--open (name)
  "Show a new buffer called NAME in the selected window, give it a view.
Return the view's target."
  (switch-to-buffer (generate-new-buffer name))
  (portal-view-open 'terminal (list :directory temporary-file-directory)))

(defun portal-view-test--shown (target &optional window)
  "Whether TARGET is visible at WINDOW's edges, with no other window's target."
  (let ((window (or window (selected-window)))
        (state (portal--inspect target)))
    (and (plist-get state :visible)
         (equal (plist-get state :edges) (window-inside-pixel-edges window))
         (eq (plist-get state :frame) (window-frame window))
         (equal (portal-view-target window) target)
         (cl-every (lambda (other) (or (eq other window) (null (portal-view-target other))))
                   (window-list)))))

(ert-deftest portal-view-open-places-the-view-in-the-selected-window ()
  (portal-view-test--environment
    (let ((target (portal-view-test--open "view")))
      (should (string-prefix-p "terminal:" target))
      (should (portal-view-test--shown target))
      (should (equal (plist-get (plist-get (portal--inspect target) :options) :directory)
                     temporary-file-directory))
      (should (equal (portal-view-buffers) (list (current-buffer))))
      (should (equal (portal-view-buffers 'terminal) (list (current-buffer))))
      (should-not (portal-view-buffers 'web))
      (should (memq #'portal-view-sync window-state-change-functions))
      (should (memq #'portal-view-sync window-selection-change-functions))
      (should-error (portal-view-open 'terminal nil))
      (let ((second (portal-view-test--open "second")))
        (should-not (equal second target))
        (should (equal (portal-view-buffers) (list (get-buffer "view") (current-buffer))))))))

(ert-deftest portal-view-close-returns-the-mode-line-to-emacs ()
  ;; The view's last focus record cannot reach a buffer without a target,
  ;; so closing tells the input module itself.
  (portal-view-test--environment
    (switch-to-buffer (generate-new-buffer "view"))
    (portal-terminal-mode)
    (let ((target (portal-view-open 'terminal (list :directory temporary-file-directory))))
      (portal-fake-native-send (format "focus %s 1\n" target))
      (should (portal-input--focused-p))
      (should (and portal-input--tint (assq 'mode-line-active face-remapping-alist)))
      (portal-view-close)
      (should-not (portal-input--focused-p))
      (should-not (or portal-input--tint (assq 'mode-line-active face-remapping-alist))))))

(ert-deftest portal-view-split-keeps-one-view-in-its-pane ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (origin (selected-window))
           (other (split-window-right)))
      (should (eq (window-buffer other) (current-buffer)))
      (portal-view-sync)
      (should (portal-view-test--shown target origin))
      ;; The new pane came from the split: selecting it leaves the view.
      (select-window other)
      (portal-view-sync)
      (should (portal-view-test--shown target origin))
      (should-not (portal-view-target other))
      (should (= (length (portal-fake-native-calls 'portal--open)) 1)))))

(ert-deftest portal-view-stays-in-its-pane-whichever-pane-is-selected ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (origin (selected-window))
           (other (split-window-right))
           (unrelated (split-window-below)))
      (set-window-buffer unrelated (get-buffer "*scratch*"))
      (portal-view-sync)
      (dolist (window (list other unrelated origin other))
        (select-window window)
        (portal-view-sync)
        (should (portal-view-test--shown target origin)))
      ;; ORIGIN comes after OTHER in window order from UNRELATED; it still stays.
      (select-window unrelated)
      (should (equal (get-buffer-window-list (window-buffer origin)) (list other origin)))
      (portal-view-sync)
      (should (portal-view-test--shown target origin)))))

(ert-deftest portal-view-comes-to-a-pane-its-buffer-is-switched-into ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (buffer (current-buffer))
           (origin (selected-window))
           (other (split-window-right)))
      (select-window other)
      (switch-to-buffer "*scratch*")
      (portal-view-sync)
      (should (portal-view-test--shown target origin))
      ;; The pane showed another buffer at the last sync: the view comes.
      (switch-to-buffer buffer)
      (portal-view-sync)
      (should (portal-view-test--shown target other))
      ;; Selecting the pane it left, which still shows the buffer, does not
      ;; bring it back.
      (select-window origin)
      (portal-view-sync)
      (should (portal-view-test--shown target other))
      (should (= (length (portal-fake-native-calls 'portal--open)) 1)))))

(ert-deftest portal-view-goes-to-the-pane-left-when-its-pane-is-deleted ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (origin (selected-window))
           (other (split-window-right))
           (unrelated (split-window-below)))
      (set-window-buffer unrelated (get-buffer "*scratch*"))
      (select-window unrelated)
      (portal-view-sync)
      (should (portal-view-test--shown target origin))
      ;; The selected pane shows another buffer, so the view goes to the one
      ;; pane left that shows its own.
      (delete-window origin)
      (portal-view-sync)
      (should (portal-view-test--shown target other))
      (should (eq (selected-window) unrelated)))))

(ert-deftest portal-view-focus-takes-the-view-into-the-selected-pane ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (origin (selected-window))
           (other (split-window-right)))
      (select-window other)
      (portal-view-sync)
      (should (portal-view-test--shown target origin))
      (portal-view-focus)
      (should (portal-view-test--shown target other))
      (should (plist-get (portal--inspect target) :focused))
      ;; It stays there, and the pane it left can take it back.
      (select-window origin)
      (portal-view-sync)
      (should (portal-view-test--shown target other))
      (portal-view-focus)
      (should (portal-view-test--shown target origin)))))

(ert-deftest portal-view-quit-window-hides-without-ending ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (buffer (current-buffer)))
      (quit-window)
      (should-not (eq (window-buffer) buffer))
      (portal-view-sync)
      (should-not (plist-get (portal--inspect target) :visible))
      (should-not (portal-view-target))
      (should (equal (portal-view-buffers) (list buffer)))
      (should-not (portal-fake-native-calls 'portal--close))
      (switch-to-buffer buffer)
      (portal-view-sync)
      (should (portal-view-test--shown target)))))

(ert-deftest portal-view-appears-in-another-pane-showing-its-buffer ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (buffer (current-buffer))
           (other (split-window-right)))
      (switch-to-buffer "*scratch*")
      (set-window-buffer other (get-buffer "*scratch*"))
      (portal-view-sync)
      (should-not (plist-get (portal--inspect target) :visible))
      ;; Shown only in a pane that is not selected: the view goes there.
      (set-window-buffer other buffer)
      (portal-view-sync)
      (should (portal-view-test--shown target other))
      ;; Then switched into the selected pane as well: the view comes there.
      (switch-to-buffer buffer)
      (portal-view-sync)
      (should (portal-view-test--shown target (selected-window))))))

(ert-deftest portal-view-kill-buffer-ends-the-view ()
  (portal-view-test--environment
    (let ((target (portal-view-test--open "view"))
          (kept (portal-view-test--open "kept")))
      (kill-buffer "view")
      (should (equal (portal-fake-native-calls 'portal--close) (list (list target))))
      (should-not (portal--inspect target))
      (should (equal (portal-fake-native-targets) (list kept)))
      (should (equal (portal-view-buffers) (list (current-buffer))))
      (should (memq #'portal-view-sync window-state-change-functions))
      ;; Changing major mode ends the view too, and the last one removes the hooks.
      (fundamental-mode)
      (should-not (portal-view-buffers))
      (should-not (portal-fake-native-targets))
      (should-not (memq #'portal-view-sync window-state-change-functions))
      (should-not (memq #'portal-view-close kill-buffer-hook)))))

(ert-deftest portal-view-sync-makes-no-native-call-when-nothing-moved ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (other (split-window-below)))
      (set-window-buffer other (get-buffer "*scratch*"))
      (portal-view-sync)
      (setq portal-fake-native-log nil)
      (portal-view-sync)
      (select-window other)
      (portal-view-sync)
      (portal-view-sync (selected-frame))
      (should-not portal-fake-native-log)
      ;; Resizing moves the view: one placement, then nothing again.
      (window-resize other 2)
      (portal-view-sync)
      (portal-view-sync)
      (should (equal (mapcar #'car (portal-fake-native-calls 'portal--place)) (list target)))
      (should (= (length portal-fake-native-log) 1)))))

(ert-deftest portal-view-failed-open-leaves-nothing-registered ()
  (portal-view-test--environment
    (dolist (failure '(portal--open portal--place))
      (switch-to-buffer (generate-new-buffer (symbol-name failure)))
      (let ((portal-fake-native-failures (list failure)))
        (should-error (portal-view-open 'terminal (list :directory temporary-file-directory))))
      (should-not (portal-view-buffers))
      (should-not (portal-view-target))
      (should-not (portal-fake-native-targets))
      (should-not (memq #'portal-view-close kill-buffer-hook))
      (should-not (memq #'portal-view-sync window-state-change-functions)))
    ;; A failed placement released the view that the native module opened.
    (should (equal (portal-fake-native-calls 'portal--close)
                   (list (list (caar (portal-fake-native-calls 'portal--place))))))
    ;; The buffer can still open a view afterwards.
    (should (portal-view-test--shown (portal-view-open 'terminal nil)))))

(ert-deftest portal-view-follows-its-buffer-into-another-frame ()
  (portal-view-test--environment
    (portal-fake-native-with-frame other
      (let* ((target (portal-view-test--open "view"))
             (buffer (current-buffer))
             (origin (selected-window))
             (remote (frame-selected-window other)))
        ;; Another frame shows the buffer, but the view's own pane is selected.
        (set-window-buffer remote buffer)
        (portal-view-sync)
        (should (portal-view-test--shown target origin))
        ;; Selecting that frame leaves the view where it is.
        (select-frame other)
        (portal-view-sync)
        (should (portal-view-test--shown target origin))
        ;; Switching the buffer into that frame's pane moves the view there,
        ;; in one placement.
        (switch-to-buffer "*scratch*")
        (portal-view-sync)
        (let ((portal-fake-native-log nil))
          (switch-to-buffer buffer)
          (portal-view-sync)
          (should (portal-view-test--shown target remote))
          (should (equal (mapcar #'car portal-fake-native-log) '(portal--place))))
        (should (equal (frame-parameter other 'title)
                       (frame-parameter (selected-frame) 'title)))
        ;; Back in the first frame, a take brings it back.
        (select-frame (window-frame origin))
        (portal-view-focus)
        (should (portal-view-test--shown target origin))
        ;; With only the other frame showing it, the view goes there, unselected.
        (switch-to-buffer "*scratch*")
        (portal-view-sync)
        (should (eq (plist-get (portal--inspect target) :frame) other))
        (should (equal (portal-view-target remote) target))
        (should-not (portal-fake-native-calls 'portal--close))
        (should (= (length (portal-fake-native-calls 'portal--open)) 1))))))

(ert-deftest portal-view-follows-a-preview-in-the-minibuffer-origin ()
  (portal-view-test--environment
    (portal-fake-native-with-frame other
      (let* ((target (portal-view-test--open "view"))
             (buffer (current-buffer))
             (origin (selected-window))
             (remote (frame-selected-window other)))
        (set-window-buffer remote buffer)
        (switch-to-buffer "*scratch*")
        ;; Batch Emacs cannot enter the minibuffer, so a window stands in for it.
        (let ((minibuffer (split-window-below)))
          (select-window minibuffer)
          (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () minibuffer))
                    ((symbol-function 'minibuffer-selected-window) (lambda () origin)))
            (portal-view-sync)
            (should (equal (portal-view-target remote) target))
            ;; A preview in the window the minibuffer returns to shows the view,
            ;; even from another frame, and ending it puts the view back.
            (set-window-buffer origin buffer)
            (portal-view-sync)
            (should (portal-view-test--shown target origin))
            (set-window-buffer origin "*scratch*")
            (portal-view-sync)
            (should (equal (portal-view-target remote) target))
            (should (eq (plist-get (portal--inspect target) :frame) other))))))))

;; Batch Emacs cannot enter the minibuffer: a window split below the view's
;; pane stands in for it, active while `active' is.
(defmacro portal-view-test--with-minibuffer (active &rest body)
  "Run BODY with every frame's minibuffer window active while ACTIVE is non-nil."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'minibuffer-window-active-p) (lambda (_) ,active)))
     ,@body))

(defun portal-view-test--shrunk-log (target)
  "Record each run of `portal-view-shrunk-hook' with TARGET's places so far.
Return a function of no arguments that returns the record, oldest first."
  (let ((log nil))
    (add-hook 'portal-view-shrunk-hook
              (lambda ()
                (push (list (portal-view-shrunk-p)
                            (length (portal-fake-native-calls 'portal--place)))
                      log))
              nil t)
    (ignore target)
    (lambda () (reverse log))))

(ert-deftest portal-view-minibuffer-shrinking-its-pane-is-told-around-the-place ()
  (portal-view-test--environment
    (let* ((active nil)
           (target (portal-view-test--open "view"))
           (pane (selected-window))
           (log (portal-view-test--shrunk-log target))
           (placed (lambda () (length (portal-fake-native-calls 'portal--place)))))
      (portal-view-test--with-minibuffer active
        (portal-view-sync)
        (let ((before (funcall placed))
              (below (split-window-below)))
          ;; The minibuffer opens and grows over the pane's bottom: told once,
          ;; before the view is placed in the shrunk pane.
          (setq active t)
          (select-window below)
          (portal-view-sync)
          (should (portal-view-test--shown target pane))
          (should (equal (funcall log) (list (list t before))))
          (with-current-buffer (window-buffer pane) (should (portal-view-shrunk-p)))
          (window-resize below 1)
          (portal-view-sync)
          (should (equal (funcall log) (list (list t before))))
          ;; It closes, and the pane is as it was: told after the place.
          (delete-window below)
          (setq active nil)
          (portal-view-sync)
          (should (portal-view-test--shown target pane))
          (should (equal (funcall log) (list (list t before) (list nil (funcall placed)))))
          (with-current-buffer (window-buffer pane) (should-not (portal-view-shrunk-p))))))))

(ert-deftest portal-view-minibuffer-shrinking-ends-however-the-minibuffer-goes ()
  (portal-view-test--environment
    (let* ((active nil)
           (target (portal-view-test--open "view"))
           (buffer (current-buffer))
           (pane (selected-window))
           (shrunk (lambda () (with-current-buffer buffer (portal-view-shrunk-p)))))
      (portal-view-test--with-minibuffer active
        (portal-view-sync)
        (let ((below (split-window-below)))
          ;; Ended with nothing moved, as by C-g over a split it made.
          (setq active t)
          (select-window below)
          (portal-view-sync)
          (should (funcall shrunk))
          (setq active nil)
          (portal-view-sync)
          (should-not (funcall shrunk))
          ;; Left for the pane itself, as in a recursive edit.
          (setq active t)
          (delete-window below)
          (portal-view-sync)
          (setq below (split-window-below))
          (select-window below)
          (portal-view-sync)
          (should (funcall shrunk))
          (select-window pane)
          (portal-view-sync)
          (should-not (funcall shrunk))
          ;; Inactive, the same shrinking is a change of layout.
          (delete-window below)
          (portal-view-sync)
          (setq active nil)
          (select-window (split-window-below))
          (portal-view-sync)
          (should-not (funcall shrunk))
          (delete-other-windows pane)
          (portal-view-sync)
          ;; A pane that loses width as well is not shrunk by the minibuffer.
          (setq active t)
          (select-window (split-window-right))
          (portal-view-sync)
          (should (portal-view-test--shown target pane))
          (should-not (funcall shrunk)))))))

(ert-deftest portal-view-frame-deletion-hides-views-without-ending-them ()
  (portal-view-test--environment
    (let ((origin (selected-window))
          target buffer kept)
      (portal-fake-native-with-frame other
        (select-frame other)
        (setq target (portal-view-test--open "view")
              buffer (current-buffer))
        (should (portal-view-test--shown target))
        (select-frame (window-frame origin))
        (setq kept (portal-view-test--open "kept"))
        (should-not (portal-fake-native-calls 'portal--hide))
        (delete-frame other)
        (should (equal (portal-fake-native-calls 'portal--hide) (list (list target))))
        (should-not (plist-get (portal--inspect target) :visible))
        (should (portal-view-test--shown kept))
        (should (equal (portal-view-buffers) (list buffer (get-buffer "kept")))))
      (portal-view-sync)
      (should-not (plist-get (portal--inspect target) :visible))
      ;; Showing the buffer again brings back the same view.
      (let ((window (split-window-right)))
        (set-window-buffer window buffer)
        (portal-view-sync)
        (should (equal (portal-view-target window) target))
        (should (equal (plist-get (portal--inspect target) :edges)
                       (window-inside-pixel-edges window)))
        (should (equal (portal-view-target origin) kept)))
      (should-not (portal-fake-native-calls 'portal--close))
      (should (= (length (portal-fake-native-calls 'portal--open)) 2)))))

(ert-deftest portal-view-terminal-commands-cover-every-frame ()
  (portal-view-test--environment
    (portal-terminal)
    (let ((first (current-buffer))
          (second (progn (portal-terminal-new) (current-buffer))))
      (portal-fake-native-with-frame other
        (select-frame other)
        ;; The first terminal comes to this frame, keeping its shell.
        (portal-terminal)
        (should (eq (current-buffer) first))
        (should (eq (plist-get (portal--inspect (portal-view-target)) :frame) other))
        (portal-terminal-next)
        (should (eq (current-buffer) second))
        (let ((last-command-event ?\s-0)) (portal-terminal-select-index))
        (should (eq (current-buffer) first))
        (portal-terminal-focus)
        (should (= (length (portal-fake-native-calls 'portal--open)) 2))))))

(ert-deftest portal-view-terminal-commands-switch-split-zoom-and-kill ()
  (portal-view-test--environment
    (portal-terminal)
    (let* ((first (current-buffer))
           (first-id (portal-view-target))
           (second (progn (portal-terminal-new) (current-buffer))))
      (portal-view-sync)
      (should-not (plist-get (portal--inspect first-id) :visible))
      ;; Previous and next go in creation order; last returns to the one before.
      (portal-terminal-previous)
      (should (eq (current-buffer) first))
      (portal-terminal-next)
      (should (eq (current-buffer) second))
      (portal-terminal-last)
      (should (eq (current-buffer) first))
      ;; Splitting starts a third shell beside the first, which stays shown.
      (portal-terminal-split-right)
      (portal-view-sync)
      (let ((right (current-buffer)))
        (should (= (length (window-list)) 2))
        (should (= (length (portal-terminal-buffers)) 3))
        (should (plist-get (portal--inspect first-id) :visible))
        (other-window 1)
        (should (eq (current-buffer) first))
        (other-window 1)
        (should (eq (current-buffer) right))
        ;; Zoom fills the frame, then restores the layout.
        (portal-terminal-zoom)
        (should (= (length (window-list)) 1))
        (portal-terminal-zoom)
        (should (= (length (window-list)) 2))
        ;; Killing the pane asks, then ends its shell and removes the pane.
        (let ((portal-terminal-confirm-kill t) asked)
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (setq asked prompt) t)))
            (portal-terminal-kill-pane))
          (should asked))
        (should-not (buffer-live-p right))
        (should (= (length (window-list)) 1))
        (should (= (length (portal-terminal-buffers)) 2))))))

(ert-deftest portal-view-terminal-theme-is-a-name-or-nil ()
  (let ((original portal-terminal-theme))
    (unwind-protect
        (progn
          (setq portal-terminal-theme "Dracula")
          (should-error (setq portal-terminal-theme 42))
          (should (equal portal-terminal-theme "Dracula")))
      (setq portal-terminal-theme original))))

(ert-deftest portal-view-terminal-theme-pair-reaches-old-and-new-terminals ()
  (let ((original portal-terminal-theme))
    (unwind-protect
        (portal-view-test--environment
          (portal-terminal)
          ;; A pair reaches the running terminals at once, light first.
          (setq portal-terminal-theme '("Catppuccin Latte" . "Catppuccin Mocha"))
          (should (equal (portal-fake-native-calls 'portal--terminal-theme)
                         '(("Catppuccin Latte" "Catppuccin Mocha"))))
          ;; Anything but two names is refused, and changes nothing.
          (dolist (value '(("Dracula") ("Dracula" . 3) (3 . "Dracula") ("Dracula" "Alabaster")
                           [ "Dracula" "Alabaster" ]))
            (should-error (setq portal-terminal-theme value))
            (should (equal portal-terminal-theme '("Catppuccin Latte" . "Catppuccin Mocha"))))
          ;; A new terminal opens with both.
          (portal-terminal-new)
          (let ((options (plist-get (portal--inspect (portal-view-target)) :options)))
            (should (equal (plist-get options :theme) "Catppuccin Latte"))
            (should (equal (plist-get options :dark-theme) "Catppuccin Mocha")))
          ;; A single name and nil are as before: no dark theme.
          (setopt portal-terminal-theme "Dracula")
          (setq portal-terminal-theme nil)
          (should (equal (cdr (portal-fake-native-calls 'portal--terminal-theme))
                         '(("Dracula" nil) (nil nil))))
          (setq portal-terminal-theme "Dracula")
          (portal-terminal-new)
          (let ((options (plist-get (portal--inspect (portal-view-target)) :options)))
            (should (equal (plist-get options :theme) "Dracula"))
            (should (plist-member options :dark-theme))
            (should-not (plist-get options :dark-theme))))
      (setq portal-terminal-theme original))))

(ert-deftest portal-view-terminal-opacity-reaches-old-and-new-terminals ()
  (let ((original portal-terminal-opacity))
    (unwind-protect
        (portal-view-test--environment
          (portal-terminal)
          ;; A change reaches the running terminals at once.
          (setq portal-terminal-opacity 0.85)
          (should (equal (portal-fake-native-calls 'portal--terminal-opacity) '((0.85))))
          ;; It is a number from 0 to 1, and a refused one changes nothing.
          (dolist (value '(1.5 -0.1 "0.5" nil 0.0e+NaN))
            (should-error (setq portal-terminal-opacity value))
            (should (equal portal-terminal-opacity 0.85)))
          (setopt portal-terminal-opacity 0)
          (should (equal (portal-fake-native-calls 'portal--terminal-opacity) '((0.85) (0))))
          ;; A new terminal opens at it.
          (portal-terminal-new)
          (should (equal (plist-get (plist-get (portal--inspect (portal-view-target)) :options)
                                    :opacity)
                         0)))
      (setq portal-terminal-opacity original))))

;; Batch Emacs's frames are text terminals, where the `default' face has a
;; nominal height of 1, but its attribute can still be set per frame.  Making
;; or selecting a frame on another terminal sets it back to 1 in every frame,
;; so tests set it again after making one, and never select it.
(defmacro portal-view-test--with-default-height (height &rest body)
  "Run BODY with the `default' face HEIGHT tenths of a point high in every frame."
  (declare (indent 1))
  `(let ((heights (mapcar (lambda (frame) (cons frame (face-attribute 'default :height frame)))
                          (frame-list))))
     (unwind-protect
         (progn (set-face-attribute 'default nil :height ,height) ,@body)
       (dolist (entry heights)
         (when (frame-live-p (car entry))
           (set-face-attribute 'default (car entry) :height (cdr entry)))))))

(defun portal-view-test--points (target)
  "The text size the fake shows TARGET's terminal at, or nil."
  (plist-get (portal--inspect target) :points))

(defun portal-view-test--sized (target)
  "The sizes sent to TARGET's terminal, oldest first."
  (mapcar #'cadr (cl-remove-if-not (lambda (call) (equal (car call) target))
                                   (portal-fake-native-calls 'portal--terminal-text-size))))

(ert-deftest portal-view-terminal-text-size-is-emacs-text-size ()
  (portal-view-test--with-default-height 170
    (with-temp-buffer
      (should (equal (portal-terminal--text-size (current-buffer) (selected-frame)) 17.0))
      ;; The buffer's own zoom, by `text-scale-mode-step' to its amount.
      (text-scale-set 2)
      (should (< (abs (- (portal-terminal--text-size (current-buffer) (selected-frame)) 24.48))
                 1e-9))
      (text-scale-set 0)
      (should (equal (portal-terminal--text-size (current-buffer) (selected-frame)) 17.0))
      ;; The face's height in that frame.
      (portal-fake-native-with-frame other
        (set-face-attribute 'default (selected-frame) :height 170)
        (set-face-attribute 'default other :height 300)
        (should (equal (portal-terminal--text-size (current-buffer) other) 30.0))
        (should (equal (portal-terminal--text-size (current-buffer) (selected-frame)) 17.0))))))

(ert-deftest portal-view-terminal-text-size-follows-the-buffer-and-its-frame ()
  (portal-view-test--with-default-height 170
    (portal-view-test--environment
      ;; A new terminal opens at the size of Emacs text.
      (portal-terminal)
      (let ((first (current-buffer)) (first-id (portal-view-target)))
        (should (equal (plist-get (plist-get (portal--inspect first-id) :options) :points) 17.0))
        (split-window-right)
        (other-window 1)
        (portal-terminal-new)
        (let ((second (current-buffer)) (second-id (portal-view-target)))
          (portal-view-sync)
          (run-hook-with-args 'window-state-change-functions (selected-frame))
          ;; Nothing changed, so nothing is sent.
          (should-not (portal-fake-native-calls 'portal--terminal-text-size))
          ;; Zooming one terminal's buffer sizes that terminal alone.
          (text-scale-increase 1)
          (should (equal (portal-view-test--sized second-id) '(20.4)))
          (should (equal (portal-view-test--points second-id) 20.4))
          (should-not (portal-view-test--sized first-id))
          (text-scale-set 0)
          (should (equal (portal-view-test--sized second-id) '(20.4 17.0)))
          ;; A size beyond what a terminal shows is clamped.
          (text-scale-set 12)
          (should (equal (portal-view-test--points second-id) 72))
          (text-scale-set 0)
          ;; A change of the frame's font sizes every shown terminal.
          (set-face-attribute 'default (selected-frame) :height 300)
          (run-hook-with-args 'window-state-change-functions (selected-frame))
          (should (equal (portal-view-test--points first-id) 30.0))
          (should (equal (portal-view-test--points second-id) 30.0))
          ;; A hidden terminal keeps its size until it is shown.
          (with-selected-window (get-buffer-window first)
            (switch-to-buffer (get-buffer-create "*scratch*")))
          (portal-view-sync)
          (set-face-attribute 'default (selected-frame) :height 200)
          (run-hook-with-args 'window-state-change-functions (selected-frame))
          (should (equal (portal-view-test--points second-id) 20.0))
          (should (equal (portal-view-test--points first-id) 30.0))
          (with-current-buffer first (text-scale-increase 1))
          (should (equal (portal-view-test--points first-id) 30.0))
          ;; A terminal shown in another frame takes that frame's size.
          (portal-fake-native-with-frame other
            (set-face-attribute 'default (selected-frame) :height 200)
            (set-face-attribute 'default other :height 140)
            (set-window-buffer (frame-first-window other) first)
            (portal-view-sync)
            (run-hook-with-args 'window-state-change-functions other)
            (should (eq (plist-get (portal--inspect first-id) :frame) other))
            (should (< (abs (- (portal-view-test--points first-id) 16.8)) 1e-9))
            (should (equal (portal-view-test--points second-id) 20.0)))
          (should (eq second (window-buffer))))))
    ;; With the last terminal gone, nothing follows sizes.
    (should-not (memq #'portal-terminal--resize-shown window-state-change-functions))))

(ert-deftest portal-view-terminal-buffers-follow-the-view-lifecycle ()
  (portal-view-test--environment
    (portal-terminal)
    (let ((buffer (current-buffer))
          (target (portal-view-target)))
      (should (eq major-mode 'portal-terminal-mode))
      (should (equal (plist-get (plist-get (portal--inspect target) :options) :quick) nil))
      (should (equal (portal-input--target) target))
      (let ((origin (selected-window))
            (other (split-window-right)))
        (portal-view-sync)
        (should (portal-view-test--shown target))
        (should-not (portal-input--target other))
        ;; Selecting the other pane leaves the terminal; RET there takes it.
        (select-window other)
        (portal-view-sync)
        (should (portal-view-test--shown target origin))
        (should-not (portal-input--target))
        (call-interactively (keymap-lookup portal-terminal-mode-map "RET"))
        (should (portal-view-test--shown target other))
        (should (equal (portal-input--target) target))
        ;; A click in the pane it left brings it back.
        (select-window origin)
        (call-interactively (key-binding [mouse-1]))
        (should (portal-view-test--shown target origin))
        (delete-window other))
      (quit-window)
      (portal-view-sync)
      (should-not (plist-get (portal--inspect target) :visible))
      ;; Returning reuses the same hidden shell.
      (portal-terminal)
      (should (eq (current-buffer) buffer))
      (should (portal-view-test--shown target))
      (should (= (length (portal-fake-native-calls 'portal--open)) 1))
      (portal-terminal-close)
      (should-not (portal--inspect target))
      (should (buffer-live-p buffer))
      (should-error (portal-terminal-focus) :type 'user-error))))

;;; Placards

(ert-deftest portal-view-placard-says-where-the-view-is-until-it-closes ()
  (portal-view-test--environment
    (portal-terminal)
    (let ((buffer (current-buffer)))
      (should (equal (buffer-string) (concat "This terminal is showing in another pane.\n"
                                             "RET or a click brings it here.\n")))
      ;; C-c C-k ends the shell, keeping the buffer, which says so.
      (call-interactively (keymap-lookup portal-terminal-mode-map "C-c C-k"))
      (should (buffer-live-p buffer))
      (should (equal (buffer-string) "This terminal has ended.\n")))
    (portal-open-url "about:blank")
    (should (equal (buffer-string) (concat "This page is showing in another pane.\n"
                                           "RET or a click brings it here.\n")))
    (portal-view-close)
    (should (equal (buffer-string) "This page is closed.\n"))
    ;; A buffer without a placard keeps its own text when its view closes.
    (switch-to-buffer (generate-new-buffer "own"))
    (insert "own text")
    (portal-view-open 'terminal nil)
    (portal-view-close)
    (should (equal (buffer-string) "own text"))))

(defun portal-view-test--text-width (window)
  "The width of the text WINDOW shows of its buffer, in columns."
  (car (window-text-pixel-size window)))

(ert-deftest portal-view-text-is-hidden-in-the-views-pane-alone ()
  (portal-view-test--environment
    (portal-terminal)
    (let* ((buffer (current-buffer))
           (origin (selected-window))
           (other (split-window-right)))
      (set-window-buffer other buffer)
      (portal-view-sync)
      (should (eq portal-view--window origin))
      ;; The view's pane shows none of the placard; the other pane shows it.
      (should (= (portal-view-test--text-width origin) 0))
      (should (> (portal-view-test--text-width other) 0))
      ;; Point moves through the text there as through any text.
      (with-selected-window other
        (goto-char (point-min))
        (call-interactively #'next-line)
        (call-interactively #'forward-char)
        (should (= (line-number-at-pos) 2))
        (should (= (point) (1+ (line-beginning-position)))))
      ;; The text follows the view when it moves.
      (select-window other)
      (portal-view-focus)
      (should (eq portal-view--window other))
      (should (> (portal-view-test--text-width origin) 0))
      (should (= (portal-view-test--text-width other) 0))
      ;; Text the buffer gets later is hidden there too.
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert "more text, at the end\n")
        (goto-char (point-min))
        (insert "more text, at the start\n"))
      (should (= (portal-view-test--text-width other) 0))
      (portal-view-placard "terminal" "This terminal has ended.")
      (should (= (portal-view-test--text-width other) 0))
      (should (> (portal-view-test--text-width origin) 0))
      ;; Hidden in no pane, the text is hidden nowhere: shown again, it is
      ;; hidden in its new pane alone.
      (delete-window other)
      (switch-to-buffer "*scratch*")
      (portal-view-sync)
      (should-not portal-view--window)
      (with-current-buffer buffer (should-not (overlay-buffer portal-view--veil)))
      (let ((pane (split-window-right)))
        (set-window-buffer pane buffer)
        (portal-view-sync)
        (should (eq (buffer-local-value 'portal-view--window buffer) pane))
        (should (= (portal-view-test--text-width pane) 0))
        ;; Switched into the selected pane, the view takes it, and the
        ;; pane it left shows the text.
        (set-window-buffer (selected-window) buffer)
        (portal-view-sync)
        (should (eq (buffer-local-value 'portal-view--window buffer) (selected-window)))
        (should (= (portal-view-test--text-width (selected-window)) 0))
        (should (> (portal-view-test--text-width pane) 0))
        ;; Once the view closes, its pane shows the text that says so.
        (with-current-buffer buffer (portal-view-close))
        (should (> (portal-view-test--text-width (selected-window)) 0))
        (should-not (cl-some (lambda (overlay) (overlay-get overlay 'portal-view-veil))
                             (with-current-buffer buffer
                               (overlays-in (point-min) (point-max)))))))))

;;; Records

(defvar portal-view-test--handled nil
  "Records the test handlers saw, oldest first, as (TYPE BUFFER ARGUMENTS).")

(defun portal-view-test--handler (type)
  "Return a record handler that logs TYPE, the current buffer and its arguments."
  (lambda (&rest arguments)
    (setq portal-view-test--handled
          (append portal-view-test--handled (list (list type (current-buffer) arguments))))))

(defmacro portal-view-test--handling (types &rest body)
  "Run BODY with only logging handlers, one for each of TYPES."
  (declare (indent 1))
  `(let ((portal-view-test--handled nil)
         (portal-view-record-handlers
          (mapcar (lambda (type) (cons type (portal-view-test--handler type))) ,types)))
     ,@body))

(ert-deftest portal-view-record-split-across-reads-is-dispatched-once ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (record (format "ping %s 3 838\n" target)))
      (portal-view-test--handling '("ping")
        (portal-fake-native-send (substring record 0 9))
        (should-not portal-view-test--handled)
        (portal-fake-native-send (substring record 9 -1) "\n" "")
        (should (equal portal-view-test--handled
                       `(("ping" ,(current-buffer) (,target "3" "838")))))))))

(ert-deftest portal-view-records-in-one-read-each-reach-their-handler-and-buffer ()
  (portal-view-test--environment
    (let ((first (portal-view-test--open "first"))
          (second (portal-view-test--open "second")))
      (switch-to-buffer "*scratch*")
      (portal-view-test--handling '("ping" "pong")
        (push (cons "fail" (lambda (&rest _) (error "Expected failure")))
              portal-view-record-handlers)
        ;; A failing handler is reported; the records after it still arrive.
        (portal-fake-native-send (format "ping %s 1\nfail %s\npong %s\nping %s 2 x\n"
                                         second first first second))
        (portal-fake-native-send "")
        (should (equal portal-view-test--handled
                       `(("ping" ,(get-buffer "second") (,second "1"))
                         ("pong" ,(get-buffer "first") (,first))
                         ("ping" ,(get-buffer "second") (,second "2" "x")))))
        (should (eq (current-buffer) (get-buffer "*scratch*")))))))

(ert-deftest portal-view-records-hook-runs-once-after-the-filter-returns ()
  (portal-view-test--environment
    (let ((target (portal-view-test--open "view")) runs)
      (portal-view-test--handling '("ping")
        (let ((portal-view-records-hook (list (lambda () (push portal-view-test--handled runs)))))
          ;; A fragment that completes no record schedules nothing.
          (portal-fake-native-send (format "ping %s 1" target))
          (portal-fake-native-send "")
          (sit-for 0.05)
          (should-not runs)
          (portal-fake-native-send (format "\nping %s 2\n" target))
          (portal-fake-native-send "")
          ;; The handlers ran in the filter; the hook waits for its timer.
          (should (= (length portal-view-test--handled) 2))
          (should-not runs)
          (sit-for 0.05)
          ;; One run covers every batch handled before it.
          (should (= (length runs) 1))
          (should (= (length (car runs)) 2)))))))

(ert-deftest portal-view-records-handled-while-the-hook-runs-earn-one-more-run ()
  (portal-view-test--environment
    (let ((target (portal-view-test--open "view")) (depth 0) (deepest 0) runs)
      (portal-view-test--handling '("ping")
        (let ((portal-view-records-hook
               (list (lambda ()
                       (cl-incf depth)
                       (setq deepest (max deepest depth))
                       (push (length portal-view-test--handled) runs)
                       ;; The first run waits for input, as a prompt would,
                       ;; while another record arrives.
                       (when (= (length runs) 1)
                         (portal-fake-native-send (format "ping %s 2\n" target))
                         (portal-fake-native-send "")
                         (sit-for 0.05))
                       (cl-decf depth)))))
          (portal-fake-native-send (format "ping %s 1\n" target))
          (portal-fake-native-send "")
          (sit-for 0.05)
          (sit-for 0.05)
          ;; The record handled during the first run got its own run, after
          ;; the first returned, never nested in it.
          (should (equal runs '(2 1)))
          (should (= deepest 1)))))))

(ert-deftest portal-view-record-for-an-unknown-target-is-dropped ()
  (portal-view-test--environment
    (let ((target (portal-view-test--open "view"))
          (closed (portal-view-test--open "closed")))
      (kill-buffer "closed")
      (portal-view-test--handling '("ping")
        (portal-fake-native-send
         (format "ping %s 1\nping terminal:999999 2\nping\n\npong %s 3\nping %s 4\n"
                 closed target target))
        (should (equal portal-view-test--handled
                       `(("ping" ,(get-buffer "view") (,target "4")))))))))

(ert-deftest portal-view-input-records-queue-commands-for-every-view ()
  (portal-view-test--environment
    (let ((target (portal-view-test--open "view"))
          (other (portal-view-test--open "other"))
          (unread-command-events nil))
      (portal-fake-native-send
       (format "key %s 3 120 8\nbinding %s 4 8388704\nliteral %s 5 0\ncancel web:999999 6 0\nescape %s 7 0\n"
               target target other other))
      (should (equal unread-command-events
                     `((portal-input-key (,target 3 120 8))
                       (portal-input-binding (,target 4 8388704))
                       (portal-input-literal (,other 5 0))
                       (portal-input-escape (,other 7 0))))))))

(ert-deftest portal-view-feature-records-coexist-with-view-records ()
  (portal-view-test--environment
    (let ((target (portal-view-test--open "view")) features
          (origin (current-buffer)))
      (let ((portal-view-feature-record-handlers
             (list (cons "launcher" (lambda (&rest fields)
                                      (push (cons (current-buffer) fields) features))))))
        (portal-view-test--handling '("ping")
          (portal-fake-native-send (format "launcher 17 3\nping %s 1\nlauncher 17 4\n" target))
          (should (equal features `((,origin "17" "4") (,origin "17" "3"))))
          (should (equal portal-view-test--handled `(("ping" ,origin (,target "1"))))))))))

(ert-deftest portal-view-pgtk-frame-stays-focused-while-its-view-has-the-keyboard ()
  "On pgtk, GTK's focus-out for a view taking the keyboard never runs."
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (frame (selected-frame))
           (handled nil)
           (handle (lambda (event) (push event handled)))
           (event (list 'focus-out frame)))
      (cl-flet ((state (&rest facts)
                  (puthash target (append facts (gethash target portal-fake-native--views))
                           portal-fake-native--views)))
        ;; Emacs has the keyboard: the frame's window lost it.
        (portal-view--keep-frame-focus handle event)
        (should (equal handled (list event)))
        ;; The view has the keyboard of a window that has it.
        (state :focused t :active t)
        (portal-view--keep-frame-focus handle event)
        (should (equal handled (list event)))
        ;; The window lost the keyboard, the view's with it.
        (state :active nil)
        (portal-view--keep-frame-focus handle event)
        (should (= (length handled) 2))
        ;; Another frame's focus is its own.
        (state :active t)
        (portal-view--keep-frame-focus handle (list 'focus-out 'another-frame))
        (should (= (length handled) 3))))))

(ert-deftest portal-view-says-emacs-has-drawn-on-pgtk-frames-alone ()
  "A timer tells the module once redisplay is done, where the module waits."
  (portal-view-test--environment
    (portal-view-test--open "view")
    (should-not portal-view--drawn-timer)
    (let ((drawn 0))
      (unwind-protect
          (cl-letf (((symbol-function 'framep) (lambda (_frame) 'pgtk))
                    ((symbol-function 'portal--drawn) (lambda () (cl-incf drawn) t)))
            ;; Two changes before Emacs is idle are told once.
            (set-window-buffer (split-window-below) (get-buffer-create "*scratch*"))
            (portal-view-sync)
            (delete-other-windows)
            (portal-view-sync)
            (should (timerp portal-view--drawn-timer))
            (should (= drawn 0))
            (timer-event-handler portal-view--drawn-timer)
            (should (= drawn 1))
            (should-not portal-view--drawn-timer))
        (when portal-view--drawn-timer
          (cancel-timer portal-view--drawn-timer)
          (setq portal-view--drawn-timer nil))))))

(ert-deftest portal-view-unsupported-emacs-names-what-to-change ()
  ;; Each requirement names its own fix; a newer build is checked first.
  (dlet ((features (cons 'ns (remq 'pgtk features))))
    (let ((emacs-version "31.1") (system-type 'darwin) (window-system 'ns))
      (should-not (portal-view--unsupported))
      (let ((emacs-version "30.2") (window-system nil))
        (should (string-match-p "Emacs 31.1 or newer; this is Emacs 30.2"
                                (portal-view--unsupported))))
      (let ((system-type 'windows-nt))
        (should (string-match-p "only on macOS and Linux; this Emacs runs on windows-nt"
                                (portal-view--unsupported))))
      (cl-letf (((symbol-function 'module-load) nil))
        (should (string-match-p "--with-modules" (portal-view--unsupported))))
      (dlet ((features (remq 'ns features)) (window-system nil))
        (should (string-match-p "--with-ns" (portal-view--unsupported))))
      (let ((window-system nil))
        (should (string-match-p "graphical Emacs frame" (portal-view--unsupported)))))))

(ert-deftest portal-view-unsupported-on-linux-wants-pgtk-on-wayland ()
  (let ((display "GdkWaylandDisplay"))
    (cl-letf (((symbol-function 'pgtk-backend-display-class) (lambda (&rest _) display)))
      (dlet ((features (cons 'pgtk (remq 'ns features))))
        (let ((emacs-version "31.1") (system-type 'gnu/linux) (window-system 'pgtk))
          (should-not (portal-view--unsupported))
          ;; An X11 or Lucid build has no GTK frame to put a view in.
          (dlet ((features (remq 'pgtk features)) (window-system 'x))
            (should (string-match-p "--with-pgtk" (portal-view--unsupported))))
          (let ((window-system nil))
            (should (string-match-p "graphical Emacs frame" (portal-view--unsupported))))
          ;; GDK_BACKEND=x11 puts a pgtk frame on X11.
          (setq display "GdkX11Display")
          (should (string-match-p "frame on Wayland; this frame's display is a GdkX11Display"
                                  (portal-view--unsupported))))))))

(provide 'portal-view-tests)
;;; portal-view-tests.el ends here
