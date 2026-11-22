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
(declare-function dbus-call-method "dbus" (bus service path interface method &rest args))
(declare-function dbus-ping "dbus" (bus service &optional timeout))
(declare-function dbus-register-signal "dbus" (bus service path interface signal handler &rest args))
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

(defun portal-render-smoke--mac-keyboard (_target)
  "Whether the frame's window is the key window of the active app."
  (string-match-p " (active)\\'" (portal-test-responder)))

;; On Linux the frame fills its output, and each place captures it and
;; types into it through the compositor, as a person's screenshot and
;; keys go.

(defun portal-render-smoke--program-output (program &rest arguments)
  "Run PROGRAM with ARGUMENTS; return (STATUS . OUTPUT), its two streams."
  (with-temp-buffer
    (let ((status (condition-case err
                      (apply #'call-process program nil t nil arguments)
                    (file-error (error-message-string err)))))
      (cons status (string-trim (buffer-string))))))

(defun portal-render-smoke--missing (&rest programs)
  "Say which of PROGRAMS are not on PATH, or nil when none is missing."
  (when-let* ((missing (seq-remove #'executable-find programs)))
    (format "%s not found" (string-join missing ", "))))

(defun portal-render-smoke--write-ppm (file width height raw)
  "Write RAW, rows of 24-bit RGB padded to 4 bytes, at FILE as a PPM.
Return nil, or why not."
  (let* ((row (* 3 width))
         (stride (* 4 (/ (+ row 3) 4))))
    (if (/= (length raw) (* stride height))
        (format "%d bytes, not %dx%d RGB" (length raw) width height)
      (with-temp-file file
        (set-buffer-multibyte nil)
        (insert (format "P6\n%d %d\n255\n" width height))
        (if (= stride row)
            (insert raw)
          (dotimes (y height)
            (insert (substring raw (* y stride) (+ (* y stride) row))))))
      nil)))

;;;; Hyprland: grim and wtype, which its wlr protocols serve

(defun portal-render-smoke--hyprctl (&rest arguments)
  "What hyprctl answers to ARGUMENTS, parsed from its JSON, or nil."
  (pcase (apply #'portal-render-smoke--program-output "hyprctl" "-j" arguments)
    (`(0 . ,json)
     (ignore-errors (json-parse-string json :object-type 'alist :array-type 'list
                                       :null-object nil :false-object nil)))))

(defun portal-render-smoke--hyprland-window ()
  "This Emacs's window as Hyprland lists it, or nil."
  (seq-find (lambda (client) (eql (alist-get 'pid client) (emacs-pid)))
            (portal-render-smoke--hyprctl "clients")))

(defun portal-render-smoke--hyprland-ready ()
  "Nil when this Hyprland can be captured and typed into, else why not."
  (portal-render-smoke--missing "hyprctl" "grim" "wtype"))

(defun portal-render-smoke--hyprland-capture (file)
  "Capture the frame's window at FILE with grim; return its scale, or why not.
The region is the window's on its monitor, at the monitor's scale."
  (let* ((window (portal-render-smoke--hyprland-window))
         (monitor (seq-find (lambda (monitor) (eql (alist-get 'id monitor)
                                                   (alist-get 'monitor window)))
                            (portal-render-smoke--hyprctl "monitors")))
         (scale (alist-get 'scale monitor))
         (start (float-time)))
    (if (not (and window scale))
        "Hyprland lists no window of this Emacs, or not its monitor"
      (pcase-let* ((`(,x ,y) (alist-get 'at window))
                   (`(,width ,height) (alist-get 'size window))
                   (`(,status . ,output)
                    (portal-render-smoke--program-output
                     "grim" "-t" "ppm" "-s" (number-to-string scale)
                     "-g" (format "%d,%d %dx%d" x y width height) file)))
        (if (not (eql status 0))
            (format "grim exited %s: %s" status output)
          (portal-render-smoke--note "captured %dx%d at %d,%d of %s, scale %s, in %.3fs by grim"
                                     width height x y (alist-get 'name monitor) scale
                                     (- (float-time) start))
          scale)))))

(defun portal-render-smoke--hyprland-type (text)
  "Type TEXT and Return with wtype, into the window with the keyboard."
  (let ((start (float-time)))
    (pcase (portal-render-smoke--program-output "wtype" text)
      (`(0 . ,_)
       (pcase (portal-render-smoke--program-output "wtype" "-k" "Return")
         (`(0 . ,_) (portal-render-smoke--note "typed in %.3fs by wtype" (- (float-time) start))
          nil)
         (`(,status . ,output) (format "wtype exited %s: %s" status output))))
      (`(,status . ,output) (format "wtype exited %s: %s" status output)))))

(defun portal-render-smoke--hyprland-keyboard (_target)
  "Whether Hyprland's active window is this Emacs's."
  (eql (alist-get 'pid (portal-render-smoke--hyprctl "activewindow")) (emacs-pid)))

(defun portal-render-smoke--hyprland-describe ()
  "Hyprland's active window, for the record."
  (let ((active (portal-render-smoke--hyprctl "activewindow")))
    (format "the active window is %S of %S, pid %s; this Emacs is %s"
            (alist-get 'title active) (alist-get 'class active)
            (alist-get 'pid active) (emacs-pid))))

;;;; GNOME: Mutter's own ScreenCast and RemoteDesktop, over D-Bus

(defconst portal-render-smoke--mutter "org.gnome.Mutter" "Mutter's D-Bus prefix.")

(defvar portal-render-smoke--mutter-typing nil
  "The path of the RemoteDesktop session that types, once it has started.")

(defun portal-render-smoke--mutter-call (service path method &rest arguments)
  "Call METHOD on Mutter's SERVICE at its object PATH, with ARGUMENTS.
A session's path is called on the service's Session interface."
  (let ((name (concat portal-render-smoke--mutter "." service)))
    (apply #'dbus-call-method :session name path
           (if (string-match-p "/Session" path) (concat name ".Session") name)
           method arguments)))

(defun portal-render-smoke--gnome-ready ()
  "Nil when this GNOME can be captured and typed into, else why not."
  (require 'dbus)
  (or (portal-render-smoke--missing "gst-launch-1.0")
      (unless (featurep 'dbusbind) "this Emacs has no D-Bus")
      (seq-some (lambda (service)
                  (let ((name (concat portal-render-smoke--mutter "." service)))
                    (unless (dbus-ping :session name 1000)
                      (format "no %s on the session bus" name))))
                '("ScreenCast" "RemoteDesktop" "DisplayConfig"))))

(defun portal-render-smoke--gnome-monitor ()
  "The frame's monitor as Mutter has it: (CONNECTOR WIDTH HEIGHT SCALE), or nil.
WIDTH and HEIGHT are its current mode's, in device pixels.  Mutter places
its monitors in device pixels or in Emacs's, as its layout mode says, so
either matches the frame's monitor's top left."
  (pcase-let* ((`(,_serial ,monitors ,logical ,_properties)
                (portal-render-smoke--mutter-call
                 "DisplayConfig" "/org/gnome/Mutter/DisplayConfig" "GetCurrentState"))
               (`(,fx ,fy) (alist-get 'geometry (frame-monitor-attributes))))
    (catch 'found
      (dolist (entry logical)
        (pcase-let ((`(,x ,y ,scale ,_transform ,_primary ,specs . ,_) entry))
          (when (or (and (= x fx) (= y fy))
                    (and (= x (round (* scale fx))) (= y (round (* scale fy)))))
            (let* ((connector (car (car specs)))
                   (monitor (seq-find (lambda (m) (equal (car (car m)) connector)) monitors))
                   (mode (seq-find (lambda (mode)
                                     (caar (alist-get "is-current" (car (last mode))
                                                      nil nil #'equal)))
                                   (nth 1 monitor))))
              (throw 'found (list connector (nth 1 mode) (nth 2 mode) scale)))))))))

(defun portal-render-smoke--gnome-capture (file)
  "Capture the frame's monitor at FILE through Mutter's ScreenCast.
One frame of its PipeWire stream, read with GStreamer.  Return the scale,
or why not."
  (let ((start (float-time)) node session)
    (unwind-protect
        (condition-case err
            (pcase-let ((`(,connector ,width ,height ,scale) (portal-render-smoke--gnome-monitor)))
              (if (not (and connector width))
                  "Mutter has no monitor where the frame is"
                (setq session (portal-render-smoke--mutter-call
                               "ScreenCast" "/org/gnome/Mutter/ScreenCast" "CreateSession"
                               '(:array :signature "{sv}")))
                (let ((stream (portal-render-smoke--mutter-call
                               "ScreenCast" session "RecordMonitor" connector
                               '(:array (:dict-entry "cursor-mode" (:variant :uint32 0)))))
                      (raw (concat file ".raw")))
                  (dbus-register-signal :session nil stream
                                        (concat portal-render-smoke--mutter ".ScreenCast.Stream")
                                        "PipeWireStreamAdded" (lambda (id) (setq node id)))
                  (portal-render-smoke--mutter-call "ScreenCast" session "Start")
                  ;; D-Bus signals arrive as events, which reading handles.
                  (let ((deadline (+ (float-time) 10)))
                    (while (and (not node) (< (float-time) deadline))
                      (read-event nil nil 0.05)))
                  (if (not node)
                      "Mutter's ScreenCast gave no PipeWire stream in 10 s"
                    (pcase (portal-render-smoke--program-output
                            "gst-launch-1.0" "-q" "pipewiresrc" (format "path=%d" node)
                            "num-buffers=1" "!" "videoconvert" "!"
                            (format "video/x-raw,format=RGB,width=%d,height=%d" width height)
                            "!" "filesink" (concat "location=" raw))
                      (`(0 . ,_)
                       (or (portal-render-smoke--write-ppm
                            file width height
                            (with-temp-buffer
                              (set-buffer-multibyte nil)
                              (insert-file-contents-literally raw)
                              (buffer-string)))
                           (progn
                             (portal-render-smoke--note
                              "captured %s, %dx%d at scale %s, in %.3fs by Mutter's ScreenCast"
                              connector width height scale (- (float-time) start))
                             scale)))
                      (`(,status . ,output)
                       (format "GStreamer exited %s on stream %s: %s" status node output)))))))
          (dbus-error (format "Mutter's ScreenCast: %s" (error-message-string err))))
      ;; Stopping a session ends its stream.
      (when session
        (ignore-errors (portal-render-smoke--mutter-call "ScreenCast" session "Stop"))))))

(defun portal-render-smoke--gnome-type (text)
  "Type TEXT and Return as keysyms through Mutter's RemoteDesktop; nil, or why not."
  (condition-case err
      (let ((start (float-time)))
        (unless portal-render-smoke--mutter-typing
          (let ((session (portal-render-smoke--mutter-call
                          "RemoteDesktop" "/org/gnome/Mutter/RemoteDesktop" "CreateSession")))
            (portal-render-smoke--mutter-call "RemoteDesktop" session "Start")
            (setq portal-render-smoke--mutter-typing session)
            ;; A key sent straight after Start is lost.
            (portal-render-smoke--pause 0.3)))
        (dolist (character (append text "\r" nil))
          (let ((keysym (if (eq character ?\r) #xff0d character)))
            (dolist (down '(t nil))
              (portal-render-smoke--mutter-call
               "RemoteDesktop" portal-render-smoke--mutter-typing
               "NotifyKeyboardKeysym" :uint32 keysym down)))
          (portal-render-smoke--pause 0.01))
        (portal-render-smoke--note "typed in %.3fs by Mutter's RemoteDesktop"
                                   (- (float-time) start))
        nil)
    (dbus-error (format "Mutter's RemoteDesktop: %s" (error-message-string err)))))

(defun portal-render-smoke--active (target)
  "Whether GTK says the window of TARGET's frame has the keyboard."
  (plist-get (portal--inspect target) :active))

(defun portal-render-smoke--linux-describe ()
  "What Emacs knows of the keyboard, for the record."
  (format "the frame's focus state is %S" (frame-focus-state)))

;;;; Plasma: KWin's ScreenShot2 through Spectacle, and its EIS

(defun portal-render-smoke--plasma-ready ()
  "Nil when this Plasma can be captured and typed into, else why not."
  (require 'dbus)
  (let ((typer (getenv "PORTAL_SMOKE_EI_TYPE")))
    (or (portal-render-smoke--missing "spectacle")
        (unless (featurep 'dbusbind) "this Emacs has no D-Bus")
        (unless (dbus-ping :session "org.kde.KWin" 1000) "no org.kde.KWin on the session bus")
        (unless (and typer (file-executable-p typer))
          (format "no EIS typer: %s" (or (getenv "PORTAL_SMOKE_EI_WHY") "not built"))))))

(defun portal-render-smoke--plasma-capture (file)
  "Capture the active window, the frame's, at FILE with Spectacle.
KWin's ScreenShot2 answers only the programs its desktop files authorise,
and Spectacle is one.  It writes a PPM, a format of Qt's own.  Return the
frame's scale, or why not."
  (let ((start (float-time)))
    (pcase (portal-render-smoke--program-output
            "spectacle" "--background" "--nonotify" "--activewindow" "--output" file)
      (`(0 . ,_)
       (if (not (file-exists-p file))
           "Spectacle wrote no capture"
         (portal-render-smoke--note "captured the active window in %.3fs by Spectacle"
                                    (- (float-time) start))
         (frame-scale-factor)))
      (`(,status . ,output) (format "Spectacle exited %s: %s" status output)))))

(defun portal-render-smoke--plasma-type (text)
  "Type TEXT and Return through KWin's EIS; nil, or why not."
  (let ((start (float-time)))
    (pcase (portal-render-smoke--program-output (getenv "PORTAL_SMOKE_EI_TYPE") text)
      (`(0 . ,_) (portal-render-smoke--note "typed in %.3fs through KWin's EIS"
                                            (- (float-time) start))
       nil)
      (`(,status . ,output) (format "the EIS typer exited %s: %s" status output)))))

(defvar portal-render-smoke--adapters
  `((mac :window-system ns
         :capture portal-render-smoke--mac-capture
         :type portal-render-smoke--mac-type
         :keyboard portal-render-smoke--mac-keyboard
         :describe portal-test-responder)
    (hyprland :window-system pgtk
              :ready portal-render-smoke--hyprland-ready
              :capture portal-render-smoke--hyprland-capture
              :type portal-render-smoke--hyprland-type
              :keyboard portal-render-smoke--hyprland-keyboard
              :describe portal-render-smoke--hyprland-describe)
    (gnome :window-system pgtk
           :ready portal-render-smoke--gnome-ready
           :capture portal-render-smoke--gnome-capture
           :type portal-render-smoke--gnome-type
           :keyboard portal-render-smoke--active
           :click t
           :describe portal-render-smoke--linux-describe)
    (plasma :window-system pgtk
            :ready portal-render-smoke--plasma-ready
            :capture portal-render-smoke--plasma-capture
            :type portal-render-smoke--plasma-type
            :keyboard portal-render-smoke--active
            :describe portal-render-smoke--linux-describe))
  "Each place's adapter: its name, then its window system and functions.
:ready, when there is one, returns nil when the place offers a way to
capture and to type, or a string saying why not: the test is then not
run.  :capture writes the frame's content area as it is shown, a binary
PPM in device pixels whose origin is the frame's top left, at the file it
is given, and returns the device scale, or a string saying why it could
not: the test is then not run.  :type types a string of lowercase letters
and Return, and returns nil, or a string saying why it could not: the test
is then not run.  :keyboard says whether the frame's window has the
keyboard, given the terminal's view, which `frame-focus-state' cannot: it
stays nil while a view has the keys.  :click, when non-nil, says the
place does not give a window a script started the keyboard: when the
window has not had it for 3 seconds, the test asks the person at the
desktop to click it, and waits PORTAL_SMOKE_CLICK_WAIT seconds (30).
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

(defun portal-render-smoke--rgb-kind (r g b)
  "Which of the test's colours R, G and B make, or nil."
  (cond ((and (> r 220) (< g 40) (< b 40)) 'red)
        ((and (< r 40) (< g 40) (> b 220)) 'blue)
        ((and (< r 40) (> g 220) (< b 40)) 'green)
        ((and (< (abs (- r #xf9)) 24) (< (abs (- g #x81)) 24) (< (abs (- b #x28)) 24))
         'orange)))

(defun portal-render-smoke--kind (color)
  "Which of the test's colours COLOR, (R G B), is, or nil."
  (apply #'portal-render-smoke--rgb-kind color))

(defun portal-render-smoke--boxes (screen box)
  "Each colour's bounding box and count in BOX of SCREEN, every pixel read.
An alist of (KIND LEFT TOP RIGHT BOTTOM COUNT)."
  (pcase-let ((`(,left ,top ,right ,bottom) box)
              (`(,width ,_ ,start ,bytes) screen)
              (found nil))
    (cl-loop for y from top below bottom
             do (cl-loop for x from left below right
                         for at = (+ start (* 3 (+ x (* y width))))
                         for kind = (portal-render-smoke--rgb-kind
                                     (aref bytes at) (aref bytes (+ at 1)) (aref bytes (+ at 2)))
                         when kind
                         do (let ((have (alist-get kind found)))
                              (if (not have)
                                  (push (cons kind (vector x y (1+ x) (1+ y) 1)) found)
                                (aset have 0 (min (aref have 0) x))
                                (aset have 1 (min (aref have 1) y))
                                (aset have 2 (max (aref have 2) (1+ x)))
                                (aset have 3 (max (aref have 3) (1+ y)))
                                (aset have 4 (1+ (aref have 4)))))))
    (mapcar (lambda (entry) (cons (car entry) (append (cdr entry) nil))) found)))

;; Every pixel of a pane is read: compiled, that takes a fraction of a second.
(byte-compile 'portal-render-smoke--pixel)
(byte-compile 'portal-render-smoke--rgb-kind)
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
        ;; A Linux capture is the frame's window or its output, which the
        ;; frame fills: either way the frame's size, or the pane's edges
        ;; are not the capture's coordinates.
        (unless (eq window-system 'ns)
          (portal-render-smoke--check
           (format "%s: the capture is the frame" name)
           (and (= width (round (* scale (frame-pixel-width))))
                (= height (round (* scale (frame-pixel-height)))))
           (list :capture (list width height) :scale scale
                 :frame (list (frame-pixel-width) (frame-pixel-height)))))
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

(defun portal-render-smoke--renderer ()
  "Record what draws the terminal on Linux, once it has drawn.
Ghostty's engine as the module reports it, the OpenGL drivers this Emacs
has loaded and the GPU devices it holds open: a hardware renderer opens
a DRM node, software rendering need not."
  (unless (eq window-system 'ns)
    (when (fboundp 'portal--terminal-engine)
      (portal-render-smoke--note "engine %s" (portal--terminal-engine)))
    (let* ((case-fold-search nil)
           (maps (with-temp-buffer
                   (ignore-errors (insert-file-contents "/proc/self/maps"))
                   (buffer-string)))
           (drivers (seq-uniq
                     (seq-filter (lambda (file)
                                   (string-match-p
                                    "\\`lib\\(EGL\\|GL\\|gallium\\|nvidia\\|vulkan_\\)\\|_dri\\.so"
                                    (file-name-nondirectory file)))
                                 (mapcar (lambda (line) (car (last (split-string line))))
                                         (split-string maps "\n" t)))))
           (devices (seq-uniq
                     (seq-filter (lambda (file) (string-prefix-p "/dev/dri/" file))
                                 (mapcar (lambda (fd) (file-truename fd))
                                         (ignore-errors
                                           (directory-files "/proc/self/fd" t "\\`[0-9]+\\'")))))))
      (portal-render-smoke--note "OpenGL drivers loaded: %s"
                                 (if drivers (mapconcat #'file-name-nondirectory drivers ", ")
                                   "none"))
      (portal-render-smoke--note "GPU devices open: %s"
                                 (if devices (string-join devices ", ") "none")))))

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
     (let ((keyboard (lambda () (funcall (plist-get adapter :keyboard) target))))
       (if (not (plist-get adapter :click))
           (portal-render-smoke--until keyboard 5)
         (or (portal-render-smoke--until keyboard 3)
             (let ((wait (string-to-number (or (getenv "PORTAL_SMOKE_CLICK_WAIT") "30"))))
               (portal-render-smoke--note "asking for a click on the window, for %ds" wait)
               (message "Portal's smoke test: click this window to give it the keyboard")
               (portal-render-smoke--until keyboard wait)))))
     (funcall (plist-get adapter :describe)))
    (when-let* ((why (funcall (plist-get adapter :type) token)))
      (portal-render-smoke--not-run "cannot type here: %s" why))
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
    (portal-render-smoke--renderer)
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
               (when-let* ((ready (plist-get adapter :ready))
                           (why (funcall ready)))
                 (portal-render-smoke--not-run "no way to capture or type on %s: %s" place why))
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
