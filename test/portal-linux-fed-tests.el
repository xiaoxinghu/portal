;;; portal-linux-fed-tests.el --- A Rex block's screen on Linux, to the pixel -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A fed terminal in a pgtk Emacs on Wayland, read from the output's
;; pixels: a grid that is not its pane's, drawn from the pane's bottom-left
;; corner, with the theme's background beside it or clipped at the top and
;; the right, at the terminal's opacity.  The block is the fake Rex
;; server's (test/fake-rex-server.py), and another client of its, "the
;; app", holds it at the grid each test chooses.  Loaded by
;; test/linux-gui.sh after test/portal-linux-gui-tests.el and
;; test/portal-linux-terminal-tests.el, whose helpers these use.
;;
;; The theme is Great Pumpkin, whose background is a flat orange, over a
;; pane that is green underneath; the block's output paints every cell of
;; its grid blue and the first cell of its last row red, in colours of
;; their own (24-bit), so the grid, its corner and what is beside it are
;; told apart.

(require 'ert)
(require 'cl-lib)
(require 'portal-rex)
(require 'portal-fake-rex)
(require 'portal-linux-gui-tests)
(require 'portal-linux-terminal-tests)

(defconst portal-linux-fed--paint
  "\e[0m\e[H\e[48;2;0;0;255m\e[2J\e[%d;1H\e[48;2;255;0;0m \e[48;2;0;0;255m\e[1;1Hpainted"
  "The output that paints a grid of %d rows blue, and its last row's first cell red.")

(defun portal-linux-fed--blue-p (color)
  (pcase-let ((`(,red ,green ,blue) color)) (and (< red 30) (< green 30) (> blue 225))))

(defun portal-linux-fed--red-p (color)
  (pcase-let ((`(,red ,green ,blue) color)) (and (> red 225) (< green 30) (< blue 30))))

(defmacro portal-linux-fed--showing (server &rest body)
  "Show SERVER's block, which the app holds, in a frame of one pane, and run BODY.
BODY runs with `target' bound to the block's terminal once it is live and
the buffer current.  Emacs has not the keyboard, so it takes no block."
  (declare (indent 1))
  `(let ((portal-rex-socket (portal-fake-rex-socket ,server))
         (menu menu-bar-mode) (tool tool-bar-mode)
         (theme portal-terminal-theme))
     (portal-linux-gui--tool "grim")
     (unwind-protect
         (save-window-excursion
           (menu-bar-mode -1)
           (tool-bar-mode -1)
           (delete-other-windows)
           (setq portal-terminal-theme portal-linux-terminal--theme)
           (advice-add 'frame-focus-state :override #'ignore '((name . portal-linux-fed)))
           (portal-rex-connect)
           (switch-to-buffer "*rex: fake/shell*")
           (face-remap-add-relative 'default :background portal-linux-gui--pane)
           (redisplay t)
           (let ((target portal-view--target))
             (should target)
             (portal-linux-gui--wait
              (lambda () (equal (plist-get (plist-get (portal--inspect target) :rex) :state)
                                "live")))
             ,@body))
       (advice-remove 'frame-focus-state 'portal-linux-fed)
       (mapc #'portal-rex-disconnect (portal-rex-connections))
       (setq portal-terminal-theme theme)
       (menu-bar-mode (if menu 1 -1))
       (tool-bar-mode (if tool 1 -1)))))

(defun portal-linux-fed--hold (server target columns rows)
  "Have the app hold SERVER's block at COLUMNS by ROWS, and paint it.
Returns once TARGET holds that grid and its frame shows the paint."
  (portal-fake-rex-command server :claim "block:fake-1" :client "client:app" :name "Rex.app"
                           :columns columns :rows rows)
  (portal-linux-gui--wait
   (lambda () (let ((state (portal--inspect target)))
                (equal (list (plist-get state :columns) (plist-get state :rows))
                       (list columns rows)))))
  (portal-fake-rex-command server :output "block:fake-1"
                           :data (format portal-linux-fed--paint rows))
  (portal-linux-terminal--shows target "painted")
  (portal-linux-gui--wait (lambda () (plist-get (portal--inspect target) :showing)))
  ;; The frame with the paint, and the pane's place, on the screen.
  (portal-linux-gui--pause 0.4))

(defun portal-linux-fed--padding ()
  "Ghostty's padding on each side, in device pixels: 2 points at 96 to the inch."
  (/ (* 2 96 (portal-linux-gui--scale)) 72))

(defun portal-linux-fed--cell (target)
  "TARGET's cell, (WIDTH HEIGHT), in device pixels."
  (plist-get (portal--inspect target) :cell))

(defun portal-linux-fed--outside (screen box)
  "Check that nothing of the terminal's is just outside BOX on SCREEN."
  (pcase-let ((`(,left ,top ,right ,bottom) box)
              (at (lambda (x y) (portal-linux-gui--pixel screen x y))))
    (dolist (point `((,(1- left) ,(/ (+ top bottom) 2)) (,right ,(/ (+ top bottom) 2))
                     (,(/ (+ left right) 2) ,bottom) (,(/ (+ left right) 2) ,(1- top))))
      (pcase-let ((`(,x ,y) point))
        (when (and (< -1 x (car screen)) (< -1 y (cadr screen)))
          (let ((color (funcall at x y)))
            (should-not (portal-linux-terminal--orange-p color))
            (should-not (portal-linux-fed--blue-p color))))))))

(ert-deftest portal-linux-gui-fed-holds-a-small-grid-from-the-bottom-left ()
  :tags '(:gui)
  (portal-fake-rex-with (server)
    (portal-linux-fed--showing server
      (portal-linux-fed--hold server target 20 5)
      (pcase-let* ((screen (portal-linux-gui--screen))
                   (`(,left ,top ,right ,bottom) (portal-linux-gui--box (selected-window)))
                   (`(,width ,height) (portal-linux-fed--cell target))
                   (padding (portal-linux-fed--padding))
                   (at (lambda (x y) (portal-linux-gui--pixel screen x y)))
                   ;; The grid's own box, from the pane's bottom left.
                   (grid-left (+ left padding))
                   (grid-bottom (- bottom padding))
                   (grid-top (- grid-bottom (* 5 height)))
                   (grid-right (+ grid-left (* 20 width))))
        (ert-info ((format "Pane %S, cell %S" (list left top right bottom) (list width height)))
          ;; Its last row's first cell at the pane's bottom left, inside
          ;; Ghostty's padding.
          (should (portal-linux-fed--red-p (funcall at (+ grid-left (/ width 2))
                                                    (- grid-bottom (/ height 2)))))
          (should (portal-linux-fed--blue-p (funcall at (+ grid-left (* 3 width))
                                                     (- grid-bottom (/ height 2)))))
          ;; Its edges to the pixel: the grid inside them, Ghostty's
          ;; padding or the backdrop just outside.
          (let ((middle (- grid-bottom (* 2 height))))
            (dolist (edge `((,grid-left ,middle t) (,(1- grid-left) ,middle nil)
                            (,(1- grid-right) ,middle t) (,grid-right ,middle nil)
                            ;; The first row's text is at its left.
                            (,(- grid-right (/ width 2)) ,grid-top t)
                            (,(- grid-right (/ width 2)) ,(1- grid-top) nil)
                            (,(+ grid-left width) ,(1- grid-bottom) t)
                            (,(+ grid-left width) ,grid-bottom nil)))
              (pcase-let ((`(,x ,y ,inside) edge))
                (ert-info ((format "At %S: %S" (list x y) (funcall at x y)))
                  (should (eq inside (portal-linux-fed--blue-p (funcall at x y))))
                  (unless inside
                    (should (portal-linux-terminal--orange-p (funcall at x y))))))))
          (should (portal-linux-terminal--orange-p (funcall at (+ grid-right width)
                                                            (+ grid-top (/ height 2)))))
          (should (portal-linux-terminal--orange-p (funcall at (+ grid-left width)
                                                            (- grid-top height))))
          ;; Below the grid, Ghostty's padding; beside and above it, the
          ;; theme's background, to the pane's corners.
          (should (portal-linux-terminal--orange-p (funcall at (+ grid-left width) (1- bottom))))
          (dolist (corner `((,left ,top) (,(1- right) ,top) (,(1- right) ,(1- bottom))
                            (,left ,(1- bottom))))
            (should (portal-linux-terminal--orange-p (apply at corner))))
          ;; No pane shows, and nothing of the terminal outside it.
          (should (= 0 (portal-linux-gui--count screen 'pane
                                                (list 0 0 (car screen) (cadr screen)))))
          (portal-linux-fed--outside screen (list left top right bottom)))))))

(ert-deftest portal-linux-gui-fed-clips-a-large-grid-at-the-top-and-right ()
  :tags '(:gui)
  (portal-fake-rex-with (server)
    (portal-linux-fed--showing server
      (pcase-let* ((`(,left ,top ,right ,bottom) (portal-linux-gui--box (selected-window)))
                   (`(,width ,height) (portal-linux-fed--cell target))
                   ;; More cells each way than the pane holds.
                   (columns (+ 8 (/ (- right left) width)))
                   (rows (+ 4 (/ (- bottom top) height))))
        (portal-linux-fed--hold server target columns rows)
        (pcase-let* ((screen (portal-linux-gui--screen))
                     (padding (portal-linux-fed--padding))
                     (at (lambda (x y) (portal-linux-gui--pixel screen x y))))
          (ert-info ((format "Pane %S, cell %S, grid %S" (list left top right bottom)
                             (list width height) (list columns rows)))
            ;; The last row's first cell at the pane's bottom left, as for
            ;; a small grid: the prompt stays in view.
            (should (portal-linux-fed--red-p (funcall at (+ left padding (/ width 2))
                                                      (- bottom padding (/ height 2)))))
            ;; The rest of the pane is grid, to its top and right edges.
            (dolist (corner `((,(1- right) ,top) (,(1- right) ,(- bottom padding 1))
                              (,(+ left padding) ,top)))
              (ert-info ((format "At %S: %S" corner (apply at corner)))
                (should (portal-linux-fed--blue-p (apply at corner)))))
            (should (= 0 (portal-linux-gui--count screen 'pane
                                                  (list 0 0 (car screen) (cadr screen)))))
            (portal-linux-fed--outside screen (list left top right bottom))))))))

(ert-deftest portal-linux-gui-fed-draws-its-background-once-below-full-opacity ()
  :tags '(:gui)
  (let ((original portal-terminal-opacity))
    (unwind-protect
        (portal-fake-rex-with (server)
          (setopt portal-terminal-opacity 0.5)
          (portal-linux-fed--showing server
            (portal-fake-rex-command server :claim "block:fake-1" :client "client:app"
                                     :name "Rex.app" :columns 20 :rows 5)
            (portal-linux-gui--wait
             (lambda () (equal (plist-get (portal--inspect target) :columns) 20)))
            (portal-fake-rex-command server :output "block:fake-1" :data "\e[H\e[2Jclear")
            (portal-linux-terminal--shows target "clear")
            (portal-linux-gui--pause 0.4)
            (pcase-let* ((screen (portal-linux-gui--screen))
                         (`(,left ,top ,right ,bottom) (portal-linux-gui--box (selected-window)))
                         (`(,width ,height) (portal-linux-fed--cell target))
                         (padding (portal-linux-fed--padding))
                         (at (lambda (x y) (portal-linux-gui--pixel screen x y)))
                         ;; An empty cell of the grid, and the pane beside it.
                         (inside (funcall at (+ left padding (* 10 width))
                                          (- bottom padding (/ height 2))))
                         (beside (funcall at (- right 4) (+ top 4))))
              (ert-info ((format "Inside %S, beside %S" inside beside))
                ;; The pane's green shows through the theme's orange, the
                ;; same in the grid as beside it: drawn once, not twice.
                (should-not (portal-linux-terminal--orange-p beside))
                (should-not (eq (portal-linux-gui--kind beside) 'pane))
                (should (> (nth 1 beside) #x90))
                (should (cl-every (lambda (a b) (< (abs (- a b)) 12)) inside beside))))))
      (setopt portal-terminal-opacity original))))

(provide 'portal-linux-fed-tests)
;;; portal-linux-fed-tests.el ends here
