;;; portal-launcher-tests.el --- Launcher policy checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'portal-launcher)
(require 'portal-launcher-examples)

(ert-deftest portal-launcher-load-is-inert ()
  ;; This suite runs in -Q without launcher.el, which Portal does not need.
  (should-not (locate-library "launcher"))
  (should-not (featurep 'launcher))
  ;; Shortcuts are a separate module, which this one does not load.
  (should-not (member '(require . portal-global-shortcut)
                      (alist-get (symbol-file 'portal-launcher-present) load-history
                                 nil nil #'equal)))
  (should (member '(require . portal-view)
                  (alist-get (symbol-file 'portal-launcher-present) load-history
                             nil nil #'equal)))
  (should-not portal-launcher-mode)
  (should-not portal-launcher--frame)
  (should-not (memq #'portal-launcher--before-delete delete-frame-functions))
  (should-not (advice-member-p #'portal-launcher--guard-parameters #'modify-frame-parameters))
  ;; Portal chooses no command and no chord.
  (dolist (function '(portal-launcher-applications portal-launcher-toggle))
    (should-not (fboundp function)))
  (dolist (option '(portal-launcher-command portal-launcher-shortcut))
    (should-not (boundp option))))

(require 'portal-global-shortcut)

(ert-deftest portal-launcher-rejects-unsupported-before-loading ()
  (let ((emacs-repository-version "unvalidated")
        (frames (frame-list)))
    (cl-letf (((symbol-function 'portal-view--load) (lambda () (ert-fail "Loaded native code"))))
      (should-error (portal-launcher-show) :type 'user-error)
      (should-not portal-launcher-mode)
      (should (equal frames (frame-list))))))

(ert-deftest portal-launcher-rejects-invalid-input-before-enabling ()
  (cl-letf (((symbol-function 'portal-launcher-mode) (lambda (&rest _) (ert-fail "Enabled"))))
    ;; A buffer panel cannot fit its content.
    (dolist (size '((199 420) (720 99) (720) (720 420 3) (720 . 420) (720 420.5) (720 auto)))
      (let ((portal-launcher-size size))
        (should-error (portal-launcher-show) :type 'user-error)))
    (let ((portal-launcher-offset '(0))) (should-error (portal-launcher-show) :type 'user-error))
    (let ((portal-launcher-screen -1)) (should-error (portal-launcher-show) :type 'user-error))
    (let ((portal-launcher-corner-radius -1)) (should-error (portal-launcher-show) :type 'user-error))
    (should-error (portal-launcher-show "missing launcher test buffer") :type 'user-error))
  (should-not portal-launcher-mode))

(ert-deftest portal-launcher-size-resolves-per-kind ()
  ;; The default fits a minibuffer panel and keeps the buffer panel's size.
  (should-not (default-value 'portal-launcher-size))
  (let ((portal-launcher-size nil))
    (should (equal (portal-launcher--size 'minibuffer) '(720 auto)))
    (should (equal (portal-launcher--size 'buffer) '(720 420))))
  (let ((portal-launcher-size '(640 auto)))
    (should (equal (portal-launcher--size 'minibuffer) '(640 auto)))
    (should-error (portal-launcher--size 'buffer) :type 'user-error))
  ;; Numbers are fixed sizes for both kinds, not maxima.
  (let ((portal-launcher-size '(720 240)))
    (dolist (kind '(minibuffer buffer))
      (should (equal (portal-launcher--size kind) '(720 240)))))
  (dolist (size '((199 auto) (720 99) (720 . auto) (720 auto 1) (auto 240) (auto auto)
                  (720 "auto") (720 fit) (720 240.0) (720 nil) 720 auto t))
    (let ((portal-launcher-size size))
      (dolist (kind '(minibuffer buffer))
        (should-error (portal-launcher--size kind) :type 'user-error))))
  ;; The option's type describes each valid setting.
  (require 'wid-edit)
  (let ((type (widget-convert (get 'portal-launcher-size 'custom-type))))
    (dolist (value '(nil (720 auto) (720 240)))
      (should (widget-apply type :match value)))
    (dolist (value '((720 fit) (auto 240) 720))
      (should-not (widget-apply type :match value)))))

(ert-deftest portal-launcher-requires-guard-for-native-callers ()
  (skip-unless (featurep 'native-compile))
  (let ((comp-installed-trampolines-h (make-hash-table)))
    (should-error (portal-launcher--check-guard) :type 'user-error)
    (puthash 'modify-frame-parameters t comp-installed-trampolines-h)
    (should-error (portal-launcher--check-guard) :type 'user-error)
    (puthash 'delete-frame t comp-installed-trampolines-h)
    (should-not (portal-launcher--check-guard))))

(ert-deftest portal-launcher-failed-enable-removes-partial-hooks ()
  (skip-unless (featurep 'native-compile))
  (let ((comp-installed-trampolines-h (make-hash-table))
        (native-comp-enable-subr-trampolines nil))
    (cl-letf (((symbol-function 'portal-launcher--check-support) #'ignore)
              ((symbol-function 'portal-view--load) #'ignore)
              ((symbol-function 'portal--launcher-attach) #'ignore)
              ((symbol-function 'portal--launcher-prepare) #'ignore)
              ((symbol-function 'portal--launcher-fit) #'ignore))
      (should-error (portal-launcher-mode 1) :type 'user-error)
      (should-not portal-launcher-mode)
      (should-not portal-launcher--frame)
      (should-not (advice-member-p #'portal-launcher--guard-parameters #'modify-frame-parameters))
      (should-not (memq #'portal-launcher--before-delete delete-frame-functions)))))

(ert-deftest portal-launcher-rejects-a-module-missing-its-bindings ()
  ;; A module loaded before a rebuild stays loaded, so it can lack a binding
  ;; this Lisp calls, such as the fit that redisplay calls.
  (dolist (missing '(portal--launcher-attach portal--launcher-prepare portal--launcher-fit))
    (let ((portal-launcher-mode nil) (portal-launcher--frame nil))
      (cl-letf (((symbol-function 'portal-launcher--check-support) #'ignore)
                ((symbol-function 'portal-view--load) #'ignore)
                ((symbol-function 'portal-launcher--check-guard) (lambda () (ert-fail "Reached the guard")))
                ((symbol-function 'portal--launcher-attach) #'ignore)
                ((symbol-function 'portal--launcher-prepare) #'ignore)
                ((symbol-function 'portal--launcher-fit) #'ignore))
        (fmakunbound missing)
        (should (string-prefix-p "Rebuild Portal"
                                 (cadr (should-error (portal-launcher-mode 1) :type 'user-error))))
        (should-not portal-launcher-mode)
        (should-not (advice-member-p #'portal-launcher--guard-parameters #'modify-frame-parameters))
        (should-not (memq #'portal-launcher--before-delete delete-frame-functions))))))

(ert-deftest portal-launcher-role-guard-is-atomic-and-scoped ()
  (let ((portal-launcher--frame (selected-frame)) passed)
    (dolist (change '((undecorated . nil) (fullscreen . fullboth) (parent-frame . other)
                      (tool-bar-lines . 1) (no-focus-on-map . nil) (minibuffer . nil)))
      (should-error
       (portal-launcher--guard-parameters
        (lambda (&rest _) (ert-fail "Mutated frame")) nil
        (list '(background-color . "red") change))
       :type 'user-error))
    (portal-launcher--guard-parameters
     (lambda (_frame parameters) (setq passed parameters)) nil
     '((parent-frame . nil) (undecorated . t) (font . "Menlo 18") (ns-appearance . dark)))
    (should (equal passed '((font . "Menlo 18") (ns-appearance . dark)))))
  (let ((portal-launcher--frame (selected-frame)) passed)
    (cl-letf (((symbol-function 'portal-launcher--kind) (lambda (_frame) 'minibuffer)))
      (should-error
       (portal-launcher--guard-parameters
        (lambda (&rest _) (ert-fail "Mutated frame")) nil '((minibuffer . t)))
       :type 'user-error)
      (portal-launcher--guard-parameters
       (lambda (_frame parameters) (setq passed parameters)) nil
       '((minibuffer . only) (undecorated . t) (font . "Menlo 18"))))
    (should (equal passed '((font . "Menlo 18")))))
  ;; Each kind's role is the buffer role but for the minibuffer.
  (dolist (kind '(minibuffer minibuffer buffer))
    (should (equal (assq-delete-all 'minibuffer (copy-alist (portal-launcher--frame-role kind)))
                   (assq-delete-all 'minibuffer (copy-alist portal-launcher--role)))))
  (should (equal (assq 'minibuffer (portal-launcher--frame-role 'minibuffer)) '(minibuffer . only)))
  (should (equal (assq 'minibuffer portal-launcher--role) '(minibuffer . t)))
  (let (portal-launcher--frame)
    (should (equal
             (portal-launcher--guard-parameters (lambda (_frame parameters) parameters)
                                                nil '((fullscreen . fullboth)))
             '((fullscreen . fullboth))))))

(ert-deftest portal-launcher-disable-removes-hooks-without-a-frame ()
  (let ((native-comp-enable-subr-trampolines nil))
    (unwind-protect
        (progn
          (portal-launcher--hooks t)
          (portal-launcher--hooks t)
          (portal-launcher-mode -1)
          (portal-launcher-mode -1)
          (should-not (memq #'portal-launcher--before-delete delete-frame-functions))
          (should-not (memq #'portal-launcher--shutdown kill-emacs-hook))
          (should-not (advice-member-p #'portal-launcher--guard-parameters #'modify-frame-parameters)))
      (portal-launcher--hooks nil))))

;; Global shortcuts with stand-ins for their native registrations.
(defmacro portal-launcher-test--shortcuts (&rest body)
  "Run BODY with global shortcuts whose native registrations are stand-ins.
NATIVE is an alist of the IDs and chords native code has registered."
  (declare (indent 0))
  `(let ((portal-global-shortcut--registrations nil)
         (portal-view-feature-record-handlers nil)
         (portal-view--pending "")
         (kill-emacs-hook nil)
         (unread-command-events nil)
         (native nil) (token 0))
     (cl-letf (((symbol-function 'portal-view--load) #'ignore)
               ((symbol-function 'portal--shortcut-chord) #'identity)
               ((symbol-function 'portal--shortcut-set)
                (lambda (replacing chord)
                  (setq native (cons (cons (cl-incf token) chord)
                                     (assq-delete-all replacing native)))
                  token))
               ((symbol-function 'portal--shortcut-remove)
                (lambda (id) (setq native (assq-delete-all id native)) t)))
       ,@body)))

(defun portal-launcher-test--press (name)
  "Send the record of a press of NAME's chord; return the event it queued."
  (portal-view--receive
   nil (format "shortcut %s\n" (cadr (assq name portal-global-shortcut--registrations))))
  (pop unread-command-events))

(defmacro portal-launcher-test--panel (&rest body)
  "Run BODY with the real enable and show paths, only native calls stubbed.
The selected frame stands in for the panel, and deleting it is a no-op."
  (declare (indent 0))
  `(let ((portal-launcher-mode nil)
         (portal-launcher--frame nil)
         (portal-launcher--session nil)
         (portal-launcher--return-window nil)
         (native-comp-enable-subr-trampolines nil))
     (cl-letf (((symbol-function 'portal-launcher--check-support) #'ignore)
               ((symbol-function 'portal-launcher--check-guard) #'ignore)
               ((symbol-function 'portal-view--load) #'ignore)
               ((symbol-function 'portal-launcher--create)
                (lambda (_kind) (setq portal-launcher--frame (selected-frame))))
               ((symbol-function 'portal--launcher-attach) #'ignore)
               ((symbol-function 'portal--launcher-prepare) #'ignore)
               ((symbol-function 'portal--launcher-show) #'ignore)
               ((symbol-function 'portal--launcher-fit) #'ignore)
               ((symbol-function 'portal--launcher-hide) #'ignore)
               ((symbol-function 'portal--launcher-detach) #'ignore)
               ((symbol-function 'portal--launcher-inspect) (lambda () '(:session 1)))
               ((symbol-function 'make-frame-invisible) #'ignore)
               ((symbol-function 'make-frame-visible) #'ignore)
               ((symbol-function 'delete-frame) #'ignore))
       (unwind-protect (progn ,@body)
         (portal-launcher--hooks nil)))))

(ert-deftest portal-launcher-enabling-and-presenting-claim-no-shortcut ()
  (portal-launcher-test--shortcuts
    (portal-global-shortcut-set 'other "other" #'ignore)
    (let ((registrations (copy-tree portal-global-shortcut--registrations))
          (before native))
      (cl-letf (((symbol-function 'portal-global-shortcut-set)
                 (lambda (&rest _) (ert-fail "Set a global shortcut"))))
        (portal-launcher-test--panel
          (portal-launcher-mode 1)
          (portal-launcher-mode 1)
          (should portal-launcher-mode)
          (portal-launcher-mode -1)
          ;; Presenting and showing enable the mode, which sets nothing.
          (should (eq 'value (portal-launcher-present (lambda () 'value) :kind 'minibuffer)))
          (should portal-launcher-mode)
          (should (eq 'command (portal-launcher-present #'portal-launcher-test--command)))
          (should (eq (portal-launcher-show (current-buffer)) (selected-frame)))
          (portal-launcher-hide)
          (should (equal registrations portal-global-shortcut--registrations))
          (should (equal before native))
          ;; Disabling and deleting the panel leave every shortcut set.
          (delete-frame portal-launcher--frame)
          (portal-launcher-mode -1)
          (portal-launcher-mode -1)
          (should-not portal-launcher-mode)
          (should (equal registrations portal-global-shortcut--registrations))
          (should (equal before native)))))))

(ert-deftest portal-launcher-failed-enable-keeps-a-live-panel-guarded ()
  (portal-launcher-test--panel
    (portal-launcher-show (current-buffer))
    (portal-launcher-hide)
    ;; Its frame must still detach on deletion, so its guards stay.
    (cl-letf (((symbol-function 'portal-launcher--check-guard)
               (lambda () (user-error "No trampoline"))))
      (should-error (portal-launcher-mode 1) :type 'user-error))
    (should portal-launcher-mode)
    (should (memq #'portal-launcher--before-delete delete-frame-functions))
    (portal-launcher-mode -1)
    (should-not (memq #'portal-launcher--before-delete delete-frame-functions))))

(ert-deftest portal-launcher-failed-deletion-keeps-the-mode ()
  (portal-launcher-test--panel
    (portal-launcher-mode 1)
    (let ((portal-launcher--frame (selected-frame)))
      (cl-letf (((symbol-function 'delete-frame) (lambda (&rest _) (error "Active minibuffer"))))
        (should-error (portal-launcher-mode -1)))
      (should portal-launcher-mode)
      (should (memq #'portal-launcher--before-delete delete-frame-functions)))))

(ert-deftest portal-launcher-command-validation-precedes-native-work ()
  (cl-letf (((symbol-function 'portal-launcher--show) (lambda (&rest _) (ert-fail "Presented invalid command")))
            ((symbol-function 'portal-launcher-cancel) (lambda () (ert-fail "Cancelled the session"))))
    ;; Portal has no default command: FUNCTION is required.
    (should-error (portal-launcher-present) :type 'wrong-number-of-arguments)
    (should-not (commandp #'portal-launcher-present))
    (dolist (command (list nil 'identity 42 "string" (lambda (_x) nil)))
      (should-error (portal-launcher-present command) :type 'user-error))
    ;; Invalid options, even with a valid function, change nothing; an active
    ;; session would be cancelled before anything is shown.
    (let ((portal-launcher--session (portal-launcher--make-session :tag (make-symbol "active"))))
      (dolist (options '((:kind) (:kind nil) (:kind window) (:kind minibuffer :mode-line)
                         (:mode-line none) (:mode-line 0) (:size 3) (minibuffer)
                         (:keep-open) (:keep-open 1) (:keep-open yes)
                         ;; Only a buffer panel can stay open.
                         (:kind minibuffer :keep-open t) (:keep-open t :kind minibuffer)))
        (should-error (apply #'portal-launcher-present #'ignore options) :type 'user-error))
      (should-error (portal-launcher-present (lambda (_x) nil) :kind 'minibuffer) :type 'user-error)
      ;; So do invalid settings, including an automatic buffer panel.
      (let ((portal-launcher-size '(720 auto)))
        (dolist (options '(() (:kind buffer) (:mode-line nil :keep-open t)))
          (should-error (apply #'portal-launcher-present #'ignore options) :type 'user-error)))
      (dolist (size '((720 99) (720 fit)))
        (let ((portal-launcher-size size))
          (should-error (portal-launcher-present #'ignore :kind 'minibuffer) :type 'user-error)))
      (let ((portal-launcher-offset '(0)))
        (should-error (portal-launcher-present #'ignore :kind 'minibuffer) :type 'user-error)))))

(ert-deftest portal-launcher-options-default-to-a-buffer-with-mode-lines ()
  (should (equal (portal-launcher--options nil) '(buffer t nil)))
  (should (equal (portal-launcher--options '(:kind minibuffer)) '(minibuffer t nil)))
  (should (equal (portal-launcher--options '(:mode-line nil :kind buffer)) '(buffer nil nil)))
  (should (equal (portal-launcher--options '(:kind minibuffer :mode-line nil)) '(minibuffer nil nil)))
  (should (equal (portal-launcher--options '(:keep-open t)) '(buffer t t)))
  (should (equal (portal-launcher--options '(:kind minibuffer :keep-open nil)) '(minibuffer t nil))))

(defmacro portal-launcher-test--session (&rest body)
  "Exercise real session unwinding with only the native frame stubbed."
  (declare (indent 0))
  `(let ((portal-launcher--frame (selected-frame))
         (native-comp-enable-subr-trampolines nil)
         (portal-launcher--session nil) (unread-command-events nil)
         (hidden nil) (shown nil) (session-id 10) (deleted 0) (disabled 0))
     (cl-letf (((symbol-function 'portal-launcher--show)
                (lambda (kind _buffer mode-line) (push (list kind mode-line) shown)))
               ((symbol-function 'portal--launcher-inspect) (lambda () (list :session session-id)))
               ((symbol-function 'portal--launcher-fit) #'ignore)
               ((symbol-function 'portal--launcher-hide) (lambda (&optional restore) (push restore hidden)))
               ((symbol-function 'make-frame-invisible) #'ignore)
               ((symbol-function 'delete-frame) (lambda (&rest _) (cl-incf deleted)))
               ((symbol-function 'portal-launcher--disable) (lambda () (cl-incf disabled))))
       ,@body)))

(ert-deftest portal-launcher-command-success-error-and-quit ()
  (portal-launcher-test--session
    (let ((old-rules display-buffer-alist)
          (old-maps emulation-mode-map-alists))
      (should (= 42 (portal-launcher-present (lambda () (interactive) 42))))
      (should (equal hidden '(nil)))
      (should-error (portal-launcher-present (lambda () (interactive) (error "Command failed"))))
      (should (equal hidden '(t nil)))
      (should-not (portal-launcher-present (lambda () (interactive) (signal 'quit nil))))
      (should (equal hidden '(t t nil)))
      (should (eq old-rules display-buffer-alist))
      (should (eq old-maps emulation-mode-map-alists))
      (should-not portal-launcher--session))))

(ert-deftest portal-launcher-calls-commands-and-functions ()
  (portal-launcher-test--session
    (should (eq 'value (portal-launcher-present (lambda () 'value))))
    (should (equal "*Portal Launcher*" (portal-launcher-present (lambda () (buffer-name)) :kind 'minibuffer)))
    ;; A command reads the caller's prefix argument; a plain function is not
    ;; called interactively.
    (let ((current-prefix-arg '(4)))
      (should (equal '(4) (portal-launcher-present (lambda (arg) (interactive "P") arg))))
      (should (equal '((4) nil) (portal-launcher-present
                               (lambda (&optional arg) (list current-prefix-arg arg))
                               :kind 'minibuffer))))
    (should (eq 'command (portal-launcher-present #'portal-launcher-test--command
                                                  :kind 'buffer :mode-line nil)))
    (should (equal shown '((buffer nil) (minibuffer t) (buffer t) (minibuffer t) (buffer t))))
    (should (equal hidden '(nil nil nil nil nil)))
    (should-not portal-launcher--session)))

(ert-deftest portal-launcher-loads-autoloads-to-check-arguments ()
  ;; An autoloaded function that is not a command is called at once, so it
  ;; is loaded to count its arguments before anything is shown or cancelled.
  (let* ((directory (make-temp-file "portal-launcher-lazy" t))
         (load-path (cons directory load-path)))
    (unwind-protect
        (progn
          (dolist (library '(("portal-launcher-test-lazy-1" . "(x) x")
                             ("portal-launcher-test-lazy-0" . "() 'lazy")))
            (with-temp-file (expand-file-name (concat (car library) ".el") directory)
              (insert ";;; -*- lexical-binding: t; -*-\n"
                      (format "(defun %s--run %s)\n(provide '%s)\n"
                              (car library) (cdr library) (car library))))
            (autoload (intern (concat (car library) "--run")) (car library)))
          (cl-letf (((symbol-function 'portal-launcher--show) (lambda (&rest _) (ert-fail "Presented")))
                    ((symbol-function 'portal-launcher-cancel) (lambda () (ert-fail "Cancelled"))))
            (let ((portal-launcher--session (portal-launcher--make-session :tag (make-symbol "active"))))
              (should-error (portal-launcher-present 'portal-launcher-test-lazy-1--run)
                            :type 'user-error)))
          (portal-launcher-test--session
            (should (autoloadp (symbol-function 'portal-launcher-test-lazy-0--run)))
            (should (eq 'lazy (portal-launcher-present 'portal-launcher-test-lazy-0--run)))))
      (dolist (name '(portal-launcher-test-lazy-1 portal-launcher-test-lazy-0))
        (fmakunbound (intern (format "%s--run" name)))
        (setq features (delq name features)))
      (delete-directory directory t))))

(defun portal-launcher-test--command ()
  (interactive)
  'command)

(ert-deftest portal-launcher-presentation-settings-are-scoped ()
  (portal-launcher-test--session
    (let ((resize-mini-frames 'user-setting)
          (window-buffer-change-functions (list #'ignore))
          (frame (selected-frame))
          (other (get-buffer-create " *launcher test*")))
      ;; A minibuffer presentation displays no buffer, here or elsewhere.
      ;; Emacs fits no panel itself: only an automatic one, through Portal.
      (pcase-dolist (`(,size ,fit) `((nil ,#'portal-launcher--fit) ((640 auto) ,#'portal-launcher--fit)
                                     ((720 240) nil)))
        (let ((portal-launcher-size size))
          (should (equal (list nil fit 1)
                         (portal-launcher-present
                          (lambda ()
                            (list (display-buffer other) resize-mini-frames
                                  (length (window-list frame 'never))))
                          :kind 'minibuffer)))))
      (should-not (portal-launcher-present (lambda () resize-mini-frames)))
      (should (eq resize-mini-frames 'user-setting))
      ;; An automatic panel also fits after commands, during its session.
      (pcase-dolist (`(,size ,kind ,refit) '((nil minibuffer t) ((720 240) minibuffer nil) (nil buffer nil)))
        (let ((portal-launcher-size size))
          (should (eq refit (portal-launcher-present
                             (lambda () (and (memq #'portal-launcher--refit (default-value 'post-command-hook)) t))
                             :kind kind)))))
      (should-not (memq #'portal-launcher--refit (default-value 'post-command-hook)))
      (should-not (get-buffer-window other t))
      ;; A buffer presentation hides new windows' mode lines through the
      ;; session's redisplay hook, then deletes them and clears the parameter.
      (should (equal '((none none) (portal-launcher--hide-mode-lines ignore))
                     (portal-launcher-present
                      (lambda ()
                        (let ((window (display-buffer other)))
                          (run-hook-with-args 'window-buffer-change-functions frame)
                          (list (mapcar (lambda (window) (window-parameter window 'mode-line-format))
                                        (list (selected-window) window))
                                window-buffer-change-functions)))
                      :mode-line nil)))
      (should (equal '(ignore) window-buffer-change-functions))
      (should (eq resize-mini-frames 'user-setting))
      (should (= 1 (length (window-list frame 'never))))
      (should-not (window-parameter (selected-window) 'mode-line-format))
      ;; With mode lines, the hook is absent and new windows still go.
      (should (equal '(nil (ignore))
                     (portal-launcher-present
                      (lambda ()
                        (list (window-parameter (display-buffer other) 'mode-line-format)
                              window-buffer-change-functions)))))
      (should (= 1 (length (window-list frame 'never))))
      ;; Errors and cancellation restore the same state.
      (dolist (ending (list (lambda () (error "Command failed")) (lambda () (signal 'quit nil))
                            #'portal-launcher-cancel))
        (ignore-errors
          (portal-launcher-present
           (lambda () (display-buffer other) (funcall ending)) :mode-line nil)))
      (should (equal '(ignore) window-buffer-change-functions))
      (should (= 1 (length (window-list frame 'never))))
      (should-not (window-parameter (selected-window) 'mode-line-format))
      ;; A window's own mode-line parameter outlasts either setting.
      (set-window-parameter (selected-window) 'mode-line-format '("custom"))
      (should (eq 'none (portal-launcher-present
                         (lambda ()
                           (run-hook-with-args 'window-buffer-change-functions frame)
                           (window-parameter (selected-window) 'mode-line-format))
                         :mode-line nil)))
      (should (equal '("custom") (window-parameter (selected-window) 'mode-line-format)))
      (should (equal '("custom") (portal-launcher-present
                                  (lambda () (window-parameter (selected-window) 'mode-line-format)))))
      (should (equal '("custom") (window-parameter (selected-window) 'mode-line-format)))
      (set-window-parameter (selected-window) 'mode-line-format nil)
      ;; A layout from before the call stays; only the call's windows go,
      ;; and a show that fails deletes nothing.
      (let ((kept (split-window)))
        (portal-launcher-present (lambda () (display-buffer other) (split-window)) :mode-line nil)
        (should (= 2 (length (window-list frame 'never))))
        (should (window-live-p kept))
        (cl-letf (((symbol-function 'portal-launcher--show) (lambda (&rest _) (error "Cannot present"))))
          (should-error (portal-launcher-present #'ignore)))
        (should (window-live-p kept))
        (should-not (window-parameter kept 'mode-line-format))
        (delete-window kept))
      (kill-buffer other))))

(ert-deftest portal-launcher-fit-asks-the-panel-only-for-new-heights ()
  ;; Emacs calls `resize-mini-frames' as it redisplays; the GUI suite
  ;; measures real content. Here the measurement is a stand-in.
  (portal-launcher-test--session
    (let ((frame (selected-frame))
          (other (get-buffer-create " *launcher test*"))
          (height 0) asked)
      (cl-letf (((symbol-function 'portal-launcher--fitted-height) (lambda (_frame) height))
                ((symbol-function 'portal--launcher-fit)
                 (lambda (session height) (push (list session height) asked))))
        (cl-flet ((fit (new) (setq height new) (funcall resize-mini-frames frame)))
          (portal-launcher-present
           (lambda ()
             ;; The first height, then only changes, go to this session's panel.
             (dolist (new '(100 100 164 164 100)) (fit new))
             ;; Another minibuffer-only frame is not the panel's.
             (setq height 300)
             (funcall resize-mini-frames 'another-frame)
             ;; An echo area message replaces the minibuffer's buffer in its
             ;; window while displayed; the input's height stays.
             (let* ((window (minibuffer-window frame)) (minibuffer (window-buffer window)))
               (set-window-buffer window other)
               (fit 300)
               (set-window-buffer window minibuffer))
             (fit 300))
           :kind 'minibuffer)
          (should (equal (reverse asked) '((10 100) (10 164) (10 100) (10 300))))
          ;; After the presentation, and in a fixed one, nothing fits; nor
          ;; does a session whose panel is gone.
          (setq asked nil)
          (portal-launcher--fit frame)
          (let ((portal-launcher--session (portal-launcher--make-session :fit t :native-id 10))
                (portal-launcher--frame nil))
            (portal-launcher--fit nil)
            (portal-launcher--refit))
          (let ((portal-launcher-size '(720 240)))
            (portal-launcher-present (lambda ()
                                       (should-not resize-mini-frames)
                                       (setq height 400)
                                       (portal-launcher--fit frame))
                                     :kind 'minibuffer))
          (should-not asked)))
      (kill-buffer other))))

(ert-deftest portal-launcher-automatic-panel-opens-at-its-measured-height ()
  (portal-launcher-test--panel
    (let (shown)
      (cl-letf (((symbol-function 'portal--launcher-show) (lambda (&rest args) (push args shown)))
                ((symbol-function 'portal-launcher--fitted-height) (lambda (_frame) 137)))
        (pcase-dolist (`(,size ,kind ,expected) '((nil minibuffer (720 137)) (nil buffer (720 420))
                                                  ((640 auto) minibuffer (640 137))
                                                  ((720 240) minibuffer (720 240))
                                                  ((720 240) buffer (720 240))))
          (let ((portal-launcher-size size))
            (portal-launcher-present #'ignore :kind kind)
            (should (equal (pop shown) (append expected '(0 0 -1 t 14))))))
        (let ((portal-launcher-offset '(-30 40)) (portal-launcher-screen 1))
          (portal-launcher-show)
          (should (equal (pop shown) '(720 420 -30 40 1 t 14))))
        ;; The option keeps its value; nothing replaced it with a height.
        (should-not portal-launcher-size)))))

(ert-deftest portal-launcher-resize-fixes-both-kinds-outside-minibuffer-panels ()
  (portal-launcher-test--panel
    (let (shown)
      (cl-letf (((symbol-function 'portal--launcher-show) (lambda (&rest args) (push (take 2 args) shown))))
        ;; Prompts offer the setting's numbers, or 720 by 420.
        (pcase-dolist (`(,size . ,defaults) '((nil 720 420) ((640 auto) 640 420) ((640 300) 640 300)))
          (let ((portal-launcher-size size) offered)
            (cl-letf (((symbol-function 'read-number)
                       (lambda (_prompt default) (push default offered) (+ default 10))))
              (call-interactively #'portal-launcher-resize))
            (should (equal (reverse offered) defaults))
            ;; Numbers fix both kinds, so minibuffer panels stop fitting.
            (should (equal portal-launcher-size (mapcar (lambda (n) (+ n 10)) defaults)))
            (should (equal (pop shown) portal-launcher-size))))
        ;; A minibuffer presentation's panel cannot become a buffer panel:
        ;; nothing changes, and the presentation goes on.
        (let ((portal-launcher-size '(640 auto)))
          (should (eq 'continued
                      (portal-launcher-present
                       (lambda ()
                         (cl-letf (((symbol-function 'portal-launcher--kind) (lambda (_frame) 'minibuffer))
                                   ((symbol-function 'read-number) (lambda (&rest _) (ert-fail "Prompted"))))
                           (should-error (portal-launcher-resize 700 300) :type 'user-error)
                           (should-error (call-interactively #'portal-launcher-resize) :type 'user-error))
                         'continued)
                       :kind 'minibuffer)))
          (should (equal shown '((640 100))))
          (should (equal portal-launcher-size '(640 auto))))))))

(ert-deftest portal-launcher-second-invocation-unwinds-the-command ()
  (portal-launcher-test--session
    (dolist (dismiss (list (lambda () (portal-launcher-present #'ignore))
                           #'portal-launcher-hide #'portal-launcher-cancel))
      (portal-launcher-present
       (lambda () (interactive) (funcall dismiss) (ert-fail "Command survived dismissal"))))
    (should (equal hidden '(t t t)))))

(ert-deftest portal-launcher-blur-is-queued-and-session-scoped ()
  (portal-launcher-test--session
    (portal-launcher-present
     (lambda ()
       (interactive)
       (dolist (value '(nil "9" "-10" "10x" "10\n")) (portal-launcher--queue-blur value))
       (portal-launcher--queue-blur "10" "extra")
       (should-not unread-command-events)
       (portal-launcher--queue-blur "10")
       (should (equal unread-command-events '((portal-launcher-blur 10))))
       (portal-launcher--blur '(portal-launcher-blur 9))
       (portal-launcher--blur (pop unread-command-events))
       (ert-fail "Command survived focus loss")))
    (should (equal hidden '(nil)))
    (cl-incf session-id)
    (should (eq 'new (portal-launcher-present
                     (lambda () (interactive) (portal-launcher--blur '(portal-launcher-blur 10)) 'new))))
    (portal-launcher--queue-blur "11")
    (should-not unread-command-events)))

(ert-deftest portal-launcher-session-defers-deletion-until-unwound ()
  (portal-launcher-test--session
    (portal-launcher-present
     (lambda ()
       (interactive)
       (portal-launcher--delete-frame (lambda (&rest _) (ert-fail "Deleted during command")))
       (ert-fail "Continued after delete request")))
    (should (= deleted 1))
    (should (= disabled 0))
    (should (equal hidden '(t)))))

(ert-deftest portal-launcher-show-failure-restores-session-bindings ()
  (portal-launcher-test--session
    (cl-letf (((symbol-function 'portal-launcher--show) (lambda (&rest _) (error "Cannot present"))))
      (should-error (portal-launcher-present (lambda () (interactive) (ert-fail "Ran without panel")))))
    (should-not portal-launcher--session)
    (should (equal hidden '(t)))))

(defvar portal-launcher-test--action #'ignore
  "Function that <f14> calls during `portal-launcher-test--type'.")

(defun portal-launcher-test--type (keys function &rest options)
  "Present FUNCTION with OPTIONS from a command loop, then read KEYS there.
KEYS, a `kbd' string, drive the panel's commands and prompts; <f14> calls
`portal-launcher-test--action'.  The end of the keyboard macro also leaves
a persistent panel's recursive edit, so a test cannot wait for input."
  (let ((map (make-sparse-keymap)) (global (current-global-map)))
    (set-keymap-parent map global)
    (keymap-set map "<f13>" (lambda ()
                              (interactive)
                              (throw 'portal-launcher-test--presented
                                     (apply #'portal-launcher-present function options))))
    (keymap-set map "<f14>" (lambda () (interactive) (funcall portal-launcher-test--action)))
    (use-global-map map)
    (unwind-protect
        (catch 'portal-launcher-test--presented
          (execute-kbd-macro (vconcat [f13] (kbd keys)))
          (ert-fail "The presentation did not return"))
      (use-global-map global))))

(defun portal-launcher-test--hello (&rest bindings)
  "Set up the hello-world UI, with local BINDINGS of (KEY . COMMAND).
Return its buffer, as setup functions may."
  (switch-to-buffer (get-buffer-create "*Portal launcher hello*"))
  (let ((inhibit-read-only t)) (erase-buffer) (insert "Hello world!"))
  (special-mode)
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (current-local-map))
    (keymap-set map "n" #'portal-launcher-test--greet)
    (pcase-dolist (`(,key . ,command) bindings) (keymap-set map key command))
    (use-local-map map))
  (current-buffer))

(defun portal-launcher-test--greet ()
  "Greet a name read from the minibuffer."
  (interactive)
  (let ((name (read-string "Name: ")) (inhibit-read-only t))
    (goto-char (point-max))
    (insert "\nHello " name "!")))

(defun portal-launcher-test--unwound (depth)
  "Check that a presentation left no session state, given the earlier DEPTH."
  (should-not portal-launcher--session)
  (should-not (active-minibuffer-window))
  (should (= depth (recursion-depth)))
  (should-not (memq #'portal-launcher--dismiss-if-blurred (default-value 'post-command-hook)))
  (should-not (memq #'portal-launcher--refit (default-value 'post-command-hook)))
  (should-not (memq #'portal-launcher--hide-mode-lines window-buffer-change-functions)))

;; Completion in a minibuffer panel, typed into a real minibuffer.  Portal
;; returns whatever the user's completion returns and adds no input policy;
;; the graphical suite types a representative few of these with native keys.

(declare-function vertico-mode "vertico" (&optional arg))
(declare-function marginalia-mode "marginalia" (&optional arg))
(defvar vertico-sort-function)

(defmacro portal-launcher-test--completion (enhanced &rest body)
  "Run BODY with stock completion, or Vertico, Orderless and Marginalia if
ENHANCED, as the launcher guide's completion setups configure them."
  (declare (indent 1))
  `(progn
     (require 'vertico)
     (require 'orderless)
     (require 'marginalia)
     (let ((completion-styles (if ,enhanced '(orderless basic) '(basic)))
           (completion-category-defaults nil)
           (vertico-sort-function #'identity)
           (minibuffer-history nil))
       (vertico-mode (if ,enhanced 1 -1))
       (marginalia-mode (if ,enhanced 1 -1))
       (unwind-protect (progn ,@body)
         (vertico-mode -1)
         (marginalia-mode -1)))))

(ert-deftest portal-launcher-completion-returns-what-completion-returns ()
  ;; With Vertico, Return accepts the highlighted candidate with no typed
  ;; text, the first or one chosen with arrows; stock completion highlights
  ;; nothing and returns "".  Text that matches nothing is returned as is.
  (portal-launcher-test--session
    (let ((reader completing-read-function)
          (window (selected-window))
          (picker (lambda () (completing-read "Pick: " '("Calculator" "Calendar" "Chess")))))
      (dolist (enhanced '(nil t))
        (portal-launcher-test--completion enhanced
          (cl-flet ((pick (keys) (portal-launcher-test--type keys picker :kind 'minibuffer)))
            (should (equal "Chess" (pick "C h e s s RET")))
            (should (equal "Notes" (pick "N o t e s RET")))
            (should (equal (if enhanced "Calculator" "") (pick "RET")))
            (when enhanced
              (should (equal "Calendar" (pick "<down> RET")))
              (should (equal "Calculator" (pick "<down> <up> RET"))))
            (should-not (pick "<escape>"))))
        (should (eq reader completing-read-function))
        (should (eq window (selected-window))))
      (should (equal (cl-remove-duplicates shown :test #'equal) '((minibuffer t)))))))

(ert-deftest portal-launcher-completion-stack-completes-commands ()
  ;; A command reader with category metadata, as M-x's: stock completion
  ;; matches the whole name and Orderless its words, in the panel's own
  ;; minibuffer; the call's display rules and keys go with it.
  (portal-launcher-test--session
    (dolist (enhanced '(nil t))
      (portal-launcher-test--completion enhanced
        (let ((rules display-buffer-alist)
              (maps emulation-mode-map-alists)
              (frames nil))
          (should
           (equal "forward-line"
                  (portal-launcher-test--type
                   (if enhanced "l i n e SPC f o r RET" "f o r w a r d - l i n e RET")
                   (lambda ()
                     (interactive)
                     (minibuffer-with-setup-hook
                         (lambda () (push (window-frame (active-minibuffer-window)) frames))
                       (completing-read
                        "Command: "
                        (lambda (string predicate action)
                          (if (eq action 'metadata) '(metadata (category . command))
                            (complete-with-action action '("forward-line" "forward-char")
                                                  string predicate)))
                        nil t)))
                   :kind 'minibuffer)))
          (should (equal frames (list portal-launcher--frame)))
          (should (eq rules display-buffer-alist))
          (should (eq maps emulation-mode-map-alists)))))))

(ert-deftest portal-launcher-completion-stock-list-shows-nowhere ()
  ;; Tab completes and Return accepts in a minibuffer panel, fixed or
  ;; fitting, but stock completion's *Completions* list shows nowhere.
  (portal-launcher-test--session
    (dolist (portal-launcher-size '((720 420) nil))
      (portal-launcher-test--completion nil
        (let ((windows (window-list nil t)) shown-lists)
          (should
           (equal "alpha"
                  (portal-launcher-test--type
                   "a TAB TAB h a RET"
                   (lambda ()
                     (minibuffer-with-setup-hook
                         (lambda ()
                           (add-hook 'post-command-hook
                                     (lambda ()
                                       (push (list (minibuffer-contents)
                                                   (get-buffer-window "*Completions*" t))
                                             shown-lists))
                                     90 t))
                       (completing-read "Pick: " '("alpha" "alps" "beta") nil t)))
                   :kind 'minibuffer)))
          (should (member '("alp" nil) shown-lists))
          (should-not (cl-some #'cadr shown-lists))
          (should (equal windows (window-list nil t))))))))

(ert-deftest portal-launcher-keep-open-runs-commands-until-dismissed ()
  (portal-launcher-test--session
    (let ((depth (recursion-depth))
          (rules display-buffer-alist)
          (maps emulation-mode-map-alists)
          inside)
      (unwind-protect
          (progn
            ;; The setup's buffer stays; a local command reads a name from
            ;; the panel's minibuffer, and a later one sees the session.
            (should-not
             (portal-launcher-test--type
              "n o k RET C-c p <escape>"
              (lambda ()
                (portal-launcher-test--hello
                 (cons "C-c p"
                       (lambda ()
                         (interactive)
                         (setq inside (list (and portal-launcher--session t) hidden
                                            (- (recursion-depth) depth) (buffer-string)
                                            (and (memq #'portal-launcher--hide-mode-lines
                                                       window-buffer-change-functions)
                                                 t)))))))
              :mode-line nil :keep-open t))
            (should (equal inside '(t nil 1 "Hello world!\nHello ok!" t)))
            ;; Escape cancelled, so focus may return to the previous app.
            (should (equal hidden '(t)))
            (portal-launcher-test--unwound depth)
            (should (eq rules display-buffer-alist))
            (should (eq maps emulation-mode-map-alists))
            ;; Hiding kills no buffer and keeps its contents.
            (should (equal "Hello world!\nHello ok!"
                           (with-current-buffer "*Portal launcher hello*" (buffer-string))))
            ;; Without :keep-open, the panel hides when the setup returns,
            ;; whose value is returned.
            (dolist (options '(nil (:keep-open nil)))
              (should (eq (get-buffer "*Portal launcher hello*")
                          (apply #'portal-launcher-present #'portal-launcher-test--hello options))))
            (should (equal hidden '(nil nil t)))
            (portal-launcher-test--unwound depth))
        (kill-buffer "*Portal launcher hello*")))))

(ert-deftest portal-launcher-keep-open-dismissal-unwinds-the-interaction ()
  (portal-launcher-test--session
    (let ((depth (recursion-depth)) (count 0))
      (unwind-protect
          (dolist (prompt '(nil t))
            (dolist (dismissal
                     `(("<escape>") ("C-g")
                       ("<f14>" . ,(lambda () (portal-launcher-present #'ignore)))
                       ("<f14>" . portal-launcher-hide)
                       ("<f14>" . portal-launcher-cancel)
                       ("<f14>" . ,(lambda ()
                                     (portal-launcher--delete-frame
                                      (lambda (&rest _) (ert-fail "Deleted during the session")))))
                       ;; In a prompt, these act on the prompt, as elsewhere.
                       ,@(unless prompt
                           '(("<f14>" . exit-recursive-edit) ("<f14>" . abort-recursive-edit)))))
              (let ((portal-launcher-test--action
                     (lambda () (funcall (cdr dismissal)) (ert-fail "The command survived dismissal"))))
                (should-not (portal-launcher-test--type
                             ;; A later command's prompt, with text typed in it.
                             (concat (if prompt "n a " "") (car dismissal))
                             #'portal-launcher-test--hello :keep-open t))
                (cl-incf count)
                (should (= count (length hidden)))
                (should (eq t (car hidden)))
                (portal-launcher-test--unwound depth)
                (should (equal "Hello world!"
                               (with-current-buffer "*Portal launcher hello*" (buffer-string)))))))
        (kill-buffer "*Portal launcher hello*"))
      (should (= deleted 2)))))

(ert-deftest portal-launcher-keep-open-survives-command-errors ()
  (portal-launcher-test--session
    (let ((depth (recursion-depth)) errors after)
      (unwind-protect
          (let ((command-error-function
                 (lambda (data &rest _)
                   ;; Batch Emacs's report would exit. Emacs's report also
                   ;; discards queued input; the person then types on.
                   (push data errors)
                   (discard-input)
                   (setq unread-command-events (listify-key-sequence (kbd "C-c p <escape>"))))))
            (should-not
             (portal-launcher-test--type
              "C-c e"
              (lambda ()
                (portal-launcher-test--hello
                 (cons "C-c e" (lambda () (interactive) (error "Later command failed")))
                 (cons "C-c p" (lambda () (interactive)
                                 (setq after (list (and portal-launcher--session t) hidden))))))
              :keep-open t))
            (should (equal errors '((error "Later command failed"))))
            (should (equal after '(t nil)))
            (should (equal hidden '(t)))
            (portal-launcher-test--unwound depth))
        (kill-buffer "*Portal launcher hello*")))))

(ert-deftest portal-launcher-keep-open-focus-loss-outlasts-error-reports ()
  ;; Focus loss queued while a command runs, then discarded by the command
  ;; loop's error report, still hides the panel, without restoring focus.
  (portal-launcher-test--session
    (let ((depth (recursion-depth))
          (minibuffer-message-timeout 0)
          (portal-launcher-test--action
           (lambda ()
             (portal-launcher--queue-blur "10")
             (should (equal unread-command-events '((portal-launcher-blur 10))))
             (error "Failed after focus loss")))
          reports)
      (unwind-protect
          (let ((command-error-function (lambda (data &rest _) (push data reports) (discard-input))))
            ;; In the buffer, then in a prompt, whose own error report
            ;; discards input as well.
            (dolist (keys '("<f14> <escape>" "n <f14> RET <escape>"))
              (should-not (portal-launcher-test--type keys #'portal-launcher-test--hello :keep-open t))
              (should-not (car hidden))
              (portal-launcher-test--unwound depth))
            (should (equal hidden '(nil nil)))
            (should (equal reports '((error "Failed after focus loss")))))
        (kill-buffer "*Portal launcher hello*")))))

(ert-deftest portal-launcher-keep-open-focus-loss-and-stale-events ()
  (portal-launcher-test--session
    (let ((depth (recursion-depth)) probed)
      (unwind-protect
          (cl-flet ((present (keys &optional setup)
                      (setq probed nil)
                      (portal-launcher-test--type
                       keys (lambda ()
                              (portal-launcher-test--hello
                               (cons "C-c p" (lambda () (interactive) (setq probed t))))
                              (when setup (funcall setup)))
                       :keep-open t)))
            ;; Focus lost while a command or the setup ran hides the panel
            ;; before it reads more input, without restoring focus. The
            ;; queued event, which the command loop would not read as a
            ;; special event once Lisp has finished, goes with the session.
            (let ((portal-launcher-test--action (lambda () (portal-launcher--queue-blur "10"))))
              (should-not (present "<f14> C-c p <escape>"))
              (should-not probed)
              (should-not unread-command-events))
            (should-not (present "C-c p <escape>" (lambda () (portal-launcher--queue-blur "10"))))
            (should-not probed)
            (should-not unread-command-events)
            ;; Without :keep-open, the function's value is still returned.
            (should (eq 'value (portal-launcher-present
                                (lambda () (portal-launcher--queue-blur "10") 'value))))
            (should-not unread-command-events)
            (should (equal hidden '(nil nil nil)))
            ;; A later presentation ignores focus loss reported for the
            ;; earlier one, as does the command loop once both are gone.
            (cl-incf session-id)
            (let ((portal-launcher-test--action (lambda () (portal-launcher--queue-blur "10"))))
              (should-not (present "<f14> C-c p <escape>"))
              (should probed)
              (should (equal hidden '(t nil nil nil))))
            (portal-launcher-test--unwound depth)
            (portal-launcher--queue-blur "11")
            (should-not unread-command-events))
        (kill-buffer "*Portal launcher hello*")))))

(ert-deftest portal-launcher-keep-open-setup-failure-is-recoverable ()
  (portal-launcher-test--session
    (let ((depth (recursion-depth)))
      (unwind-protect
          (progn
            (should (equal '(error "Setup failed")
                           (should-error
                            (portal-launcher-test--type
                             "<escape>"
                             (lambda () (portal-launcher-test--hello) (error "Setup failed"))
                             :mode-line nil :keep-open t))))
            (should (equal hidden '(t)))
            (portal-launcher-test--unwound depth)
            (should (equal "Hello world!"
                           (with-current-buffer "*Portal launcher hello*" (buffer-string))))
            ;; A new presentation works.
            (should-not (portal-launcher-test--type "n x RET <escape>" #'portal-launcher-test--hello
                                                    :keep-open t))
            (should (equal "Hello world!\nHello x!"
                           (with-current-buffer "*Portal launcher hello*" (buffer-string))))
            (should (equal hidden '(t t)))
            (portal-launcher-test--unwound depth))
        (kill-buffer "*Portal launcher hello*")))))

;; The launcher guide's user configuration composes launchers without launcher.el.
(defmacro portal-launcher-test--readme (examples &rest body)
  "Run BODY after loading the launcher guide's EXAMPLES, once with each binding.
A configuration file may or may not enable `lexical-binding', so the
examples load from a file with dynamic binding, then with lexical binding,
which LEXICAL names.  BODY runs in a test keymap, and MESSAGES returns what
was logged since loading."
  (declare (indent 1))
  `(dolist (lexical '(nil t))
     (portal-launcher-test--shortcuts
       (portal-launcher-test--session
         (let ((global (current-global-map))
               (map (make-sparse-keymap))
               (suggest-key-bindings nil)
               (extended-command-suggest-shorter nil)
               (start (with-current-buffer "*Messages*" (point-max))))
           (set-keymap-parent map global)
           (keymap-set map "<f14>" (lambda () (interactive) (funcall portal-launcher-test--action)))
           (use-global-map map)
           (cl-flet ((messages ()
                       (with-current-buffer "*Messages*"
                         (buffer-substring-no-properties start (point-max)))))
             (unwind-protect
                 (progn
                   (should (eq lexical (portal-launcher-examples-load ,examples lexical)))
                   ;; Emacs folds a message repeated from the run before.
                   (message "Launcher guide examples loaded with lexical-binding %s" lexical)
                   ,@body)
               (use-global-map global)
               (when (get-buffer "*Hello*") (kill-buffer "*Hello*")))))))))

(defconst portal-launcher-test--launchers
  '("launcher-picker" "launcher-hello" "launcher-shortcuts")
  "The launcher guide's examples that need no other package.")

(ert-deftest portal-launcher-readme-launchers-from-m-x-a-key-and-shortcuts ()
  (portal-launcher-test--readme portal-launcher-test--launchers
    (let ((depth (recursion-depth)))
      ;; Evaluating the configuration set exactly its three shortcuts.
      (should (equal (mapcar #'car portal-global-shortcut--registrations)
                     '(pick-fruit hello clock)))
      (should (= 3 (length native)))
      ;; One command, with its presentation options, from M-x, its key and
      ;; its global shortcut.
      (execute-kbd-macro (kbd "M-x my/pick-fruit RET Banana RET"))
      (execute-kbd-macro (kbd "C-c f Cherry RET"))
      (execute-kbd-macro (vconcat (vector (portal-launcher-test--press 'pick-fruit))
                                  (kbd "Apple RET")))
      (should (string-match-p "Picked Banana\nPicked Cherry\nPicked Apple" (messages)))
      (should (equal shown '((minibuffer t) (minibuffer t) (minibuffer t))))
      (should (equal hidden '(nil nil nil)))
      ;; The persistent buffer from its shortcut: its local command reads a
      ;; name, and the same chord again dismisses the panel.
      (let ((press (portal-launcher-test--press 'hello)))
        (execute-kbd-macro (vconcat (vector press) (kbd "n ok RET") (vector press))))
      (should (equal "Hello world!\nHello ok!" (with-current-buffer "*Hello*" (buffer-string))))
      (should (equal (car shown) '(buffer nil)))
      (should (eq t (car hidden)))
      ;; And from M-x, until Escape.
      (execute-kbd-macro (kbd "M-x my/hello RET n x RET <escape>"))
      (should (equal "Hello world!\nHello x!" (with-current-buffer "*Hello*" (buffer-string))))
      (portal-launcher-test--unwound depth)
      ;; A shortcut that presents nothing.
      (let ((presented (length shown)))
        (execute-kbd-macro (vector (portal-launcher-test--press 'clock)))
        (should (= presented (length shown)))
        (should (string-match-p "^[0-9][0-9]:[0-9][0-9]$" (car (last (split-string (messages) "\n" t))))))
      ;; Presenting set no shortcut of its own.
      (should (equal (mapcar #'car portal-global-shortcut--registrations)
                     '(pick-fruit hello clock)))
      (should (= 3 (length native))))))

(ert-deftest portal-launcher-readme-shortcuts-outlast-panels-and-reloads ()
  (portal-launcher-test--readme portal-launcher-test--launchers
    (let ((stale (portal-launcher-test--press 'pick-fruit))
          (chords (mapcar #'caddr portal-global-shortcut--registrations))
          (ids (mapcar #'cadr portal-global-shortcut--registrations)))
      ;; Dismissal and a deletion request leave the shortcuts set.
      (execute-kbd-macro (vconcat (vector (portal-launcher-test--press 'hello)) (kbd "<escape>")))
      (let ((portal-launcher-test--action
             (lambda () (portal-launcher--delete-frame (lambda (&rest _) (ert-fail "Deleted"))))))
        (execute-kbd-macro (vconcat (vector (portal-launcher-test--press 'hello)) (kbd "<f14>"))))
      (should (= deleted 1))
      (should (equal ids (mapcar #'cadr portal-global-shortcut--registrations)))
      ;; Evaluating the configuration again keeps one registration per name,
      ;; and a press from before it calls nothing.
      (portal-launcher-examples-load '("launcher-shortcuts") lexical)
      (should (equal chords (mapcar #'caddr portal-global-shortcut--registrations)))
      (should (= 3 (length native)))
      (should-not (cl-intersection ids (mapcar #'cadr portal-global-shortcut--registrations)))
      (let ((presented (length shown)))
        (execute-kbd-macro (vector stale))
        (should (= presented (length shown))))
      ;; Removing one leaves the others.
      (let ((hello (portal-launcher-test--press 'hello)))
        (should (portal-global-shortcut-remove 'hello))
        (should (equal (mapcar #'car portal-global-shortcut--registrations) '(pick-fruit clock)))
        (should (= 2 (length native)))
        (let ((presented (length shown)))
          (execute-kbd-macro (vector hello))
          (should (= presented (length shown)))))
      (execute-kbd-macro (vconcat (vector (portal-launcher-test--press 'pick-fruit)) (kbd "Apple RET")))
      (should (string-match-p "Picked Apple" (messages))))))

(defvar launcher-bangs)

(ert-deftest portal-launcher-readme-app-recipe-with-either-binding ()
  ;; launcher.el is absent here: a stand-in `launcher' reads one completion
  ;; result, as the tested revision does, and records it.  The recipe must
  ;; not depend on a closure, which dynamic binding would not make.
  (portal-launcher-test--readme '("launcher-app")
    (let ((launcher-bangs '(("!g" "Google" "g?q=%s") ("!gh" "GitHub" "gh?q=%s")))
          (reader completing-read-function)
          launched)
      (cl-letf (((symbol-function 'launcher)
                 (lambda (&optional refresh)
                   (interactive "P")
                   (push (list refresh (completing-read "Launch: " '("!g" "!gh" "Calculator")))
                         launched))))
        (execute-kbd-macro (kbd "M-x my/app-launcher RET Calculator RET"))
        ;; Stock completion's Space would complete "!gh"; here it inserts one.
        (execute-kbd-macro (kbd "M-x my/app-launcher RET !gh SPC portal RET"))
        ;; An empty or blank result and a bang with no query cancel.
        (dolist (keys '("RET" "SPC SPC RET" "!g RET" "!gh SPC RET"))
          (execute-kbd-macro (kbd (concat "M-x my/app-launcher RET " keys))))
        (execute-kbd-macro (kbd "C-u M-x my/app-launcher RET Calculator RET"))
        (execute-kbd-macro (vconcat (vector (portal-launcher-test--press 'app-launcher))
                                    (kbd "Calculator RET"))))
      (should (equal (reverse launched)
                     '((nil "Calculator") (nil "!gh portal") ((4) "Calculator") (nil "Calculator"))))
      ;; Cancellation may return focus to the previous app; success does not.
      (should (equal (reverse hidden) '(nil nil t t t t nil nil)))
      (should (equal shown (make-list 8 '(minibuffer t))))
      (should (eq reader completing-read-function)))))

(ert-deftest portal-launcher-shutdown-preserves-exit-and-later-hooks ()
  ;; A real kill-emacs in another process catches nonlocal exits that a
  ;; mocked kill-emacs or an isolated run-hooks would miss.
  (with-temp-buffer
    (let ((status
           (call-process
            (expand-file-name invocation-name invocation-directory) nil t nil
            "--batch" "-Q" "-L" (file-name-directory (locate-library "portal-launcher"))
            "--eval"
            (prin1-to-string
             '(progn
                (require 'portal-launcher)
                (require 'portal-global-shortcut)
                (let ((native-comp-enable-subr-trampolines nil)
                      (portal-launcher-mode t)
                      ;; A user's shortcut is not the launcher's to release.
                      (portal-global-shortcut--registrations
                       (list (list 'app-launcher 1 "Control-Option-Command-P" #'ignore)))
                      (portal-launcher--frame (selected-frame))
                      (frame (selected-frame))
                      (detached 0) (released 0) (deleted 0))
                  (cl-letf (((symbol-function 'portal-launcher--show) #'ignore)
                            ((symbol-function 'portal--launcher-inspect) (lambda () '(:session 1)))
                            ((symbol-function 'portal--launcher-hide) #'ignore)
                            ((symbol-function 'make-frame-invisible) #'ignore)
                            ((symbol-function 'portal--launcher-detach) (lambda () (cl-incf detached)))
                            ((symbol-function 'portal--shortcut-remove)
                             (lambda (id) (when (eql id 1) (cl-incf released))))
                            ((symbol-function 'delete-frame) (lambda (&rest _) (cl-incf deleted))))
                    (portal-launcher--hooks t)
                    (add-hook 'kill-emacs-hook
                              (lambda ()
                                (princ (format "later-hook: %S\n"
                                               (list detached released deleted
                                                     portal-launcher-mode
                                                     (length portal-global-shortcut--registrations)
                                                     (and (frame-live-p frame) t)))))
                              90)
                    (portal-launcher-present (lambda () (interactive) (kill-emacs 23)))
                    ;; Reaching here means the launcher swallowed shutdown.
                    (setq kill-emacs-hook nil)
                    (kill-emacs 99))))))))
      (should (= status 23))
      (should (string-match-p "later-hook: (1 0 0 nil 1 t)" (buffer-string))))))

(provide 'portal-launcher-tests)
