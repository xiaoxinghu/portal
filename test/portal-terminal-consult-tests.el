;;; portal-terminal-consult-tests.el --- The Consult adapter -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'portal-completion-testing
         (expand-file-name "portal-completion-testing"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

;; `portal-completion-testing' types into a real minibuffer with Consult,
;; Vertico and Orderless on.

(ert-deftest portal-terminal-consult-auto-enables-in-either-load-order ()
  ;; Fresh Emacs processes exercise package loading, without this suite's
  ;; already-loaded adapter or explicit mode activation masking a failure.
  (let ((portal (locate-library "portal")))
    (dolist (consult-first '(nil t))
      (dolist (enabled '(nil t))
        (let ((form
               `(progn
                  (setq load-path ',load-path)
                  ,@(unless enabled '((setq portal-terminal-consult-auto-enable nil)))
                  ,@(when consult-first '((require 'consult)))
                  (load ,portal nil t)
                  ,@(unless consult-first
                      '((cl-assert (not (featurep 'consult)))
                        (cl-assert (not (featurep 'portal-terminal-consult)))
                        (require 'consult)))
                  (cl-assert (eq (bound-and-true-p portal-terminal-consult-mode) ,enabled))
                  (if ,enabled
                      (progn
                        ;; Reloading must enable, not toggle or duplicate sources.
                        (load ,portal nil t)
                        (cl-assert portal-terminal-consult-mode)
                        (cl-assert (= (cl-count 'portal-terminal-consult-source
                                               consult-buffer-sources) 1))
                        (cl-assert (= (cl-count 'portal-terminal-consult-project-source
                                               consult-project-buffer-sources) 1))
                        (cl-assert (eq portal-terminal--reader #'portal-terminal-consult--read))
                        (portal-terminal-consult-mode -1)
                        (cl-assert (eq portal-terminal--reader #'portal-terminal--completing-read))
                        (cl-assert (not (memq 'portal-terminal-consult-source consult-buffer-sources))))
                    (cl-assert (not (featurep 'portal-terminal-consult)))))))
          (with-temp-buffer
            (let ((status (call-process (expand-file-name invocation-name invocation-directory)
                                        nil t nil "--batch" "-Q" "--eval"
                                        (prin1-to-string form))))
              (ert-info ((format "Consult first: %S, enabled: %S\n%s"
                                 consult-first enabled (buffer-string)))
                (should (eq status 0))))))))))

;; Each picker case reads once through `portal-terminal--read-choice' in a
;; fresh Emacs whose config has not loaded Consult, with both readers stubbed
;; to return their own names, and asserts on the reader and Consult after.
(defun portal-terminal-consult-test--first-read (setup after-portal assertions)
  "Read once in a fresh Emacs, then check ASSERTIONS.
SETUP runs before Portal loads and AFTER-PORTAL after.  The read's
result is in `chosen'."
  (let ((form
         `(progn
            (setq load-path ',load-path)
            (require 'cl-lib)
            ,@setup
            (load ,(locate-library "portal") nil t)
            (require 'portal-terminal-choose)
            ,@after-portal
            (advice-add 'portal-terminal--completing-read :override
                        (lambda (&rest _) 'completing-read))
            (advice-add 'portal-terminal-consult--read :override
                        (lambda (&rest _) 'consult))
            (let ((chosen (portal-terminal--read-choice nil default-directory nil)))
              ,@assertions))))
    (with-temp-buffer
      (let ((status (call-process (expand-file-name invocation-name invocation-directory)
                                  nil t nil "--batch" "-Q" "--eval"
                                  (prin1-to-string form))))
        (ert-info ((buffer-string))
          (should (eq status 0)))))))

(ert-deftest portal-terminal-consult-first-picker-loads-consult ()
  ;; A config that loads Consult lazily opens a picker before anything else
  ;; loads Consult: the picker loads it, and reads with it.
  (portal-terminal-consult-test--first-read
   '((cl-assert (locate-library "consult")))
   '((cl-assert (not (featurep 'consult))))
   '((cl-assert (featurep 'consult))
     (cl-assert portal-terminal-consult-mode)
     (cl-assert (eq portal-terminal--reader #'portal-terminal-consult--read))
     (cl-assert (eq chosen 'consult) nil "Read with %S" chosen))))

(ert-deftest portal-terminal-consult-picker-without-auto-enable-leaves-consult ()
  (portal-terminal-consult-test--first-read
   '((cl-assert (locate-library "consult"))
     (setq portal-terminal-consult-auto-enable nil))
   nil
   '((cl-assert (not (featurep 'consult)))
     (cl-assert (not (featurep 'portal-terminal-consult)))
     (cl-assert (eq chosen 'completing-read) nil "Read with %S" chosen))))

(ert-deftest portal-terminal-consult-picker-keeps-mode-turned-off ()
  ;; Consult is loaded and the mode was turned off by hand: it stays off.
  (portal-terminal-consult-test--first-read
   '((require 'consult))
   '((cl-assert portal-terminal-consult-mode)
     (portal-terminal-consult-mode -1))
   '((cl-assert (not portal-terminal-consult-mode))
     (cl-assert (eq chosen 'completing-read) nil "Read with %S" chosen))))

(ert-deftest portal-terminal-consult-buffer-narrows-to-terminals-once ()
  (portal-completion-test--environment
    (let* ((server (portal-completion-test--open "one/app" :title "npm run dev"))
           (tests (portal-completion-test--open "one/app" :title "bun test" :exited t))
           (worktree (portal-completion-test--open "two/app"
                                                :pwd (portal-completion-test--path "one/app/api"))))
      (with-current-buffer server (portal-terminal-rename "server"))
      (portal-fake-native-report (buffer-local-value 'portal-view--target server)
                                 :pwd (portal-completion-test--path "one/app/api"))
      (let ((default-directory (portal-completion-test--path "one/app/")))
        (portal-terminal-toggle)
        (portal-terminal-quick-dismiss))
      (switch-to-buffer "consult-file.el")
      (pcase-let ((`(,all ,terminals ,matched)
                   (portal-completion-test--type
                    #'consult-buffer "<f11> t SPC <f11> app SPC api SPC dev <f11> RET"
                    #'portal-completion-test--matches)))
        ;; The default list shows each terminal once, as a buffer.
        (dolist (buffer (list server tests worktree))
          (should (= (cl-count buffer (mapcar #'portal-completion-test--value all)) 1)))
        ;; Narrowed with t, only terminals, most recent first, without quick
        ;; ones; each shows and matches its label, project, directory and title.
        (should (equal (mapcar #'portal-completion-test--value terminals) (list worktree tests server)))
        (should (equal (mapcar #'portal-completion-test--value matched) (list server)))
        (should (string-match-p "\\`server +one/app +.*/one/app/api/ +npm run dev"
                                (car matched))))
      (should (eq (current-buffer) server))
      (should (eq (car (buffer-list)) server))
      ;; The project's buffers narrow to its terminals by assignment.
      (switch-to-buffer "consult-file.el")
      (should (equal (portal-completion-test--type #'consult-project-buffer "t SPC <f11> bun RET"
                                                #'portal-completion-test--shown)
                     (list (list server tests))))
      (should (eq (current-buffer) tests))
      ;; The adapter adds its sources once and removes them.
      (portal-terminal-consult-mode)
      (should (= (cl-count 'portal-terminal-consult-source consult-buffer-sources) 1))
      (portal-terminal-consult-mode -1)
      (should-not (memq 'portal-terminal-consult-source consult-buffer-sources))
      (should-not (memq 'portal-terminal-consult-project-source consult-project-buffer-sources)))))

(ert-deftest portal-terminal-consult-waiting-narrows-to-blocks-that-wait ()
  (portal-completion-test--environment
    (let* ((report (lambda (buffer state ago &rest status)
                     (with-current-buffer buffer
                       (setq portal-terminal--status
                             (append (list :state state :time (- (float-time) ago)
                                           :waiting (not (eq state 'working)))
                                     status)))
                     buffer))
           (plain (portal-completion-test--open "one/app"))
           (working (funcall report (portal-completion-test--open "one/app") 'working 0
                             :message "Reading slides.ts"))
           (asking (funcall report (portal-completion-test--open "one/app") 'blocked 120
                            :kind "question" :message "Clean up the task now?"))
           (done (funcall report (portal-completion-test--open "two/app") 'done 720)))
      (switch-to-buffer "consult-file.el")
      ;; w narrows `consult-buffer' to the blocks that wait, longest first;
      ;; unnarrowed, each terminal is listed once, as a buffer.
      (pcase-let ((`(,all ,waiting)
                   (portal-completion-test--type
                    #'consult-buffer "<f11> w SPC <f11> RET"
                    #'portal-completion-test--shown)))
        (dolist (buffer (list plain working asking done))
          (should (= (cl-count buffer all) 1)))
        (should (equal waiting (list done asking))))
      (should (eq (current-buffer) done))
      ;; The pickers too, within the terminals they list, with the status
      ;; words to type.
      (switch-to-buffer "consult-file.el")
      (should (equal (portal-completion-test--type
                      #'portal-terminal-choose "<f11> w SPC <f11> DEL quest <f11> RET"
                      #'portal-completion-test--shown)
                     `((,done ,asking ,working ,plain new named)
                       (,done ,asking)
                       (,asking))))
      (should (eq (current-buffer) asking))
      (switch-to-buffer "consult-file.el")
      (should (equal (portal-completion-test--type
                      #'portal-terminal-choose-project "w SPC <f11> C-g"
                      #'portal-completion-test--shown)
                     `((,asking))))
      ;; The adapter adds the source once and removes it.
      (should (= (cl-count 'portal-terminal-consult-waiting-source consult-buffer-sources) 1))
      (portal-terminal-consult-mode)
      (should (= (cl-count 'portal-terminal-consult-waiting-source consult-buffer-sources) 1))
      (portal-terminal-consult-mode -1)
      (should-not (memq 'portal-terminal-consult-waiting-source consult-buffer-sources)))))

(ert-deftest portal-terminal-consult-picker-reads-with-consult ()
  (portal-completion-test--environment
    (let* ((one (portal-completion-test--path "one/app/"))
           (server (portal-completion-test--open "one/app" :title "npm run dev"
                                              :pwd (portal-completion-test--path "one/app/api")))
           (tests (portal-completion-test--open "one/app" :title "bun test"))
           (worktree (portal-completion-test--open "two/app"))
           (prompt (lambda () (list (minibuffer-prompt) (minibuffer-contents-no-properties)
                                    (portal-completion-test--shown)))))
      (switch-to-buffer "consult-file.el")
      ;; The project's terminals, recent first, then the New group, which
      ;; narrows with n; DEL widens again.
      (should (equal (portal-completion-test--type
                      #'portal-terminal-choose-project "<f11> n SPC <f11> DEL api SPC dev RET" prompt)
                     `(("Terminal in app: " "" (,tests ,server new named))
                       ("Terminal in app: " "" (new named)))))
      (should (eq (current-buffer) server))
      ;; M-a widens to every project, keeping the input.
      (should (equal (portal-completion-test--type #'portal-terminal-choose-project "two M-a <f11> RET"
                                                prompt)
                     `(("Terminal: " "two" (,worktree)))))
      (should (eq (current-buffer) worktree))
      ;; A New entry starts a terminal in the project; unmatched input starts nothing.
      (switch-to-buffer "consult-file.el")
      (portal-completion-test--type #'portal-terminal-choose-project "n SPC RET")
      (should (equal (plist-get (portal-terminal-metadata) :project) one))
      (should (equal (plist-get (portal-terminal-metadata) :directory) one))
      (let ((count (length (portal-terminal-buffers))))
        (switch-to-buffer "consult-file.el")
        (portal-completion-test--type #'portal-terminal-choose "zzz RET C-g")
        (should (= (length (portal-terminal-buffers)) count))
        (should (equal (buffer-name) "consult-file.el"))
        ;; A terminal closed before it is chosen is reported, not guessed.
        (should-error (portal-completion-test--type #'portal-terminal-choose "bun <f11> RET"
                                                 (lambda () (kill-buffer tests)))
                      :type 'user-error)
        (should (equal (buffer-name) "consult-file.el"))
        (should (= (length (portal-terminal-buffers)) (1- count)))))))

(ert-deftest portal-terminal-consult-preview-restores-and-records-nothing ()
  (portal-completion-test--environment
    (let* ((file (current-buffer))
           (window (selected-window))
           (shown (portal-completion-test--open "one/app" :title "shown"))
           (hidden (portal-completion-test--open "two/app" :title "hidden"))
           (target (buffer-local-value 'portal-view--target shown))
           ;; Another frame can show it too; batch Emacs cannot read a keyboard
           ;; macro then, so the view tests and the graphical suite cover that.
           (remote (split-window-right))
           (placement (lambda ()
                        (portal-view-sync)
                        (list (window-buffer window) (portal-view-target window)
                              (portal-view-target remote)
                              (plist-get (portal--inspect target) :focused)
                              (minibuffer-contents-no-properties)))))
      ;; The terminal is shown in another window; this one shows a file.
      (set-window-buffer remote shown)
      (switch-to-buffer file)
      (portal-view-sync)
      (should (equal (portal-view-target remote) target))
      (let ((order (portal-terminal--recent (portal-terminal-buffers))))
        (should (equal order (list hidden shown)))
        ;; Moving to a candidate does not preview it; M-. does, moving the
        ;; live terminal here without the keyboard, and typing continues.
        (should (equal (portal-completion-test--type
                        #'portal-terminal-choose "shown <f11> M-. <f11> SPC x <f11> C-g"
                        placement)
                       `((,file nil ,target nil "shown")
                         (,shown ,target nil nil "shown")
                         (,shown ,target nil nil "shown x"))))
        ;; Cancelling restores the window and the view, and records nothing.
        (portal-view-sync)
        (should (eq (window-buffer window) file))
        (should (equal (portal-view-target remote) target))
        (should (equal (portal-terminal--recent (portal-terminal-buffers)) order)))
      ;; Accepting after a preview selects the terminal here and records it.
      (portal-completion-test--type #'portal-terminal-choose "hidden M-. RET")
      (should (eq (window-buffer window) hidden))
      (should (eq (car (buffer-list)) hidden))
      ;; From a quick panel, the editing window previews, and the panel stays.
      (let ((default-directory (portal-completion-test--path "one/app/")))
        (portal-terminal-toggle))
      (let ((panel (selected-window)) (quick (current-buffer)))
        (should (equal (portal-completion-test--type
                        #'portal-terminal-choose "hidden M-. <f11> C-g"
                        (lambda () (list (window-buffer window) (window-buffer panel))))
                       `((,hidden ,quick))))
        (should (eq (selected-window) panel))
        (portal-completion-test--type #'portal-terminal-choose "shown RET")
        (should (eq (selected-window) window))
        (should (eq (window-buffer window) shown))
        (should (eq (window-buffer panel) quick))))))

(ert-deftest portal-terminal-consult-preview-skips-quick-and-closed-terminals ()
  (portal-completion-test--environment
    (let* ((file (current-buffer))
           (window (selected-window))
           (closed (portal-completion-test--open "one/app"))
           (quick (let ((default-directory (portal-completion-test--path "one/app/")))
                    (portal-terminal-toggle)
                    (prog1 (current-buffer) (portal-terminal-quick-dismiss))))
           (state (progn (switch-to-buffer file) (portal-terminal-consult--state))))
      (with-current-buffer closed (portal-terminal-close))
      (funcall state 'preview quick)
      (should (eq (window-buffer window) file))
      (funcall state 'preview closed)
      (should (eq (window-buffer window) file))
      (funcall state 'preview nil)
      (funcall state 'exit nil)
      (funcall state 'return nil)
      (should (eq (window-buffer window) file))
      ;; Other display commands place ordinary terminals as they do buffers.
      (let ((extra (portal-completion-test--open "one/app")))
        (switch-to-buffer file)
        (let ((consult--buffer-display #'switch-to-buffer-other-window)
              (state (portal-terminal-consult--state)))
          (funcall state 'return extra))
        (should-not (eq (selected-window) window))
        (should (eq (window-buffer) extra))))))

(ert-deftest portal-terminal-consult-preview-key-follows-the-source ()
  (portal-completion-test--environment
    (portal-completion-test--open "one/app")
    (let ((original (copy-sequence portal-terminal-consult-source))
          sources)
      (unwind-protect
          (cl-letf (((symbol-function 'consult--multi)
                     (lambda (list &rest _) (setq sources list) '(nil))))
            ;; Manual preview by default; `consult-customize' changes it everywhere.
            (should (equal (plist-get portal-terminal-consult-source :preview-key) "M-."))
            (consult-customize portal-terminal-consult-source :preview-key '(:debounce 0.3 any)
                               :narrow ?T)
            (should-error (portal-terminal-choose) :type 'user-error)
            (should (equal (plist-get (car sources) :preview-key) '(:debounce 0.3 any)))
            (should (equal (plist-get (car sources) :narrow) ?T))
            (should-not (plist-get (car sources) :hidden))
            (should (eq (plist-get (car sources) :category) 'buffer)))
        (setq portal-terminal-consult-source original)))))

;;; portal-terminal-consult-tests.el ends here
