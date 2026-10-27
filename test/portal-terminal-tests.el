;;; portal-terminal-tests.el --- Real native terminal checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'json)
(require 'portal-terminal)

;; Tests kill live shells without asking; the prompt has its own tests.
(setq portal-terminal-confirm-kill nil)
(declare-function portal--terminal-text "portal-terminal" (target))
(declare-function portal--terminal-paste "portal-terminal" (target text &optional enter))
(declare-function portal--inspect "portal-view" (target))
(declare-function portal--close "portal-view" (target))
(declare-function portal-test-native-key "test-terminal-input" (code flags text &optional windowless))
(declare-function portal-test-native-post-key "test-terminal-input" (code flags text &optional windowless))

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

(defconst portal-terminal-test--color-probe
  (expand-file-name "terminal-colors.py" (file-name-directory load-file-name)))

(defun portal-terminal-test--colors (id)
  "Query ID's actual colors and shell PID over its PTY."
  (let* ((directory (make-temp-file "portal-colors-" t))
         (receipt (expand-file-name "colors.json" directory)))
    (unwind-protect
        (progn
          (portal-terminal-test--paste
           (format "/usr/bin/python3 %s %s"
                   (shell-quote-argument portal-terminal-test--color-probe)
                   (shell-quote-argument receipt)) t id)
          (portal-terminal-test--wait (lambda () (file-exists-p receipt)))
          (with-temp-buffer
            (insert-file-contents receipt)
            (json-parse-buffer :object-type 'plist)))
      (delete-directory directory t))))

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

(ert-deftest portal-terminal-start-uses-shell-startup ()
  :tags '(:gui)
  (skip-unless (eq window-system 'ns))
  ;; test/terminal-shell-startup.sh launches a fresh native process with these
  ;; dotfiles. Lisp-side setenv cannot change the native parent's environment.
  (skip-unless (getenv "PORTAL_TEST_SHELL_DIRECTORY"))
  (let* ((directory (file-truename (make-temp-file "portal-shell-launch-" t)))
         (receipt (expand-file-name "receipt.json" directory))
         (process-environment (copy-sequence process-environment))
         (exec-path '("/usr/bin" "/bin"))
         (arguments '("implement @tasks/space ' é.md" "$(touch SHOULD_NOT_EXIST)" "`pwd`"
                      "" "a\\b" "line\nnext")))
    (unwind-protect
        (save-window-excursion
          (setenv "PATH" "/usr/bin:/bin")
          (setenv "PORTAL_LISP_ONLY" "must-not-be-exported")
          (setenv "PORTAL_SHELL_PROFILE" "wrong")
          (setenv "PORTAL_SHELL_RC" "wrong")
          (should-not (executable-find "portal-startup-cli"))
          (dolist (program (list "portal-startup-cli"
                                 (expand-file-name "tools/portal ' é\\tool" (getenv "PORTAL_TEST_SHELL_DIRECTORY"))))
            (let ((buffer (portal-terminal-start directory program (cons receipt arguments))))
              (unwind-protect
                  (progn
                    (portal-terminal-test--wait (lambda () (file-exists-p receipt)))
                    (let ((result (with-temp-buffer
                                    (insert-file-contents receipt)
                                    (json-parse-buffer :object-type 'plist :array-type 'list :null-object nil))))
                      (should (equal (plist-get result :args) arguments))
                      (should (equal (plist-get result :cwd) directory))
                      (should (equal (plist-get result :profile) "login-loaded"))
                      (should (equal (plist-get result :rc) "interactive-loaded"))
                      (should-not (plist-get result :lisp))
                      (should (equal (plist-get result :term) "xterm-ghostty"))
                      (should (equal (plist-get result :inside) "portal-ghostty")))
                    (should-not (file-exists-p (expand-file-name "SHOULD_NOT_EXIST" directory))))
                (kill-buffer buffer)
                (when (file-exists-p receipt) (delete-file receipt))))))
      (delete-directory directory t))))

(ert-deftest portal-terminal-start-missing-program-is-reported-in-terminal ()
  :tags '(:gui)
  (skip-unless (eq window-system 'ns))
  (save-window-excursion
    (let* ((buffer (portal-terminal-start temporary-file-directory "portal-no-such-program-4817" nil))
           (target (buffer-local-value 'portal-view--target buffer)))
      (unwind-protect
          (portal-terminal-test--wait
           (lambda () (string-search "portal-no-such-program-4817" (portal--terminal-text target))))
        (kill-buffer buffer)))))

(ert-deftest portal-terminal-theme-live-and-new-sessions ()
  :tags '(:gui)
  (skip-unless (eq window-system 'ns))
  (let ((original portal-terminal-theme))
    (unwind-protect
        (progn
          (setq portal-terminal-theme "Dracula")
          (portal-terminal-test--session
            (should (member "Dracula" (portal-terminal-themes)))
            ;; One color tells the themes apart; Ghostty owns the rest.
            (let* ((first (portal-view-target))
                   (initial (portal-terminal-test--colors first)))
              (should (equal (plist-get initial :background) "282a36"))
              ;; Hide the first shell, then recolor both existing sessions.
              (portal-terminal-new)
              (let ((second (portal-view-target)))
                (should-not (plist-get (portal-terminal-test--state first) :visible))
                (setopt portal-terminal-theme "Alabaster")
                (dolist (id (list second first))
                  (let ((colors (portal-terminal-test--colors id)))
                    (should (equal (plist-get colors :background) "f7f7f7"))
                    ;; The first shell survives its recoloring.
                    (when (equal id first)
                      (should (equal (plist-get colors :pid) (plist-get initial :pid))))))
                ;; The native catalog refuses a name it lacks.
                (should-error (setq portal-terminal-theme "No such Portal theme"))
                (should (equal portal-terminal-theme "Alabaster"))
                ;; New shells use the same setting.
                (portal-terminal-new)
                (should (equal (plist-get (portal-terminal-test--colors (portal-view-target))
                                         :background) "f7f7f7"))
                (setq portal-terminal-theme nil)
                (should (member (plist-get (portal-terminal-test--colors first) :background)
                                '("f7f7f7" "212121")))))))
      (setq portal-terminal-theme original))))

(ert-deftest portal-terminal-real-shell-survives-hiding-and-resizes ()
  :tags '(:gui)
  (portal-terminal-test--session
    (let* ((terminal-buffer (current-buffer))
           (directory (make-temp-file "portal-terminal-test-" t))
           (receipt (expand-file-name "receipt" directory))
           (resumed (expand-file-name "resumed" directory))
           (initial (portal-terminal-test--state)))
      (unwind-protect
          (progn
            (should (plist-get initial :ready))
            (should (plist-get initial :visible))
            (should (plist-get initial :focused))
            (should (string-match-p "[Ll]ayer" (plist-get initial :layer)))
            (portal-terminal-test--paste
             (format "export PORTAL_TEST_VALUE=survived; printf '\\033[32mGHOSTTY_RENDER_OK\\033[0m\\n'; printf '%%s' \"$$\" > %s && /bin/mv %s %s"
                     (shell-quote-argument (concat receipt ".tmp"))
                     (shell-quote-argument (concat receipt ".tmp"))
                     (shell-quote-argument receipt)) t)
            (portal-terminal-test--wait (lambda () (file-exists-p receipt)))
            (should (string-match-p "GHOSTTY_RENDER_OK" (portal-terminal-test--text)))
            (let ((pid (with-temp-buffer
                         (insert-file-contents receipt)
                         (string-to-number (buffer-string)))))
              (should (process-attributes pid))
              ;; Hiding must leave the same shell alive and draining its PTY.
              (switch-to-buffer (get-buffer-create "*scratch*"))
              (redisplay t)
              (should-not (plist-get (portal-terminal-test--state) :visible))
              (portal-terminal-test--paste
               (format "printf '%%s:%%s' \"$$\" \"$PORTAL_TEST_VALUE\" > %s && /bin/mv %s %s"
                       (shell-quote-argument (concat resumed ".tmp"))
                       (shell-quote-argument (concat resumed ".tmp"))
                       (shell-quote-argument resumed)) t)
              (portal-terminal-test--wait (lambda () (file-exists-p resumed)))
              (should (equal (with-temp-buffer
                               (insert-file-contents resumed) (buffer-string))
                             (format "%s:survived" pid)))
              (switch-to-buffer terminal-buffer)
              (redisplay t)
              (should (plist-get (portal-terminal-test--state) :visible))
              ;; Splitting updates both the actual viewport and PTY dimensions.
              (let ((other (split-window-right)))
                (set-window-buffer other (get-buffer "*scratch*"))
                (redisplay t)
                (portal-terminal-test--wait
                 (lambda () (< (plist-get (portal-terminal-test--state) :columns)
                               (plist-get initial :columns))))
                (should (equal (plist-get (portal-terminal-test--state) :edges)
                               (window-inside-pixel-edges (selected-window)))))
              (portal-terminal-close)
              (should-not (portal-terminal-test--state))
              (portal-terminal-test--wait (lambda () (not (process-attributes pid))))))
        (delete-directory directory t)))))

(ert-deftest portal-terminal-follows-its-buffer-into-another-frame ()
  :tags '(:gui)
  (skip-unless (fboundp 'portal-test-native-key))
  (portal-terminal-test--session
    (let* ((buffer (current-buffer))
           (directory (make-temp-file "portal-terminal-frames-" t))
           (before (expand-file-name "before" directory))
           (moved (expand-file-name "moved" directory))
           (returned (expand-file-name "returned" directory))
           (frame (make-frame))
           (pid (lambda (file) (with-temp-buffer (insert-file-contents file) (buffer-string)))))
      (unwind-protect
          (progn
            (portal-terminal-test--paste
             (format "seq -f 'PORTAL_LINE_%%g' 1 3000; printf '%%s' \"$$\" > %s"
                     (shell-quote-argument before)) t)
            (portal-terminal-test--wait (lambda () (file-exists-p before)))
            ;; Showing the buffer in the other frame's selected pane moves the view.
            (select-frame-set-input-focus frame)
            (switch-to-buffer buffer)
            (portal-terminal-focus)
            (should (plist-get (portal-terminal-test--state) :focused))
            (should (equal (plist-get (portal-terminal-test--state) :edges)
                           (window-inside-pixel-edges (frame-selected-window frame))))
            ;; Keys typed into the new frame reach the same shell.
            (portal-terminal-test--paste
             (format "printf '%%s' \"$$\" > %s" (shell-quote-argument moved)) nil)
            (should (portal-test-native-key 36 0 "\r"))
            (portal-terminal-test--wait (lambda () (file-exists-p moved)))
            (should (equal (funcall pid moved) (funcall pid before)))
            (let ((text (portal-terminal-test--text)))
              (should (string-match-p "^PORTAL_LINE_1$" text))
              (should (string-match-p "^PORTAL_LINE_3000$" text)))
            ;; Deleting that frame hides the view; the original frame still
            ;; shows the buffer, so the view returns there with its shell.
            (delete-frame frame)
            (select-frame-set-input-focus (window-frame (get-buffer-window buffer t)))
            (portal-terminal-focus)
            (should (plist-get (portal-terminal-test--state) :focused))
            (portal-terminal-test--paste
             (format "printf '%%s' \"$$\" > %s" (shell-quote-argument returned)) t)
            (portal-terminal-test--wait (lambda () (file-exists-p returned)))
            (should (equal (funcall pid returned) (funcall pid before)))
            (should (string-match-p "^PORTAL_LINE_3000$" (portal-terminal-test--text))))
        (when (frame-live-p frame) (delete-frame frame))
        (delete-directory directory t)))))

(ert-deftest portal-terminal-metadata-follows-a-real-shell ()
  :tags '(:gui)
  (portal-terminal-test--session
    (let* ((buffer (current-buffer))
           (project (plist-get (portal-terminal-metadata) :project))
           (directory (file-truename (make-temp-file "portal-metadata-" t)))
           (nested (expand-file-name "a b é" directory))
           (metadata (lambda (key) (plist-get (portal-terminal-metadata buffer) key))))
      (make-directory nested)
      (unwind-protect
          (progn
            ;; Shells report their directory as a percent-encoded file URL, as
            ;; Ghostty's shell integration does at each prompt.
            (portal-terminal-test--paste
             (format "cd %s && printf '\\033]7;file://%%s%%s\\007' \"$(hostname)\" %s"
                     (shell-quote-argument nested)
                     (shell-quote-argument (concat directory "/a%20b%20%C3%A9")))
             t)
            (portal-terminal-test--wait
             (lambda () (equal (funcall metadata :directory) (file-name-as-directory nested))))
            (should (equal (buffer-local-value 'default-directory buffer)
                           (file-name-as-directory nested)))
            (should (equal (funcall metadata :project) project))
            ;; Ghostty's bundled integration reports each prompt's directory.
            ;; It skips macOS's own /bin/bash, which is too old for it.
            (when (let ((shell (or (getenv "SHELL") "")))
                    (and (member (file-name-nondirectory shell) '("zsh" "bash"))
                         (not (equal shell "/bin/bash"))))
              (portal-terminal-test--paste "cd /usr/share" t)
              (portal-terminal-test--wait
               (lambda () (equal (funcall metadata :directory) "/usr/share/")))
              (should (equal (funcall metadata :project) project)))
            ;; A hidden terminal's title reaches Emacs without renaming it.
            (portal-terminal-rename "portal-metadata-smoke")
            (switch-to-buffer (get-buffer-create "*scratch*"))
            (redisplay t)
            (should-not (plist-get (portal-terminal-test--state) :visible))
            (portal-terminal-test--paste "printf '\\033]2;PORTAL hidden title\\007'; sleep 3" t)
            (portal-terminal-test--wait
             (lambda () (equal (funcall metadata :title) "PORTAL hidden title")))
            (should (equal (buffer-name buffer) "portal-metadata-smoke"))
            ;; The exit is reported when it happens, leaving the buffer, its
            ;; last output and the keyboard until a key returns it to Emacs.
            (switch-to-buffer buffer)
            (portal-terminal-focus)
            (portal-terminal-test--paste "exit" t)
            (portal-terminal-test--wait (lambda () (funcall metadata :exited)))
            ;; Rendered, not inspected: a GUI Emacs formats mode lines.
            (should (equal (with-current-buffer buffer (format-mode-line mode-line-process))
                           " ● :exited"))
            (should (string-match-p "sleep 3" (portal-terminal-test--text)))
            (should (plist-get (portal-terminal-test--state) :focused))
            (when (fboundp 'portal-test-native-key)
              (should (portal-test-native-key 0 0 "a"))
              (portal-terminal-test--wait
               (lambda () (not (plist-get (portal-terminal-test--state) :focused)))))
            (should (memq buffer (portal-terminal-buffers)))
            ;; Killing it ends only its own session.
            (portal-terminal-new)
            (let ((other (portal-view-target)))
              (kill-buffer buffer)
              (should-not (portal-terminal-metadata buffer))
              (should (plist-get (portal-terminal-test--state other) :ready))
              (should-not (plist-get (portal-terminal-metadata) :exited))))
        (delete-directory directory t)))))

(ert-deftest portal-terminal-native-keys-clipboard-and-focus ()
  :tags '(:gui)
  (skip-unless (fboundp 'portal-test-native-key))
  (portal-terminal-test--session
    (let ((clipboard (gui-get-selection 'CLIPBOARD 'STRING)))
      (unwind-protect
          (progn
            (select-frame-set-input-focus (selected-frame))
            (portal-terminal-focus)
            ;; Cmd-V and Return traverse AppKit and the native key handler.
            (gui-set-selection 'CLIPBOARD "printf '\\nPORTAL_KEYBOARD_OK\\n'")
            (should (portal-test-native-key 9 (ash 1 20) "v"))
            (should (portal-test-native-key 36 0 "\r"))
            (portal-terminal-test--wait
             (lambda () (string-match-p "^PORTAL_KEYBOARD_OK" (portal-terminal-test--text))))
            ;; The inspection selected the actual grid; Cmd-C must copy it.
            (should (portal-test-native-key 8 (ash 1 20) "c"))
            (should (string-match-p "PORTAL_KEYBOARD_OK"
                                    (gui-get-selection 'CLIPBOARD 'STRING)))
            (portal-terminal-test--paste "sleep 30" t)
            (accept-process-output nil 0.1)
            (should (portal-test-native-key 8 (ash 1 18) "\C-c"))
            (portal-terminal-test--paste "printf '\\nPORTAL_INTERRUPT_OK\\n'" t)
            (portal-terminal-test--wait
             (lambda () (string-match-p "^PORTAL_INTERRUPT_OK" (portal-terminal-test--text))))
            ;; Escape remains terminal input. Command-period returns focus.
            (should (portal-test-native-key 53 0 "\e"))
            (should (plist-get (portal-terminal-test--state) :focused))
            (should (portal-test-native-key 47 (ash 1 20) "."))
            (should-not (plist-get (portal-terminal-test--state) :focused))
            (portal-terminal-focus)
            (should (plist-get (portal-terminal-test--state) :focused)))
        (gui-set-selection 'CLIPBOARD clipboard)))))

(ert-deftest portal-terminal-windowless-escape-restores-emacs-input ()
  :tags '(:gui)
  (skip-unless (fboundp 'portal-test-native-post-key))
  (portal-terminal-test--session
    (select-frame-set-input-focus (selected-frame))
    (portal-terminal-focus)
    ;; AppKit may route keys through the key window without event.window.
    (should (portal-test-native-key 47 (ash 1 20) "." t))
    (should-not (plist-get (portal-terminal-test--state) :focused))
    ;; Pump the real Emacs event loop: checking firstResponder alone misses
    ;; broken handoffs that still prevent Emacs commands from receiving keys.
    (should (portal-test-native-post-key 7 (ash 1 18) "\C-x"))
    (should (portal-test-native-post-key 11 0 "b"))
    (let ((keys (with-timeout (2 (ert-fail "Emacs did not receive C-x b"))
                  (read-key-sequence-vector nil))))
      (should (equal keys (vconcat (kbd "C-x b"))))
      (should (eq (key-binding keys) #'switch-to-buffer)))))

(ert-deftest portal-terminal-focus-takes-the-key-window ()
  :tags '(:gui)
  (skip-unless (fboundp 'portal-test-native-key))
  (portal-terminal-test--session
    (let ((frame (selected-frame))
          (other (make-frame)))
      (unwind-protect
          (progn
            ;; Another Emacs window holds the keyboard while Emacs selects the
            ;; terminal's frame, as a child frame redirecting its focus does.
            (select-frame-set-input-focus other)
            (sit-for 0.1)
            (select-frame frame 'norecord)
            (portal-terminal-focus)
            (should (plist-get (portal-terminal-test--state) :focused))
            ;; The injector types into the key window, as the keyboard does.
            (should (portal-test-native-key 0 0 "printf '\\nPORTAL_KEY_WINDOW_OK\\n'"))
            (should (portal-test-native-key 36 0 "\r"))
            (portal-terminal-test--wait
             (lambda () (string-match-p "^PORTAL_KEY_WINDOW_OK" (portal-terminal-test--text)))))
        (delete-frame other)))))

(ert-deftest portal-terminal-unfocus-command-returns-focus ()
  :tags '(:gui)
  (portal-terminal-test--session
    (should (plist-get (portal-terminal-test--state) :focused))
    (call-interactively #'portal-terminal-unfocus)
    (should-not (plist-get (portal-terminal-test--state) :focused))
    (should (plist-get (portal-terminal-test--state) :ready))
    (portal-terminal-focus)
    (should (plist-get (portal-terminal-test--state) :focused))))

(ert-deftest portal-terminal-invalid-target-preserves-live-shell ()
  :tags '(:gui)
  (portal-terminal-test--session
    (should-error (portal--close 42) :type 'wrong-type-argument)
    (should-error (portal--close "terminal:0"))
    (should-not (portal--inspect "terminal:0"))
    (should (plist-get (portal-terminal-test--state) :ready))
    (should (plist-get (portal-terminal-test--state) :focused))))

(provide 'portal-terminal-tests)
(defvar portal-terminal-test--keys (make-sparse-keymap)
  "Emacs bindings the chord tests give every buffer, as a user's config does.")

(defmacro portal-terminal-test--with-keys (bindings &rest body)
  "Run BODY with BINDINGS, (KEY . COMMAND) pairs, active in every buffer."
  (declare (indent 1))
  `(let ((portal-terminal-test--keys (make-sparse-keymap)))
     (dolist (binding ,bindings)
       (keymap-set portal-terminal-test--keys (car binding) (cdr binding)))
     (let ((emulation-mode-map-alists
            (cons `((t . ,portal-terminal-test--keys)) emulation-mode-map-alists)))
       ,@body)))

(defun portal-terminal-test--chord (trigger &rest strokes)
  "Send TRIGGER, a Super chord, and STROKES through the real event channel.
The terminal does not use TRIGGER, so Emacs reads it, and STROKES after it."
  (select-frame-set-input-focus (selected-frame))
  (portal-terminal-focus)
  (should (apply #'portal-test-native-key trigger))
  ;; Deliver immediately, before Lisp processes the notification. This catches
  ;; races that slower, individually evaluated synthetic keys would conceal.
  (dolist (stroke strokes) (should (apply #'portal-test-native-key stroke)))
  (let* ((keys (with-timeout (3 (ert-fail "The chord did not wake Emacs"))
                 (read-key-sequence-vector nil)))
         (event (aref keys 0)))
    (ert-info ((format "Received keys: %S" keys))
      (should (eq (car-safe event) 'portal-input-key)))
    (should (eq (key-binding keys) #'portal-input--dispatch))
    (with-timeout (3 (ert-fail "The chord's command did not finish"))
      (portal-input--dispatch event))))

(defconst portal-terminal-test--super (ash 1 20))

;; One chord proves delivery; portal-view-tests.el runs the commands in batch.
(ert-deftest portal-terminal-chord-runs-an-emacs-command ()
  :tags '(:gui)
  (portal-terminal-test--with-keys '(("s-n" . portal-terminal-new))
    (portal-terminal-test--session
      (let ((first (current-buffer))
            (first-id (portal-view-target)))
        (portal-terminal-test--chord (list 45 portal-terminal-test--super "n"))
        (should-not (eq (current-buffer) first))
        (should (= (length (portal-view-buffers 'terminal)) 2))
        (should (plist-get (portal-terminal-test--state (portal-view-target)) :focused))
        (should-not (plist-get (portal-terminal-test--state first-id) :visible))))))

(ert-deftest portal-terminal-control-chords-reach-the-shell ()
  :tags '(:gui)
  ;; tmux's prefix is the shell's, and a Super chord never leaks into it.
  (portal-terminal-test--with-keys '(("s-j" . undefined))
    (portal-terminal-test--session
      (dolist (chord '((11 "\C-b" 2) (0 "\C-a" 1)))
        (portal-terminal-test--raw-byte
         (lambda ()
           (portal-terminal-test--chord (list 38 portal-terminal-test--super "j"))
           (should (plist-get (portal-terminal-test--state) :focused))
           (should (portal-test-native-key (nth 0 chord) (ash 1 18) (nth 1 chord) t)))
         (nth 2 chord))))))

(defvar portal-terminal-test--answer nil)
(defun portal-terminal-test--prompt ()
  (interactive)
  (setq portal-terminal-test--answer (read-string "Answer: ")))

(ert-deftest portal-terminal-chord-minibuffer-cancel-and-escape ()
  :tags '(:gui)
  (let ((map (make-sparse-keymap)))
    (keymap-set map "a" #'ignore)
    (portal-terminal-test--with-keys
        `(("s-e" . portal-terminal-test--prompt) ("s-x" . execute-extended-command)
          ("s-y" . ,map))
      (portal-terminal-test--session
        (let ((super portal-terminal-test--super))
          (setq portal-terminal-test--answer nil)
          (portal-terminal-test--chord (list 14 super "e") '(4 0 "h") '(34 0 "i") '(36 0 "\r"))
          (should (equal portal-terminal-test--answer "hi"))
          (should-not (active-minibuffer-window))
          (should (plist-get (portal-terminal-test--state) :focused))
          ;; M-x completes before returning input to the selected native app.
          (portal-terminal-test--chord
           (list 7 super "x") '(34 0 "i") '(5 0 "g") '(45 0 "n")
           '(31 0 "o") '(15 0 "r") '(14 0 "e") '(36 0 "\r"))
          (should-not (active-minibuffer-window))
          (should (plist-get (portal-terminal-test--state) :focused))
          ;; C-g cancels a sequence Emacs is reading.
          (portal-terminal-test--chord (list 16 super "y") (list 5 (ash 1 18) "\C-g"))
          (should (plist-get (portal-terminal-test--state) :focused))
          (portal-test-native-key 47 super ".")
          (should-not (plist-get (portal-terminal-test--state) :focused))
          (portal-test-native-post-key 7 (ash 1 18) "\C-x")
          (portal-test-native-post-key 11 0 "b")
          (should (equal (with-timeout (3 (ert-fail "Detached editor did not receive C-x b"))
                           (read-key-sequence-vector nil))
                         (vconcat (kbd "C-x b")))))))))

(ert-deftest portal-terminal-chord-follows-native-pane-and-keeps-shells-independent ()
  :tags '(:gui)
  (portal-terminal-test--with-keys '(("s-n" . portal-terminal-new))
    (portal-terminal-test--session
      (let ((left (current-buffer))
            (left-id (portal-view-target))
            (left-window (selected-window))
            (directory (make-temp-file "portal-sessions-" t)))
        (unwind-protect
            (progn
              (portal-terminal-split-right)
              (let ((right (current-buffer))
                    (right-id (portal-view-target))
                    (left-file (expand-file-name "left" directory))
                    (right-file (expand-file-name "right" directory)))
                (portal-terminal-test--paste (format "echo $$ > %s" (shell-quote-argument left-file)) t left-id)
                (portal-terminal-test--paste (format "echo $$ > %s" (shell-quote-argument right-file)) t right-id)
                (portal-terminal-test--wait
                 (lambda () (and (file-exists-p left-file) (file-exists-p right-file))))
                (should-not
                 (equal (with-temp-buffer (insert-file-contents left-file) (buffer-string))
                        (with-temp-buffer (insert-file-contents right-file) (buffer-string))))
                ;; A click can focus a native pane without selecting its Emacs
                ;; window. The notification must carry the actual session ID.
                (should (portal--input left-id "focus"))
                (should (eq (current-buffer) right))
                (portal-test-native-key 45 portal-terminal-test--super "n" t)
                (let ((event (aref (with-timeout (3 (ert-fail "No clicked-pane chord"))
                                    (read-key-sequence-vector nil))
                                   0)))
                  (with-timeout (3 (ert-fail "Clicked-pane command stalled"))
                    (portal-input--dispatch event)))
                (should (eq (selected-window) left-window))
                (should-not (memq (current-buffer) (list left right)))
                (should (plist-get (portal-terminal-test--state right-id) :visible))
                (kill-buffer right)
                (should-not (portal-terminal-test--state right-id))
                (should (plist-get (portal-terminal-test--state left-id) :ready))))
          (delete-directory directory t))))))

;;; portal-terminal-tests.el ends here

(ert-deftest portal-terminal-quick-real-process-and-native-toggle ()
  :tags '(:gui)
  (skip-unless (and (eq window-system 'ns) (fboundp 'portal-test-native-key)))
  (let* ((directory (make-temp-file "portal-quick-native-" t))
         (receipt (expand-file-name "started" directory))
         (finished (expand-file-name "finished" directory))
         (resumed (expand-file-name "resumed" directory))
         (source (generate-new-buffer "quick-native-source"))
         (context (frame-parameter nil 'portal-project-context)))
    (save-window-excursion
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer source)
            (setq buffer-file-name (expand-file-name "source.el" directory)
                  default-directory (file-name-as-directory directory))
            (select-frame-set-input-focus (selected-frame))
            (sit-for 0.1)
            (portal-terminal-toggle)
            (let ((id (portal-view-target)) (quick (current-buffer)))
              (portal-terminal-test--paste
               (format "export PORTAL_QUICK_VALUE=preserved; cd /; printf '%%s' \"$$\" > %s; sleep 1; printf 'done' > %s"
                       (shell-quote-argument receipt) (shell-quote-argument finished)) t id)
              (portal-terminal-test--wait (lambda () (file-exists-p receipt)))
              ;; A Super chord bound in Emacs toggles from inside the panel.
              (portal-terminal-test--with-keys '(("s-t" . portal-terminal-toggle))
                (portal-terminal-test--chord (list 17 portal-terminal-test--super "t")))
              (should (eq (current-buffer) source))
              (should-not (plist-get (portal-terminal-test--state id) :visible))
              (should-not (plist-get (portal-terminal-test--state id) :focused))
              (portal-terminal-test--wait (lambda () (file-exists-p finished)))
              (portal-terminal-toggle)
              (should (eq (current-buffer) quick))
              (should (equal (portal-view-target) id))
              (should (plist-get (portal-terminal-test--state id) :focused))
              (portal-terminal-test--paste
               (format "printf '%%s:%%s:%%s' \"$$\" \"$PORTAL_QUICK_VALUE\" \"$PWD\" > %s"
                       (shell-quote-argument resumed)) t id)
              (portal-terminal-test--wait (lambda () (file-exists-p resumed)))
              (should (equal (with-temp-buffer (insert-file-contents resumed) (buffer-string))
                             (concat (with-temp-buffer (insert-file-contents receipt) (buffer-string))
                                     ":preserved:/")))
              ;; Dismissing, from a chord too, keeps the shell.
              (portal-terminal-test--with-keys '(("s-w" . portal-terminal-quick-dismiss))
                (portal-terminal-test--chord (list 13 portal-terminal-test--super "w")))
              (should (eq (current-buffer) source))
              (should (plist-get (portal-terminal-test--state id) :ready))
              (should-not (portal-terminal-buffers))
              (kill-buffer quick)
              (should-not (portal-terminal-test--state id))))
        (portal-terminal-close-all)
        (kill-buffer source)
        (set-frame-parameter nil 'portal-project-context context)
        (delete-directory directory t)))))

(defmacro portal-terminal-test--native-maps (&rest body)
  (declare (indent 0))
  `(unwind-protect
       (let ((portal-terminal-native-map (make-sparse-keymap))
             (portal-terminal-quick-native-map (make-sparse-keymap))
             (portal-terminal--native-maps (cons (make-sparse-keymap) (make-sparse-keymap))))
         (portal-terminal-refresh-bindings)
         ,@body)
     (portal-terminal-refresh-bindings)))

(defun portal-terminal-test--native-binding (trigger &rest strokes)
  "Send TRIGGER and immediate follow-up STROKES through the native bridge."
  (select-frame-set-input-focus (selected-frame))
  (portal-terminal-focus)
  (should (apply #'portal-test-native-key trigger))
  (dolist (stroke strokes) (should (apply #'portal-test-native-key stroke)))
  (let* ((keys (with-timeout (3 (ert-fail "Native binding did not wake Emacs"))
                 (read-key-sequence-vector nil)))
         (event (aref keys 0)))
    (should (eq (car-safe event) 'portal-input-binding))
    (should (eq (key-binding keys) #'portal-input--dispatch))
    (with-timeout (3 (ert-fail "Native binding command did not finish"))
      (portal-input--dispatch event))))

(defun portal-terminal-test--raw-byte (sender expected)
  "Use a real raw-mode PTY to check that SENDER delivers exactly EXPECTED."
  (let* ((directory (make-temp-file "portal-native-byte-" t))
         (ready (expand-file-name "ready" directory))
         (receipt (expand-file-name "byte" directory)))
    (unwind-protect
        (progn
          (portal-terminal-test--paste
           (format "old=$(stty -g); stty -icanon -echo min 1 time 0; touch %s; dd bs=1 count=1 2>/dev/null | od -An -tu1 > %s; stty \"$old\""
                   (shell-quote-argument ready) (shell-quote-argument receipt)) t)
          (portal-terminal-test--wait (lambda () (file-exists-p ready)))
          (funcall sender)
          (portal-terminal-test--wait
           (lambda () (and (file-exists-p receipt)
                           (> (file-attribute-size (file-attributes receipt)) 0))))
          (should (= expected (with-temp-buffer (insert-file-contents receipt)
                                                 (string-to-number (buffer-string))))))
      (delete-directory directory t))))

(defun portal-terminal-test--binding-failure ()
  (interactive)
  (user-error "Deliberate native binding failure"))

(ert-deftest portal-terminal-bindings-live-rebind-prompt-error-and-unbind ()
  :tags '(:gui)
  (portal-terminal-test--native-maps
    (portal-terminal-test--session
      (let ((id (portal-view-target)))
        (portal-terminal-bind-key portal-terminal-native-map "C-]" #'ignore)
        (portal-terminal-test--native-binding (list 30 (ash 1 18) "\C-]" t))
        (should (plist-get (portal-terminal-test--state id) :focused))
        ;; Rebind a live session; rapid follow-ups must reach the minibuffer.
        (portal-terminal-bind-key portal-terminal-native-map "C-]" #'portal-terminal-test--prompt)
        (setq portal-terminal-test--answer nil)
        (portal-terminal-test--native-binding
         (list 30 (ash 1 18) "\C-]" t) '(4 0 "h") '(34 0 "i") '(36 0 "\r"))
        (should (equal portal-terminal-test--answer "hi"))
        (should (equal (portal-view-target) id))
        (should (plist-get (portal-terminal-test--state id) :focused))
        (portal-terminal-bind-key portal-terminal-native-map "C-]" #'portal-terminal-test--binding-failure)
        (portal-terminal-test--native-binding (list 30 (ash 1 18) "\C-]" t))
        (should-not (plist-get (portal-terminal-test--state id) :focused))
        ;; Unbinding restores the actual terminal control byte, not a Lisp stub.
        (portal-terminal-unbind-key portal-terminal-native-map "C-]")
        (portal-terminal-focus)
        (portal-terminal-test--raw-byte
         (lambda () (portal-test-native-key 30 (ash 1 18) "\C-]" t)) 29)))))

(ert-deftest portal-terminal-bindings-nested-prefix-cancel-and-literal ()
  :tags '(:gui)
  (portal-terminal-test--native-maps
    (portal-terminal-test--session
      (portal-terminal-bind-key portal-terminal-native-map "C-] x y" #'portal-terminal-test--prompt)
      (setq portal-terminal-test--answer nil)
      (portal-terminal-test--native-binding
       (list 30 (ash 1 18) "\C-]" t)
       '(7 0 "x") '(16 0 "y") '(0 0 "a") '(36 0 "\r"))
      (should (equal portal-terminal-test--answer "a"))
      (portal-terminal-test--raw-byte
       (lambda ()
         ;; Cancel and unknown suffixes must not leak into the PTY.
         (portal-terminal-test--native-binding
          (list 30 (ash 1 18) "\C-]" t) (list 5 (ash 1 18) "\C-g"))
         (portal-terminal-test--native-binding
          (list 30 (ash 1 18) "\C-]" t) '(6 0 "z"))
         ;; Repeating this custom prefix sends its own original native event.
         (portal-terminal-test--native-binding
          (list 30 (ash 1 18) "\C-]" t) (list 30 (ash 1 18) "\C-]")))
       29))))

(ert-deftest portal-terminal-bindings-quick-only-toggle-and-hidden-session-updates ()
  :tags '(:gui)
  (portal-terminal-test--native-maps
    (portal-terminal-test--session
      (let ((regular (current-buffer)) (regular-id (portal-view-target)))
        (portal-terminal-bind-key portal-terminal-quick-native-map "C-]" #'portal-terminal-toggle)
        ;; A quick-only binding must still reach an ordinary terminal's PTY.
        (portal-terminal-test--raw-byte
         (lambda () (portal-test-native-key 30 (ash 1 18) "\C-]" t)) 29)
        (portal-terminal-quick--show (file-name-as-directory temporary-file-directory))
        (let ((quick (current-buffer)) (id (portal-view-target)))
          (portal-terminal-quick-dismiss)
          (portal-terminal-bind-key portal-terminal-quick-native-map "s-`" #'portal-terminal-toggle)
          (portal-terminal-quick--show (file-name-as-directory temporary-file-directory))
          (should (equal (portal-view-target) id))
          (portal-terminal-test--native-binding (list 50 (ash 1 20) "`" t))
          (should (eq (current-buffer) regular))
          (should-not (plist-get (portal-terminal-test--state id) :visible))
          (should (plist-get (portal-terminal-test--state id) :ready))
          (should (plist-get (portal-terminal-test--state regular-id) :ready))
          (kill-buffer quick))))))

(ert-deftest portal-terminal-bindings-new-session-and-native-validation ()
  :tags '(:gui)
  (portal-terminal-test--native-maps
    (portal-terminal-bind-key portal-terminal-native-map "s-j" #'portal-terminal-test--prompt)
    (portal-terminal-test--session
      ;; Bad JSON or either bad profile cannot partially replace live bindings.
      (should-error (portal--terminal-bindings "{"))
      (should-error (portal--terminal-bindings
                     "{\"regular\":[],\"quick\":[{\"character\":\"x\",\"modifiers\":0,\"event\":120}]}"))
      (setq portal-terminal-test--answer nil)
      (portal-terminal-test--native-binding
       (list 38 (ash 1 20) "j" t) '(0 0 "a") '(36 0 "\r"))
      (should (equal portal-terminal-test--answer "a"))
      (portal-terminal-new)
      (setq portal-terminal-test--answer nil)
      (portal-terminal-test--native-binding
       (list 38 (ash 1 20) "j" t) '(11 0 "b") '(36 0 "\r"))
      (should (equal portal-terminal-test--answer "b")))))

(ert-deftest portal-terminal-bindings-shifted-characters ()
  :tags '(:gui)
  (portal-terminal-test--native-maps
    (portal-terminal-test--session
      (dolist (binding '(("s-!" 18 "!") ("s-J" 38 "J")))
        (portal-terminal-bind-key portal-terminal-native-map (car binding)
                                  #'portal-terminal-test--prompt)
        (setq portal-terminal-test--answer nil)
        (portal-terminal-test--native-binding
         (list (cadr binding) (+ (ash 1 20) (ash 1 17)) (caddr binding))
         '(0 0 "a") '(36 0 "\r"))
        (should (equal portal-terminal-test--answer "a"))))))
