;;; portal-system-tests.el --- System-wide actions in batch Emacs -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Runs the real Lisp module on the real C core: PORTAL_TEST_MODULE names
;; the module built with test/portal-fake-backend.c, which posts any chord
;; but one with F19, refusing it with a message that names the key and
;; modifiers it was asked to post, and shows any status but one starting
;; with "Refuse", quoting the text it was given.
;; test/portal-shortcuts-tests.c covers what reaches the platform for each
;; chord, test/portal-status-tests.c where the status panel goes, and
;; test/native-status.swift the real panel.

(require 'ert)

(let ((file (getenv "PORTAL_TEST_MODULE")))
  (unless (and file (file-exists-p file))
    (error "Set PORTAL_TEST_MODULE to the fake-backend module"))
  (module-load file))

(require 'portal-system)
(require 'portal-global-shortcut)
(declare-function portal--shortcuts "portal-global-shortcut" ())

(defmacro portal-system-tests--with (&rest body)
  "Run BODY with the native module standing in for macOS's."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'portal-view--load) #'ignore))
     ,@body))

(ert-deftest portal-system-post-key-posts-valid-chords ()
  (portal-system-tests--with
    (dolist (chord '("Command-V" "command-v" "Shift-Option-Command-7" "Control-Space"
                     "Control-F12"))
      (should-not (portal-post-key chord)))
    (should-not (portal--shortcuts))))

(ert-deftest portal-system-post-key-rejects-what-global-shortcuts-reject ()
  (portal-system-tests--with
    (dolist (chord '("" "V" "Shift-V" "Hyper-V" "Command-Command-V" "Command-F21"
                     "Command-!" "Command-V Q" "Command-É"))
      (let ((posting (should-error (portal-post-key chord)))
            (setting (should-error (portal-global-shortcut-set 'portal-system-tests chord
                                                               #'ignore))))
        (should (equal posting setting))))
    (dolist (chord '(nil 86 Command-V))
      (should-error (portal-post-key chord) :type 'user-error))
    (should-not portal-global-shortcut--registrations)))

(ert-deftest portal-system-post-key-signals-the-platform-error ()
  (portal-system-tests--with
    ;; The platform received the parsed key and modifiers: F19, Control and
    ;; Shift.
    (should (equal (should-error (portal-post-key "shift-control-f19"))
                   '(error "Cannot post Control-Shift-F19: The fake may not post F19+3")))))

(defmacro portal-system-tests--recording-status (calls &rest body)
  "Run BODY, pushing each call of the native status functions onto CALLS.
The calls still reach the module."
  (declare (indent 1))
  `(let ((show (symbol-function 'portal--status-show))
         (hide (symbol-function 'portal--status-hide)))
     (cl-letf (((symbol-function 'portal--status-show)
                (lambda (&rest arguments) (push (cons 'show arguments) ,calls)
                  (apply show arguments)))
               ((symbol-function 'portal--status-hide)
                (lambda () (push '(hide) ,calls) (funcall hide))))
       (unwind-protect (progn ,@body)
         (portal-status--cancel-timer)))))

(ert-deftest portal-system-status-shows-and-hides ()
  (portal-system-tests--with
    (let (calls)
      (portal-system-tests--recording-status calls
        (should-not (portal-status-show "Pasted" :tone 'success))
        (should-not (portal-status-show "Transcribing…" :tone 'progress))
        (should-not (portal-status-hide))
        (should-not (portal-status-hide)))
      (should (equal (nreverse calls)
                     '((show "Pasted" "success" "bottom" -1 0 24 0 0 0 0 1)
                       (show "Transcribing…" "progress" "bottom" -1 0 24 0 0 0 0 1)
                       (hide) (hide)))))))

(ert-deftest portal-system-status-passes-its-options ()
  (portal-system-tests--with
    (let (calls)
      (portal-system-tests--recording-status calls
        ;; The margin keeps off anchored edges only.
        (dolist (position portal-status-positions)
          (portal-status-show "Recording" :position position))
        (portal-status-show "Done" :position 'top-right :offset '(-5 . 40) :screen 'primary
                            :width 300 :height 40 :tone 'success)
        (portal-status-show "A long status" :screen 2 :min-width 120 :max-width 480
                            :max-lines 3 :tone 'error))
      (should (equal (mapcar (lambda (call) (nthcdr 4 call)) (reverse (nthcdr 2 calls)))
                     '((-1 24 24 0 0 0 0 1) (-1 0 24 0 0 0 0 1) (-1 24 24 0 0 0 0 1)
                       (-1 24 0 0 0 0 0 1) (-1 0 0 0 0 0 0 1) (-1 24 0 0 0 0 0 1)
                       (-1 24 24 0 0 0 0 1) (-1 0 24 0 0 0 0 1) (-1 24 24 0 0 0 0 1))))
      (should (equal (cadr calls) '(show "Done" "success" "top-right" 0 -5 40 300 40 0 0 1)))
      (should (equal (car calls)
                     '(show "A long status" "error" "bottom" 2 0 24 0 0 120 480 3))))))

(ert-deftest portal-system-status-hides-after-its-timeout ()
  (portal-system-tests--with
    (let (calls)
      (portal-system-tests--recording-status calls
        (portal-status-show "Pasted" :tone 'success :timeout 0.01)
        ;; Wait for the timer, however late a busy machine runs it.
        (with-timeout (5 nil)
          (while (not (equal (car calls) '(hide))) (sleep-for 0.01)))
        (should (equal (car calls) '(hide)))
        ;; Showing again cancels the timeout, and hiding forgets it.
        (setq calls nil)
        (portal-status-show "Pasted" :timeout 0.01)
        (portal-status-show "Recording")
        (portal-status-show "Pasted" :timeout 0.05)
        (portal-status-hide)
        (sleep-for 0.1)
        (should (equal (mapcar #'car calls) '(hide show show show)))))))

(ert-deftest portal-system-status-rejects-invalid-options ()
  (portal-system-tests--with
    (dolist (text '(nil "" 42 Recording))
      (should-error (portal-status-show text) :type 'user-error))
    (dolist (options '((:position middle) (:position "top") (:offset (1 2)) (:offset 5)
                       (:screen main) (:screen -1) (:width 0) (:height -5) (:min-width 1.5)
                       (:max-width "wide") (:max-lines 0) (:tone loud) (:tone recording)
                       (:timeout 0) (:timeout "soon")))
      (should-error (apply #'portal-status-show "Recording" options) :type 'user-error))
    ;; The core rejects what only it can check.
    (should (equal (should-error (portal-status-show "Recording" :min-width 300
                                                     :max-width 200))
                   '(error "A status panel's minimum width exceeds its maximum")))))

(ert-deftest portal-system-status-signals-the-platform-error ()
  (portal-system-tests--with
    ;; The platform received the text as given.
    (should (equal (should-error (portal-status-show "Refuse «dictée»"))
                   '(error "The fake may not show \"Refuse «dictée»\"")))))

(provide 'portal-system-tests)
;;; portal-system-tests.el ends here
