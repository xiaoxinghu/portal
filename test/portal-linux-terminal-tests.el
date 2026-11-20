;;; portal-linux-terminal-tests.el --- Portal's terminals on Linux -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Terminals in a pgtk Emacs on Wayland: a local shell in a Ghostty surface,
;; its frames shown by the presenter of native/Linux/presenter.c.  Loaded
;; by test/linux-gui.sh after test/portal-linux-gui-tests.el, whose helpers
;; these use, on the desktop of test/linux-desktop.sh.
;;
;; The terminals here take the theme Great Pumpkin, whose background is a
;; flat orange, over a pane that is green underneath, so a terminal that
;; covers its pane shows orange at its corners and no green anywhere.  The
;; shell is the user's own login shell, as for any terminal.

(require 'ert)
(require 'cl-lib)
(require 'portal-terminal)
(require 'portal-linux-gui-tests)

(defconst portal-linux-terminal--theme "Great Pumpkin")

(defun portal-linux-terminal--orange-p (color)
  "Whether COLOR, (RED GREEN BLUE), is the theme's background, #f98128."
  (pcase-let ((`(,red ,green ,blue) color))
    (and (< (abs (- red #xf9)) 12) (< (abs (- green #x81)) 12) (< (abs (- blue #x28)) 12))))

(defmacro portal-linux-terminal--with (&rest body)
  "Run BODY in a frame of one pane, with neither menu bar nor tool bar.
`portal-linux-terminal--open' opens terminals in it; each is closed after."
  (declare (indent 0))
  `(let ((menu menu-bar-mode) (tool tool-bar-mode)
         (theme portal-terminal-theme)
         (before (portal-view-buffers 'terminal)))
     (portal-linux-gui--tool "grim")
     (portal-linux-gui--tool "wtype")
     (unwind-protect
         (save-window-excursion
           (menu-bar-mode -1)
           (tool-bar-mode -1)
           (delete-other-windows)
           (setq portal-terminal-theme portal-linux-terminal--theme)
           ,@body)
       (let ((portal-terminal-confirm-kill nil))
         (dolist (buffer (portal-view-buffers 'terminal))
           (unless (memq buffer before) (kill-buffer buffer))))
       (setq portal-terminal-theme theme)
       (portal-linux-gui--pause 0.1)
       (discard-input)
       (setq unread-command-events nil)
       (menu-bar-mode (if menu 1 -1))
       (tool-bar-mode (if tool 1 -1)))))

(defun portal-linux-terminal--open (&optional directory)
  "Open a terminal in the selected pane, in DIRECTORY, and return its target.
Its pane is green underneath.  Returns once it shows a frame and its shell
has drawn a prompt."
  (let* ((default-directory (file-name-as-directory (or directory temporary-file-directory)))
         (buffer (portal-terminal-new))
         (target (buffer-local-value 'portal-view--target buffer)))
    (with-current-buffer buffer
      (face-remap-add-relative 'default :background portal-linux-gui--pane))
    (portal-linux-gui--wait (lambda () (portal-linux-gui--get :showing target)))
    ;; A login shell takes a moment for its startup files.
    (portal-linux-gui--wait
     (lambda () (not (equal (portal-linux-gui--get :pwd target) ""))))
    target))

(defun portal-linux-terminal--text (target)
  "TARGET's text, scrollback and screen."
  (portal--terminal-text target))

(defun portal-linux-terminal--covers (window target)
  "Check that TARGET's frames cover WINDOW's body on the screen, to the pixel."
  (portal-linux-gui--wait
   (lambda ()
     (pcase-let ((`(,left ,top ,right ,bottom) (window-inside-pixel-edges window))
                 (state (portal-linux-gui--state target)))
       (and (plist-get state :showing)
            (equal (plist-get state :edges) (list left top right bottom))))))
  (portal-linux-gui--pause 0.3)
  (pcase-let* ((screen (portal-linux-gui--screen))
               (`(,left ,top ,right ,bottom) (portal-linux-gui--box window))
               (at (lambda (x y) (portal-linux-gui--pixel screen x y))))
    (ert-info ((format "Pane %S" (list left top right bottom)))
      ;; Ghostty's padding, the theme's background, at the pane's corners,
      ;; and nothing of it just outside.
      (dolist (corner `((,left ,top -1 -1) (,(1- right) ,top 1 -1)
                        (,left ,(1- bottom) -1 1) (,(1- right) ,(1- bottom) 1 1)))
        (pcase-let ((`(,x ,y ,dx ,dy) corner))
          (should (portal-linux-terminal--orange-p (funcall at x y)))
          (when (< -1 (+ x dx) (car screen))
            (should-not (portal-linux-terminal--orange-p (funcall at (+ x dx) y))))
          (when (< -1 (+ y dy) (cadr screen))
            (should-not (portal-linux-terminal--orange-p (funcall at x (+ y dy)))))))
      (should (= 0 (portal-linux-gui--count screen 'pane (list 0 0 (car screen) (cadr screen))))))))

(defun portal-linux-terminal--run (target line)
  "Type LINE into TARGET, which has the keyboard, and Return.
Returns once Emacs has read what was typed, which wtype only sends: the
keyboard may then move on."
  (should (portal-linux-gui--get :focused target))
  (portal-linux-gui--type line)
  (portal-linux-gui--type "-k" "Return")
  (portal-linux-gui--pause 0.3))

(defun portal-linux-terminal--shows (target text &optional seconds)
  "Wait for TARGET's text to have TEXT, for at most SECONDS, or 10."
  (let ((deadline (+ (float-time) (or seconds 10)))
        found)
    (while (and (not (setq found (string-search text (portal-linux-terminal--text target))))
                (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (redisplay t))
    (unless found
      (let ((shown (portal-linux-terminal--text target)))
        (ert-fail (list 'not-shown text (substring shown (max 0 (- (length shown) 600)))))))))

(defun portal-linux-terminal--until (predicate seconds)
  "Wait for PREDICATE, letting GTK and the pipe run, for at most SECONDS."
  (let ((deadline (+ (float-time) seconds)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05)
      (redisplay t))
    (should (funcall predicate))))

(defun portal-linux-terminal--dmabufs ()
  "How many DMABUFs this Emacs has open."
  (cl-count-if (lambda (file)
                 (string-search "dmabuf" (or (file-symlink-p file) "")))
               (directory-files (format "/proc/%d/fd" (emacs-pid)) t "\\`[0-9]+\\'")))

(defun portal-linux-terminal--busy (seconds)
  "Keep Emacs's main thread in Lisp for SECONDS, reading no input."
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end))))

;;; A shell

(ert-deftest portal-linux-gui-terminal-runs-a-shell-typed-into ()
  :tags '(:gui)
  (portal-linux-terminal--with
    (let ((target (portal-linux-terminal--open "/tmp/"))
          (window (selected-window)))
      (should (portal-linux-gui--get :focused target))
      (should (equal (portal-linux-gui--get :theme target) portal-linux-terminal--theme))
      ;; The shell reports where it is, and is in the foreground.
      (should (equal (file-name-as-directory (portal-linux-gui--get :pwd target)) "/tmp/"))
      (should (string-match-p "sh\\'" (portal-linux-gui--get :program target)))
      (portal-linux-terminal--covers window target)
      ;; Typed text, a sign typed with Shift, Return, and a line the shell ran.
      (portal-linux-terminal--run target "echo PORTAL-$((6*7))")
      (portal-linux-terminal--shows target "PORTAL-42")
      ;; Control-U, which the shell takes as a key, clears the line.
      (portal-linux-gui--type "never ran")
      (portal-linux-gui--type "-M" "ctrl" "-k" "u" "-m" "ctrl")
      (portal-linux-terminal--run target "echo SECOND-$((1+1))")
      (portal-linux-terminal--shows target "SECOND-2")
      (should-not (string-search "never ran" (portal-linux-terminal--text target)))
      ;; A program in the foreground, and its end.
      (portal-linux-terminal--run target "sleep 2")
      (portal-linux-gui--wait
       (lambda () (string-match-p "/sleep\\'" (portal-linux-gui--get :program target))))
      (portal-linux-gui--wait
       (lambda () (string-match-p "sh\\'" (portal-linux-gui--get :program target))))
      ;; Nothing typed reached Emacs.
      (should-not (read-event nil nil 0.2)))))

(ert-deftest portal-linux-gui-terminal-follows-its-pane ()
  :tags '(:gui)
  "A terminal's grid follows its pane, and its frames cover the pane."
  (portal-linux-terminal--with
    (let* ((target (portal-linux-terminal--open))
           (window (selected-window))
           (columns (portal-linux-gui--get :columns target))
           (rows (portal-linux-gui--get :rows target)))
      (should (> columns 40))
      (should (> rows 10))
      (let ((right (split-window-right)))
        (set-window-buffer right (get-buffer-create "*scratch*"))
        (portal-linux-terminal--covers window target)
        (should (< (portal-linux-gui--get :columns target) columns))
        (let ((below (split-window-below)))
          (set-window-buffer below (get-buffer-create "*scratch*"))
          (portal-linux-terminal--covers window target)
          (should (< (portal-linux-gui--get :rows target) rows))
          (enlarge-window 5)
          (portal-linux-terminal--covers window target))
        (delete-other-windows window)
        (portal-linux-terminal--covers window target)
        (portal-linux-gui--wait
         (lambda () (and (= (portal-linux-gui--get :columns target) columns)
                         (= (portal-linux-gui--get :rows target) rows))))))))

(ert-deftest portal-linux-gui-terminal-runs-on-while-hidden ()
  :tags '(:gui)
  "Its shell runs on while its buffer is hidden, and it shows again."
  (portal-linux-terminal--with
    (let ((target (portal-linux-terminal--open))
          (buffer (current-buffer))
          (window (selected-window)))
      (portal-linux-terminal--run target "sleep 1; echo LATER-$((2*3))")
      (switch-to-buffer (get-buffer-create "*scratch*"))
      (portal-linux-gui--wait (lambda () (not (portal-linux-gui--get :showing target))))
      (let ((committed (portal-linux-gui--get :committed target)))
        (portal-linux-gui--pause 1.5)
        ;; Hidden, it shows nothing; its shell went on.
        (should-not (portal-linux-gui--get :showing target))
        (should (<= (- (portal-linux-gui--get :committed target) committed) 2))
        (should (string-search "LATER-6" (portal-linux-terminal--text target))))
      (switch-to-buffer buffer)
      (portal-linux-terminal--covers window target)
      ;; Shown, it takes keys and draws again.
      (portal-terminal-focus)
      (portal-linux-gui--wait (lambda () (portal-linux-gui--get :focused target)))
      (portal-linux-terminal--run target "echo AGAIN-$((3*3))")
      (portal-linux-terminal--shows target "AGAIN-9"))))

(defun portal-linux-terminal--set-clipboard (text &optional primary)
  "Put TEXT on the clipboard, or with PRIMARY the primary selection, with wl-copy.
wl-copy keeps serving it from a process of its own; nil clears it."
  (should (eql 0 (apply #'call-process (portal-linux-gui--tool "wl-copy") nil nil nil
                        (append (and primary '("--primary"))
                                (if text (list "--" text) '("--clear")))))))

(defun portal-linux-terminal--clipboard ()
  "The clipboard's text, read by wl-paste.
Emacs may own the clipboard, so it goes on serving GTK while wl-paste reads."
  (let* ((output (generate-new-buffer " *portal-wl-paste*"))
         (process (make-process :name "portal-wl-paste" :buffer output :noquery t
                                :command (list (portal-linux-gui--tool "wl-paste") "--no-newline")
                                :stderr (get-buffer-create " *portal-wl-paste-errors*"))))
    (unwind-protect
        (progn
          (portal-linux-terminal--until (lambda () (not (process-live-p process))) 5)
          (with-current-buffer output (buffer-string)))
      (kill-buffer output))))

(ert-deftest portal-linux-gui-terminal-copies-and-pastes-with-insert ()
  :tags '(:gui)
  "Shift-Insert pastes the clipboard and Control-Insert copies to it, as in Emacs.
The primary selection, which Shift-Insert pastes in Ghostty by default, is
not what is pasted."
  (portal-linux-terminal--with
    (unwind-protect
        (let ((target (portal-linux-terminal--open))
              (window (selected-window))
              (scale (portal-linux-gui--scale)))
          (portal-linux-terminal--set-clipboard "PASTED-$((3*4))")
          (portal-linux-terminal--set-clipboard "PRIMARY-$((1+1))" t)
          (portal-linux-gui--type "echo ")
          (portal-linux-gui--type "-M" "shift" "-k" "Insert" "-m" "shift")
          ;; The clipboard is read on its own time: Return once it is in.
          (portal-linux-terminal--shows target "echo PASTED-$((3*4))")
          (portal-linux-gui--type "-k" "Return")
          (portal-linux-terminal--shows target "PASTED-12")
          (should-not (string-search "PRIMARY-2" (portal-linux-terminal--text target)))
          ;; Select the whole pane with the pointer, then copy.
          (portal-linux-terminal--run target "clear; echo COPIED-$((5+2))")
          (portal-linux-terminal--shows target "COPIED-7")
          (portal-linux-terminal--set-clipboard nil)
          (pcase-let ((`(,left ,top ,right ,bottom)
                       (mapcar (lambda (edge) (/ edge scale)) (portal-linux-gui--box window))))
            ;; The pointer goes back to the middle, off the corners that the
            ;; next test reads.
            (portal-linux-gui--point 'move (+ left 4) (+ top 4) 'press
                                     'move (/ (+ left right) 2) (/ (+ top bottom) 2)
                                     'move (- right 4) (- bottom 4) 'release
                                     'move (/ (+ left right) 2) (/ (+ top bottom) 2)))
          (portal-linux-gui--pause 0.3)
          (portal-linux-gui--type "-M" "ctrl" "-k" "Insert" "-m" "ctrl")
          (portal-linux-terminal--until
           (lambda () (string-search "COPIED-7" (portal-linux-terminal--clipboard))) 5)
          ;; Neither key reached Emacs.
          (should-not (read-event nil nil 0.2)))
      (portal-linux-terminal--set-clipboard nil)
      (portal-linux-terminal--set-clipboard nil t))))

(ert-deftest portal-linux-gui-terminal-reports-the-button-clicked ()
  :tags '(:gui)
  "A program that asks for the mouse is told which button was pressed.
In xterm's report of a press, 1b 5b 4d then the button: 21 the middle, 22
the right; its release follows, which the program reads too."
  (portal-linux-terminal--with
    (let ((target (portal-linux-terminal--open))
          (window (selected-window))
          (scale (portal-linux-gui--scale)))
      (pcase-let ((`(,left ,top . ,_) (portal-linux-gui--box window)))
        (pcase-dolist (`(,button ,code ,name) '((273 "22" "RIGHT") (274 "21" "MIDDLE")))
          (portal-linux-terminal--run
           target
           (format "stty raw -echo; printf '\\033[?1000h'; head -c 3; head -c 3 | od -An -tx1 | sed 's/^/%s/'; head -c 6 >/dev/null; printf '\\033[?1000l'; stty sane"
                   name))
          (portal-linux-gui--pause 0.5)
          (portal-linux-gui--point 'move (+ (/ left scale) 200) (+ (/ top scale) 200)
                                   'click button)
          (portal-linux-terminal--shows target (format "%s %s" name code)))))))

;;; Frames

(ert-deftest portal-linux-gui-terminal-draws-while-lisp-is-busy ()
  :tags '(:gui)
  "Output reaches the screen while Emacs's main thread is in Lisp."
  (portal-linux-terminal--with
    (let ((target (portal-linux-terminal--open)))
      (portal-linux-terminal--run target "yes PORTAL-OUTPUT")
      (portal-linux-gui--wait (lambda () (> (portal-linux-gui--get :committed target) 20)))
      ;; Idle, as many commits as the output shows frames: 60 a second
      ;; here, never one for each frame the renderer makes.
      (let ((state (portal-linux-gui--state target))
            (start (float-time)))
        (portal-linux-gui--pause 1)
        (let* ((after (portal-linux-gui--state target))
               (seconds (- (float-time) start))
               (rate (lambda (key) (/ (- (plist-get after key) (plist-get state key)) seconds))))
          (message "Idle, a second: %.0f frames announced, %.0f committed, %.0f shown"
                   (funcall rate :announced) (funcall rate :committed) (funcall rate :framed))
          (should (< 40 (funcall rate :committed) 70))
          (should (> (funcall rate :announced) (funcall rate :committed)))))
      ;; Half a second in Lisp, reading nothing.
      (let ((before (portal-linux-gui--get :framed target)))
        (portal-linux-terminal--busy 0.5)
        (let ((shown (- (portal-linux-gui--get :framed target) before)))
          (message "Half a second of busy Lisp: %d frames shown" shown)
          (should (>= shown 20))))
      (portal-linux-gui--type "-M" "ctrl" "-k" "c" "-m" "ctrl"))))

(ert-deftest portal-linux-gui-terminal-closes-beside-a-flood ()
  :tags '(:gui)
  "Two terminals side by side, one closed while the other runs a large `cat'.
No crash and no hang; no frame of the other torn, in a recording read by
test/linux-torn.py; and no DMABUF left open by the one closed."
  (let ((recorder (executable-find "wf-recorder"))
        (flash (make-temp-file "portal-flash-"))
        (recording (expand-file-name "terminal-flood.mkv"
                                     (or (getenv "PORTAL_TEST_LOGS")
                                         (expand-file-name "build" (getenv "PORTAL_GUI_ROOT"))))))
    (unless recorder (ert-fail "The Linux graphical checks need wf-recorder"))
    ;; 256 MB of text that keeps every cell red, then blue, over and over:
    ;; a clear in one color, then lines of text whose letters are the
    ;; background's color, which scroll in with that background; and the
    ;; cursor hidden, which has a color of its own.
    (should (eql 0 (call-process
                    "python3" nil nil nil "-c"
                    "import sys
line = b'portal ' * 11 + b'\\n'
with open(sys.argv[1], 'wb') as out:
    out.write(b'\\033[?25l')
    for i in range(256 * 16):
        color = b'255;0;0' if i % 2 == 0 else b'0;0;255'
        out.write(b'\\033[48;2;' + color + b'm\\033[38;2;' + color + b'm\\033[2J\\033[H')
        out.write(line * (65536 // len(line)))"
                    flash)))
    (unwind-protect
        (portal-linux-terminal--with
          (let* ((baseline (portal-linux-terminal--dmabufs))
                 (first (portal-linux-terminal--open))
                 (left (selected-window))
                 (right (split-window-right))
                 (second (progn (select-window right)
                                (switch-to-buffer (get-buffer-create "*scratch*"))
                                (portal-linux-terminal--open)))
                 (second-buffer (window-buffer right))
                 box cell process)
            (portal-linux-terminal--covers left first)
            (portal-linux-terminal--covers right second)
            ;; Where the first is while the recording runs, before the other
            ;; closes and its pane goes.
            (setq box (portal-linux-gui--box left)
                  cell (cadr (portal-linux-gui--get :cell first)))
            (portal-linux-gui--wait (lambda () (portal-linux-gui--get :focused second)))
            (portal-linux-terminal--run second "yes SECOND")
            (select-window left)
            (portal-terminal-focus)
            (portal-linux-gui--wait (lambda () (portal-linux-gui--get :focused first)))
            (setq process (start-process "portal-linux-recorder" nil recorder
                                         "-o" (getenv "PORTAL_TEST_DESKTOP") "-D" "-r" "60"
                                         "-c" "libx264rgb" "-p" "preset=ultrafast" "-p" "crf=0"
                                         "-f" recording "-y"))
            (portal-linux-gui--pause 1)
            (portal-linux-terminal--run
             first (format "cat %s; printf '\\033[0m\\033[2J\\033[?25h'; echo FLOOD-DONE"
                           (shell-quote-argument flash)))
            (portal-linux-terminal--until
             (lambda () (string-match-p "/cat\\'" (portal-linux-gui--get :program first))) 10)
            (portal-linux-gui--pause 0.3)
            ;; Closed under output, both its own and the other's.
            (let ((portal-terminal-confirm-kill nil)
                  (start (float-time)))
              (kill-buffer second-buffer)
              (message "Closing a terminal under a flood took %.1f ms"
                       (* 1000 (- (float-time) start))))
            (should-not (portal--inspect second))
            ;; Its text is read once the cat is done: reading all of it
            ;; selects it, under the terminal's lock.
            (let ((start (float-time)))
              (portal-linux-terminal--until
               (lambda () (string-match-p "sh\\'" (portal-linux-gui--get :program first))) 40)
              (message "The rest of the cat took %.1f s" (- (float-time) start)))
            (portal-linux-terminal--shows first "FLOOD-DONE")
            (portal-linux-gui--pause 0.5)
            (interrupt-process process)
            (portal-linux-gui--wait (lambda () (not (process-live-p process))))
            ;; The other ran on, and drew.
            (should (portal-linux-gui--get :showing first))
            ;; Its frames are its own DMABUFs, which it keeps while they
            ;; show: once it is closed too, none is left of either.
            (message "DMABUFs: %d before either, %d with one" baseline
                     (portal-linux-terminal--dmabufs))
            (let ((portal-terminal-confirm-kill nil))
              (kill-buffer (window-buffer left)))
            (portal-linux-gui--pause 0.5)
            (message "DMABUFs once both are closed: %d" (portal-linux-terminal--dmabufs))
            (should (= (portal-linux-terminal--dmabufs) baseline))
            ;; Its cells: Ghostty's padding, inside the pane, and below the
            ;; last whole row, is the theme's background.
            (pcase-let* ((`(,l ,top ,r ,bottom) box)
                         (inset 24)
                         (bottom (- bottom cell)))
              (with-temp-buffer
                (let ((status (call-process "python3" nil t nil "-B"
                                            (expand-file-name "test/linux-torn.py"
                                                              (getenv "PORTAL_GUI_ROOT"))
                                            recording
                                            (number-to-string (+ l inset))
                                            (number-to-string (+ top inset))
                                            (number-to-string (- r inset))
                                            (number-to-string (- bottom inset)))))
                  (message "Torn frames in %S: %s" box (string-trim (buffer-string)))
                  (should (eql status 0)))))))
      (delete-file flash))))

(provide 'portal-linux-terminal-tests)
;;; portal-linux-terminal-tests.el ends here
