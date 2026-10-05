;;; portal-gui-testing.el --- Shared fixtures of the graphical suites -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Helpers for suites that run in a disposable graphical Emacs with the real
;; module and the test-only event injector, build/test-terminal-input.dylib
;; (docs/testing.md).  Loading this file defines no tests.

(require 'ert)
(require 'json)
(require 'portal)

(declare-function portal--inspect "portal-view" (target))
(declare-function portal--web-load "portal-web" (target url))
(declare-function portal--terminal-text "portal-terminal" (target))
(declare-function portal--terminal-paste "portal-terminal" (target text &optional enter))
(declare-function portal--close "portal-view" (target))
(declare-function portal-test-native-key "test-terminal-input" (code flags text &optional windowless))
(declare-function portal-test-native-post-key "test-terminal-input" (code flags text &optional windowless))
(declare-function portal-test-web-eval "test-terminal-input" (script))
(declare-function portal-test-native-target-frame "test-terminal-input" (title))
(declare-function portal-test-native-click "test-terminal-input" (x y))
(declare-function portal--process-snapshot "portal-view" (variable))

;; Web views.

(defmacro portal-test--with-web (&rest body)
  "Run BODY in one window, then kill the web buffers it opened."
  (declare (indent 0))
  `(progn
     (skip-unless (eq window-system 'ns))
     (let ((buffers (portal-view-buffers 'web)))
       (save-window-excursion
         (unwind-protect
             (progn (delete-other-windows) ,@body)
           (dolist (buffer (portal-view-buffers 'web))
             (unless (memq buffer buffers) (kill-buffer buffer))))))))

(defun portal-test--wait-for-page (title &optional target)
  "Wait for web view TARGET to finish loading a page titled TITLE.
TARGET defaults to the selected pane's view.  Return its state."
  (let ((target (or target (portal-view-target)))
        (deadline (+ (float-time) 15))
        state)
    (while (progn
             (redisplay t)
             (setq state (portal--inspect target))
             (and (< (float-time) deadline)
                  (not (and (equal (plist-get state :title) title)
                            (not (plist-get state :loading))))))
      (sleep-for 0.05))
    (should (equal (plist-get state :title) title))
    (should-not (plist-get state :loading))
    (should-not (plist-get state :error))
    state))

(defun portal-test--shown (target window)
  "Whether web view TARGET is visible within WINDOW's text area."
  (redisplay t)
  (let ((state (portal--inspect target)))
    (and (plist-get state :visible)
         (equal (plist-get state :edges) (window-inside-pixel-edges window)))))

;; Terminals.

;; Tests kill live shells without asking; the prompt has its own tests.
(setq portal-terminal-confirm-kill nil)

(defvar portal-terminal-test--target nil
  "The target of the terminal each test session starts with.")

(defun portal-terminal-test--state (&optional target)
  "Inspect TARGET, defaulting to the session's first terminal."
  (portal--inspect (or target portal-terminal-test--target)))

(defun portal-terminal-test--paste (text enter &optional target)
  "Paste TEXT into TARGET, pressing Enter if ENTER is non-nil."
  (portal--terminal-paste (or target portal-terminal-test--target) text enter))

(defun portal-terminal-test--text (&optional target)
  "Return TARGET's scrollback, defaulting to the session's first terminal."
  (portal--terminal-text (or target portal-terminal-test--target)))

(defun portal-terminal-test--wait (predicate)
  "Wait for a real shell or native UI event, with a bounded timeout."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (redisplay t))
    (should (funcall predicate))))

(defmacro portal-terminal-test--session (&rest body)
  (declare (indent 0))
  `(progn
     (skip-unless (eq window-system 'ns))
     (save-window-excursion
       (unwind-protect
           (progn (delete-other-windows)
                  (select-frame-set-input-focus (selected-frame))
                  (sit-for 0.1)
                  (portal-terminal)
                  (let ((portal-terminal-test--target (portal-view-target))) ,@body))
         (portal-terminal-close-all)))))

(defmacro portal-terminal-test--native-maps (&rest body)
  (declare (indent 0))
  `(unwind-protect
       (let ((portal-terminal-native-map (make-sparse-keymap))
             (portal-terminal-quick-native-map (make-sparse-keymap))
             (portal-terminal--native-maps (cons (make-sparse-keymap) (make-sparse-keymap))))
         (portal-terminal-refresh-bindings)
         ,@body)
     (portal-terminal-refresh-bindings)))

;; Keyboard input returning to Emacs.

(defun portal-integration-test--emacs-input ()
  "Verify the real editor receives a complete Emacs key sequence."
  (portal-test-native-post-key 7 (ash 1 18) "\C-x")
  (portal-test-native-post-key 11 0 "b")
  (should (equal (with-timeout (3 (ert-fail "Emacs did not regain keyboard input"))
                   (read-key-sequence-vector nil))
                 (vconcat (kbd "C-x b")))))

;; Page scripts, and an Excalidraw document.

(defun portal-excalidraw-gui--js (script)
  "Run SCRIPT in the actual webview, returning its result."
  (should (portal-test-web-eval script))
  (portal-terminal-test--wait (lambda () (portal-test-web-eval nil)))
  (let ((result (json-parse-string (portal-test-web-eval nil) :object-type 'plist)))
    (should-not (plist-get result :error))
    (plist-get result :value)))

(defmacro portal-excalidraw-gui--document (&rest body)
  (declare (indent 0))
  `(progn
     (skip-unless (eq window-system 'ns))
     (save-window-excursion
       (let ((directory (make-temp-file "portal-drawing-gui-" t)) document)
         (unwind-protect
             (progn
               (delete-other-windows)
               (select-frame-set-input-focus (selected-frame))
               (sit-for 0.1)
               (should (portal-view--with-frame-title (selected-frame)
                                                      #'portal-test-native-target-frame))
               (find-file (expand-file-name "drawing.excalidraw" directory))
               (setq document (current-buffer))
               (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
               (redisplay t)
               (portal-view-sync)
               ,@body)
           (when (buffer-live-p document)
             (with-current-buffer document
               (portal-excalidraw--close)
               (set-buffer-modified-p nil)
               (kill-buffer document)))
           (portal-test-native-target-frame nil)
           (delete-directory directory t))))))

;; A folder of Markdown documents, and links clicked in their previews.

(defvar portal-markdown-gui--directory nil "The current test's Markdown folder.")

(defun portal-markdown-gui--file (name)
  "Return file NAME in the test folder."
  (expand-file-name name portal-markdown-gui--directory))

(defun portal-markdown-gui--write (name text)
  "Write TEXT to file NAME in the test folder, creating its directory."
  (let ((file (portal-markdown-gui--file name)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))))

(defun portal-markdown-gui--link-point (text)
  "Scroll the preview's link with TEXT into view and return where to click it."
  (portal-excalidraw-gui--js
   (format "const a = [...document.links].find(a => a.textContent === %S);
            a.scrollIntoView({block: 'center'}); const r = a.getBoundingClientRect();
            return [Math.round(r.left + 3), Math.round(r.top + r.height / 2)];" text)))

(defun portal-markdown-gui--click-link (text)
  "Click the preview's link with TEXT with the real mouse."
  (let ((point (portal-markdown-gui--link-point text)))
    (should (portal-test-native-click (aref point 0) (aref point 1)))))

(defun portal-markdown-gui--scroll ()
  "Return the preview's vertical scroll position."
  (portal-excalidraw-gui--js "return Math.round(window.scrollY);"))

(defun portal-markdown-gui--event (type)
  "Read the next queued native event, which must be TYPE, and run its command."
  (let ((event (aref (with-timeout (5 (ert-fail (format "No %s event" type)))
                       (read-key-sequence-vector nil))
                     0)))
    (should (eq (car-safe event) type))
    (funcall (lookup-key global-map (vector type)) event)))

(defun portal-markdown-gui--state ()
  "Return the preview toolbar's state."
  (portal-toolbar--action "state"))

;; The agent dashboard with real terminals.

(defmacro portal-agents-gui--environment (&rest body)
  "Run BODY in one window with live updates every 0.2 seconds.
Afterwards nothing is tracked, and no dashboard, terminal or timer remains."
  (declare (indent 0))
  `(progn
     (skip-unless (eq window-system 'ns))
     (let ((buffers (buffer-list))
           (portal-agents-live-update t)
           (portal-agents-live-update-interval 0.2))
       (setq portal-agents--tracked nil)
       (unwind-protect
           (save-window-excursion
             (delete-other-windows)
             (select-frame-set-input-focus (selected-frame))
             (sit-for 0.1)
             ,@body)
         (when (buffer-live-p portal-agents--buffer) (kill-buffer portal-agents--buffer))
         (setq portal-agents--tracked nil)
         (portal-terminal-close-all)
         (dolist (buffer (buffer-list))
           (unless (memq buffer buffers) (kill-buffer buffer))))
       (should (= (portal-agents-gui--timers) 0)))))

(defun portal-agents-gui--timers ()
  "Return how many dashboard timers are scheduled."
  (cl-count #'portal-agents--tick timer-list :key #'timer--function))

(defun portal-agents-gui--wait (seconds)
  "Run the event loop for SECONDS, with timers and redisplay.
Unlike `sit-for', it waits while input is pending."
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end)
      (accept-process-output nil 0.05)
      (redisplay))))

(defun portal-agents-gui--settle ()
  "Redisplay, which runs window hooks, and handle waiting native records."
  (redisplay t)
  (accept-process-output nil 0.05)
  (redisplay t))

(defun portal-agents-gui--open (name)
  "Start a terminal named NAME in the selected window and return its buffer."
  (portal-terminal-new)
  (portal-terminal-rename name)
  (current-buffer))

(defun portal-agents-gui--row (buffer)
  "Return BUFFER's row as the dashboard prints it, or nil."
  (with-current-buffer portal-agents--buffer
    (save-excursion
      (goto-char (point-min))
      (while (and (not (eobp)) (not (eq (car (tabulated-list-get-id)) buffer)))
        (forward-line 1))
      (append (tabulated-list-get-entry) nil))))

(defun portal-agents-gui--view (buffer)
  "Return where BUFFER's view is and whether it has the keyboard.
Where is the window showing BUFFER at the view's edges, in any frame, nil
when the view is hidden, or `elsewhere'."
  (portal-agents-gui--settle)
  (let* ((state (portal-terminal-test--state (buffer-local-value 'portal-view--target buffer)))
         (edges (plist-get state :edges)))
    (list (and (plist-get state :visible)
               (or (seq-find (lambda (window)
                               (and (eq (window-buffer window) buffer)
                                    (equal (append (window-inside-pixel-edges window) nil) edges)))
                             (window-list-1 nil 'nomini t))
                   'elsewhere))
          (and (plist-get state :focused) t))))

(defun portal-agents-gui--visit (buffer)
  "Show the dashboard in the selected window and type RET on BUFFER's row."
  (switch-to-buffer portal-agents--buffer)
  (portal-agents-gui--settle)
  (goto-char (point-min))
  (while (not (eq (car (tabulated-list-get-id)) buffer))
    (forward-line 1))
  (execute-kbd-macro (kbd "RET"))
  (portal-agents-gui--settle))

(defun portal-discovery-gui--type (buffer text)
  "Type TEXT and Return in BUFFER's shell or Claude session."
  (portal--terminal-paste (buffer-local-value 'portal-view--target buffer) text t))

(defun portal-discovery-gui--wait (predicate &optional seconds)
  "Wait up to SECONDS (default 15) for PREDICATE through the real event loop."
  (let ((deadline (+ (float-time) (or seconds 15))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (redisplay t))
    (ert-info ((format "Waiting for %S; rows: %S" predicate
                       (and (buffer-live-p portal-agents--buffer)
                            (with-current-buffer portal-agents--buffer tabulated-list-entries))))
      (should (funcall predicate)))))

(provide 'portal-gui-testing)
;;; portal-gui-testing.el ends here
