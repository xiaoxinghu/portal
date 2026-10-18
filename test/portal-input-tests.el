;;; portal-input-tests.el --- Shared input contract -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'portal)

(ert-deftest portal-input-chords-become-emacs-events ()
  ;; The core sends a chord as typed: Shift made the character.
  (dolist (case '((?x 8 "s-x") (?A 9 "s-A") (?! 9 "s-!") (?A 3 "C-S-a") (?x 2 "C-x")
                  (?x 4 "M-x") (?\s 9 "S-s-SPC") (?\s 2 "C-SPC") (?é 4 "M-é")))
    (should (equal (key-description (vector (portal-input--event (nth 0 case) (nth 1 case))))
                   (nth 2 case)))))

(ert-deftest portal-input-mode-line-names-who-has-the-keyboard ()
  ;; After the mode name, in `mode-line-process', where comint and eat put
  ;; a buffer's state; the view's focus record changes it.  Batch Emacs
  ;; renders no mode line, so this checks the construct and what it says.
  (with-temp-buffer
    (portal-web-mode)
    (setq portal-view--target "web:7")
    (let ((portal-view--buffers (list (current-buffer))))
      ;; The list starts with a string: one starting with a symbol would be
      ;; the conditional construct, and show nothing of the owner.
      (should (equal mode-line-process '("" portal-input-mode-line-process)))
      (should (get 'portal-input-mode-line-process 'risky-local-variable))
      (should (equal (portal-input--mode-line-process) "[emacs]"))
      (portal-view--dispatch "focus web:7 1")
      (should (portal-input--focused-p))
      (should (equal (portal-input--mode-line-process) "[app]"))
      (should (string-match-p (regexp-quote portal-input-escape-key)
                              (get-text-property 0 'help-echo (portal-input--mode-line-process))))
      (portal-view--dispatch "focus web:7 0")
      (should (equal (portal-input--mode-line-process) "[emacs]"))
      ;; A view closed while it had the keyboard sends no record its buffer
      ;; can take: without a view, Emacs has the keyboard, and so it does
      ;; with the next view in the buffer until that one says otherwise.
      (portal-view--dispatch "focus web:7 1")
      (setq portal-view--target nil)
      (should (equal (portal-input--mode-line-process) "[emacs]"))
      (setq portal-view--target "web:8")
      (should (equal (portal-input--mode-line-process) "[emacs]"))
      (portal-view--dispatch "focus web:8 1")
      (should (equal (portal-input--mode-line-process) "[app]"))
      ;; Turning the mode off takes the construct out; on puts it back once.
      (portal-input-mode -1)
      (should-not mode-line-process)
      (portal-input-mode 1)
      (portal-input-mode 1)
      (should (equal mode-line-process '("" portal-input-mode-line-process))))))

(ert-deftest portal-input-terminal-mode-line-adds-the-exit ()
  (with-temp-buffer
    (portal-terminal-mode)
    (should (equal mode-line-process
                   '("" portal-input-mode-line-process (portal-terminal--exited ":exited"))))
    (should (equal (portal-input--mode-line-process) "[emacs]"))))

(defvar portal-input-test--called nil)
(defun portal-input-test--save () (interactive) (setq portal-input-test--called t))

(defmacro portal-input-test--in (mode &rest body)
  "Run BODY in a buffer in MODE, as a native view's, with a fake module."
  (declare (indent 1))
  `(with-temp-buffer
     (,mode)
     (let (resumed actions)
       (cl-letf (((symbol-function 'portal-view-buffers) (lambda (&rest _) (list (current-buffer))))
                 ((symbol-function 'portal-input-focus) (lambda () (setq resumed t)))
                 ((symbol-function 'portal--input)
                  (lambda (_target action &rest _) (push action actions) t)))
         ,@body))))

(ert-deftest portal-input-chord-reads-the-buffer-keymaps-and-resumes ()
  ;; C-x C-s, as typed in the buffer: its remapping of save-buffer applies.
  (portal-input-test--in portal-web-mode
    (use-local-map (make-sparse-keymap))
    (define-key (current-local-map) [remap save-buffer] #'portal-input-test--save)
    (let ((portal-input-test--called nil) (unread-command-events (list ?\C-s)))
      (portal-input--run "web:1" 1 (kbd "C-x") nil)
      (should portal-input-test--called)
      (should resumed)
      (should (equal (reverse actions) '("ack" "command" "finish"))))))

(ert-deftest portal-input-a-chord-alone-can-be-the-command ()
  (portal-input-test--in portal-terminal-mode
    (local-set-key (kbd "s-j") #'portal-input-test--save)
    (let ((portal-input-test--called nil) (unread-command-events nil))
      (portal-input--run "terminal:1" 1 (kbd "s-j") nil)
      (should portal-input-test--called)
      (should resumed)
      (should-not unread-command-events))))

(ert-deftest portal-input-type-ahead-keeps-emacs-in-control ()
  ;; x, typed at once after a chord that is a whole command, fell through or
  ;; claimed by a native binding, is Emacs's next command.
  (dolist (binding '(nil portal-input-test--save))
    (portal-input-test--in portal-terminal-mode
      (local-set-key (kbd "s-j") #'portal-input-test--save)
      (let ((portal-input-test--called nil) (unread-command-events nil))
        (cl-letf (((symbol-function 'portal--input)
                   (lambda (_target action &rest _)
                     ;; The platform replays what was typed after the trigger.
                     (when (equal action "ack") (setq unread-command-events (list ?x)))
                     t)))
          (portal-input--run "terminal:1" 1 (kbd "s-j") binding))
        (should portal-input-test--called)
        (should-not resumed)
        (should (equal unread-command-events '(?x)))))))

(defun portal-input-test--transient ()
  (interactive)
  (set-transient-map (make-sparse-keymap)))

(ert-deftest portal-input-an-unfinished-command-keeps-emacs-in-control ()
  ;; A prefix argument, or a transient keymap, waits for the user's next key.
  (dolist (command '(universal-argument portal-input-test--transient))
    (portal-input-test--in portal-web-mode
      (use-local-map (make-sparse-keymap))
      (local-set-key (kbd "C-u") command)
      (let ((unread-command-events nil) (prefix-arg nil)
            (overriding-terminal-local-map nil) (pre-command-hook nil))
        (portal-input--run "web:1" 1 (kbd "C-u") nil)
        (should overriding-terminal-local-map)
        (should (equal prefix-arg (and (eq command 'universal-argument) '(4))))
        (should-not resumed)))))

(ert-deftest portal-input-escape-and-error-do-not-resume ()
  (dolist (kind '(unfocus escape error hidden))
    (with-temp-buffer
      (portal-web-mode)
      (let (resumed
            (unread-command-events (when (eq kind 'escape)
                                     (list '(portal-input-escape ("web:1" 1 0))))))
        (cl-letf (((symbol-function 'portal-view-buffers) (lambda (&rest _) (list (current-buffer))))
                  ((symbol-function 'portal-input-focus) (lambda () (setq resumed t)))
                  ;; Once the user or a hidden view ended the handoff, it
                  ;; cannot be finished.
                  ((symbol-function 'portal--input)
                   (lambda (_target action &rest _)
                     (not (and (memq kind '(escape hidden)) (equal action "finish"))))))
          (pcase kind
            ('escape (portal-input--run "web:1" 1 (kbd "C-x") nil))
            (_ (portal-input--run "web:1" 1 (kbd "s-j")
                                  (pcase kind
                                    ('unfocus #'portal-input-unfocus)
                                    ('error (lambda () (interactive) (error "Expected failure")))
                                    ('hidden #'ignore))))))
        ;; A command that hid the view, such as by showing another terminal
        ;; in its pane, still resumes the selected view.
        (should (eq resumed (eq kind 'hidden)))))))

(ert-deftest portal-input-escape-while-a-busy-command-runs-does-not-resume ()
  ;; A command that reads no input leaves the user's escape records in the
  ;; pipe; a hidden origin sends none.  A subprocess writes them, as the
  ;; native module does, while Emacs stops reading the pipe.  Another view's
  ;; escape, after this one's, must not hide it.
  (let* ((origin (generate-new-buffer "portal-input-origin"))
         (other (generate-new-buffer "portal-input-other"))
         (portal-view--pending "")
         (portal-view--channel (make-pipe-process :name "portal-input-test" :noquery t
                                                  :filter #'portal-view--receive))
         (unread-command-events nil)
         (busy (lambda (records)
                 (lambda ()
                   (interactive)
                   (when records
                     (stop-process portal-view--channel)
                     (let ((writer (make-process
                                    :name "portal-input-test-escape" :noquery t
                                    :command (list "sh" "-c" (format "printf '%s' >&2" records))
                                    :stderr portal-view--channel)))
                       (while (process-live-p writer) (sleep-for 0.01)))
                     (continue-process portal-view--channel)))))
         resumed)
    (unwind-protect
        (progn
          (dolist (view (list (cons origin "web:1") (cons other "web:2")))
            (with-current-buffer (car view)
              (portal-web-mode)
              (setq-local portal-view--target (cdr view))))
          (cl-letf (((symbol-function 'portal-view-buffers) (lambda (&rest _) (list origin other)))
                    ((symbol-function 'portal-input-focus) (lambda () (setq resumed t)))
                    ;; Either way, the handoff has ended by the time it finishes.
                    ((symbol-function 'portal--input)
                     (lambda (_target action &rest _) (not (equal action "finish")))))
            (with-current-buffer origin
              (portal-input--run "web:1" 1 (kbd "s-j") (funcall busy nil))
              (should resumed)
              (setq resumed nil)
              (portal-input--run "web:1" 2 (kbd "s-j")
                                 (funcall busy "escape web:1 2 0\\nescape web:2 3 0\\n"))
              (should-not resumed)
              (should (= (buffer-local-value 'portal-input--escaped origin) 2))
              (should (= (buffer-local-value 'portal-input--escaped other) 3))
              (should (equal (mapcar #'car unread-command-events)
                             '(portal-input-escape portal-input-escape))))))
      (delete-process portal-view--channel)
      (kill-buffer origin)
      (kill-buffer other))))

(ert-deftest portal-input-escape-ends-a-sequence-without-taking-the-next-event ()
  ;; A native handoff, such as Open in Emacs, escapes a key sequence Emacs is
  ;; reading before its own event arrives; the event must survive for the
  ;; command loop.
  (portal-input-test--in portal-web-mode
    (let* ((edit '(portal-web-edit ("web:1")))
           (unread-command-events (list '(portal-input-escape ("web:1" 1 0)) edit)))
      (portal-input--run "web:1" 1 (kbd "C-x") nil)
      (should-not resumed)
      (should (equal unread-command-events (list edit))))))

(ert-deftest portal-input-cancel-and-undefined-sequences-never-reach-the-view ()
  (dolist (key (list '(portal-input-cancel ("web:1" 1 0)) ?~))
    (portal-input-test--in portal-web-mode
      (let ((unread-command-events (list key)))
        (portal-input--run "web:1" 1 (kbd "C-x") nil)
        (should resumed)
        (should-not unread-command-events)
        (should-not (member "literal" actions))))))

(ert-deftest portal-input-native-binding-maps-send-their-trigger ()
  ;; A native binding's prefix map: its trigger again goes to the app.
  (portal-input-test--in portal-terminal-mode
    (let ((map (make-sparse-keymap)) (unread-command-events (list ?\s-j)))
      (keymap-set map "x" #'portal-input-test--save)
      (portal-input--run "terminal:1" 1 (kbd "s-j") map)
      (should (member "literal" actions))
      (should resumed))))

(ert-deftest portal-input-native-binding-chords-use-portal-modifiers ()
  ;; The native module's values, not a platform's key flags.
  (dolist (case '(("C-b" "b" 2) ("C-S-b" "b" 3) ("M-a" "a" 4) ("s-e" "e" 8)
                  ("s-!" "!" 8) ("s-J" "j" 9) ("C-M-s-SPC" " " 14)))
    (should (equal (portal-input--chord (car case)) (cdr case))))
  (dolist (bad '("b" "C-b x" "<f5>" "s-S-1" "C-é"))
    (should-error (portal-input--chord bad))))

(ert-deftest portal-input-escape-key-validation ()
  (dolist (case '(("s-." "." 8) ("C-s-g" "g" 10) ("s-!" "!" 8)
                  ("C-<escape>" "\e" 2) ("s-<escape>" "\e" 8)))
    (should (equal (portal-input--escape-chord (car case)) (cdr case))))
  (dolist (bad '("." "<escape>" "S-a" "s-. x" "s-<f5>" "s-S-1" "C-é"))
    (should-error (portal-input--escape-chord bad))))

(ert-deftest portal-input-escape-key-updates-live-and-on-module-load ()
  (let (sent)
    (cl-letf (((symbol-function 'portal--input-escape-key)
               (lambda (&rest chord) (push chord sent))))
      (let ((portal-input-escape-key "C-s-g"))
        (should (equal (car sent) '("g" 10)))
        (should (eq (keymap-lookup portal-input-mode-map "C-s-g") #'portal-input-unfocus))
        (should-not (keymap-lookup portal-input-mode-map "s-."))
        (setq sent nil)
        (portal-input--initialize)
        (should (equal sent '(("g" 10))))
        (setq portal-input-escape-key "C-<escape>")
        (should (equal (car sent) '("\e" 2)))
        (should-not (keymap-lookup portal-input-mode-map "C-s-g"))
        (should-error (customize-set-variable 'portal-input-escape-key "a"))
        (should (equal portal-input-escape-key "C-<escape>")))
      (should (equal (car sent) '("." 8)))
      (should (eq (keymap-lookup portal-input-mode-map "s-.") #'portal-input-unfocus)))))

(ert-deftest portal-input-stale-module-refuses-escape-remapping-and-connection ()
  ;; Updated Lisp in an Emacs still running the old module must not replace
  ;; its working wrapper escape with a key the native side cannot reserve.
  (let* ((portal-input-mode-map (make-sparse-keymap))
         (portal-input--escape-installed "s-<escape>")
         (before portal-input-escape-key))
    (keymap-set portal-input-mode-map "s-<escape>" #'portal-input-unfocus)
    (cl-letf (((symbol-value 'features) (cons 'portal-native-module features))
              ((symbol-function 'portal--input) #'ignore)
              ((symbol-function 'portal--input-escape-key) nil)
              ((symbol-function 'portal-view--load) #'ignore))
      (dolist (action (list #'portal-input--initialize
                            (lambda () (setq portal-input-escape-key "C-s-g"))
                            (lambda () (customize-set-variable 'portal-input-escape-key "C-s-g"))
                            #'portal-input--connect))
        (should (string-match-p "Restart Emacs"
                                (error-message-string (should-error (funcall action) :type 'user-error))))
        (should (equal portal-input-escape-key before))
        (should (equal portal-input--escape-installed "s-<escape>"))
        (should (eq (keymap-lookup portal-input-mode-map "s-<escape>") #'portal-input-unfocus))
        (should-not (keymap-lookup portal-input-mode-map "s-."))
        (should-not (keymap-lookup portal-input-mode-map "C-s-g"))))))

(ert-deftest portal-input-escape-can-be-configured-before-module-load ()
  ;; No module is different from an incompatible loaded one: startup
  ;; configuration remains possible, then reaches the module when it loads.
  (let (sent)
    (cl-letf (((symbol-value 'features) (remq 'portal-native-module features))
              ((symbol-function 'portal--input) nil)
              ((symbol-function 'portal--input-escape-key) nil))
      (let ((portal-input-escape-key "C-s-g"))
        (should (eq (keymap-lookup portal-input-mode-map "C-s-g") #'portal-input-unfocus))
        (cl-letf (((symbol-value 'features) (cons 'portal-native-module features))
                  ((symbol-function 'portal--input) #'ignore)
                  ((symbol-function 'portal--input-escape-key)
                   (lambda (&rest chord) (push chord sent)))
                  ((symbol-function 'portal-view--load) #'ignore))
          (portal-input--initialize)
          (portal-input--connect)
          (should (equal sent '(("g" 10)))))))))

(ert-deftest portal-input-wrapper-controls-work-with-evil ()
  (skip-unless (locate-library "evil"))
  (require 'evil)
  (dolist (mode '(portal-web-mode portal-terminal-mode portal-excalidraw-mode))
    (with-temp-buffer
      (cl-letf (((symbol-function 'portal-excalidraw--start) #'ignore))
        (funcall mode))
      (evil-local-mode 1)
      (dolist (state '(normal motion insert))
        (evil-change-state state)
        (should (eq (key-binding (kbd "RET")) #'portal-input-focus))
        (should (eq (key-binding (kbd "s-.")) #'portal-input-unfocus))))))

(ert-deftest portal-input-chords-use-evil-state-keymaps ()
  ;; A chord runs what it would in the buffer, Evil's state keymaps included.
  (skip-unless (locate-library "evil"))
  (require 'evil)
  (portal-input-test--in portal-web-mode
    (evil-local-mode 1)
    (evil-normal-state)
    (evil-local-set-key 'normal (kbd "C-c a") #'portal-input-test--save)
    (let ((portal-input-test--called nil) (unread-command-events (list ?a)))
      (portal-input--run "web:1" 1 (kbd "C-c") nil)
      (should portal-input-test--called)
      (should resumed))))

(provide 'portal-input-tests)
