;;; portal-pointer-gui-tests.el --- The mouse pointer over a view -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Load the test-only event injector first. The mouse moves as a mouse's
;; does: the injector warps the pointer and sends AppKit the mouse-moved
;; event, in several moves, never one, since WebKit answers the first move
;; before AppKit has let go of the pointer Emacs's cursor rectangle gave it.

(require 'ert)
(require 'portal-web)
(require 'portal-terminal)
(require 'portal-tests)
(require 'portal-terminal-tests)
(declare-function portal-test-mouse-move "test-terminal-input" (x y &optional flags))
(declare-function portal-test-cursor "test-terminal-input" ())
(declare-function portal--inspect "portal-view" (target))
(declare-function portal-test-native-target-frame "test-terminal-input" (title))

(defconst portal-pointer-gui--command (ash 1 20)
  "AppKit's modifier flag for Command.")

(defconst portal-pointer-gui--page
  (concat "data:text/html,<title>Pointer</title><style>"
          "body{margin:0} a,div{display:block;position:absolute;left:0;width:240px;height:60px}"
          "a{top:0;font-size:40px} div{top:100px;cursor:crosshair}</style>"
          "<a href='https://example.com/'>Link</a><div></div>")
  "A page with a link at the top and a region asking for the crosshair below.")

(defvar portal-pointer-gui--at nil
  "Where the injector last put the pointer, (X . Y) in frame pixels.")

(defun portal-pointer-gui--glide (x y &optional flags)
  "Move the pointer to X Y, frame pixels, as a mouse does, holding FLAGS.
It goes in four moves 10 ms apart from where it last went."
  (let ((from (or portal-pointer-gui--at (cons x y))))
    (dotimes (i 5)
      (should (portal-test-mouse-move (+ (car from) (/ (* (- x (car from)) i) 4))
                                      (+ (cdr from) (/ (* (- y (cdr from)) i) 4))
                                      flags))
      ;; Emacs redraws between moves, as it does when idle, and so
      ;; redoes its cursor rectangle as its own pointer changes.
      (redisplay t)
      (accept-process-output nil 0.01))
    (setq portal-pointer-gui--at (cons x y))))

(defun portal-pointer-gui--in (target x y)
  "The frame pixels of X Y in view TARGET, from its top-left corner."
  (let ((edges (plist-get (portal--inspect target) :edges)))
    (cons (+ (nth 0 edges) x) (+ (nth 1 edges) y))))

(defun portal-pointer-gui--glide-in (target x y &optional flags)
  "Glide to X Y in view TARGET, holding FLAGS."
  (let ((point (portal-pointer-gui--in target x y)))
    (portal-pointer-gui--glide (car point) (cdr point) flags)))

(defun portal-pointer-gui--glide-onto-text (window)
  "Glide onto the text at the top-left of Emacs WINDOW."
  (let ((edges (window-inside-pixel-edges window)))
    (portal-pointer-gui--glide (+ (nth 0 edges) 30) (+ (nth 1 edges) 8))))

(defun portal-pointer-gui--expect (name)
  "Wait for the pointer to be NAME, a name `portal-test-cursor' returns.
The pointer stays still meanwhile: a page answers the moves already made."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (equal (portal-test-cursor) name)) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (redisplay t)))
  (should (equal (portal-test-cursor) name)))

(defmacro portal-pointer-gui--with-page (&rest body)
  "Run BODY with text in a left window and the page in the selected right one.
TEXT is bound to the left window and TARGET to the page's view."
  (declare (indent 0))
  `(portal-test--with-web
     (let ((text-buffer (get-buffer-create " *portal-pointer-text*"))
           (portal-pointer-gui--at nil))
       (unwind-protect
           (progn
             (with-current-buffer text-buffer
               (dotimes (i 60) (insert (format "Line %d of plain text, long enough to point at.\n" i)))
               (goto-char (point-min)))
             (select-frame-set-input-focus (selected-frame))
             (sit-for 0.1)
             (should (portal-view--with-frame-title (selected-frame)
                                                    #'portal-test-native-target-frame))
             (switch-to-buffer text-buffer)
             (let ((text (selected-window)))
               (select-window (split-window-right))
               (portal-open-url portal-pointer-gui--page)
               (portal-test--wait-for-page "Pointer")
               (let ((target (portal-view-target)))
                 (ignore text target)
                 ,@body)))
         (portal-test-native-target-frame nil)
         (kill-buffer text-buffer)))))

(ert-deftest portal-pointer-gui-a-page-sets-its-pointer-and-emacs-gets-it-back ()
  :tags '(:gui)
  (portal-pointer-gui--with-page
    (let ((page (current-buffer))
          (other (get-buffer-create " *portal-pointer-other*")))
      (unwind-protect
          (progn
            (portal-pointer-gui--glide-onto-text text)
            (portal-pointer-gui--expect "ibeam")
            ;; Over the page, what it asks for, not Emacs's I-beam.
            (portal-pointer-gui--glide-in target 100 30)
            (portal-pointer-gui--expect "hand")
            ;; Emacs redraws with the mouse at rest, and redoes its rectangle.
            (message "Redrawn under the page")
            (redisplay t)
            (portal-pointer-gui--expect "hand")
            (portal-pointer-gui--glide-in target 100 130)
            (portal-pointer-gui--expect "crosshair")
            ;; Off the view, Emacs's again.
            (portal-pointer-gui--glide-onto-text text)
            (portal-pointer-gui--expect "ibeam")
            (portal-pointer-gui--glide-in target 100 30)
            (portal-pointer-gui--expect "hand")
            ;; Hidden with the mouse in it: no exit comes.
            (set-window-buffer (selected-window) other)
            (redisplay t)
            (should-not (plist-get (portal--inspect target) :visible))
            (portal-pointer-gui--glide-onto-text text)
            (portal-pointer-gui--expect "ibeam")
            ;; Back, and closed with the mouse in it.
            (set-window-buffer (selected-window) page)
            (redisplay t)
            (portal-terminal-test--wait (lambda () (plist-get (portal--inspect target) :visible)))
            (portal-pointer-gui--glide-in target 100 30)
            (portal-pointer-gui--expect "hand")
            (kill-buffer page)
            (redisplay t)
            (portal-pointer-gui--glide-onto-text text)
            (portal-pointer-gui--expect "ibeam"))
        (kill-buffer other)))))

(defun portal-pointer-gui--cell (target column row)
  "The point in terminal TARGET at the middle of the cell at COLUMN and ROW."
  (let* ((state (portal--inspect target))
         (edges (plist-get state :edges))
         ;; Ghostty pads the grid by 2 points on each side.
         (width (/ (float (- (nth 2 edges) (nth 0 edges) 4)) (plist-get state :columns)))
         (height (/ (float (- (nth 3 edges) (nth 1 edges) 4)) (plist-get state :rows))))
    (list (round (+ 2 (* width (+ column 0.5)))) (round (+ 2 (* height (+ row 0.5)))))))

(defun portal-pointer-gui--glide-to-cell (column row &optional flags)
  "Glide to the cell at COLUMN and ROW of the session's terminal, holding FLAGS."
  (pcase-let ((`(,x ,y) (portal-pointer-gui--cell portal-terminal-test--target column row)))
    (portal-pointer-gui--glide-in portal-terminal-test--target x y flags)))

(ert-deftest portal-pointer-gui-a-terminal-shows-ghosttys-pointer ()
  :tags '(:gui)
  (portal-terminal-test--session
    (let ((directory (make-temp-file "portal-pointer-gui-" t))
          (portal-pointer-gui--at nil))
      (unwind-protect
          (let ((printed (expand-file-name "printed" directory))
                (moused (expand-file-name "moused" directory)))
            (should (portal-view--with-frame-title (selected-frame)
                                                   #'portal-test-native-target-frame))
            (portal-terminal-test--wait
             (lambda () (plist-get (portal-terminal-test--state) :ready)))
            (portal-terminal-test--paste
             (format "clear; printf 'https://example.com/pointer\\n'; : > %s"
                     (shell-quote-argument printed))
             t)
            (portal-terminal-test--wait
             (lambda () (and (file-exists-p printed)
                             (string-match-p "^https://example\\.com/pointer$"
                                             (portal-terminal-test--text)))))
            ;; Over the link with Command, the hand Ghostty asks for.
            (portal-pointer-gui--glide-to-cell 30 8)
            (portal-pointer-gui--glide-to-cell 8 0 portal-pointer-gui--command)
            (portal-pointer-gui--expect "hand")
            ;; Off it, Ghostty's I-beam.
            (portal-pointer-gui--glide-to-cell 30 8)
            (portal-pointer-gui--expect "ibeam")
            ;; A program with the mouse gets Ghostty's arrow, where Emacs
            ;; would show its I-beam. Its mouse reports go to cat.
            (portal-terminal-test--paste
             (format "printf '\\033[?1003hMOUSE_ON\\n'; : > %s; cat > /dev/null"
                     (shell-quote-argument moused))
             t)
            (portal-terminal-test--wait
             (lambda () (and (file-exists-p moused)
                             (string-search "MOUSE_ON" (portal-terminal-test--text)))))
            (portal-pointer-gui--glide-to-cell 20 6)
            (portal-pointer-gui--expect "arrow"))
        (portal-test-native-target-frame nil)
        (delete-directory directory t)))))

(provide 'portal-pointer-gui-tests)
;;; portal-pointer-gui-tests.el ends here
