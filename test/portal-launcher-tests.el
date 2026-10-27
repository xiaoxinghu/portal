;;; portal-launcher-tests.el --- Launcher policy checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
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
    ;; Outside a presentation, a buffer panel cannot fit its content.
    (dolist (size '((199 420) (720 99) (720) (720 420 3) (720 . 420) (720 420.5) (720 auto)))
      (let ((portal-launcher-size size))
        (should-error (portal-launcher-show) :type 'user-error)))
    (let ((portal-launcher-offset '(0))) (should-error (portal-launcher-show) :type 'user-error))
    (let ((portal-launcher-height-limits '(200 100))) (should-error (portal-launcher-show) :type 'user-error))
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
  ;; (WIDTH auto) fits both kinds.
  (let ((portal-launcher-size '(640 auto)))
    (dolist (kind '(minibuffer buffer))
      (should (equal (portal-launcher--size kind) '(640 auto)))))
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
     (cl-letf (((symbol-function 'portal--shortcut-chord) #'identity)
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
      ;; So do invalid settings, for either kind.
      (dolist (size '((720 99) (720 fit) (199 auto)))
        (let ((portal-launcher-size size))
          (dolist (kind '(minibuffer buffer))
            (should-error (portal-launcher-present #'ignore :kind kind) :type 'user-error))))
      (let ((portal-launcher-offset '(0)))
        (should-error (portal-launcher-present #'ignore :kind 'minibuffer) :type 'user-error))
      ;; Height limits are checked for every presentation, fixed or not.
      (dolist (size '(nil (720 240)))
        (dolist (limits '((content 0) (300 200) (100)))
          (let ((portal-launcher-size size) (portal-launcher-height-limits limits))
            (dolist (kind '(minibuffer buffer))
              (should-error (portal-launcher-present #'ignore :kind kind) :type 'user-error))))))))

(ert-deftest portal-launcher-height-limits-are-validated ()
  (should (equal (default-value 'portal-launcher-height-limits) '(100 nil)))
  (dolist (limits '((100 nil) (content nil) (content 480) (60 480) (480 480) (1 1) (content 1)))
    (let ((portal-launcher-height-limits limits))
      (should (equal (portal-launcher--height-limits) limits))))
  (dolist (limits '(nil 100 content (100) (100 nil 3) (100 . 200) (0 nil) (-1 nil) (content 0)
                    (content -5) (300 200) (101 100) (100.0 nil) (100 480.0) ("content" nil)
                    (fit nil) (100 auto) (nil nil) (content content) (100 t)
                    (100000000000000000000000 nil) (content 100000000000000000000000)))
    (let ((portal-launcher-height-limits limits))
      (should-error (portal-launcher--height-limits) :type 'user-error)))
  ;; The option's type describes each valid setting.
  (require 'wid-edit)
  (let ((type (widget-convert (get 'portal-launcher-height-limits 'custom-type))))
    (dolist (value '((100 nil) (content nil) (content 480) (60 480)))
      (should (widget-apply type :match value)))
    (dolist (value '(nil (100 nil 3) (fit nil) (100 auto)))
      (should-not (widget-apply type :match value)))))

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
      ;; Nor a buffer panel's frame, whose minibuffer Emacs then resizes.
      (dolist (size '(nil (640 auto) (720 240)))
        (let ((portal-launcher-size size))
          (should-not (portal-launcher-present (lambda () resize-mini-frames)))))
      (should (eq resize-mini-frames 'user-setting))
      ;; An automatic panel also fits after commands, and an automatic
      ;; buffer panel as Emacs starts each redisplay, during the session.
      (pcase-dolist (`(,size ,kind ,refit ,redisplay)
                     '((nil minibuffer t nil) ((640 auto) minibuffer t nil) ((720 240) minibuffer nil nil)
                       (nil buffer nil nil) ((640 auto) buffer t t) ((720 240) buffer nil nil)))
        (let ((portal-launcher-size size))
          (should (equal (list refit redisplay)
                         (portal-launcher-present
                          (lambda ()
                            (list (and (memq #'portal-launcher--refit (default-value 'post-command-hook)) t)
                                  (and (advice-function-member-p #'portal-launcher--fit-on-redisplay
                                                                 (default-value 'pre-redisplay-function))
                                       t)))
                          :kind kind)))))
      (should-not (memq #'portal-launcher--refit (default-value 'post-command-hook)))
      (should-not (advice-function-member-p #'portal-launcher--fit-on-redisplay (default-value 'pre-redisplay-function)))
      ;; An automatic presentation keeps the height limits in effect as it
      ;; started, a `let' binding included; a fixed one has none.
      (pcase-dolist (`(,size ,limits ,kept) '((nil (100 nil) (100 nil)) (nil (content 300) (content 300))
                                              ((640 auto) (80 nil) (80 nil)) ((720 240) (content 300) nil)))
        (cl-letf (((symbol-function 'portal-launcher--candidate-legal-height) (lambda (&rest _) 60))
                  (portal-launcher-size size) (portal-launcher-height-limits limits))
          (should (equal kept (portal-launcher-present
                               (lambda ()
                                 (let ((portal-launcher-height-limits '(1 1)))
                                   (portal-launcher--session-limits portal-launcher--session)))
                               :kind 'minibuffer)))
          (should (equal limits portal-launcher-height-limits))))
      (should (equal '(100 nil) portal-launcher-height-limits))
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
      (cl-letf (((symbol-function 'portal-launcher--kind) (lambda (_frame) 'minibuffer))
                ((symbol-function 'portal-launcher--fitted-height) (lambda (&rest _) height))
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
          (let ((portal-launcher--session (portal-launcher--make-session :limits '(100 nil) :native-id 10))
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

(ert-deftest portal-launcher-redisplay-observer-uses-the-global-value ()
  ;; A buffer with its own `pre-redisplay-function', current as the
  ;; presentation starts or as it ends, neither gets the observer nor keeps
  ;; it from the global value, which keeps it only during the presentation.
  (portal-launcher-test--session
    (let ((portal-launcher-size '(640 auto))
          (local (generate-new-buffer " *launcher local redisplay*"))
          (caller (generate-new-buffer " *launcher caller*"))
          seen)
      (cl-flet ((installed ()
                  (and (advice-function-member-p #'portal-launcher--fit-on-redisplay
                                                 (default-value 'pre-redisplay-function))
                       t)))
        (unwind-protect
            (progn
              (with-current-buffer local (setq-local pre-redisplay-function #'ignore))
              ;; Started from the buffer with its own value.
              (with-current-buffer local
                (portal-launcher-present
                 (lambda ()
                   (push (list (installed) (buffer-local-value 'pre-redisplay-function local)) seen))))
              ;; Ended in a buffer that got its own value meanwhile.
              (with-current-buffer caller
                (portal-launcher-present
                 (lambda ()
                   (with-current-buffer caller (setq-local pre-redisplay-function #'ignore))
                   (push (list (installed) (buffer-local-value 'pre-redisplay-function caller)) seen))))
              (should (equal seen '((t ignore) (t ignore))))
              (should-not (installed))
              (dolist (buffer (list local caller))
                (should (eq #'ignore (buffer-local-value 'pre-redisplay-function buffer)))))
          (kill-buffer local)
          (kill-buffer caller))))))

(ert-deftest portal-launcher-buffer-fit-follows-redisplay ()
  ;; An automatic buffer panel fits as Emacs starts each redisplay, which
  ;; may change only its minibuffer, measuring no further than the maximum.
  ;; The measurement is a stand-in; the GUI suite measures real content.
  (portal-launcher-test--session
    (let ((frame (selected-frame))
          (other (get-buffer-create " *launcher test*"))
          (portal-launcher-size '(640 auto))
          (height 0) asked limits)
      (cl-letf (((symbol-function 'portal-launcher--kind) (lambda (_frame) 'buffer))
                ((symbol-function 'portal-launcher--legal-height) (lambda (_frame) 60))
                ((symbol-function 'portal-launcher--candidate-legal-height) (lambda (&rest _) 60))
                ((symbol-function 'portal-launcher--fitted-height)
                 (lambda (_frame max) (push max limits) height))
                ((symbol-function 'portal--launcher-fit)
                 (lambda (session height) (push (list session height) asked))))
        (cl-flet ((before-redisplay (new windows)
                    (setq height new)
                    (funcall pre-redisplay-function windows)))
          (let ((portal-launcher-height-limits '(content 480)))
            (portal-launcher-present
             (lambda ()
               (let ((mini (minibuffer-window frame)))
                 ;; Whichever windows Emacs redisplays, the panel is measured
                 ;; once: Emacs lists no minibuffer window, whose echo area
                 ;; message may have changed.
                 (before-redisplay 120 t)
                 (before-redisplay 150 nil)
                 (before-redisplay 200 (list 'other-window))
                 ;; An echo area message keeps no buffer panel from fitting.
                 (let ((minibuffer (window-buffer mini)))
                   (set-window-buffer mini other)
                   (before-redisplay 260 t)
                   (set-window-buffer mini minibuffer))
                 ;; Unchanged heights ask nothing; the maximum caps.
                 (before-redisplay 260 t)
                 (before-redisplay 5000 t)
                 ;; A hidden panel is not measured.
                 (cl-letf (((symbol-function 'frame-visible-p) #'ignore))
                   (before-redisplay 300 t))))))
          (should (equal (reverse asked) '((10 120) (10 150) (10 200) (10 260) (10 480))))
          (should (equal limits (make-list 6 480)))
          ;; Nothing fits after the presentation, or in a fixed one.
          (setq asked nil)
          (should-not (advice-function-member-p #'portal-launcher--fit-on-redisplay (default-value 'pre-redisplay-function)))
          (portal-launcher--fit-on-redisplay t)
          (let ((portal-launcher-size '(720 240)))
            (portal-launcher-present (lambda () (portal-launcher--fit-on-redisplay t))))
          (should-not asked)))
      (kill-buffer other))))

(ert-deftest portal-launcher-height-requests-are-bounded-and-session-bound ()
  ;; The frame's legal height is a stand-in here; the GUI suite measures
  ;; real frames.
  (portal-launcher-test--session
    (let ((legal 60) asked)
      (cl-letf (((symbol-function 'portal-launcher--legal-height) (lambda (_frame) legal))
                ((symbol-function 'portal-launcher--candidate-legal-height) (lambda (&rest _) legal))
                ((symbol-function 'portal--launcher-fit)
                 (lambda (session height) (push (list session height) asked))))
        (cl-flet ((heights (limits requests)
                    ;; REQUESTS are content heights, or functions to call.
                    (setq asked nil)
                    (let ((portal-launcher-height-limits limits))
                      (portal-launcher-present
                       (lambda ()
                         (dolist (request requests)
                           (if (functionp request)
                               (funcall request)
                             (portal-launcher--request-height portal-launcher--session request))))
                       :kind 'minibuffer))
                    (mapcar #'cadr (reverse asked))))
          ;; The default keeps the 100-point minimum and no maximum but
          ;; the screen's, which the native panel applies.
          (should (equal (heights '(100 nil) '(40 100 164 2000)) '(100 164 2000)))
          ;; `content' allows the frame's legal height, and no less; so does
          ;; a numeric minimum below it. Unchanged heights ask nothing.
          (should (equal (heights '(content nil) '(40 60 75 1)) '(60 75 60)))
          (should (equal (heights '(50 nil) '(1 80)) '(60 80)))
          (should (equal (heights '(80 nil) '(1 90 79)) '(80 90 80)))
          ;; The maximum caps content.
          (should (equal (heights '(content 150) '(40 149 150 151 4000 100)) '(60 149 150 100)))
          ;; A legal height that grows past the maximum, as with a larger
          ;; font, wins over it.
          (should (equal (heights '(content 150)
                                  (list 100 (lambda () (setq legal 200)) 100 4000
                                        (lambda () (setq legal 60)) 4000))
                         '(100 200 150)))
          (should (equal '(100 nil) portal-launcher-height-limits))
          ;; Only the current presentation's automatic, visible panel
          ;; answers: not a finished one's requester, such as a timer.
          (setq asked nil)
          (let (old)
            (let ((portal-launcher-height-limits '(content nil)))
              (portal-launcher-present (lambda () (setq old portal-launcher--session)) :kind 'minibuffer)
              (portal-launcher--request-height old 80)
              (cl-incf session-id)
              (portal-launcher-present
               (lambda ()
                 (portal-launcher--request-height old 90)
                 (cl-letf (((symbol-function 'frame-visible-p) #'ignore))
                   (portal-launcher--request-height portal-launcher--session 85))
                 (portal-launcher--request-height portal-launcher--session 95))
               :kind 'minibuffer))
            (let ((portal-launcher-size '(720 240)))
              (portal-launcher-present
               (lambda () (portal-launcher--request-height portal-launcher--session 300))
               :kind 'minibuffer)))
          (should (equal asked '((11 95)))))))))

(ert-deftest portal-launcher-legal-height-follows-the-frames-windows ()
  ;; In batch Emacs, a frame's pixels are its lines, without borders.
  ;; Each window needs a line of text and its mode and header lines, and
  ;; `window-min-height' lines; the minibuffer, a line.
  (save-window-excursion
    (let ((frame (selected-frame)) (buffer (generate-new-buffer " *launcher legal*")))
      (unwind-protect
          (progn
            (delete-other-windows)
            (let ((window-min-height 1))
              (should (= 3 (portal-launcher--legal-height frame)))
              (split-window)
              (should (= 5 (portal-launcher--legal-height frame)))
              (with-current-buffer buffer (setq header-line-format "Header"))
              (set-window-buffer (selected-window) buffer)
              (should (= 6 (portal-launcher--legal-height frame))))
            ;; Emacs's default of 4 lines, which its Lisp resizing of the
            ;; minibuffer assumes, wins over that.
            (should (= 4 (default-value 'window-min-height)))
            (should (= 9 (portal-launcher--legal-height frame)))
            (delete-other-windows)
            (should (= 5 (portal-launcher--legal-height frame)))
            (let ((window-min-height 6))
              (should (= 7 (portal-launcher--legal-height frame))))
            ;; Emacs keeps a frame as tall as its min-height parameter asks.
            (set-frame-parameter frame 'min-height 10)
            (should (= 10 (portal-launcher--legal-height frame))))
        (set-frame-parameter frame 'min-height nil)
        (kill-buffer buffer)))))

(ert-deftest portal-launcher-legal-height-keeps-the-minibuffer-resizable ()
  ;; Emacs's Lisp resizing of the minibuffer window, as Vertico grows its
  ;; candidates, computes a negative height when the root window is below
  ;; its least height, honoring `window-min-height'. A frame at its legal
  ;; height never is: there, resizing works.
  (save-window-excursion
    (delete-other-windows)
    (let ((frame (selected-frame)) (mini (minibuffer-window)))
      (cl-flet ((resize (delta)
                  (condition-case error
                      (progn (window-resize mini delta) (window-total-height mini))
                    (error (car error)))))
        ;; The prototype's failure: the root window below its least height.
        (let ((window-min-height 30))
          (should (< (window-total-height (frame-root-window frame)) 30))
          (should (eq 'args-out-of-range (resize 0)))
          (should (eq 'args-out-of-range (resize 1))))
        ;; With the root at least that tall, no resize fails.
        (let ((window-min-height (- (window-total-height (frame-root-window frame)) 1)))
          (should (<= (portal-launcher--legal-height frame) (frame-pixel-height frame)))
          (should (= 2 (resize 1)))
          (should (= 1 (resize -1))))))))

(ert-deftest portal-launcher-buffer-height-measures-the-window-and-minibuffer ()
  ;; In batch Emacs, a frame's pixels are its lines. The GUI suite
  ;; measures fonts, faces and borders.
  (save-window-excursion
    (delete-other-windows)
    (let* ((frame (selected-frame)) (window (selected-window)) (mini (minibuffer-window))
           (buffer (generate-new-buffer " *launcher fit*"))
           (window-min-height 1)
           ;; The frame's other rows, such as a menu bar here, count once.
           (rows (- (frame-pixel-height frame) (window-pixel-height window) (window-pixel-height mini)))
           (prompt nil))
      (cl-flet ((height (&optional max)
                  (when-let* ((height (portal-launcher--buffer-height frame (or max 1000))))
                    (- height rows)))
                (fill (text) (with-current-buffer buffer (erase-buffer) (insert text) (goto-char (point-min)))))
        (unwind-protect
            (progn
              (set-window-buffer window buffer)
              ;; A text line and the mode line, the minibuffer's line.
              (should (= 3 (height)))
              (fill "1\n2\n3\n4\n5\n6\n7\n8\n9\n10")
              (should (= 12 (height)))
              ;; A final newline adds the empty line where point can be.
              (fill "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
              (should (= 13 (height)))
              ;; Wherever the window is scrolled, and wherever point is.
              (set-window-start window (with-current-buffer buffer (- (point-max) 3)))
              (with-current-buffer buffer (goto-char (point-max)))
              (set-window-point window (with-current-buffer buffer (point-max)))
              (should (= 13 (height)))
              (should (= (window-start window) (with-current-buffer buffer (- (point-max) 3))))
              ;; Lines wrap at the window's width.
              (fill (make-string (+ (window-body-width window) 10) ?w))
              (should (= 4 (height)))
              (with-current-buffer buffer (setq-local truncate-lines t))
              (should (= 3 (height)))
              (with-current-buffer buffer (kill-local-variable 'truncate-lines))
              ;; Overlay strings at the end count, as a stream or completion
              ;; UI might show them.
              (fill "Prompt")
              (let ((overlay (with-current-buffer buffer (make-overlay (point-max) (point-max)))))
                (overlay-put overlay 'after-string "\nOne\nTwo\nThree")
                (should (= 6 (height)))
                (overlay-put overlay 'after-string nil)
                (overlay-put overlay 'before-string "\nOne\nTwo")
                (should (= 5 (height)))
                (delete-overlay overlay))
              ;; Header lines count; a hidden mode line does not.
              (with-current-buffer buffer (setq-local header-line-format "Header"))
              (should (= 4 (height)))
              (set-window-parameter window 'mode-line-format 'none)
              (should (= 3 (height)))
              (with-current-buffer buffer (kill-local-variable 'header-line-format))
              (should (= 2 (height)))
              (set-window-parameter window 'mode-line-format nil)
              ;; A long buffer is measured to MAX only.
              (fill (mapconcat #'number-to-string (number-sequence 1 100000) "\n"))
              (let ((start (float-time)))
                (should (= 8 (height 6)))
                (should (< (- (float-time) start) 0.05)))
              ;; The window never counts below its least height, which
              ;; honors `window-min-height'.
              (fill "One line")
              (should (= 3 (height)))
              (let ((window-min-height 4))
                (should (= 5 (height))))
              ;; The minibuffer counts as its line, to which Emacs resets it
              ;; as the frame resizes, whatever an echo area message grew
              ;; it to.
              (window-resize mini 2)
              (should (= 3 (height)))
              (window-resize mini -2)
              (should (= 3 (height)))
              ;; A prompt counts at least what it displays, once.
              (let ((map (make-sparse-keymap)) (global (current-global-map)))
                (set-keymap-parent map global)
                (keymap-set map "<f13>" (lambda () (interactive) (read-string "One\nTwo\nThree: ")))
                (keymap-set map "<f14>"
                            (lambda ()
                              (interactive)
                              (push (height) prompt)
                              (set-window-buffer window (window-buffer mini))
                              (push (height) prompt)
                              (set-window-buffer window buffer)))
                (use-global-map map)
                (unwind-protect (execute-kbd-macro (kbd "<f13> <f14> RET"))
                  (use-global-map global)))
              ;; 7 if the prompt counted twice.
              (should (equal (reverse prompt) '(5 5)))
              ;; Another ordinary window's layout is the caller's: the frame
              ;; keeps its height.
              (split-window)
              (should (= (height) (- (frame-pixel-height frame) rows))))
          (kill-buffer buffer))))))

(ert-deftest portal-launcher-buffer-panel-counts-lines-a-short-window-drops ()
  ;; Emacs drops the mode, header and tab lines of a window too short for
  ;; them and a text line, as `window-min-height' 1 allows. The fitted
  ;; height counts a line for each the window asks for, so the panel grows
  ;; to show them rather than staying that short.
  (save-window-excursion
    (delete-other-windows)
    (let* ((window-min-height 1)
           (buffer (generate-new-buffer " *launcher dropped*"))
           (window (selected-window))
           (other (split-window)))
      (unwind-protect
          (progn
            (set-window-buffer window buffer)
            (should (= 0 (portal-launcher--dropped-lines window)))
            (window-resize window (- 1 (window-total-height window)) nil 'safe)
            (should (= 1 (window-total-height window)))
            (should (= 0 (window-mode-line-height window)))
            (should (= 1 (portal-launcher--dropped-lines window)))
            (with-current-buffer buffer
              (setq-local header-line-format "Header" tab-line-format "Tabs"))
            (should (= 3 (portal-launcher--dropped-lines window)))
            ;; Hidden ones are not asked for.
            (set-window-parameter window 'mode-line-format 'none)
            (set-window-parameter window 'header-line-format 'none)
            (should (= 1 (portal-launcher--dropped-lines window)))
            ;; Tall enough, the window shows what it asks for.
            (set-window-parameter window 'mode-line-format nil)
            (set-window-parameter window 'header-line-format nil)
            (delete-window other)
            (should (> (window-mode-line-height window) 0))
            (should (= 0 (portal-launcher--dropped-lines window))))
        (kill-buffer buffer)))))

(ert-deftest portal-launcher-buffer-panel-shows-a-fitting-buffer-from-its-start ()
  ;; Emacs scrolls a window too short for point, as a panel can briefly be
  ;; before it grows; once all of the buffer fits, it shows from its
  ;; beginning again. A longer buffer, and point, stay as they are.
  (save-window-excursion
    (delete-other-windows)
    (let ((frame (selected-frame)) (window (selected-window))
          (buffer (generate-new-buffer " *launcher start*")))
      (unwind-protect
          (progn
            (set-window-buffer window buffer)
            (with-current-buffer buffer
              (insert (mapconcat #'number-to-string (number-sequence 1 5) "\n") "\n"))
            (set-window-point window 9)
            (set-window-start window 5)
            (portal-launcher--show-buffer-start frame)
            (should (= 1 (window-start window)))
            (should (= 9 (window-point window)))
            (with-current-buffer buffer
              (save-excursion
                (goto-char (point-max))
                (insert (mapconcat #'number-to-string (number-sequence 6 100) "\n"))))
            (set-window-start window 50)
            (portal-launcher--show-buffer-start frame)
            (should (= 50 (window-start window)))
            (should (= 9 (window-point window))))
        (kill-buffer buffer)))))

(ert-deftest portal-launcher-automatic-panel-opens-at-its-measured-height ()
  (portal-launcher-test--panel
    (let ((fitted 137) shown)
      (cl-letf (((symbol-function 'portal--launcher-show) (lambda (&rest args) (push args shown)))
                ((symbol-function 'portal-launcher--fitted-height) (lambda (&rest _) fitted))
                ((symbol-function 'portal-launcher--legal-height) (lambda (_frame) 60))
                ((symbol-function 'make-frame) (lambda (_parameters) 'candidate)))
        (pcase-dolist (`(,size ,kind ,expected) '((nil minibuffer (720 137)) (nil buffer (720 420))
                                                  ((640 auto) minibuffer (640 137))
                                                  ((640 auto) buffer (640 137))
                                                  ((720 240) minibuffer (720 240))
                                                  ((720 240) buffer (720 240))))
          (let ((portal-launcher-size size))
            (portal-launcher-present #'ignore :kind kind)
            (should (equal (pop shown) (append expected '(0 0 -1 t 14))))))
        (let ((portal-launcher-offset '(-30 40)) (portal-launcher-screen 1))
          (portal-launcher-show)
          (should (equal (pop shown) '(720 420 -30 40 1 t 14))))
        ;; The first automatic height is within the limits; numeric
        ;; heights ignore them.
        (pcase-dolist (`(,limits ,content ,size ,height)
                       '(((100 nil) 40 nil 100) ((content nil) 40 nil 60) ((content nil) 137 nil 137)
                         ((80 nil) 40 nil 80) ((content 120) 137 nil 120) ((content 120) 137 (640 auto) 120)
                         ((content 120) 137 (720 240) 240) ((content 50) 137 (720 240) 240)))
          (setq fitted content)
          (let ((portal-launcher-height-limits limits) (portal-launcher-size size))
            (portal-launcher-present #'ignore :kind 'minibuffer)
            (should (equal (take 2 (pop shown)) (list (if (eq (car size) 640) 640 720) height)))))
        ;; A maximum below the frame's legal height shows nothing.
        (dolist (limits '((content 59) (content 1) (1 1)))
          (let ((portal-launcher-height-limits limits))
            (should-error (portal-launcher-present #'ignore :kind 'minibuffer) :type 'user-error)))
        (should-not shown)
        (should-not portal-launcher--session)
        ;; The options keep their values; nothing replaced them with a height.
        (should-not portal-launcher-size)
        (should (equal '(100 nil) portal-launcher-height-limits))))))

(ert-deftest portal-launcher-maximum-is-checked-on-the-frame-to-show ()
  ;; Frames and legal heights are stand-ins here: a candidate frame is its
  ;; parameters, whose legal height is a 28-point line, as many as its
  ;; min-height, plus both borders. The GUI suite measures real frames.
  (let* ((portal-launcher--frame (selected-frame))
         (portal-launcher-font nil)
         (native-comp-enable-subr-trampolines nil)
         ;; The live minibuffer panel's own parameters, changed since it was
         ;; made with `portal-launcher-frame-parameters' (16-point borders).
         (live '((internal-border-width . 80) (min-height . nil)))
         (kind 'minibuffer)
         made deleted fonts)
    (cl-letf (((symbol-function 'portal-launcher--kind) (lambda (_frame) kind))
              ((symbol-function 'portal-launcher--check-support) #'ignore)
              ((symbol-function 'frame-parameter)
               (lambda (frame name)
                 (should (eq frame portal-launcher--frame))
                 (alist-get name live)))
              ((symbol-function 'make-frame) (lambda (parameters) (push parameters made) parameters))
              ((symbol-function 'delete-frame) (lambda (frame &rest _) (push frame deleted)))
              ((symbol-function 'set-frame-font)
               (lambda (font _keep-size frames inhibit-customize)
                 (push (list font (length frames) inhibit-customize) fonts)))
              ((symbol-function 'portal-launcher--legal-height)
               (lambda (frame)
                 (let ((parameters (if (consp frame) frame live)))
                   (+ (* 28 (max 1 (or (alist-get 'min-height parameters) 1)))
                      (* 2 (alist-get 'internal-border-width parameters)))))))
      ;; Without a maximum, nothing is measured.
      (portal-launcher--check-maximum 'minibuffer '(content nil) t)
      (portal-launcher--check-maximum 'minibuffer nil t)
      ;; A frame that presenting reuses unchanged is measured as it is: its
      ;; 80-point borders need 188 points.
      (portal-launcher--check-maximum 'minibuffer '(content 188) t)
      (should (equal '(user-error "Launcher maximum height 144 is below the legal height of its panel, 188 points")
                     (should-error (portal-launcher--check-maximum 'minibuffer '(content 144) t) :type 'user-error)))
      (should-not made)
      ;; With a font to apply, a hidden candidate stands in for the frame
      ;; presenting reuses: its own borders and min-height, not the initial
      ;; parameters, which would give 60 points; then it is deleted.
      (let ((portal-launcher-font "Menlo 24"))
        (should-error (portal-launcher--check-maximum 'minibuffer '(content 144) t) :type 'user-error)
        (portal-launcher--check-maximum 'minibuffer '(content 188) t)
        (setf (alist-get 'min-height live) 3)
        (should-error (portal-launcher--check-maximum 'minibuffer '(content 188) t) :type 'user-error)
        (portal-launcher--check-maximum 'minibuffer '(content 244) t))
      (should (= 4 (length made)))
      (dolist (parameters made)
        (should (eq 'only (alist-get 'minibuffer parameters)))
        (should-not (alist-get 'visibility parameters))
        (should (= 80 (alist-get 'internal-border-width parameters))))
      (should (equal (mapcar (lambda (parameters) (alist-get 'min-height parameters)) made) '(3 3 nil nil)))
      (should (equal deleted made))
      ;; Its font is applied without customizing the default face.
      (should (equal fonts (make-list 4 '("Menlo 24" 1 t))))
      ;; A frame of another kind is replaced: the candidate has the
      ;; parameters a presentation makes a frame with.
      (setq made nil deleted nil kind 'buffer)
      (portal-launcher--check-maximum 'minibuffer '(content 60) t)
      (should-error (portal-launcher--check-maximum 'minibuffer '(content 59) t) :type 'user-error)
      (should (equal made (make-list 2 (portal-launcher--parameters 'minibuffer))))
      (should (equal deleted made))
      ;; Unsupported builds make no frame; a failed measurement still
      ;; deletes its candidate.
      (setq made nil deleted nil)
      (cl-letf (((symbol-function 'portal-launcher--check-support) (lambda () (user-error "Unsupported"))))
        (should-error (portal-launcher--check-maximum 'minibuffer '(content 300) t) :type 'user-error))
      (should-not made)
      (cl-letf (((symbol-function 'portal-launcher--legal-height) (lambda (_frame) (error "Failed"))))
        (should-error (portal-launcher--check-maximum 'minibuffer '(content 300) t)))
      (should (equal deleted made)))))

(ert-deftest portal-launcher-buffer-maximum-is-checked-on-the-panel-to-show ()
  ;; A buffer panel's maximum is checked on a candidate set up as the
  ;; presentation first shows the live panel it reuses: that panel's font
  ;; and windows, which the presentation keeps, with its first buffer in
  ;; the selected window and the mode lines it asks for. The batch frame
  ;; stands in for the candidate here, its layout restored as the candidate
  ;; is deleted, and its legal height for Menlo 13's at `window-min-height'
  ;; 1: 15-point lines for each window's text, mode and header lines and
  ;; the minibuffer, and both 16-point borders. The GUI suite measures real
  ;; candidates.
  (save-window-excursion
    (delete-other-windows)
    (let* ((window (selected-window))
           (shown (generate-new-buffer " *launcher shown*"))
           (plain (generate-new-buffer " *launcher plain*"))
           (portal-launcher--frame (selected-frame))
           (portal-launcher-font nil)
           made measured layout)
      (with-current-buffer shown (setq-local header-line-format "Header"))
      (cl-flet ((check (max mode-line)
                  (condition-case error
                      (progn (portal-launcher--check-maximum 'buffer (list 'content max) mode-line) 'ok)
                    (user-error (cadr error)))))
        (cl-letf (((symbol-function 'portal-launcher--check-support) #'ignore)
                  ((symbol-function 'portal-launcher--kind) (lambda (_frame) 'buffer))
                  ;; A new frame has one window.
                  ((symbol-function 'make-frame)
                   (lambda (parameters)
                     (push parameters made)
                     (delete-other-windows (frame-first-window))
                     (selected-frame)))
                  ((symbol-function 'delete-frame)
                   (lambda (&rest _)
                     (set-window-configuration layout)
                     (dolist (window (window-list nil 'never))
                       (set-window-parameter window 'mode-line-format nil))))
                  ((symbol-function 'portal-launcher--legal-height)
                   (lambda (frame)
                     (let ((windows (window-list frame 'never (frame-first-window frame))))
                       (push (mapcar (lambda (window)
                                       (list (buffer-name (window-buffer window))
                                             (window-parameter window 'mode-line-format)))
                                     windows)
                             measured)
                       (+ 32 15 (* 15 (apply #'+ (mapcar
                                                   (lambda (window)
                                                     (+ 1 (if (eq (window-parameter window 'mode-line-format) 'none)
                                                              0 1)
                                                        (if (buffer-local-value 'header-line-format
                                                                                (window-buffer window))
                                                            1 0)))
                                                   windows))))))))
          (unwind-protect
              (progn
                ;; One window showing a buffer with a header line: 62 points
                ;; without the mode line, 77 with it, not the live panel's 92.
                (set-window-buffer window shown)
                (setq layout (current-window-configuration))
                (should (equal (list (check 70 nil) (check 61 nil) (check 70 t) (check 77 t))
                               '(ok "Launcher maximum height 61 is below the legal height of its panel, 62 points"
                                    "Launcher maximum height 70 is below the legal height of its panel, 77 points"
                                    ok)))
                (should (equal (reverse measured)
                               (append (make-list 2 (list (list portal-launcher--buffer 'none)))
                                       (make-list 2 (list (list portal-launcher--buffer nil))))))
                ;; The candidate has the live panel's font and room for its
                ;; windows.
                (dolist (parameters made)
                  (should (equal (alist-get 'font parameters) (frame-parameter nil 'font)))
                  (should (eql (alist-get 'height parameters) (frame-height))))
                ;; A split the live panel keeps: its selected window, the
                ;; lower one, shows the presentation's buffer, the other its
                ;; own with a header line, and both hide their mode lines
                ;; or neither.
                (setq window (split-window window))
                (set-window-buffer window plain)
                (select-window window)
                (setq layout (current-window-configuration) measured nil)
                (should (equal (list (check 92 nil) (check 91 nil) (check 121 t) (check 122 t))
                               '(ok "Launcher maximum height 91 is below the legal height of its panel, 92 points"
                                    "Launcher maximum height 121 is below the legal height of its panel, 122 points"
                                    ok)))
                (should (equal (reverse measured)
                               (append (make-list 2 (list (list (buffer-name shown) 'none)
                                                          (list portal-launcher--buffer 'none)))
                                       (make-list 2 (list (list (buffer-name shown) nil)
                                                          (list portal-launcher--buffer nil))))))
                ;; The live panel's windows, buffers and selection are as
                ;; they were.
                (should (eq (selected-window) window))
                (should (equal (mapcar #'window-buffer (window-list nil 'never (frame-first-window)))
                               (list shown plain)))
                (should-not (cl-some (lambda (window) (window-parameter window 'mode-line-format))
                                     (window-list nil 'never))))
            (kill-buffer shown)
            (kill-buffer plain)))))))

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

(ert-deftest portal-launcher-numeric-resize-stops-buffer-fitting ()
  ;; During an automatic buffer presentation, showing again with an
  ;; automatic size fits the new native session; a numeric resize fixes
  ;; the panel for the rest of the call. Outside a presentation, a buffer
  ;; panel cannot fit.
  (portal-launcher-test--panel
    (let ((portal-launcher-size '(640 auto)) (session-id 1) shown asked)
      (cl-letf (((symbol-function 'portal--launcher-show) (lambda (&rest args) (push (take 2 args) shown)))
                ((symbol-function 'portal--launcher-inspect) (lambda () (list :session session-id)))
                ((symbol-function 'portal--launcher-fit) (lambda (id height) (push (list id height) asked)))
                ((symbol-function 'portal-launcher--fitted-height) (lambda (&rest _) 150))
                ((symbol-function 'portal-launcher--legal-height) (lambda (_frame) 60)))
        (portal-launcher-present
         (lambda ()
           (portal-launcher--fit-on-redisplay t)
           (portal-launcher--request-height portal-launcher--session 200)
           (setq session-id 2)
           (portal-launcher-show)
           (portal-launcher--fit-on-redisplay t)
           (portal-launcher--request-height portal-launcher--session 220)
           (setq session-id 3)
           (portal-launcher-resize 700 300)
           (portal-launcher--request-height portal-launcher--session 240)
           (portal-launcher--fit-on-redisplay t)
           (should-not (portal-launcher--session-limits portal-launcher--session)))
         :kind 'buffer)
        (should (equal (reverse shown) '((640 150) (640 150) (700 300))))
        (should (equal (reverse asked) '((1 150) (1 200) (2 220))))
        (should (equal portal-launcher-size '(700 300)))
        (let ((portal-launcher-size '(640 auto)))
          (should (string-prefix-p "Only a presentation fits"
                                   (cadr (should-error (portal-launcher-show) :type 'user-error)))))
        (should (equal (length shown) 3))))))

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
  (should-not (advice-function-member-p #'portal-launcher--fit-on-redisplay (default-value 'pre-redisplay-function)))
  (should-not (memq #'portal-launcher--hide-mode-lines window-buffer-change-functions)))

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

;; Every kind of panel, dismissed every way, on the fake native module.  The
;; graphical suite keeps one row for each way that only the platform can
;; prove: a native key, the global shortcut's hot key and focus loss.
(defmacro portal-launcher-test--fake-panel (&rest body)
  "Run BODY with the real launcher, whose native calls go to the fake module.
ORDINARY is the selected window of a terminal frame, and panels are
terminal frames too: on the same terminal, whose prompts a keyboard macro
can type into.  The global shortcut `portal-launcher-test' presents a
launcher, as the guide's toggling chords do."
  (declare (indent 0))
  `(portal-launcher-test--shortcuts
     (portal-fake-native-with-frame frame
       ;; Nothing is drawn, so the terminal can take new frames.
       (let ((inhibit-redisplay t)
             (portal-launcher-mode nil)
             (portal-launcher--frame nil)
             (portal-launcher--session nil)
             (portal-launcher--return-window nil)
             (portal-launcher-frame-parameters
              (cons (cons 'terminal (frame-terminal frame)) portal-launcher-frame-parameters))
             (portal-launcher-size '(720 420))
             (native-comp-enable-subr-trampolines nil)
             (make-frame (symbol-function 'make-frame)))
         (resume-tty (frame-terminal frame))
         (portal-fake-native-reset)
         (select-frame frame)
         (cl-letf (((symbol-function 'portal-launcher--check-support) #'ignore)
                   ((symbol-function 'portal-launcher--check-guard) #'ignore)
                   ;; A terminal frame always has its own minibuffer, so the
                   ;; frame keeps the kind it was made for in a parameter.
                   ;; Making it sets the minibuffer parameter's cell to t,
                   ;; so it gets copies, not the launcher's constants.
                   ((symbol-function 'make-frame)
                    (lambda (&optional parameters)
                      (funcall make-frame
                               (cons (cons 'portal-launcher-test-kind
                                           (if (eq (alist-get 'minibuffer parameters) 'only)
                                               'minibuffer 'buffer))
                                     (copy-alist parameters)))))
                   ((symbol-function 'portal-launcher--kind)
                    (lambda (frame) (frame-parameter frame 'portal-launcher-test-kind))))
           (let ((ordinary (selected-window)))
             (unwind-protect
                 (progn
                   (portal-global-shortcut-set
                    'portal-launcher-test "test chord"
                    (lambda () (interactive) (portal-launcher-present #'ignore)))
                   ,@body)
               (portal-launcher-mode -1)
               (should-not (portal-fake-native-launcher-frame))
               (select-frame frame)
               (suspend-tty (frame-terminal frame)))))))))

(defun portal-launcher-test--dismissal (reason)
  "Return (KEYS . ACTION) that dismiss a presentation for REASON.
KEYS, for `portal-launcher-test--type', type Escape or C-g, or <f14>,
which calls ACTION."
  (pcase reason
    ('escape '("<escape>"))
    ('quit '("C-g"))
    (_ (cons "<f14>"
             (pcase reason
               ('second (lambda () (portal-launcher-present #'ignore)))
               ('shortcut
                (lambda ()
                  (portal-fake-native-send
                   (format "shortcut %d\n"
                           (cadr (assq 'portal-launcher-test portal-global-shortcut--registrations))))))
               ('hide #'portal-launcher-hide)
               ('cancel #'portal-launcher-cancel)
               ('delete (lambda () (delete-frame portal-launcher--frame t)))
               ('disable (lambda () (portal-launcher-mode -1)))
               ;; Another app, or another Emacs frame, takes the keyboard.
               ('blur #'portal-fake-native-launcher-blur)
               ;; A persistent panel's own recursive edit.
               ('exit #'exit-recursive-edit)
               ('abort #'abort-recursive-edit))))))

(defun portal-launcher-test--check-dismissed (reason frame)
  "Check that dismissing panel FRAME for REASON hid it as REASON should.
Only cancelling may give the previous app back its focus; deleting the
panel or disabling the mode also detaches it."
  (should-not (plist-get (portal--launcher-inspect) :visible))
  (should-not (plist-get (portal--launcher-inspect) :key))
  (should (equal (car (last (portal-fake-native-calls 'portal--launcher-hide)))
                 (list (not (memq reason '(blur no-input success))))))
  (should (eq (and (frame-live-p frame) t) (not (memq reason '(delete disable)))))
  (should (eq (portal-fake-native-launcher-frame) (and (frame-live-p frame) frame)))
  (should (eq portal-launcher-mode (not (eq reason 'disable)))))

(ert-deftest portal-launcher-nested-dismissal-and-reentry ()
  (portal-launcher-test--fake-panel
    (let ((depth (recursion-depth)))
      ;; A minibuffer panel at a fixed size, and fitting its content.
      (pcase-dolist (`(,kind ,portal-launcher-size) '((buffer (720 420)) (minibuffer (720 420)) (minibuffer nil)))
        (dolist (reason '(escape quit second shortcut hide cancel delete disable blur))
          (ert-info ((format "%S %S %S" kind portal-launcher-size reason))
            (let* ((dismissal (portal-launcher-test--dismissal reason))
                   (portal-launcher-test--action (cdr dismissal))
                   prompts continued)
              (setq portal-fake-native-log nil)
              (should-not
               (portal-launcher-test--type
                (car dismissal)
                (lambda ()
                  (interactive)
                  (cl-flet ((note () (push (list (window-frame (active-minibuffer-window))
                                                 (portal-fake-native-launcher-frame)
                                                 (portal-launcher--kind portal-launcher--frame))
                                           prompts)))
                    (minibuffer-with-setup-hook
                        (lambda ()
                          (note)
                          (minibuffer-with-setup-hook #'note
                            (completing-read "Inner: " '("alpha") nil t)))
                      (completing-read "Outer: " '("alpha") nil t)))
                  (setq continued t))
                :kind kind))
              (should-not continued)
              ;; Both prompts were in the attached panel made for KIND.
              (should (= (length prompts) 2))
              (should (equal (car prompts) (cadr prompts)))
              (pcase-let ((`(,frame ,attached ,made-for) (car prompts)))
                (should (eq frame attached))
                (should-not (eq frame (window-frame ordinary)))
                (should (eq made-for kind))
                (portal-launcher-test--check-dismissed reason frame))
              (should (eq ordinary (selected-window)))
              (portal-launcher-test--unwound depth)
              ;; Re-entry works, in a buffer panel even after a minibuffer one.
              (should (eq 'again (portal-launcher-present (lambda () (interactive) 'again))))
              (should (portal-launcher--live-p 'buffer))
              (should (eq portal-launcher--frame (portal-fake-native-launcher-frame)))
              (should (eq ordinary (selected-window))))))))))

(ert-deftest portal-launcher-keep-open-dismissal-and-reentry ()
  (portal-launcher-test--fake-panel
    (let ((depth (recursion-depth)))
      (unwind-protect
          (dolist (prompt '(nil t))
            (dolist (reason `(escape quit second shortcut hide cancel delete disable blur
                                     ;; In a prompt, these act on the prompt, as elsewhere.
                                     ,@(unless prompt '(exit abort))))
              (ert-info ((format "%S %S" (if prompt 'prompt 'buffer) reason))
                (let* ((dismissal (portal-launcher-test--dismissal reason))
                       (portal-launcher-test--action (cdr dismissal))
                       prompts frame)
                  (setq portal-fake-native-log nil)
                  (should-not
                   (portal-launcher-test--type
                    ;; A later command's prompt, with text typed in it.
                    (concat (if prompt "N a " "") (car dismissal))
                    (lambda ()
                      (setq frame (portal-fake-native-launcher-frame))
                      (portal-launcher-test--hello
                       (cons "N" (lambda ()
                                   (interactive)
                                   (minibuffer-with-setup-hook
                                       (lambda ()
                                         (push (eq (window-frame (active-minibuffer-window)) frame)
                                               prompts))
                                     (portal-launcher-test--greet))))))
                    :mode-line nil :keep-open t))
                  (should (framep frame))
                  (should (equal prompts (and prompt '(t))))
                  (portal-launcher-test--check-dismissed reason frame)
                  (portal-launcher-test--unwound depth)
                  (should (eq ordinary (selected-window)))
                  (should (equal "Hello world!"
                                 (with-current-buffer "*Portal launcher hello*" (buffer-string))))
                  (should (eq 'again (portal-launcher-present (lambda () (interactive) 'again))))
                  (should (eq ordinary (selected-window)))))))
        (kill-buffer "*Portal launcher hello*")))))

(ert-deftest portal-launcher-dismissal-hides-the-panel ()
  ;; Each way a presentation ends hides the panel and selects the window
  ;; it was presented from; only cancelling gives the previous app focus.
  (portal-launcher-test--fake-panel
    (let ((depth (recursion-depth)) (content (generate-new-buffer " *launcher content*")))
      (unwind-protect
          (progn
            (dolist (kind '(buffer minibuffer))
              (dolist (reason '(no-input success escape quit second shortcut hide blur))
                (ert-info ((format "%S %S" kind reason))
                  (let* ((dismissal (portal-launcher-test--dismissal reason))
                         (portal-launcher-test--action (cdr dismissal)))
                    (setq portal-fake-native-log nil)
                    (should (equal (pcase reason ('no-input 'done) ('success "ok"))
                                   (portal-launcher-test--type
                                    (pcase reason ('no-input "") ('success "o k RET") (_ (car dismissal)))
                                    (if (eq reason 'no-input) (lambda () 'done)
                                      (lambda () (interactive) (read-string "Focus: ")))
                                    :kind kind)))
                    (should (equal (portal-fake-native-calls 'portal--launcher-show)
                                   (list (list 720 420 0 0 -1 t 14))))
                    (portal-launcher-test--check-dismissed reason portal-launcher--frame)
                    (portal-launcher-test--unwound depth)
                    (should (eq ordinary (selected-window)))))))
            ;; An explicitly shown panel, hidden again.
            (setq portal-fake-native-log nil)
            (should (eq (portal-launcher-show content) (portal-fake-native-launcher-frame)))
            (should (plist-get (portal--launcher-inspect) :visible))
            (should (eq (selected-frame) portal-launcher--frame))
            (portal-launcher-hide)
            (should (equal (portal-fake-native-calls 'portal--launcher-hide) '((nil))))
            (should-not (plist-get (portal--launcher-inspect) :visible))
            (should (eq ordinary (selected-window))))
        (kill-buffer content)))))

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

(ert-deftest portal-launcher-too-small-maximum-leaves-presentations-alone ()
  ;; A maximum below the frame's legal height is invalid, found before an
  ;; existing presentation is cancelled, hidden or replaced. The candidate
  ;; frame and its legal height are stand-ins.
  (portal-launcher-test--panel
    (let ((content (generate-new-buffer " *launcher shown*"))
          (portal-launcher-test--action #'ignore)
          shown probes events)
      (cl-letf (((symbol-function 'portal--launcher-show) (lambda (&rest args) (push (take 2 args) shown)))
                ((symbol-function 'portal--launcher-hide) (lambda (&rest _) (push 'hide events)))
                ((symbol-function 'make-frame-invisible) (lambda (&rest _) (push 'invisible events)))
                ((symbol-function 'make-frame) (lambda (_parameters) 'candidate))
                ((symbol-function 'delete-frame) (lambda (frame &rest _) (push (list 'delete frame) events)))
                ((symbol-function 'portal-launcher--fitted-height) (lambda (&rest _) 137))
                ((symbol-function 'portal-launcher--legal-height) (lambda (_frame) 60)))
        (unwind-protect
            (progn
              ;; During a valid automatic presentation's prompt: the call
              ;; fails, and the prompt goes on in the same session, shown.
              (setq portal-launcher-test--action
                    (lambda ()
                      (let ((session portal-launcher--session) (before (list shown events)))
                        (dolist (limits '((content 1) (1 1) (50 59)))
                          (let ((portal-launcher-height-limits limits))
                            (should-error (portal-launcher-present #'ignore :kind 'minibuffer) :type 'user-error)))
                        (push (list (eq session portal-launcher--session) (minibuffer-contents)
                                    (equal before (list shown (cl-remove '(delete candidate) events :test #'equal))))
                              probes))))
              (should (equal "ab" (portal-launcher-test--type "a <f14> b RET"
                                                              (lambda () (read-string "Name: "))
                                                              :kind 'minibuffer)))
              (should (equal probes '((t "a" t))))
              (should (equal shown '((720 137))))
              ;; Then hidden as it returned, once.
              (should (equal (cl-remove-if (lambda (event) (equal event '(delete candidate))) events)
                             '(invisible hide)))
              ;; An explicitly shown buffer panel keeps its frame, window and
              ;; content, shown, after an invalid minibuffer presentation.
              (setq shown nil events nil)
              (with-current-buffer content (insert "Shown content"))
              (portal-launcher-show content)
              (let ((portal-launcher-height-limits '(content 1)))
                (should-error (portal-launcher-present #'ignore :kind 'minibuffer) :type 'user-error))
              (should (equal shown '((720 420))))
              (should (equal events '((delete candidate))))
              (should (eq (window-buffer (frame-selected-window portal-launcher--frame)) content))
              (should (equal "Shown content" (with-current-buffer content (buffer-string))))
              (should (eq (selected-frame) portal-launcher--frame)))
          (kill-buffer content))))))

(ert-deftest portal-launcher-too-small-maximum-checks-the-reused-frame ()
  ;; The live minibuffer panel's border became 80 points after it was made
  ;; with 16. Presenting reuses it, applying the launcher font, so the
  ;; preflight's candidate has that border: a 144-point maximum, enough for
  ;; the initial parameters' 60 points, is below its 188. Candidate frames
  ;; are their parameters here, and legal heights stand-ins.
  (portal-launcher-test--panel
    (let ((portal-launcher-font "Menlo 24")
          (original (symbol-function 'frame-parameter))
          shown events probes)
      (cl-letf (((symbol-function 'portal-launcher--kind) (lambda (_frame) 'minibuffer))
                ((symbol-function 'frame-parameter)
                 (lambda (frame name)
                   (if (and (eq frame portal-launcher--frame) (eq name 'internal-border-width))
                       80
                     (funcall original frame name))))
                ((symbol-function 'set-frame-font) #'ignore)
                ((symbol-function 'make-frame) (lambda (parameters) (push 'made events) parameters))
                ((symbol-function 'delete-frame) (lambda (frame &rest _) (push (if (consp frame) 'deleted frame) events)))
                ((symbol-function 'portal--launcher-show) (lambda (&rest args) (push (take 2 args) shown)))
                ((symbol-function 'portal--launcher-hide) (lambda (&rest _) (push 'hide events)))
                ((symbol-function 'make-frame-invisible) (lambda (&rest _) (push 'invisible events)))
                ((symbol-function 'portal-launcher--fitted-height) (lambda (&rest _) 137))
                ((symbol-function 'portal-launcher--legal-height)
                 (lambda (frame)
                   (+ 28 (* 2 (if (consp frame) (alist-get 'internal-border-width frame) 80))))))
        (portal-launcher-mode 1)
        (setq portal-launcher--frame (selected-frame))
        (cl-flet ((invalid ()
                    (condition-case error
                        (let ((portal-launcher-height-limits '(content 144)))
                          (portal-launcher-present #'ignore :kind 'minibuffer)
                          'presented)
                      (user-error (cadr error)))))
          ;; In a valid presentation's prompt, which then goes on.
          (let ((portal-launcher-test--action
                 (lambda ()
                   (let ((session portal-launcher--session) (before (list shown events)))
                     (push (list (invalid) (eq session portal-launcher--session) (minibuffer-contents)
                                 (equal (list shown (cl-set-difference events '(made deleted)))
                                        before))
                           probes)))))
            (should (equal "ab" (portal-launcher-test--type "a <f14> b RET"
                                                            (lambda () (read-string "Name: "))
                                                            :kind 'minibuffer))))
          (should (equal probes '(("Launcher maximum height 144 is below the legal height of its panel, 188 points"
                                   t "a" t))))
          (should (equal shown '((720 188))))
          ;; Without a session: nothing is shown, hidden or deleted.
          (setq events nil)
          (should (equal (invalid) "Launcher maximum height 144 is below the legal height of its panel, 188 points"))
          (should (equal events '(deleted made)))
          (should (equal shown '((720 188))))
          ;; A maximum the reused frame allows presents on it.
          (let ((portal-launcher-height-limits '(content 188)))
            (portal-launcher-present #'ignore :kind 'minibuffer))
          (should (equal shown '((720 188) (720 188))))
          (should-not (memq portal-launcher--frame events)))))))

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

(ert-deftest portal-launcher-readme-fitted-buffer ()
  ;; The guide's fitted hello panel fits the hello buffer, with its size
  ;; and limits for that call only.
  (portal-launcher-test--readme '("launcher-hello" "launcher-fitted-hello")
    (let ((depth (recursion-depth)) seen)
      (let ((portal-launcher-test--action
             (lambda ()
               (push (list (portal-launcher--session-limits portal-launcher--session)
                           (and (advice-function-member-p #'portal-launcher--fit-on-redisplay
                                                          (default-value 'pre-redisplay-function))
                                t))
                     seen))))
        ;; Batch Emacs makes no candidate frame; the GUI suite does.
        (cl-letf (((symbol-function 'portal-launcher--candidate-legal-height) (lambda (&rest _) 60)))
          (execute-kbd-macro (kbd "M-x my/hello-fitted RET n Ada RET <f14> <escape>"))))
      (should (equal seen '(((content 480) t))))
      (should (equal (car shown) '(buffer nil)))
      (should (equal "Hello world!\nHello Ada!" (with-current-buffer "*Hello*" (buffer-string))))
      (portal-launcher-test--unwound depth)
      (should-not portal-launcher-size)
      (should (equal portal-launcher-height-limits '(100 nil))))))

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
