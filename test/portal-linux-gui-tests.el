;;; portal-linux-gui-tests.el --- Portal's views and input on Linux -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; The view machinery of native/Linux, in a pgtk Emacs on Wayland, with the
;; test pattern for content (native/Linux/pattern.c).  Run by
;; test/linux-gui.sh on the desktop that test/linux-desktop.sh makes, a
;; Hyprland of the tests' own with one headless output: these tests read
;; that output's pixels with grim, type with wtype and point with
;; build/linux/portal-test-pointer, all of which act on that desktop alone.
;; One Emacs frame fills the output, so a pixel of the output is a pixel of
;; the frame.
;;
;; A view's pane has a green background.  The pattern has a red edge one
;; device pixel wide around a magenta fill, with a blue square in the
;; middle, so a pane that the view covers exactly shows a red corner at
;; each of its own and no green anywhere.

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'portal-view)
(require 'portal-input)

(defconst portal-linux-gui--pane "#00ff00" "The background of a view's pane.")

(defvar portal-linux-gui--target nil "The view of the test that runs.")

(defun portal-linux-gui--tool (name)
  "Return the program NAME, which these tests cannot run without."
  (or (executable-find name) (ert-fail (format "The Linux graphical checks need %s" name))))

(defun portal-linux-gui--state (&optional target)
  "Return what the module describes of TARGET, or of this test's view."
  (portal--inspect (or target portal-linux-gui--target)))

(defun portal-linux-gui--get (key &optional target)
  (plist-get (portal-linux-gui--state target) key))

(defun portal-linux-gui--wait (predicate)
  "Wait for PREDICATE, letting GTK and the pipe run, for at most 10 seconds."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (redisplay t))
    (should (funcall predicate))))

(defun portal-linux-gui--pause (seconds)
  "Let GTK and the pipe run for SECONDS."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.02)
      (redisplay t))))

(defun portal-linux-gui--events ()
  "Let the command loop handle what waits for it, such as focus events.
Other events that wait are dropped."
  (while (read-event nil nil 0.15)))

(defun portal-linux-gui--scale ()
  (string-to-number (or (getenv "PORTAL_TEST_DESKTOP_SCALE") "2")))

(defun portal-linux-gui--origin (&optional frame)
  "Return where FRAME's top left is on the output, in device pixels, as (X . Y)."
  (let* ((frame (or frame (selected-frame)))
         (name (make-temp-name "portal-linux-gui-"))
         (title (frame-parameter frame 'title))
         found)
    (unwind-protect
        (progn
          (set-frame-parameter frame 'title name)
          (portal-linux-gui--wait
           (lambda ()
             (with-temp-buffer
               (call-process (portal-linux-gui--tool "hyprctl") nil t nil "clients" "-j")
               (goto-char (point-min))
               (setq found (cl-find name (json-parse-buffer :object-type 'alist :array-type 'list)
                                    :key (lambda (client) (alist-get 'title client))
                                    :test #'equal))))))
      (set-frame-parameter frame 'title title))
    (pcase-let ((`(,x ,y) (alist-get 'at found)))
      (cons (* x (portal-linux-gui--scale)) (* y (portal-linux-gui--scale))))))

(defun portal-linux-gui--screen ()
  "Return the output's pixels now, as (WIDTH HEIGHT START . BYTES), from grim."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'binary))
      (should (eql 0 (call-process (portal-linux-gui--tool "grim") nil t nil "-t" "ppm" "-o"
                                   (getenv "PORTAL_TEST_DESKTOP") "-"))))
    (goto-char (point-min))
    (should (looking-at "P6[ \n]\\([0-9]+\\)[ \n]\\([0-9]+\\)[ \n]255\n"))
    (list (string-to-number (match-string 1)) (string-to-number (match-string 2))
          (1- (match-end 0)) (buffer-string))))

(defun portal-linux-gui--pixel (screen x y)
  "Return the color at X, Y of SCREEN, in device pixels, as (RED GREEN BLUE)."
  (pcase-let ((`(,width ,_ ,start ,bytes) screen))
    (let ((at (+ start (* 3 (+ x (* y width))))))
      (list (aref bytes at) (aref bytes (+ at 1)) (aref bytes (+ at 2))))))

(defun portal-linux-gui--kind (color)
  "Say what COLOR, (RED GREEN BLUE), is: `edge', `fill', `square', `pane' or nil."
  (pcase-let ((`(,red ,green ,blue) color))
    (cond ((and (> red 250) (< green 5) (< blue 5)) 'edge)
          ((and (= red 217) (= green 51) (<= 153 blue 184)) 'fill)
          ((and (< red 5) (> blue 250)) 'square)
          ((and (< red 5) (> green 250) (< blue 5)) 'pane))))

(defun portal-linux-gui--count (screen kind box)
  "Count the pixels of SCREEN that are KIND in BOX, (LEFT TOP RIGHT BOTTOM), by sampling.
Every fourth pixel of every fourth row is looked at."
  (pcase-let ((`(,left ,top ,right ,bottom) box)
              (count 0))
    (cl-loop for y from top below bottom by 4
             do (cl-loop for x from left below right by 4
                         when (eq (portal-linux-gui--kind (portal-linux-gui--pixel screen x y)) kind)
                         do (cl-incf count)))
    count))
(byte-compile 'portal-linux-gui--pixel)
(byte-compile 'portal-linux-gui--kind)
(byte-compile 'portal-linux-gui--count)

(defun portal-linux-gui--box (window)
  "Return WINDOW's body on the output, in device pixels, as (LEFT TOP RIGHT BOTTOM).
For a frame with no menu bar and no tool bar, whose panes start at its
window's top left."
  (pcase-let ((`(,x . ,y) (portal-linux-gui--origin (window-frame window)))
              (scale (portal-linux-gui--scale)))
    (cl-mapcar (lambda (edge offset) (+ offset (* scale edge)))
               (window-inside-pixel-edges window) (list x y x y))))

(defun portal-linux-gui--settled-p (window)
  "Whether the view shows a frame it drew for WINDOW's body."
  (pcase-let ((`(,left ,top ,right ,bottom) (window-inside-pixel-edges window))
              (state (portal-linux-gui--state))
              (scale (portal-linux-gui--scale)))
    (and (plist-get state :showing)
         (equal (plist-get state :edges) (list left top right bottom))
         (equal (plist-get state :drawn)
                (list (* scale (- right left)) (* scale (- bottom top)))))))

(defun portal-linux-gui--covers (window)
  "Check that the pattern covers WINDOW's body on the screen, to the pixel."
  (portal-linux-gui--wait (lambda () (portal-linux-gui--settled-p window)))
  ;; The frame after the one that settled it is on the screen by then.
  (portal-linux-gui--pause 0.1)
  (pcase-let* ((screen (portal-linux-gui--screen))
               (`(,left ,top ,right ,bottom) (portal-linux-gui--box window))
               (kind (lambda (x y) (portal-linux-gui--kind (portal-linux-gui--pixel screen x y)))))
    (ert-info ((format "Pane %S of a %dx%d screen" (list left top right bottom)
                       (car screen) (cadr screen)))
      ;; Its edge on the pane's outermost pixels, the fill just inside, and
      ;; nothing of the view just outside.
      (dolist (corner `((,left ,top 1 1) (,(1- right) ,top -1 1)
                        (,left ,(1- bottom) 1 -1) (,(1- right) ,(1- bottom) -1 -1)))
        (pcase-let ((`(,x ,y ,dx ,dy) corner))
          (should (eq (funcall kind x y) 'edge))
          (should (eq (funcall kind (+ x dx) (+ y dy)) 'fill))
          (should-not (funcall kind (- x dx) y))
          (when (< -1 (- y dy) (cadr screen))
            (should-not (funcall kind x (- y dy))))))
      (should (eq (funcall kind (/ (+ left right) 2) (/ (+ top bottom) 2)) 'square))
      ;; No pane shows beside the view, nor any view outside the pane.
      (should (= 0 (portal-linux-gui--count screen 'pane (list 0 0 (car screen) (cadr screen)))))
      (should (= 0 (portal-linux-gui--count screen 'fill (list 0 bottom (car screen) (cadr screen)))))
      (should (= 0 (portal-linux-gui--count screen 'fill (list right 0 (car screen) (cadr screen))))))))

(defmacro portal-linux-gui--with-view (kind options &rest body)
  "Run BODY with a test pattern of KIND, made with OPTIONS, in the selected pane.
The frame has one pane, and neither menu bar nor tool bar."
  (declare (indent 2))
  `(let ((buffer (generate-new-buffer "*portal-linux-gui*"))
         (menu menu-bar-mode) (tool tool-bar-mode))
     (portal-linux-gui--tool "grim")
     (portal-linux-gui--tool "wtype")
     (unwind-protect
         (save-window-excursion
           (menu-bar-mode -1)
           (tool-bar-mode -1)
           (delete-other-windows)
           (switch-to-buffer buffer)
           (face-remap-add-relative 'default :background portal-linux-gui--pane)
           (portal-input-mode 1)
           (use-local-map (make-sparse-keymap))
           (redisplay t)
           (let ((portal-linux-gui--target
                  (portal-view-open ,kind (append '(:test-pattern t) ,options))))
             (portal-linux-gui--wait (lambda () (portal-linux-gui--get :showing)))
             ,@body))
       ;; What a test typed or clicked and nobody read is no later test's.
       (portal-linux-gui--pause 0.1)
       (discard-input)
       (setq unread-command-events nil)
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (menu-bar-mode (if menu 1 -1))
       (tool-bar-mode (if tool 1 -1)))))

(defun portal-linux-gui--type (&rest arguments)
  "Type with wtype, as its ARGUMENTS say, into the test desktop."
  (should (eql 0 (apply #'call-process (portal-linux-gui--tool "wtype") nil nil nil arguments))))

(defun portal-linux-gui--point (&rest actions)
  "Move, click and scroll the test desktop's pointer, as ACTIONS say.
A position is in the desktop's own pixels, which are Emacs's."
  (let ((program (expand-file-name "build/linux/portal-test-pointer" (getenv "PORTAL_GUI_ROOT"))))
    (should (eql 0 (apply #'call-process program nil nil nil
                          (or (getenv "PORTAL_TEST_DESKTOP_WIDTH") "1280")
                          (or (getenv "PORTAL_TEST_DESKTOP_HEIGHT") "800")
                          (mapcar (lambda (action) (format "%s" action)) actions))))))

(defun portal-linux-gui--focus ()
  "Give the test's view the keyboard."
  (should (portal--input portal-linux-gui--target "focus"))
  (portal-linux-gui--wait (lambda () (portal-linux-gui--get :focused))))

(defun portal-linux-gui--handoff ()
  "Read the handoff of a chord the view's app did not use, and run its command."
  (let ((event (aref (with-timeout (5 (ert-fail "No chord reached Emacs"))
                       (read-key-sequence-vector nil))
                     0)))
    (ert-info ((format "Received: %S" event))
      (should (eq (car-safe event) 'portal-input-key)))
    (with-timeout (5 (ert-fail "The chord's command stalled"))
      (portal-input--dispatch event))))

(defvar portal-linux-gui--ran nil)
(defun portal-linux-gui--mark () (interactive) (setq portal-linux-gui--ran t))

;;; Where a view is

(ert-deftest portal-linux-gui-says-which-views-linux-lacks ()
  :tags '(:gui)
  (portal-view--load)
  (should (equal (cadr (should-error (portal--open "terminal" '(:directory "/")) :type 'error))
                 "Portal has no terminals on Linux yet"))
  (should (equal (cadr (should-error (portal--open "web" nil) :type 'error))
                 "Portal has no web views on Linux yet"))
  (should-not (portal--inspect "terminal:1")))

(ert-deftest portal-linux-gui-view-covers-its-pane-to-the-pixel ()
  :tags '(:gui)
  (portal-linux-gui--with-view 'terminal '(:directory "/")
    (let ((window (selected-window)))
      (should (equal (portal-linux-gui--get :scale) (portal-linux-gui--scale)))
      (portal-linux-gui--covers window)
      ;; Through splits, a pane made larger, and the frame's one pane again.
      (let ((below (split-window-below)))
        (set-window-buffer below (get-buffer-create "*scratch*"))
        (portal-linux-gui--covers window)
        (let ((right (split-window-right)))
          (set-window-buffer right (get-buffer-create "*scratch*"))
          (portal-linux-gui--covers window)
          (enlarge-window 5)
          (portal-linux-gui--covers window)
          (enlarge-window 12 t)
          (portal-linux-gui--covers window))
        (delete-other-windows window)
        (portal-linux-gui--covers window))
      ;; A tab bar is Emacs's own, inside the frame's widget.
      (unwind-protect
          (progn (tab-bar-mode 1)
                 (portal-linux-gui--covers window))
        (tab-bar-mode -1))
      (portal-linux-gui--covers window))))

(ert-deftest portal-linux-gui-view-sits-below-the-menu-and-tool-bars ()
  :tags '(:gui)
  "GTK's bars move Emacs's widget in the window, and the view with it."
  (portal-linux-gui--with-view 'terminal '(:directory "/")
    (let ((window (selected-window)))
      (unwind-protect
          (progn
            (menu-bar-mode 1)
            (tool-bar-mode 1)
            (portal-linux-gui--wait (lambda () (portal-linux-gui--settled-p window)))
            (portal-linux-gui--pause 0.3)
            (pcase-let* ((screen (portal-linux-gui--screen))
                         (scale (portal-linux-gui--scale))
                         (`(,left ,top ,right ,bottom) (window-inside-pixel-edges window))
                         (column (* scale (+ left 20)))
                         (first (cl-loop for y from 0 below (cadr screen)
                                         when (portal-linux-gui--kind
                                               (portal-linux-gui--pixel screen column y))
                                         return y))
                         (last (+ first (* scale (- bottom top)) -1)))
              ;; The bars are above the pane, and the view begins where the
              ;; pane does: no pane shows above or below it.
              (should (> first (* scale top)))
              (should (eq (portal-linux-gui--kind (portal-linux-gui--pixel screen column first))
                          'edge))
              (should (eq (portal-linux-gui--kind (portal-linux-gui--pixel screen column last))
                          'edge))
              (should-not (portal-linux-gui--kind
                           (portal-linux-gui--pixel screen column (1- first))))
              (should-not (portal-linux-gui--kind
                           (portal-linux-gui--pixel screen column (1+ last))))
              (should (eq (portal-linux-gui--kind
                           (portal-linux-gui--pixel screen (* scale left) (1+ first)))
                          'edge))
              (should (eq (portal-linux-gui--kind
                           (portal-linux-gui--pixel screen (1- (* scale right)) (1+ first)))
                          'edge))
              (should (= 0 (portal-linux-gui--count
                            screen 'pane (list 0 0 (car screen) (cadr screen)))))))
        (menu-bar-mode -1)
        (tool-bar-mode -1)))))

(ert-deftest portal-linux-gui-view-that-fills-covers-its-pane ()
  :tags '(:gui)
  "A frame of one pixel is stretched over the pane, whatever its size."
  (portal-linux-gui--with-view 'terminal '(:directory "/" :test-pattern "fill")
    (let ((window (selected-window)))
      (dotimes (_ 2)
        (portal-linux-gui--pause 0.3)
        (pcase-let ((screen (portal-linux-gui--screen))
                    (`(,left ,top ,right ,bottom) (portal-linux-gui--box window)))
          (should (equal (portal-linux-gui--get :drawn) '(1 1)))
          (dolist (at `((,left ,top) (,(1- right) ,top) (,left ,(1- bottom))
                        (,(1- right) ,(1- bottom))))
            (should (eq (portal-linux-gui--kind (apply #'portal-linux-gui--pixel screen at))
                        'fill)))
          (should (= 0 (portal-linux-gui--count
                        screen 'pane (list 0 0 (car screen) (cadr screen)))))
          (should (= 0 (portal-linux-gui--count
                        screen 'fill (list 0 bottom (car screen) (cadr screen))))))
        (set-window-buffer (split-window-below) (get-buffer-create "*scratch*"))))))

(ert-deftest portal-linux-gui-view-hides-with-its-buffer-and-shows-again ()
  :tags '(:gui)
  (portal-linux-gui--with-view 'terminal '(:directory "/")
    (let ((window (selected-window)) (buffer (current-buffer)))
      (portal-linux-gui--covers window)
      (switch-to-buffer (get-buffer-create "*scratch*"))
      (portal-linux-gui--wait (lambda () (not (portal-linux-gui--get :showing))))
      (should-not (portal-linux-gui--get :visible))
      (portal-linux-gui--pause 0.2)
      (let ((screen (portal-linux-gui--screen)))
        (should (= 0 (portal-linux-gui--count screen 'fill
                                              (list 0 0 (car screen) (cadr screen))))))
      ;; Parked, it takes no pointer: the pane under it is Emacs's.
      (let ((motions (portal-linux-gui--get :motions)))
        (portal-linux-gui--point 'move 300 300 'move 310 310)
        (portal-linux-gui--pause 0.2)
        (should (= motions (portal-linux-gui--get :motions))))
      (switch-to-buffer buffer)
      (portal-linux-gui--covers window))))

(ert-deftest portal-linux-gui-view-draws-while-lisp-is-busy ()
  :tags '(:gui)
  "Its frames come from a thread, which a busy main thread does not hold up."
  (portal-linux-gui--with-view 'terminal '(:directory "/")
    (portal-linux-gui--covers (selected-window))
    (let ((before (portal-linux-gui--get :frames))
          (deadline (+ (float-time) 1)))
      (while (< (float-time) deadline))
      (should (> (- (portal-linux-gui--get :frames) before) 30)))))

(ert-deftest portal-linux-gui-view-hides-while-a-child-frame-is-over-it ()
  :tags '(:gui)
  "A child frame is drawn in its parent's surface, which a view would cover."
  (portal-linux-gui--with-view 'terminal '(:directory "/")
    (let ((window (selected-window)) child)
      (portal-linux-gui--covers window)
      (unwind-protect
          (progn
            (setq child (make-frame `((parent-frame . ,(selected-frame)) (left . 200) (top . 150)
                                      (width . 30) (height . 5) (minibuffer . nil)
                                      (no-accept-focus . t) (undecorated . t))))
            (portal-linux-gui--wait (lambda () (portal-linux-gui--get :occluded)))
            (portal-linux-gui--wait (lambda () (not (portal-linux-gui--get :showing))))
            ;; Emacs still has the view in its pane.
            (should (portal-linux-gui--get :visible))
            (portal-linux-gui--pause 0.2)
            (let ((screen (portal-linux-gui--screen)))
              (should (= 0 (portal-linux-gui--count screen 'fill
                                                    (list 0 0 (car screen) (cadr screen))))))
            ;; Beside the pane it covers nothing.
            (set-frame-position child 200 (+ 40 (nth 3 (window-pixel-edges window))))
            (portal-linux-gui--wait (lambda () (not (portal-linux-gui--get :occluded))))
            (portal-linux-gui--wait (lambda () (portal-linux-gui--get :showing)))
            (set-frame-position child 200 150)
            (portal-linux-gui--wait (lambda () (not (portal-linux-gui--get :showing))))
            (make-frame-invisible child)
            (portal-linux-gui--wait (lambda () (portal-linux-gui--get :showing)))
            (make-frame-visible child)
            (portal-linux-gui--wait (lambda () (not (portal-linux-gui--get :showing)))))
        (when (frame-live-p child) (delete-frame child)))
      (portal-linux-gui--covers window))))

(ert-deftest portal-linux-gui-view-moves-to-another-frame-and-outlives-it ()
  :tags '(:gui)
  (portal-linux-gui--with-view 'terminal '(:directory "/")
    (let ((home (selected-frame)) (window (selected-window)) (buffer (current-buffer)) other)
      (unwind-protect
          (progn
            (setq other (make-frame))
            (set-window-buffer (frame-selected-window other) (get-buffer-create "*scratch*"))
            ;; The first frame is half as wide now, and the view with it.
            (portal-linux-gui--covers window)
            ;; Out of this frame's pane and into the other's.
            (switch-to-buffer (get-buffer-create "*scratch*"))
            (let ((far (frame-selected-window other)))
              (set-window-buffer far buffer)
              (portal-linux-gui--wait (lambda () (portal-linux-gui--settled-p far)))
              (portal-linux-gui--pause 0.2)
              (pcase-let ((screen (portal-linux-gui--screen))
                          (`(,left ,top ,right ,bottom) (portal-linux-gui--box far)))
                (should (eq (portal-linux-gui--kind (portal-linux-gui--pixel screen left top))
                            'edge))
                (should (eq (portal-linux-gui--kind
                             (portal-linux-gui--pixel screen (1- right) (1- bottom)))
                            'edge))
                ;; Nothing of it is left in the first frame.
                (should (= 0 (portal-linux-gui--count
                              screen 'fill (portal-linux-gui--box window))))))
            ;; GTK destroys a hidden window's surface, and the view's with
            ;; it: both come back with the window.
            (make-frame-invisible other t)
            (portal-linux-gui--wait (lambda () (not (portal-linux-gui--get :showing))))
            (make-frame-visible other)
            (let ((far (frame-selected-window other)))
              (portal-linux-gui--wait (lambda () (portal-linux-gui--settled-p far)))
              (portal-linux-gui--pause 0.3)
              (pcase-let ((screen (portal-linux-gui--screen))
                          (`(,left ,top . ,_) (portal-linux-gui--box far)))
                (should (eq (portal-linux-gui--kind (portal-linux-gui--pixel screen left top))
                            'edge))))
            ;; Its frame deleted under it, while its thread draws.
            (delete-frame other)
            (portal-linux-gui--pause 0.3)
            (should-not (portal-linux-gui--get :visible))
            (should-not (portal-linux-gui--get :showing)))
        (when (frame-live-p other) (delete-frame other))
        (select-frame-set-input-focus home))
      ;; And it shows again where its buffer does.
      (switch-to-buffer buffer)
      (portal-linux-gui--covers window))))

(ert-deftest portal-linux-gui-view-ends-in-the-middle-of-a-change ()
  :tags '(:gui)
  "A view closed while its window waits for Emacs to draw leaves it painting."
  (portal-linux-gui--with-view 'terminal '(:directory "/")
    (let ((window (selected-window)) (buffer (current-buffer)))
      (portal-linux-gui--covers window)
      ;; Placed anew and closed before Emacs is idle again.
      (set-window-buffer (split-window-below) (get-buffer-create "*scratch*"))
      (portal-view-sync)
      (kill-buffer buffer)
      (should-not (portal--inspect portal-linux-gui--target))
      ;; The window paints again: another view shows in it.
      (delete-other-windows)
      (switch-to-buffer (generate-new-buffer "*portal-linux-gui-next*"))
      (unwind-protect
          (progn
            (face-remap-add-relative 'default :background portal-linux-gui--pane)
            (let ((portal-linux-gui--target
                   (portal-view-open 'terminal '(:directory "/" :test-pattern t))))
              (portal-linux-gui--covers (selected-window))))
        (kill-buffer (current-buffer))))))

;;; The keyboard

(ert-deftest portal-linux-gui-view-takes-typed-text-and-keys ()
  :tags '(:gui)
  (portal-linux-gui--with-view 'terminal '(:directory "/")
    (portal-linux-gui--focus)
    (portal-linux-gui--type "hello")
    (portal-linux-gui--wait (lambda () (equal (portal-linux-gui--get :text) "hello")))
    ;; The input method composes: a dead key and a letter make one character.
    (portal-linux-gui--type "-k" "dead_acute" "-k" "e")
    (portal-linux-gui--wait (lambda () (equal (portal-linux-gui--get :text) "helloé")))
    ;; Keys that type nothing, and a terminal program's own chords.
    (portal-linux-gui--type "-k" "Return" "-k" "Up" "-M" "ctrl" "-k" "a" "-m" "ctrl"
                            "-M" "alt" "-k" "f" "-m" "alt" "-k" "F10")
    (portal-linux-gui--wait
     (lambda () (string-search "F10" (portal-linux-gui--get :keys))))
    (let ((keys (split-string (portal-linux-gui--get :keys))))
      (dolist (key '("Return" "Up" "C-a" "M-f" "F10"))
        (should (member key keys))))
    ;; None of it reached Emacs: F10 opened no menu, and nothing waits.
    (should (portal-linux-gui--get :focused))
    (should-not (read-event nil nil 0.3))
    (should (= (buffer-size) 0))))

(ert-deftest portal-linux-gui-escape-key-returns-the-keyboard-to-emacs ()
  :tags '(:gui)
  (portal-linux-gui--with-view 'terminal '(:directory "/")
    (portal-linux-gui--focus)
    (portal-linux-gui--type "a")
    (portal-linux-gui--wait (lambda () (equal (portal-linux-gui--get :text) "a")))
    ;; Control-Escape is the default off macOS.
    (portal-linux-gui--type "-M" "ctrl" "-k" "Escape" "-m" "ctrl")
    (portal-linux-gui--wait (lambda () (not (portal-linux-gui--get :focused))))
    (portal-linux-gui--wait (lambda () (not (portal-input-focused-p))))
    (portal-linux-gui--type "x")
    (should (eq (read-event nil nil 2) ?x))
    (should (equal (portal-linux-gui--get :text) "a"))))

(ert-deftest portal-linux-gui-chord-runs-an-emacs-command-with-what-follows ()
  :tags '(:gui)
  "A terminal's Super chord goes to Emacs, with the keys typed after it."
  (portal-linux-gui--with-view 'terminal '(:directory "/")
    (keymap-set (current-local-map) "s-t a b" #'portal-linux-gui--mark)
    (portal-linux-gui--focus)
    (let ((portal-linux-gui--ran nil))
      ;; Typed at once: a and b are held, and follow the chord to Emacs.
      (portal-linux-gui--type "-M" "logo" "-k" "t" "-m" "logo" "-k" "a" "-k" "b")
      (portal-linux-gui--handoff)
      (should portal-linux-gui--ran))
    ;; The view has the keyboard again, and got none of it.
    (portal-linux-gui--wait (lambda () (portal-linux-gui--get :focused)))
    (should (equal (portal-linux-gui--get :text) ""))
    (portal-linux-gui--type "z")
    (portal-linux-gui--wait (lambda () (equal (portal-linux-gui--get :text) "z")))))

(ert-deftest portal-linux-gui-page-keeps-the-chords-it-uses ()
  :tags '(:gui)
  "A web view's app is offered each chord, and keys wait for its answer."
  (portal-linux-gui--with-view 'web '(:uses "k")
    (keymap-set (current-local-map) "C-c t" #'portal-linux-gui--mark)
    (portal-linux-gui--focus)
    ;; The page uses Control-K: it and the key after it stay with the page.
    (portal-linux-gui--type "-M" "ctrl" "-k" "k" "-m" "ctrl" "-k" "b")
    (portal-linux-gui--wait (lambda () (equal (portal-linux-gui--get :text) "b")))
    (should (member "C-k" (split-string (portal-linux-gui--get :keys))))
    (should (= (portal-linux-gui--get :offered) 1))
    (should-not unread-command-events)
    ;; It does not use Control-C: that and t are Emacs's.
    (let ((portal-linux-gui--ran nil))
      (portal-linux-gui--type "-M" "ctrl" "-k" "c" "-m" "ctrl" "-k" "t")
      (portal-linux-gui--handoff)
      (should portal-linux-gui--ran))
    (portal-linux-gui--wait (lambda () (portal-linux-gui--get :focused)))
    (should (= (portal-linux-gui--get :offered) 2))
    (should (equal (portal-linux-gui--get :text) "b"))))

(ert-deftest portal-linux-gui-emacs-keeps-its-frame-focused-under-a-view ()
  :tags '(:gui)
  "GTK tells Emacs its widget lost the keyboard; Emacs's frame has it still."
  (portal-linux-gui--with-view 'terminal '(:directory "/")
    (portal-linux-gui--events)
    (should (eq (frame-focus-state) t))
    (let* ((changes 0)
           (count (lambda () (cl-incf changes))))
      (add-function :after after-focus-change-function count)
      (unwind-protect
          (progn
            (portal-linux-gui--focus)
            (portal-linux-gui--events)
            (should (eq (frame-focus-state) t))
            (should (= changes 0))
            (should (portal-linux-gui--get :focused))
            ;; Without Portal's advice Emacs says its frame lost the keyboard,
            ;; which is what the advice is for.
            (should (portal--input portal-linux-gui--target "unfocus"))
            (portal-linux-gui--events)
            (advice-remove 'handle-focus-out #'portal-view--keep-frame-focus)
            (portal-linux-gui--focus)
            (portal-linux-gui--events)
            (should-not (frame-focus-state)))
        (advice-add 'handle-focus-out :around #'portal-view--keep-frame-focus)
        (remove-function after-focus-change-function count)
        (portal--input portal-linux-gui--target "unfocus")
        (portal-linux-gui--events)))
    (should (eq (frame-focus-state) t))))

(ert-deftest portal-linux-gui-emacs-hears-its-window-lose-the-keyboard ()
  :tags '(:gui)
  "Another window takes the keyboard while a view has it, and gives it back."
  (portal-linux-gui--with-view 'terminal '(:directory "/")
    (let ((home (selected-frame)) other)
      (portal-linux-gui--focus)
      (portal-linux-gui--events)
      (unwind-protect
          (progn
            ;; A new window takes the keyboard on this desktop.
            (setq other (make-frame))
            (portal-linux-gui--wait
             (lambda () (portal-linux-gui--events) (not (frame-focus-state home))))
            ;; The view is where its window's keys go, as before.
            (should (portal-linux-gui--get :focused))
            (delete-frame other)
            (setq other nil)
            (portal-linux-gui--wait
             (lambda () (portal-linux-gui--events) (eq (frame-focus-state home) t)))
            (should (portal-linux-gui--get :focused))
            (portal-linux-gui--type "q")
            (portal-linux-gui--wait (lambda () (equal (portal-linux-gui--get :text) "q"))))
        (when (frame-live-p other) (delete-frame other))))))

;;; The pointer

(ert-deftest portal-linux-gui-view-takes-the-pointer-and-a-click-enters-it ()
  :tags '(:gui)
  (portal-linux-gui--with-view 'terminal '(:directory "/")
    (let ((window (selected-window)) (scale (portal-linux-gui--scale)) below)
      (setq below (split-window-below))
      (set-window-buffer below (get-buffer-create "*scratch*"))
      (portal-linux-gui--covers window)
      (select-window below)
      (pcase-let ((`(,left ,top . ,_) (portal-linux-gui--box window)))
        ;; The pointer over the pane, at the pane's own coordinates.
        (portal-linux-gui--point 'move (+ (/ left scale) 100) (+ (/ top scale) 60)
                                 'move (+ (/ left scale) 120) (+ (/ top scale) 80))
        (portal-linux-gui--wait (lambda () (portal-linux-gui--get :inside)))
        (portal-linux-gui--wait (lambda () (equal (portal-linux-gui--get :pointer) '(120 80))))
        (should (> (portal-linux-gui--get :motions) 0))
        (should-not (portal-linux-gui--get :focused))
        ;; A click gives it the keyboard, and asks Emacs for its pane.
        (portal-linux-gui--point 'click)
        (portal-linux-gui--wait (lambda () (= (portal-linux-gui--get :releases) 1)))
        (should (= (portal-linux-gui--get :presses) 1))
        (should (portal-linux-gui--get :focused))
        (portal-linux-gui--wait (lambda () unread-command-events))
        (let ((event (pop unread-command-events)))
          (should (eq (car-safe event) 'portal-input-select))
          (portal-input--select event))
        (should (eq (selected-window) window))
        (portal-linux-gui--point 'scroll 2)
        (portal-linux-gui--wait (lambda () (> (portal-linux-gui--get :scrolled) 0)))
        ;; A click in another pane is Emacs's, and so is the keyboard then.
        (pcase-let ((`(,left ,top . ,_) (portal-linux-gui--box below)))
          (portal-linux-gui--point 'move (+ (/ left scale) 100) (+ (/ top scale) 40) 'click))
        (portal-linux-gui--wait (lambda () (not (portal-linux-gui--get :focused))))
        (should-not (portal-linux-gui--get :inside))
        (should (= (portal-linux-gui--get :presses) 1))))))

;;; The pipe

(ert-deftest portal-linux-gui-records-a-full-pipe-held-arrive-by-a-timer ()
  :tags '(:gui)
  "A record that waits for room in the pipe is sent by the platform's timer."
  (portal-linux-gui--with-view 'terminal '(:directory "/")
    (let* ((handler (assoc "focus" portal-view-record-handlers))
           (original (cdr handler))
           (home (selected-frame))
           (pairs 30000)
           (count 0)
           other)
      (unwind-protect
          (progn
            ;; In a window without the keyboard, giving the view the
            ;; keyboard and taking it back only says so: GTK's focus, and
            ;; Emacs's events for it, stay out of this.
            (setq other (make-frame))
            (portal-linux-gui--wait
             (lambda () (portal-linux-gui--events) (not (frame-focus-state home))))
            (setcdr handler (lambda (&rest _) (cl-incf count)))
            ;; More records than a pipe holds, with nobody reading it.
            (dotimes (_ pairs)
              (portal--input portal-linux-gui--target "focus")
              (portal--input portal-linux-gui--target "unfocus"))
            ;; Reading makes room, and nothing more is sent to push the
            ;; rest through: only the timer can.
            (let ((deadline (+ (float-time) 20)))
              (while (and (< count (* 2 pairs)) (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (= count (* 2 pairs))))
        (setcdr handler original)
        (when (frame-live-p other) (delete-frame other))
        (setq unread-command-events nil)
        (portal-linux-gui--events)))))

(provide 'portal-linux-gui-tests)
;;; portal-linux-gui-tests.el ends here
