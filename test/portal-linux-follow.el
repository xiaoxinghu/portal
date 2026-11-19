;;; portal-linux-follow.el --- A view following its pane, for a recording -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Loaded by test/linux-follow.sh into a fresh Emacs on the test desktop.  It
;; opens a test pattern in a pane and then, while the desktop is recorded,
;; changes that pane as a user would, one command at a time: splits, a pane
;; made larger, one pane again, the buffer switched away and back, a second
;; frame that halves the first and goes again, another program's window
;; that does the same, and, when asked, a child frame over the pane.
;; test/linux-recording.py reads the recording and says whether the view
;; was where its pane was in every frame of it.  The view is a test pattern,
;; or with PORTAL_FOLLOW_PATTERN "terminal" a terminal whose shell prints
;; blank lines as fast as it can, so that it makes frames all the while.
;;
;; Everything Emacs draws is a flat color that the reader can tell apart:
;; the view's pane green, which no frame may show, since the view covers
;; it; every other pane yellow; fringes navy; the mode line of a pane
;; showing the view's buffer brown and every other mode line gray, with no
;; text in either.

(require 'portal-view)

(defconst portal-linux-follow-terminal-theme "Great Pumpkin"
  "The theme of a terminal followed, whose orange background is the view's color.")

(defvar portal-linux-follow--directory (getenv "PORTAL_FOLLOW_DIRECTORY")
  "Where the script and this file leave each other word.")
(defvar portal-linux-follow--buffer nil)
(defvar portal-linux-follow--window nil "The view's pane, which every step acts in.")
(defvar portal-linux-follow--child nil)
(defvar portal-linux-follow--other nil)
(defvar portal-linux-follow--program nil)
(defvar portal-linux-follow--target nil "The view followed.")

(defun portal-linux-follow--say (name)
  (write-region "" nil (expand-file-name name portal-linux-follow--directory) nil 'silent))

(defun portal-linux-follow--plain (buffer)
  "Make BUFFER a flat yellow pane."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)) (erase-buffer))
    (face-remap-add-relative 'default :background "#ffff00")
    buffer))

(defun portal-linux-follow--scratch ()
  (portal-linux-follow--plain (get-buffer-create "*scratch*")))

(defconst portal-linux-follow--steps
  `((split-below . ,(lambda () (set-window-buffer (split-window-below)
                                                  (portal-linux-follow--scratch))))
    (split-right . ,(lambda () (set-window-buffer (split-window-right)
                                                  (portal-linux-follow--scratch))))
    (taller . ,(lambda () (enlarge-window 6)))
    (wider . ,(lambda () (enlarge-window 10 t)))
    (one-pane . ,(lambda () (delete-other-windows)))
    (away . ,(lambda () (switch-to-buffer (portal-linux-follow--scratch))))
    (back . ,(lambda () (switch-to-buffer portal-linux-follow--buffer)))
    (second-frame
     . ,(lambda ()
          (let ((home (selected-frame)))
            (setq portal-linux-follow--other (make-frame))
            (set-window-buffer (frame-selected-window portal-linux-follow--other)
                               (portal-linux-follow--scratch))
            (select-frame home))))
    (first-frame-alone . ,(lambda () (delete-frame portal-linux-follow--other)))
    ;; Another program's window, which the compositor puts beside this one
    ;; while Emacs is idle; it takes a moment to come.
    (second-window
     . ,(lambda ()
          (setq portal-linux-follow--program
                (start-process "portal-linux-follow" nil
                               (expand-file-name invocation-name invocation-directory)
                               "-Q" "--eval"
                               "(progn (setq-default mode-line-format \"\" cursor-type nil)
                                       (menu-bar-mode -1) (tool-bar-mode -1) (scroll-bar-mode -1)
                                       (set-face-attribute 'fringe nil :background \"#ffff00\")
                                       (set-face-attribute 'default nil :background \"#ffff00\")
                                       (set-face-attribute 'mode-line nil :background \"#a0a0a0\" :box nil)
                                       (setq inhibit-startup-screen t))"))))
    (first-window-alone . ,(lambda () (delete-process portal-linux-follow--program)))
    (wait . ignore)
    (child-frame
     . ,(lambda ()
          (setq portal-linux-follow--child
                (make-frame `((parent-frame . ,(selected-frame)) (left . 200) (top . 120)
                              (width . 30) (height . 5) (minibuffer . nil)
                              (no-accept-focus . t) (undecorated . t))))
          (set-window-buffer (frame-selected-window portal-linux-follow--child)
                             (portal-linux-follow--scratch))))
    (no-child-frame . ,(lambda () (delete-frame portal-linux-follow--child))))
  "Each step's name and what it does, in the view's pane.")

(defun portal-linux-follow--run (names rounds interval)
  "Do the steps NAMES, ROUNDS times over, one each INTERVAL seconds, then say so."
  (let ((queue (apply #'append (make-list rounds names))))
    (letrec ((timer
              (run-at-time
               interval interval
               (lambda ()
                 (if (null queue)
                     (progn (cancel-timer timer)
                            ;; What the view counted, for the script to print.
                            (write-region (format "%S\n" (portal--inspect portal-linux-follow--target))
                                          nil (expand-file-name "facts" portal-linux-follow--directory)
                                          nil 'silent)
                            (portal-linux-follow--say "done"))
                   (let ((step (pop queue)))
                     (when (getenv "PORTAL_LINUX_TRACE") (princ (format "step %s\n" step) #'external-debugging-output))
                     (with-selected-window portal-linux-follow--window
                       (funcall (alist-get step portal-linux-follow--steps)))))))))
      timer)))

(defun portal-linux-follow-start ()
  "Open the view, say when it shows, and run the steps once the script says to."
  (setq inhibit-startup-screen t
        ring-bell-function #'ignore)
  (setq-default mode-line-format "" cursor-type nil cursor-in-non-selected-windows nil)
  (menu-bar-mode -1)
  (tool-bar-mode -1)
  (scroll-bar-mode -1)
  (blink-cursor-mode -1)
  (set-face-attribute 'fringe nil :background "#000080")
  (dolist (face '(mode-line mode-line-inactive))
    (set-face-attribute face nil :background "#a0a0a0" :box nil))
  (when (facep 'mode-line-active)
    (set-face-attribute 'mode-line-active nil :background 'unspecified :box 'unspecified))
  (portal-linux-follow--scratch)
  (setq portal-linux-follow--buffer (generate-new-buffer "*portal-linux-follow*"))
  (switch-to-buffer portal-linux-follow--buffer)
  (setq portal-linux-follow--window (selected-window))
  (face-remap-add-relative 'default :background "#00ff00")
  (dolist (face '(mode-line mode-line-inactive mode-line-active))
    (when (facep face) (face-remap-add-relative face :background "#804000")))
  (let* ((kind (getenv "PORTAL_FOLLOW_PATTERN"))
         (target
          (portal-view-open
           'terminal
           (if (equal kind "terminal")
               ;; A terminal under output all the while, its frames all
               ;; its theme's flat background: blank lines, with the
               ;; cursor hidden.
               (list :directory "/" :theme portal-linux-follow-terminal-theme :points 12
                     :command "sh -c 'printf \"\\033[?25l\"; exec yes \"\"'")
             (list :directory "/" :test-pattern (if (equal kind "fill") "fill" t)))))
         (_ (setq portal-linux-follow--target target))
         (names (mapcar #'intern (split-string (getenv "PORTAL_FOLLOW_STEPS"))))
         (rounds (string-to-number (getenv "PORTAL_FOLLOW_ROUNDS")))
         (interval (string-to-number (getenv "PORTAL_FOLLOW_INTERVAL"))))
    (letrec ((waiting
              (run-at-time
               0.1 0.1
               (lambda ()
                 (cond
                  ((file-exists-p (expand-file-name "go" portal-linux-follow--directory))
                   (cancel-timer waiting)
                   (portal-linux-follow--run names rounds interval))
                  ((plist-get (portal--inspect target) :showing)
                   ;; The echo area empty, for the reader.
                   (message nil)
                   (portal-linux-follow--say "ready")))))))
      waiting)))

(provide 'portal-linux-follow)
;;; portal-linux-follow.el ends here
