;;; portal-package-gui.el --- First use of an installed Portal -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Loaded last by test/package-gui.sh into a graphical Emacs whose HOME holds
;; a Portal installed through the use-package-vc example and never built.
;; PORTAL_PACKAGE_GUI_PHASE chooses the check:
;;   setup  M-x portal-terminal offers Download, Build here or Not now;
;;          answering b, Build here, builds once.
;;   use    A fresh Emacs opens a terminal and the Hello World web view.
;; Results go to standard error, ending with how many checks passed; Emacs
;; exits with 0 only when all hold.

(require 'cl-lib)
(require 'package)

(defvar portal-build--process)
(declare-function portal-build-problem "portal-build" ())
(declare-function portal-view-buffers "portal-view" (&optional kind))
(declare-function portal-view-target "portal-view" (&optional window))
(declare-function portal--inspect "portal-view" (target))

(defvar portal-package-gui--passed 0
  "How many checks have held in this phase.")

(defun portal-package-gui--log (format &rest arguments)
  "Report FORMAT with ARGUMENTS on standard error."
  (princ (concat (apply #'format-message format arguments) "\n") #'external-debugging-output))

(defun portal-package-gui--check (description value &optional state)
  "Report DESCRIPTION and VALUE; fail unless VALUE is non-nil.
STATE, if given, is reported too, to explain a failure."
  (portal-package-gui--log "%s %s: %S%s" (if value "ok  " "FAIL") description value
                           (if state (format " %S" state) ""))
  (unless value
    (when-let* ((buffer (get-buffer "*portal-build*")))
      (with-current-buffer buffer
        (portal-package-gui--log "*portal-build*:\n%s"
                                 (buffer-substring (max (point-min) (- (point-max) 6000))
                                                   (point-max)))))
    (kill-emacs 1))
  (cl-incf portal-package-gui--passed)
  value)

(defun portal-package-gui--wait (predicate seconds)
  "Wait up to SECONDS for PREDICATE, running process output and redisplay."
  (let ((deadline (+ (float-time) seconds)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (redisplay t))
    (funcall predicate)))

(defun portal-package-gui--setup ()
  "Type the first native command, choose to build here and wait for the build."
  (portal-package-gui--check "nothing is built yet" (eq (portal-build-problem) 'missing))
  (let (prompts messages)
    (advice-add 'read-multiple-choice :before
                (lambda (prompt choices &rest _) (push (cons prompt (mapcar #'car choices)) prompts)))
    (advice-add 'message :before (lambda (format &rest arguments)
                                   (when format
                                     (push (apply #'format-message format arguments) messages))))
    ;; The command stops with a user error after starting the build.
    (ignore-errors (execute-kbd-macro (kbd "M-x portal-terminal RET b")))
    (portal-package-gui--check "the command offered a download and a build"
                               (equal (cdar prompts) '(?d ?b ?n)) prompts)
    (portal-package-gui--check "one build started" (process-live-p portal-build--process))
    ;; Asking again while it builds starts nothing new.
    (ignore-errors (execute-kbd-macro (kbd "M-x portal-terminal RET")))
    (portal-package-gui--check "no second offer" (= (length prompts) 1))
    (portal-package-gui--check
     "the build finished"
     (portal-package-gui--wait (lambda () (not portal-build--process)) 1500))
    (portal-package-gui--check "Portal reported ready"
                               (member "Portal is ready: retry your command" messages))
    (portal-package-gui--check "the build is complete" (null (portal-build-problem)))
    (portal-package-gui--check "no native module loaded during setup"
                               (not (featurep 'portal-native-module)))))

(defun portal-package-gui--use ()
  "Open a terminal and a web view from the build that setup made."
  (portal-package-gui--check "the build is ready" (null (portal-build-problem)))
  (delete-other-windows)
  (call-interactively 'portal-terminal)
  (let ((target (portal-view-target)))
    (portal-package-gui--check "a terminal opened" (string-prefix-p "terminal:" target))
    (portal-package-gui--check
     "the terminal is shown"
     (portal-package-gui--wait (lambda () (plist-get (portal--inspect target) :visible)) 10)))
  (call-interactively 'portal-hello)
  (let ((target (portal-view-target)))
    (portal-package-gui--check "a web view opened" (string-prefix-p "web:" target))
    (portal-package-gui--check
     "the web view loaded Hello World from the app host"
     (portal-package-gui--wait
      (lambda ()
        (let ((state (portal--inspect target)))
          (and (plist-get state :visible) (equal (plist-get state :title) "Hello, world!")
               (string-prefix-p "http://127.0.0.1:" (plist-get state :url))
               (string-suffix-p "/hello" (plist-get state :url))
               (not (plist-get state :loading)) (not (plist-get state :error)))))
      20)
     (portal--inspect target))))

(condition-case err
    (progn
      (portal-package-gui--check "graphical Emacs" (eq window-system 'ns))
      (package-initialize)
      ;; Only for the checks: the commands themselves are autoloaded.
      (require 'portal-build)
      (pcase (getenv "PORTAL_PACKAGE_GUI_PHASE")
        ("setup" (portal-package-gui--setup))
        ("use" (portal-package-gui--use))
        (phase (portal-package-gui--check "a known phase" (not phase))))
      ;; The count the release notes read.
      (portal-package-gui--log "%d checks passed" portal-package-gui--passed)
      (kill-emacs 0))
  (error (portal-package-gui--log "FAIL %S" err)
         (kill-emacs 1)))

;;; portal-package-gui.el ends here
