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

(ert-deftest portal-view-split-keeps-one-view-in-the-selected-pane ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (origin (selected-window))
           (other (split-window-right)))
      (should (eq (window-buffer other) (current-buffer)))
      (portal-view-sync)
      (should (portal-view-test--shown target origin))
      (should (= (length (portal-fake-native-calls 'portal--open)) 1)))))

(ert-deftest portal-view-follows-the-selected-pane-showing-its-buffer ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (origin (selected-window))
           (other (split-window-right))
           (unrelated (split-window-below)))
      (set-window-buffer unrelated (get-buffer "*scratch*"))
      (select-window other)
      (portal-view-sync)
      (should (portal-view-test--shown target other))
      ;; A selected pane showing another buffer leaves the view where it was.
      (select-window unrelated)
      (portal-view-sync)
      (should (portal-view-test--shown target other))
      (select-window origin)
      (portal-view-sync)
      (should (portal-view-test--shown target origin))
      ;; ORIGIN comes after OTHER in window order from UNRELATED; it still stays.
      (select-window unrelated)
      (should (equal (get-buffer-window-list (window-buffer origin)) (list other origin)))
      (portal-view-sync)
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
      ;; Then shown in the selected pane as well: the view follows selection.
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
        ;; Selecting that frame moves the view there in one placement.
        (let ((portal-fake-native-log nil))
          (select-frame other)
          (portal-view-sync)
          (should (portal-view-test--shown target remote))
          (should (equal (mapcar #'car portal-fake-native-log) '(portal--place))))
        (should (equal (frame-parameter other 'title)
                       (frame-parameter (selected-frame) 'title)))
        ;; Back in the first frame, the selected pane wins again.
        (select-frame (window-frame origin))
        (portal-view-sync)
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

(ert-deftest portal-view-terminal-buffers-follow-the-view-lifecycle ()
  (portal-view-test--environment
    (portal-terminal)
    (let ((buffer (current-buffer))
          (target (portal-view-target)))
      (should (eq major-mode 'portal-terminal-mode))
      (should (equal (plist-get (plist-get (portal--inspect target) :options) :quick) nil))
      (should (equal (portal-input--target) target))
      (let ((other (split-window-right)))
        (portal-view-sync)
        (should (portal-view-test--shown target))
        (should-not (portal-input--target other))
        (select-window other)
        (portal-view-sync)
        (should (portal-view-test--shown target other))
        (should (equal (portal-input--target) target))
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

(ert-deftest portal-view-unsupported-emacs-names-what-to-change ()
  ;; Each requirement names its own fix; a newer build is checked first.
  (let ((emacs-version "31.1") (system-type 'darwin) (window-system 'ns))
    (should-not (portal-view--unsupported))
    (let ((emacs-version "30.2") (window-system nil))
      (should (string-match-p "Emacs 31.1 or newer; this is Emacs 30.2"
                              (portal-view--unsupported))))
    (let ((system-type 'gnu/linux))
      (should (string-match-p "only on macOS; this Emacs runs on gnu/linux"
                              (portal-view--unsupported))))
    (cl-letf (((symbol-function 'module-load) nil))
      (should (string-match-p "--with-modules" (portal-view--unsupported))))
    (dlet ((features (remq 'ns features)) (window-system nil))
      (should (string-match-p "--with-ns" (portal-view--unsupported))))
    (let ((window-system nil))
      (should (string-match-p "graphical Emacs frame" (portal-view--unsupported))))))

(provide 'portal-view-tests)
;;; portal-view-tests.el ends here
