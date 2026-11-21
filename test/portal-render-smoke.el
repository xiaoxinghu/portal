;;; portal-render-smoke.el --- Does a terminal draw and take input here? -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; The rendering smoke test, run by test/render-smoke.sh in a fresh
;; graphical Emacs: for the runtime directory it is given, the build in
;; `portal-build-directory', and the graphical session it runs in, does a
;; terminal draw in its pane and take input?
;;
;; One terminal in a frame of one pane runs a program of the test's own,
;; through the user's login shell as any terminal starts, not the user's
;; shell.  The program asks for a token, which is typed through the
;; platform's input path, then sets the background orange and draws an
;; asymmetric marker: a red block at the grid's top left, and a blue one
;; right of it and below, drawn only when Ghostty's resources were found.
;; It keeps writing under them.  The pane is green underneath.  The window
;; is captured as the window server or compositor shows it and the pane is
;; checked to the device pixel; the pane is then split under output and
;; checked again.  A blank, shifted, cropped, flipped or mirrored pane each
;; fails a check.
;;
;; What differs between places is an adapter of a few functions: capture
;; the frame, type a token, and say whether the frame's window has the
;; keyboard.  `portal-render-smoke--adapters' holds them.  The test exits
;; 0 when every check passed, 1 when one failed, and 77, not run, when this
;; session offers no way to capture or type, or no display: never a pass.
;; Every step's time, every check and what was found go to the record,
;; render-smoke.log in PORTAL_SMOKE_OUT, with the captures.

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'portal-terminal)

(declare-function portal--hide "portal-view" (target))
(declare-function portal--inspect "portal-view" (target))
(declare-function portal--place "portal-view" (target edges title))
(declare-function portal--terminal-text "portal-terminal" (target))
(declare-function portal-test-capture-window "test-window-capture" (file))
(declare-function portal-test-native-key "test-terminal-input" (code flags text &optional windowless))
(declare-function portal-test-responder "test-terminal-input" ())

(defvar portal-render-smoke--out
  (file-name-as-directory (or (getenv "PORTAL_SMOKE_OUT") (make-temp-file "portal-smoke-" t)))
  "The directory of the record and the captures.")

(defvar portal-render-smoke--start (float-time before-init-time)
  "When this Emacs started.")

(defvar portal-render-smoke--failures 0 "How many checks failed.")

;;; The record

(defun portal-render-smoke--note (format-string &rest arguments)
  "Add a line to the record, with the time since Emacs started."
  (let ((line (format "smoke: %6.2fs %s" (- (float-time) portal-render-smoke--start)
                      (apply #'format format-string arguments))))
    (message "%s" line)
    (write-region (concat line "\n") nil
                  (expand-file-name "render-smoke.log" portal-render-smoke--out) t 'quiet)))

(defun portal-render-smoke--check (name ok &optional evidence)
  "Record the check NAME as passed when OK, with EVIDENCE when it failed."
  (unless ok (cl-incf portal-render-smoke--failures))
  (portal-render-smoke--note "%s %s%s" (if ok "PASS" "FAIL") name
                             (if (and evidence (not ok)) (format " %S" evidence) ""))
  ok)

(define-error 'portal-render-smoke-not-run "Could not run here")

(defun portal-render-smoke--not-run (format-string &rest arguments)
  "Stop the test as not run here, saying why."
  (signal 'portal-render-smoke-not-run (list (apply #'format format-string arguments))))

(defun portal-render-smoke--until (predicate seconds)
  "Wait up to SECONDS for PREDICATE, redisplaying; return its value."
  (let ((deadline (+ (float-time) seconds)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (redisplay t))
    (funcall predicate)))

(defun portal-render-smoke--pause (seconds)
  "Wait SECONDS, redisplaying."
  (portal-render-smoke--until #'ignore seconds))

;;; Adapters

(defvar portal-render-smoke--mac-codes
  '((?a . 0) (?s . 1) (?d . 2) (?f . 3) (?h . 4) (?g . 5) (?z . 6) (?x . 7) (?c . 8) (?v . 9)
    (?b . 11) (?q . 12) (?w . 13) (?e . 14) (?r . 15) (?y . 16) (?t . 17) (?o . 31) (?u . 32)
    (?i . 34) (?p . 35) (?l . 37) (?j . 38) (?k . 40) (?n . 45) (?m . 46) (?\r . 36))
  "The ANSI key codes of the letters a token is made of, and of Return.")

(defun portal-render-smoke--mac-capture (file)
  "Capture the frame's window at FILE, a PPM; return its scale, or why not."
  (pcase (portal-test-capture-window file)
    ((and (pred stringp) why) why)
    (`(,width ,height ,scale ,seconds ,method)
     (portal-render-smoke--note "captured %dx%d at scale %s in %.3fs by %s"
                                width height scale seconds method)
     scale)))

(defun portal-render-smoke--mac-type (text)
  "Type TEXT, lowercase letters, and Return, as AppKit key events."
  (dolist (character (append text "\r" nil))
    (portal-test-native-key (alist-get character portal-render-smoke--mac-codes)
                            0 (string character))
    (portal-render-smoke--pause 0.03)))

(defun portal-render-smoke--mac-keyboard ()
  "Whether the frame's window is the key window of the active app."
  (string-match-p " (active)\\'" (portal-test-responder)))

(defvar portal-render-smoke--adapters
  `((mac :window-system ns
         :capture portal-render-smoke--mac-capture
         :type portal-render-smoke--mac-type
         :keyboard portal-render-smoke--mac-keyboard
         :describe portal-test-responder))
  "Each place's adapter: its name, then its window system and functions.
:capture writes the frame's content area as it is shown, a binary PPM in
device pixels whose origin is the frame's top left, at the file it is
given, and returns the device scale, or a string saying why it could not:
the test is then not run.  :type types a string of lowercase letters and
Return.  :keyboard says whether the frame's window has the keyboard,
which `frame-focus-state' cannot: it stays nil while a view has the keys.
:describe returns a string for the record when :keyboard fails.")

(defun portal-render-smoke--place ()
  "The place this Emacs runs in: a symbol naming an adapter, or a string."
  (let ((named (getenv "PORTAL_SMOKE_ADAPTER")))
    (cond ((and named (not (string-empty-p named))) (intern named))
          ((eq window-system 'ns) 'mac)
          ((getenv "HYPRLAND_INSTANCE_SIGNATURE") 'hyprland)
          (t (let ((desktop (downcase (or (getenv "XDG_CURRENT_DESKTOP") ""))))
               (cond ((string-match-p "gnome" desktop) 'gnome)
                     ((string-match-p "kde" desktop) 'plasma)
                     (t (format "%s, desktop %S" window-system desktop))))))))

;;; Pixels

(defun portal-render-smoke--read (file)
  "Read the PPM FILE as (WIDTH HEIGHT START . BYTES)."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'binary))
      (insert-file-contents-literally file))
    (goto-char (point-min))
    (unless (looking-at "P6[ \n]+\\([0-9]+\\)[ \n]+\\([0-9]+\\)[ \n]+255\n")
      (error "Not a PPM: %s" file))
    (list (string-to-number (match-string 1)) (string-to-number (match-string 2))
          (1- (match-end 0)) (buffer-string))))

(defun portal-render-smoke--pixel (screen x y)
  "The colour at X, Y of SCREEN as (R G B)."
  (pcase-let ((`(,width ,_ ,start ,bytes) screen))
    (let ((at (+ start (* 3 (+ x (* y width))))))
      (list (aref bytes at) (aref bytes (+ at 1)) (aref bytes (+ at 2))))))

(defun portal-render-smoke--kind (color)
  "Which of the test's colours COLOR is, or nil."
  (pcase-let ((`(,r ,g ,b) color))
    (cond ((and (> r 220) (< g 40) (< b 40)) 'red)
          ((and (< r 40) (< g 40) (> b 220)) 'blue)
          ((and (< r 40) (> g 220) (< b 40)) 'green)
          ((and (< (abs (- r #xf9)) 24) (< (abs (- g #x81)) 24) (< (abs (- b #x28)) 24))
           'orange))))

(defun portal-render-smoke--boxes (screen box)
  "Each colour's bounding box and count in BOX of SCREEN, every pixel read.
An alist of (KIND LEFT TOP RIGHT BOTTOM COUNT)."
  (pcase-let ((`(,left ,top ,right ,bottom) box)
              (found nil))
    (cl-loop for y from top below bottom
             do (cl-loop for x from left below right
                         for kind = (portal-render-smoke--kind (portal-render-smoke--pixel screen x y))
                         when kind
                         do (let ((have (alist-get kind found)))
                              (setf (alist-get kind found)
                                    (if have
                                        (list (min (nth 0 have) x) (min (nth 1 have) y)
                                              (max (nth 2 have) (1+ x)) (max (nth 3 have) (1+ y))
                                              (1+ (nth 4 have)))
                                      (list x y (1+ x) (1+ y) 1))))))
    found))

;; Every pixel of a pane is read: compiled, that takes a fraction of a second.
(byte-compile 'portal-render-smoke--pixel)
(byte-compile 'portal-render-smoke--kind)
(byte-compile 'portal-render-smoke--boxes)

(defun portal-render-smoke--examine (adapter name window target)
  "Capture with ADAPTER and check TARGET's pane, WINDOW's body; NAME the step."
  (let* ((file (expand-file-name (format "%s.ppm" name) portal-render-smoke--out))
         (scale (funcall (plist-get adapter :capture) file)))
    (when (stringp scale)
      (portal-render-smoke--not-run "cannot capture the window here: %s" scale))
    (let* ((screen (portal-render-smoke--read file))
           (box (mapcar (lambda (edge) (round (* scale edge))) (window-inside-pixel-edges window)))
           (width (nth 0 screen)) (height (nth 1 screen))
           (inside (portal-render-smoke--boxes screen box))
           (cell (* scale (frame-char-width))))
      (portal-render-smoke--note "%s: pane %S in a capture of %dx%d, the view at %S" name box
                                 width height (plist-get (portal--inspect target) :edges))
      (pcase-let ((`(,left ,top ,right ,bottom) box))
        (portal-render-smoke--check (format "%s: the pane is in the capture" name)
                                    (and (<= 0 left) (<= right width) (<= 0 top) (<= bottom height))
                                    (list :pane box :capture (list width height)))
        ;; The terminal's background at the pane's corners, and not just
        ;; outside them.
        (dolist (corner `((,left ,top -1 -1) (,(1- right) ,top 1 -1)
                          (,left ,(1- bottom) -1 1) (,(1- right) ,(1- bottom) 1 1)))
          (pcase-let ((`(,x ,y ,dx ,dy) corner))
            (portal-render-smoke--check (format "%s: orange at the corner %d,%d" name x y)
                                        (eq 'orange (portal-render-smoke--kind
                                                     (portal-render-smoke--pixel screen x y)))
                                        (portal-render-smoke--pixel screen x y))
            (when (< -1 (+ x dx) width)
              (portal-render-smoke--check
               (format "%s: not orange beside %d,%d" name x y)
               (not (eq 'orange (portal-render-smoke--kind
                                 (portal-render-smoke--pixel screen (+ x dx) y))))))
            (when (< -1 (+ y dy) height)
              (portal-render-smoke--check
               (format "%s: not orange above or below %d,%d" name x y)
               (not (eq 'orange (portal-render-smoke--kind
                                 (portal-render-smoke--pixel screen x (+ y dy)))))))))
        (portal-render-smoke--check (format "%s: none of the pane's green inside" name)
                                    (not (alist-get 'green inside)) (alist-get 'green inside))
        (let ((red (alist-get 'red inside)) (blue (alist-get 'blue inside)))
          (portal-render-smoke--check (format "%s: the red marker" name) red)
          ;; Blue only when the program found Ghostty's resources.
          (portal-render-smoke--check (format "%s: the blue marker, resources found" name) blue)
          (when (and red blue)
            ;; Red: 6 cells by 2 rows at the grid's top left, within padding
            ;; and a cell of the pane's top left.
            (portal-render-smoke--check (format "%s: red at the pane's top left" name)
                                        (and (<= 0 (- (nth 0 red) left) (* 2 cell))
                                             (<= 0 (- (nth 1 red) top) (* 2 cell)))
                                        (list :red red :pane box :cell cell))
            ;; Upright and not mirrored: red wider than tall; blue a row
            ;; high, right of red and below it.
            (portal-render-smoke--check (format "%s: the marker upright, not mirrored" name)
                                        (and (> (- (nth 2 red) (nth 0 red))
                                                (- (nth 3 red) (nth 1 red)))
                                             (> (nth 0 blue) (nth 2 red))
                                             (> (nth 1 blue) (nth 3 red))
                                             (< (- (nth 3 blue) (nth 1 blue))
                                                (- (nth 3 red) (nth 1 red))))
                                        (list :red red :blue blue))))))))

;;; Faults, for checking the test itself

(defun portal-render-smoke--fault (target)
  "Break TARGET's pane as PORTAL_SMOKE_FAULT says, for the test to find.
`blank' hides the view while its pane shows; `shift' places it a pixel,
Emacs's unit, right of and below its pane.  Portal places a view again only when
its pane changes, so either lasts until the split."
  (pcase (getenv "PORTAL_SMOKE_FAULT")
    ((or 'nil "") nil)
    ("blank" (portal--hide target))
    ("shift"
     (portal-view--with-frame-title
      (selected-frame)
      (lambda (title)
        (portal--place target
                       (vconcat (mapcar #'1+ (window-inside-pixel-edges (selected-window))))
                       title))))
    (fault (error "Unknown fault %S: blank or shift" fault)))
  (when-let* ((fault (getenv "PORTAL_SMOKE_FAULT")) ((not (string-empty-p fault))))
    (portal-render-smoke--note "fault: %s" fault)
    (portal-render-smoke--pause 0.3)))

;;; The test

(defconst portal-render-smoke--program
  "printf '\\033]11;#f98128\\007\\033[?25l\\033[2J\\033[Htoken? '
IFS= read -r token
R='\\033[48;2;255;0;0m' B='\\033[48;2;0;0;255m' N='\\033[0m'
# Blue only when Ghostty found its resources: its directory, and the
# terminfo it names describing TERM.
if [ -d \"${GHOSTTY_RESOURCES_DIR:-/nonexistent}\" ] &&
   infocmp ${TERMINFO:+-A \"$TERMINFO\"} \"$TERM\" >/dev/null 2>&1; then :; else B=$N; fi
draw() {
  printf '\\033[2J\\033[H%b      %b\\n%b      %b\\n\\033[4;20H%b   %b\\033[6;1Hgot %s\\nterm=%s res=%s terminfo=%s\\n' \\
    \"$R\" \"$N\" \"$R\" \"$N\" \"$B\" \"$N\" \"$token\" \"$TERM\" \"$GHOSTTY_RESOURCES_DIR\" \"$TERMINFO\"
}
trap draw WINCH
draw
i=0
while :; do i=$((i + 1)); printf '\\0337\\033[5;1Htick %d\\0338' \"$i\"; sleep 0.02; done
"
  "The terminal's program: read a token, draw the marker, keep writing.
Its colours are explicit, OSC 11 and 24-bit SGR, not a theme's: a Mac's
themes are compiled into its Ghostty, not read from its resources.")

(defun portal-render-smoke--token ()
  "A token of nine lowercase letters, new each run."
  (concat "smoke" (mapconcat (lambda (c) (string (+ ?a (% c 26))))
                             (substring (md5 (format "%s %s" (float-time) (emacs-pid))) 0 4) "")))

(defun portal-render-smoke--terminal (program)
  "Open a terminal running PROGRAM, a shell script, alone in its frame.
Return its view's target."
  (let ((script (expand-file-name "program.sh" portal-render-smoke--out)))
    (write-region program nil script nil 'quiet)
    ;; As a person's terminal opens: through the user's login shell.
    (with-current-buffer (portal-terminal--new nil nil "*render-smoke*" nil
                                               (json-encode (vector "/bin/sh" script)))
      (face-remap-add-relative 'default :background "#00ff00")
      (delete-other-windows)
      portal-view--target)))

(defun portal-render-smoke--run (adapter)
  "Run the checks with ADAPTER."
  (menu-bar-mode -1)
  (tool-bar-mode -1)
  (when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
  (setq portal-terminal-confirm-kill nil)
  ;; On Linux the frame fills its output, which the capture is of.
  (unless (eq window-system 'ns) (set-frame-parameter nil 'fullscreen 'fullboth))
  (delete-other-windows)
  (select-frame-set-input-focus (selected-frame))
  (portal-render-smoke--pause 0.5)
  (let ((token (portal-render-smoke--token))
        (target (portal-render-smoke--terminal portal-render-smoke--program)))
    (portal-render-smoke--note "terminal open")
    (portal-render-smoke--check
     "the terminal starts"
     (portal-render-smoke--until
      (lambda () (let ((state (portal--inspect target)))
                   (or (plist-get state :showing) (plist-get state :ready))))
      10)
     (portal--inspect target))
    (portal-render-smoke--check
     "the program asks for a token"
     (portal-render-smoke--until
      (lambda () (string-search "token?" (portal--terminal-text target))) 10)
     (portal--terminal-text target))
    (portal-render-smoke--check
     "the terminal has the frame's keys"
     (portal-render-smoke--until (lambda () (plist-get (portal--inspect target) :focused)) 5)
     (portal--inspect target))
    (portal-render-smoke--check
     "the frame's window has the keyboard"
     (portal-render-smoke--until (plist-get adapter :keyboard) 5)
     (funcall (plist-get adapter :describe)))
    (funcall (plist-get adapter :type) token)
    (portal-render-smoke--check
     (format "the typed %s reached the program" token)
     (portal-render-smoke--until
      (lambda () (string-search (concat "got " token) (portal--terminal-text target))) 10)
     (let ((text (portal--terminal-text target)))
       (substring text (max 0 (- (length text) 200)))))
    (portal-render-smoke--note
     "%s" (or (seq-find (lambda (line) (string-prefix-p "term=" line))
                        (split-string (portal--terminal-text target) "\n"))
              "the program printed no term= line"))
    (portal-render-smoke--pause 0.3)
    (portal-render-smoke--fault target)
    (portal-render-smoke--examine adapter "whole" (selected-window) target)
    ;; Split under output: the terminal keeps the left pane, green beside it.
    (let ((other (split-window-right)))
      (with-selected-window other
        (switch-to-buffer (get-buffer-create "*render-smoke-other*"))
        (face-remap-add-relative 'default :background "#00ff00"))
      (portal-render-smoke--check
       "the view follows the split"
       (portal-render-smoke--until
        (lambda () (equal (append (plist-get (portal--inspect target) :edges) nil)
                          (window-inside-pixel-edges (selected-window))))
        5)
       (list :view (plist-get (portal--inspect target) :edges)
             :pane (window-inside-pixel-edges (selected-window))))
      (portal-render-smoke--pause 0.3)
      (portal-render-smoke--examine adapter "split" (selected-window) target))))

(defun portal-render-smoke ()
  "Run the smoke test in this graphical Emacs and exit it: 0, 1 or 77."
  (let ((status
         (condition-case err
             (let* ((place (portal-render-smoke--place))
                    (adapter (and (symbolp place)
                                  (alist-get place portal-render-smoke--adapters))))
               (portal-render-smoke--note "emacs %s, window system %s, scale %s, place %s"
                                          emacs-version window-system
                                          (frame-scale-factor) place)
               (portal-render-smoke--note "runtime %s"
                                          (or portal-build-directory "the checkout's build"))
               (unless window-system
                 (portal-render-smoke--not-run "Emacs has no graphical display"))
               (unless adapter
                 (portal-render-smoke--not-run "no adapter for %s" place))
               (portal-render-smoke--check
                (format "the frame is %s's" (plist-get adapter :window-system))
                (eq window-system (plist-get adapter :window-system))
                window-system)
               (portal-render-smoke--run adapter)
               (if (zerop portal-render-smoke--failures) 0 1))
           (portal-render-smoke-not-run
            ;; Not run only when nothing failed before the test had to stop:
            ;; a failure seen stays a failure.
            (if (zerop portal-render-smoke--failures)
                (progn (portal-render-smoke--note "NOT RUN: %s" (cadr err)) 77)
              (portal-render-smoke--note "stopped: %s" (cadr err))
              1))
           (error
            (portal-render-smoke--check "the test ran to its end" nil
                                        (error-message-string err))
            1))))
    (portal-render-smoke--note "done: %s"
                               (pcase status
                                 (0 "every check passed")
                                 (77 "not run")
                                 (_ (format "%d checks failed" portal-render-smoke--failures))))
    (kill-emacs status)))

(provide 'portal-render-smoke)
;;; portal-render-smoke.el ends here
