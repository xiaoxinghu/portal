;;; portal-launcher-gui-tests.el --- Real NS panel lifecycle -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run only in a disposable graphical Emacs with the newly built module.
(require 'portal-launcher-testing)
(declare-function portal-test-hotkey "test-terminal-input" (hotkey pressed))
(declare-function portal--launcher-inspect "portal-launcher" ())
(declare-function portal--shortcuts "portal-global-shortcut" ())
(declare-function portal-test-native-post-key "test-terminal-input" (code flags text &optional windowless))
(declare-function portal-test-native-target-frame "test-terminal-input" (title))
(declare-function portal-test-frontmost "test-terminal-input" (&optional app))
(declare-function portal-test-native-focus-target "test-terminal-input" ())
(declare-function portal-test-capture-target "test-terminal-input" (file))
(declare-function vertico-mode "vertico" (&optional arg))
(declare-function marginalia-mode "marginalia" (&optional arg))
(defvar vertico-sort-function)
(defvar vertico-count)
(defvar vertico--candidates-ov)
(defvar vertico--index)

(ert-deftest portal-launcher-gui-real-buffer-and-reuse ()
  (portal-launcher-gui--with-panel
    (with-current-buffer content (insert "Real buffer in a native panel\n"))
    (portal-launcher-mode 1)
    (should (equal before (frame-list)))
    (should-not (plist-get (portal--launcher-inspect) :attached))
    (let ((frame (portal-launcher-show content)))
      (portal-launcher-gui--settle)
      (should (eq (selected-frame) frame))
      (should (eq (window-buffer (frame-selected-window frame)) content))
      (should (equal (buffer-string) "Real buffer in a native panel\n"))
      (should (plist-get (portal--launcher-inspect) :viewAttached))
      (should (plist-get (portal--launcher-inspect) :visible))
      (should (string-match-p "LauncherPanel" (plist-get (portal--launcher-inspect) :class)))
      (goto-char (point-max))
      (execute-kbd-macro "edited")
      (portal-launcher-hide)
      (should (eq (selected-window) ordinary))
      (should-not (frame-visible-p frame))
      (should-not (plist-get (portal--launcher-inspect) :visible))
      (should (eq (portal-launcher-show) frame))
      (should (string-suffix-p "edited" (buffer-string)))
      ;; The stress suite repeats this 100 times.
      (dotimes (_ 3) (portal-launcher-hide) (should (eq (portal-launcher-show) frame)))
      (portal-launcher-hide))))

(ert-deftest portal-launcher-gui-native-keyboard ()
  (skip-unless (fboundp 'portal-test-native-post-key))
  (portal-launcher-gui--with-panel
    (portal-launcher-show content)
    (portal-view--with-frame-title portal-launcher--frame #'portal-test-native-target-frame)
    (unwind-protect
        (progn
          (portal-test-native-post-key 0 0 "a")
          (should (equal (with-timeout (3 (ert-fail "Panel did not deliver input to Emacs"))
                           (read-key-sequence-vector nil)) [97])))
      (portal-test-native-target-frame nil))))

(ert-deftest portal-launcher-gui-geometry-and-appearance ()
  (portal-launcher-gui--with-panel
    (portal-launcher-show content)
    ;; The placement arithmetic for every size and offset is checked
    ;; without windows (test/native-launcher-geometry.swift); each display
    ;; gets a default and an odd placement here, each placed exactly.
    (let ((screens (plist-get (portal--launcher-inspect) :screens)) measurements)
      (dotimes (index (length screens))
        (pcase-dolist (`(,size ,offset) '(((720 420) (0 0)) ((713 407) (-137 81))))
          (let ((portal-launcher-screen index) (portal-launcher-size size)
                (portal-launcher-offset offset))
            (portal-launcher-show)
            (portal-launcher-gui--settle)
            (let ((state (portal--launcher-inspect)))
              (should (equal (plist-get state :requested) (plist-get state :actual)))
              (should (equal (cddr (plist-get state :actual)) size))
              (should (equal (list (frame-pixel-width portal-launcher--frame)
                                  (frame-pixel-height portal-launcher--frame)) size))
              (push (list :screen index :size size :offset offset
                          :requested (plist-get state :requested) :actual (plist-get state :actual))
                    measurements)))))
      (message "Launcher geometry: %S; screens: %S" (nreverse measurements) screens))
    (let ((portal-launcher-size '(713 407)))
      (dolist (appearance '(dark light nil))
        (set-frame-parameter portal-launcher--frame 'ns-appearance appearance)
        (dolist (font '("Menlo 13" "Menlo 18" "Menlo 15"))
          (let ((portal-launcher-font font))
            (portal-launcher-show)
            (portal-launcher-gui--settle)
            (should (equal (cddr (plist-get (portal--launcher-inspect) :actual)) '(713 407)))))))
    (let ((portal-launcher-size '(100000 100000)) (portal-launcher-offset '(-100000 100000)))
      (portal-launcher-show)
      (portal-launcher-gui--settle)
      (let* ((state (portal--launcher-inspect)) (actual (plist-get state :actual)))
        (should (equal actual (plist-get state :requested)))
        (should (cl-some (lambda (screen) (equal actual (plist-get screen :visible)))
                         (plist-get state :screens)))))
    ;; A disconnected index falls back to the pointer screen.
    (let ((portal-launcher-screen 999)) (portal-launcher-show))))

(ert-deftest portal-launcher-gui-delete-disable-and-child ()
  (portal-launcher-gui--with-panel
    ;; The stress suite repeats this 20 times.
    (dotimes (_ 2)
      (let ((frame (portal-launcher-show content)))
        (delete-frame frame t)
        (should-not (frame-live-p frame))
        (should-not (plist-get (portal--launcher-inspect) :attached))))
    (let* ((frame (portal-launcher-show content))
           (child (make-frame `((parent-frame . ,frame) (minibuffer . nil)
                               (undecorated . t) (width . 20) (height . 4)
                               (no-accept-focus . t) (visibility . nil)))))
      (make-frame-visible child)
      (portal-launcher-gui--settle)
      (delete-frame frame t)
      (should-not (frame-live-p child)))
    (dotimes (_ 3)
      (portal-launcher-show content)
      (portal-launcher-mode -1)
      (portal-launcher-mode -1)
      (should-not (plist-get (portal--launcher-inspect) :attached)))
    (should (eq (selected-window) ordinary))))

(ert-deftest portal-launcher-gui-rejects-mutation-and-rolls-back ()
  (portal-launcher-gui--with-panel
    (let ((initial-frames (frame-list)))
      (cl-letf (((symbol-function 'portal--launcher-attach)
                 (lambda (_title) (error "Simulated attachment failure"))))
        (should-error (portal-launcher-show content)))
      (should (equal initial-frames (frame-list)))
      (should-not (plist-get (portal--launcher-inspect) :attached)))
    (let ((frame (portal-launcher-show content)))
      (dolist (change '((undecorated . nil) (fullscreen . fullboth) (parent-frame . other)
                        (tool-bar-lines . 1) (no-focus-on-map . nil)))
        (should-error (set-frame-parameter frame (car change) (cdr change)) :type 'user-error))
      (modify-frame-parameters frame '((parent-frame . nil) (undecorated . t)))
      (should (plist-get (portal--launcher-inspect) :viewAttached))
      (portal-launcher-hide)
      ;; Ordinary Emacs frames still change their role normally.
      (set-frame-parameter (window-frame ordinary) 'undecorated t)
      (set-frame-parameter (window-frame ordinary) 'undecorated nil)
      (should (eq (portal-launcher-show) frame)))))

(ert-deftest portal-launcher-gui-picker-selection-without-typing ()
  ;; A user's picker in a minibuffer panel, typed into with native keys:
  ;; letters and Return, an arrow and Escape.  Portal returns whatever
  ;; completion returns; portal-launcher-tests.el checks each input with
  ;; stock completion and with Vertico, Orderless and Marginalia.
  (require 'vertico)
  (require 'orderless)
  (require 'marginalia)
  (portal-launcher-gui--with-panel
    (let ((reader completing-read-function)
          (picker (lambda ()
                    (completing-read "Pick: " '("Calculator" "Calendar" "Chess")))))
      (dolist (enhanced '(nil t))
        (let ((completion-styles (if enhanced '(orderless basic) '(basic)))
              (completion-category-defaults nil)
              (vertico-sort-function #'identity)
              (minibuffer-history nil))
          (vertico-mode (if enhanced 1 -1))
          (marginalia-mode (if enhanced 1 -1))
          (unwind-protect
              (cl-flet ((pick (strokes)
                          (portal-launcher-gui--present picker strokes nil '(:kind minibuffer))))
                (if (not enhanced)
                    (should (equal "Chess" (pick (append (portal-launcher-gui--text "Chess") '((36 0 "\r"))))))
                  ;; Vertico's highlight, moved with an arrow, is accepted.
                  (should (equal "Calendar" (pick '((125 0 "\uf701") (36 0 "\r")))))
                  (should-not (pick '((53 0 "\e"))))))
            (vertico-mode -1)
            (marginalia-mode -1)))
        (should (eq reader completing-read-function))
        (should (eq ordinary (selected-window)))))))

;; The launcher guide's examples, as a user configures them: the same picker from
;; M-x, its key and its global shortcut through the real command loop, a
;; persistent buffer and a shortcut that presents nothing.
(ert-deftest portal-launcher-gui-user-launchers-through-command-loop ()
  (skip-unless (fboundp 'portal-test-hotkey))
  (portal-launcher-gui--with-panel
    (let ((global (current-global-map))
          (map (make-sparse-keymap))
          (suggest-key-bindings nil)
          (extended-command-suggest-shorter nil)
          (messages (with-current-buffer "*Messages*" (point-max-marker))))
      (unwind-protect
          (progn
            ;; The picker's key goes in a map of this test's own.
            (set-keymap-parent map global)
            (use-global-map map)
            (discard-input)
            (dolist (example '("launcher-picker" "launcher-hello" "launcher-shortcuts"))
              (portal-launcher-gui--example example))
            ;; Configuring set only the three shortcuts, and no panel yet.
            (should (equal (mapcar #'car portal-global-shortcut--registrations)
                           '(pick-fruit hello clock)))
            (should (= 3 (length (portal--shortcuts))))
            (should-not portal-launcher--frame)
            (cl-flet ((pick (start fruit)
                        (portal-launcher-gui--drive
                         start (append (portal-launcher-gui--text fruit) '((36 0 "\r"))) nil t)
                        (should (with-current-buffer "*Messages*"
                                  (save-excursion
                                    (goto-char messages)
                                    (search-forward (concat "Picked " fruit) nil t))))
                        (should (portal-launcher--live-p 'minibuffer))
                        (should (eq ordinary (selected-window))))
                      (queue (keys)
                        (lambda () (setq unread-command-events (listify-key-sequence (kbd keys))))))
              (pick (queue "M-x my/pick-fruit RET") "Banana")
              (pick (queue "C-c f") "Cherry")
              (pick (lambda () (portal-launcher-gui--press 'pick-fruit)) "Apple"))
            ;; The persistent buffer from its shortcut; the same chord again
            ;; dismisses it.
            (portal-launcher-gui--drive
             (lambda () (portal-launcher-gui--press 'hello))
             (append (portal-launcher-gui--text "nok") '((36 0 "\r") (30 262144 "\C-]")))
             (lambda () (portal-launcher-gui--press 'hello))
             t)
            (should (equal "Hello world!\nHello ok!" (with-current-buffer "*Hello*" (buffer-string))))
            (portal-launcher-gui--check-unwound)
            ;; A shortcut that presents nothing leaves the hidden panel alone.
            (let ((frames (frame-list)))
              (portal-launcher-gui--drive (lambda () (portal-launcher-gui--press 'clock)) nil nil t)
              (should (equal frames (frame-list)))
              (should-not (plist-get (portal--launcher-inspect) :visible))
              (should (eq ordinary (selected-window)))
              (should (with-current-buffer "*Messages*"
                        (save-excursion
                          (goto-char messages)
                          (re-search-forward "^[0-9][0-9]:[0-9][0-9]$" nil t)))))
            ;; The shortcuts outlast deleting and disabling the panel, and
            ;; evaluating the configuration again keeps one of each.
            (let ((ids (mapcar #'cadr portal-global-shortcut--registrations)))
              (delete-frame portal-launcher--frame t)
              (portal-launcher-mode -1)
              (should (equal ids (mapcar #'cadr portal-global-shortcut--registrations)))
              (portal-launcher-gui--example "launcher-shortcuts")
              (should (= 3 (length portal-global-shortcut--registrations)))
              (should (= 3 (length (portal--shortcuts))))
              (should-not (cl-intersection ids (mapcar #'cadr portal-global-shortcut--registrations))))
            (portal-launcher-gui--drive (lambda () (portal-launcher-gui--press 'pick-fruit))
                                        (append (portal-launcher-gui--text "Apple") '((36 0 "\r")))
                                        nil t)
            (should (portal-launcher--live-p 'minibuffer))
            ;; Removing one leaves the others; its hot key is gone.
            (let ((hotkey (portal-launcher-gui--hotkey 'hello)))
              (should (portal-global-shortcut-remove 'hello))
              (should-not (portal-test-hotkey hotkey t)))
            (should (equal (mapcar #'car portal-global-shortcut--registrations) '(pick-fruit clock))))
        (use-global-map global)
        (when (get-buffer "*Hello*") (kill-buffer "*Hello*"))))))

(ert-deftest portal-launcher-gui-session-stock-and-completion-stack ()
  ;; The full completion stack in the native panel; portal-launcher-tests.el
  ;; checks stock completion and this stack's matching.
  (portal-launcher-gui--with-panel
    (require 'vertico)
    (require 'orderless)
    (require 'marginalia)
    (dolist (enhanced '(t))
      (let* ((completion-styles (if enhanced '(orderless basic) '(basic)))
             (completion-category-defaults nil)
             (rules display-buffer-alist)
             (maps emulation-mode-map-alists)
             frames visible
             (minibuffer-setup-hook
              (cons (lambda ()
                      (push (window-frame (active-minibuffer-window)) frames)
                      (push (and (frame-visible-p portal-launcher--frame)
                                 (plist-get (portal--launcher-inspect) :visible)) visible))
                    minibuffer-setup-hook)))
        (vertico-mode (if enhanced 1 -1))
        (marginalia-mode (if enhanced 1 -1))
        (unwind-protect
            (should
             (equal "forward-line"
                    (portal-launcher-gui--present
                     (lambda ()
                       (interactive)
                       (completing-read
                        "Command: "
                        (lambda (string predicate action)
                          (if (eq action 'metadata) '(metadata (category . command))
                            (complete-with-action action '("forward-line" "forward-char") string predicate)))
                        nil t))
                     (append (portal-launcher-gui--text (if enhanced "line for" "forward-line"))
                             '((36 0 "\r"))))))
          (vertico-mode -1)
          (marginalia-mode -1))
        (should (equal frames (list portal-launcher--frame)))
        (should (equal visible '(t)))
        (should (eq rules display-buffer-alist))
        (should (eq maps emulation-mode-map-alists))
        (should (eq (selected-window) ordinary))))))

(defun portal-launcher-gui--minibuffer-layout ()
  "Describe the minibuffer launcher's layout, from inside its prompt."
  (redisplay t)
  (let* ((frame portal-launcher--frame)
         (mini (active-minibuffer-window))
         (state (portal--launcher-inspect)))
    (list :input (minibuffer-contents)
          :kind (portal-launcher--kind frame)
          :windows (equal (window-list frame t) (list mini))
          :root (eq (frame-root-window frame) mini)
          :top (- (cadr (window-pixel-edges mini)) (frame-internal-border-width frame))
          :spare (- (frame-pixel-height frame) (* 2 (frame-internal-border-width frame))
                    (window-pixel-height mini))
          :clipped (- (cdr (window-text-pixel-size mini nil nil nil nil t))
                      (window-pixel-height mini))
          :mode-line (window-mode-line-height mini)
          ;; Vertico starts its candidates with a newline and ends each with one.
          :candidates (and (bound-and-true-p vertico--candidates-ov)
                           (1- (cl-count ?\n (overlay-get vertico--candidates-ov 'before-string))))
          :index (bound-and-true-p vertico--index)
          :size (list (frame-pixel-width frame) (frame-pixel-height frame))
          :native (equal (plist-get state :requested) (plist-get state :actual))
          :actual (plist-get state :actual))))

(ert-deftest portal-launcher-gui-minibuffer-panel-vertico ()
  (require 'vertico)
  (portal-launcher-gui--with-panel
    (dolist (size '((720 420) (640 320)))
      (let ((portal-launcher-size size)
            (vertico-sort-function nil) (vertico-count 10)
            (completion-styles '(basic)) (completion-category-defaults nil)
            layouts)
        (vertico-mode 1)
        (unwind-protect
            (should
             (equal "al02"
                    (portal-launcher-gui--present
                     (lambda ()
                       (minibuffer-with-setup-hook
                           (lambda ()
                             (add-hook 'post-command-hook
                                       (lambda () (push (portal-launcher-gui--minibuffer-layout) layouts))
                                       90 t))
                         (completing-read
                          "Pick: " (cons "beta" (mapcar (lambda (n) (format "al%02d" n))
                                                        (number-sequence 1 15)))
                          nil t)))
                     (append (portal-launcher-gui--text "al")
                             '((125 0 "\uf701"))
                             ;; A no-op key, so the layout after Down is
                             ;; pictured once Vertico has redrawn.
                             '((30 262144 "\C-]")) '((36 0 "\r")))
                     (lambda () (portal-launcher-gui--capture (format "minibuffer-vertico-%dx%d" (car size) (cadr size))))
                     '(:kind minibuffer))))
          (vertico-mode -1))
        (let ((layout (cadr layouts)))
          (message "Launcher minibuffer layout %S: %S" size layout)
          (should (equal (plist-get layout :input) "al"))
          (should (eq (plist-get layout :kind) 'minibuffer))
          ;; The minibuffer is the panel's only window: no buffer or mode line
          ;; above it, and the prompt starts at the top of the text area.
          (should (plist-get layout :windows))
          (should (plist-get layout :root))
          (should (= 0 (plist-get layout :top)))
          (should (= 0 (plist-get layout :spare)))
          (should (= 0 (plist-get layout :mode-line)))
          ;; Ten candidates of fifteen, the second selected, none clipped.
          (should (= 10 (plist-get layout :candidates)))
          (should (= 1 (plist-get layout :index)))
          (should (<= (plist-get layout :clipped) 0))
          (should (equal (plist-get layout :size) size))
          (should (plist-get layout :native))
          (should (equal (cddr (plist-get layout :actual)) size)))))))

;; Automatic minibuffer height: `portal-launcher-size' nil or (WIDTH auto).

(declare-function portal-test-pointer "test-terminal-input" (&optional x y))
(declare-function portal-test-compose "test-terminal-input" (text &optional commit))
(declare-function portal-test-marked-text "test-terminal-input" ())
(defvar vertico-resize)

(defvar portal-launcher-gui--layouts nil
  "What `portal-launcher-gui--record' described, most recent first.")

(defvar portal-launcher-gui--row-limit 5
  "Rows that `portal-launcher-gui--inline-rows' shows at most.")

(defvar portal-launcher-gui--refresh nil
  "Update the rows that `portal-launcher-gui--inline-rows' shows.")

(defconst portal-launcher-gui--fruits '("alpha" "alpine" "alto" "also" "altar" "beta" "bet")
  "Five of these show with no input, two start with \"alp\" and none with \"alpx\".")

(defun portal-launcher-gui--inline-rows (candidates &optional trailing)
  "Show CANDIDATES starting with the input in rows below the prompt.
An end-of-buffer overlay's after-string holds them, after a space bearing
the cursor, as an inline completion UI shows them, up to
`portal-launcher-gui--row-limit'. With TRAILING, a newline ends it. The
rows change after each command and on `portal-launcher-gui--refresh'."
  (let ((overlay (make-overlay (point-max) (point-max) nil t t))
        (buffer (current-buffer)))
    (setq portal-launcher-gui--refresh
          (lambda ()
            (with-current-buffer buffer
              (let ((input (minibuffer-contents-no-properties)))
                (move-overlay overlay (point-max) (point-max))
                (overlay-put overlay 'after-string
                             (concat (propertize " " 'cursor t)
                                     (mapconcat (lambda (row) (concat "\n" row))
                                                (take portal-launcher-gui--row-limit
                                                      (seq-filter (lambda (row) (string-prefix-p input row))
                                                                  candidates))
                                                "")
                                     (and trailing "\n")))))))
    (funcall portal-launcher-gui--refresh)
    (add-hook 'post-command-hook (lambda () (funcall portal-launcher-gui--refresh)) nil t)))

(defun portal-launcher-gui--rectangle-in (rectangle area)
  "Whether the (X Y WIDTH HEIGHT) RECTANGLE's top-left corner is in AREA."
  (and (<= (nth 0 area) (nth 0 rectangle) (+ (nth 0 area) (nth 2 area) -1))
       (< (nth 1 area) (+ (nth 1 rectangle) (nth 3 rectangle)) (+ (nth 1 area) (nth 3 area) 1))))

(defun portal-launcher-gui--record ()
  "Describe the minibuffer panel from inside its prompt, once it settles.
:fitted is the native height before this command redisplayed."
  (interactive)
  (let ((fitted (nth 3 (plist-get (portal--launcher-inspect) :actual))))
    (redisplay t)
    (let* ((frame portal-launcher--frame)
           (window (active-minibuffer-window))
           (state (portal--launcher-inspect))
           (actual (plist-get state :actual))
           (screen (cl-position-if (lambda (screen)
                                     (portal-launcher-gui--rectangle-in actual (plist-get screen :visible)))
                                   (plist-get state :screens))))
      (push (list :input (minibuffer-contents-no-properties) :fitted fitted
                  :session (plist-get state :session) :key (plist-get state :key)
                  :left (nth 0 actual) :top (+ (nth 1 actual) (nth 3 actual))
                  :width (nth 2 actual) :height (nth 3 actual)
                  :native (equal (plist-get state :requested) actual)
                  :frame (list (frame-pixel-width frame) (frame-pixel-height frame))
                  :body (window-body-height window t)
                  :text (cdr (window-text-pixel-size window))
                  :line (with-current-buffer (window-buffer window) (default-line-height))
                  :border (frame-internal-border-width frame)
                  :start (window-start window)
                  :screen screen
                  :area (plist-get (nth screen (plist-get state :screens)) :visible))
            portal-launcher-gui--layouts))))

(defun portal-launcher-gui--fit (read steps &optional setup)
  "Present READ in a minibuffer panel and return how it laid out.
SETUP runs as its first prompt starts. STEPS are native strokes, and
functions that C-] calls as commands, such as `portal-launcher-gui--record',
in order; Return then ends the prompt. Return (INITIAL . LAYOUTS): the
panel's rectangle before the prompt was displayed, and the descriptions."
  (let ((portal-launcher-gui--layouts nil) strokes actions initial
        ;; A delayed stroke timer must not catch up with several strokes at
        ;; once: Vertico, for one, does not redraw while input is waiting.
        (timer-max-repeats 1))
    (dolist (step steps)
      (if (functionp step)
          (progn (push '(30 262144 "\C-]") strokes) (push step actions))
        (push step strokes)))
    (setq actions (nreverse actions))
    (portal-launcher-gui--present
     (lambda ()
       (minibuffer-with-setup-hook
           (lambda ()
             (setq initial (plist-get (portal--launcher-inspect) :actual))
             (when setup (funcall setup)))
         (funcall read)))
     (append (nreverse strokes) '((36 0 "\r")))
     (lambda () (funcall (pop actions)))
     '(:kind minibuffer))
    (should-not actions)
    (cons initial (reverse portal-launcher-gui--layouts))))

(defun portal-launcher-gui--check-fitted (result width rows &optional exact)
  "Check that the layouts in RESULT fit ROWS lines below their first, at WIDTH.
RESULT is what `portal-launcher-gui--fit' returned. Each layout's height
must fit its text exactly, above the minimum, with the presentation's
session, focus, left and top edges unchanged since it opened, no taller.
With EXACT, the text must also be that many default lines high."
  (pcase-let* ((`(,initial . ,layouts) result)
               (first (car layouts)))
    (should (= (length layouts) (length rows)))
    (should (<= (nth 3 initial) (apply #'min (mapcar (lambda (layout) (plist-get layout :height)) layouts))))
    (cl-loop
     for layout in layouts for count in rows do
     (should (equal (list (plist-get layout :session) (plist-get layout :key) (plist-get layout :native)
                          (plist-get layout :left) (plist-get layout :top) (plist-get layout :width))
                    (list (plist-get first :session) t t
                          (nth 0 initial) (+ (nth 1 initial) (nth 3 initial)) width)))
     ;; Emacs's frame follows the native panel; its text fills it exactly.
     (let ((border (plist-get layout :border)) (text (plist-get layout :text)))
       (should (equal (plist-get layout :frame) (list width (plist-get layout :height))))
       (should (= (plist-get layout :height) (max 100 (+ text (* 2 border)))))
       (should (= (plist-get layout :body) (- (plist-get layout :height) (* 2 border))))
       (when exact (should (= text (* (1+ count) (plist-get layout :line)))))))))

(defconst portal-launcher-gui--five-two-none-five
  (append (list #'portal-launcher-gui--record) (portal-launcher-gui--text "alp")
          (list #'portal-launcher-gui--record) (portal-launcher-gui--text "x")
          (list #'portal-launcher-gui--record) (make-list 4 '(51 0 "\d"))
          (list #'portal-launcher-gui--record))
  "Steps from five rows of `portal-launcher-gui--fruits' to two, none and five.")

(ert-deftest portal-launcher-gui-minibuffer-panel-fits-content ()
  ;; Five rows, then two, none and five again: the height follows, from
  ;; the first placement's top edge, in the same presentation. A numeric
  ;; size, the control, stays fixed.
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-font "Menlo 24")
          (read (lambda () (read-from-minibuffer "Fruit: ")))
          (setup (lambda () (portal-launcher-gui--inline-rows portal-launcher-gui--fruits))))
      (pcase-dolist (`(,size ,width) '((nil 720) ((640 auto) 640)))
        (let* ((portal-launcher-size size)
               (result (portal-launcher-gui--fit read portal-launcher-gui--five-two-none-five setup)))
          (message "Launcher fitted rows %S: %S" size result)
          (portal-launcher-gui--check-fitted result width '(5 2 0 5) t)
          ;; Five rows, two and none differ in height here.
          (should (equal (length (delete-dups (mapcar (lambda (layout) (plist-get layout :height))
                                                      (cdr result))))
                         3))))
      ;; Commands and redisplay that change nothing ask the panel for nothing.
      (let* ((portal-launcher-size nil) (asks 0) before after
             (count (lambda (&rest _) (cl-incf asks))))
        (advice-add 'portal--launcher-fit :before count)
        (unwind-protect
            (portal-launcher-gui--fit read
                                      (list #'portal-launcher-gui--record
                                            (lambda () (interactive) (setq before asks))
                                            (lambda () (interactive))
                                            (lambda () (interactive) (redisplay t) (redisplay t))
                                            (lambda () (interactive) (setq after asks)))
                                      setup)
          (advice-remove 'portal--launcher-fit count))
        (message "Launcher fitted idle requests: %S then %S" before after)
        (should (> before 0))
        (should (= before after)))
      (let* ((portal-launcher-size '(720 240))
             (result (portal-launcher-gui--fit read portal-launcher-gui--five-two-none-five setup)))
        (message "Launcher fixed rows: %S" result)
        (should (equal (cddr (car result)) '(720 240)))
        (dolist (layout (cdr result))
          (should (equal (list (plist-get layout :height) (plist-get layout :frame)) '(240 (720 240)))))))))

(ert-deftest portal-launcher-gui-minibuffer-panel-fits-rendered-lines ()
  ;; Line spacing, a trailing newline, a taller row and wrapped input.
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-size nil)
          (portal-launcher-font "Menlo 24")
          (read (lambda () (read-from-minibuffer "Fruit: "))))
      (pcase-dolist (`(,name ,setup ,rows ,exact)
                     `((spacing ,(lambda ()
                                   (setq-local line-spacing 6)
                                   (portal-launcher-gui--inline-rows portal-launcher-gui--fruits))
                                (5) t)
                       (trailing ,(lambda () (portal-launcher-gui--inline-rows portal-launcher-gui--fruits t))
                                 (5) t)
                       (tall ,(lambda ()
                                (portal-launcher-gui--inline-rows
                                 (cons (propertize "alpaca" 'face '(:height 1.5)) portal-launcher-gui--fruits)))
                             (5) nil)))
        (let ((result (portal-launcher-gui--fit read (list #'portal-launcher-gui--record) setup)))
          (message "Launcher fitted %S: %S" name result)
          (portal-launcher-gui--check-fitted result 720 rows exact)
          (when (eq name 'tall)
            (let ((layout (cadr result)))
              (should (> (plist-get layout :text) (* 6 (plist-get layout :line))))))))
      ;; Input wraps at the panel's width: several lines, no rows; then two,
      ;; and none with less input; then five rows.
      (let* ((result (portal-launcher-gui--fit
                      read
                      (list (lambda () (interactive) (insert (make-string 200 ?w)))
                            #'portal-launcher-gui--record
                            (lambda () (interactive) (delete-char -150))
                            #'portal-launcher-gui--record
                            (lambda () (interactive) (delete-minibuffer-contents))
                            #'portal-launcher-gui--record)
                      (lambda () (portal-launcher-gui--inline-rows portal-launcher-gui--fruits))))
             (lines (mapcar (lambda (layout) (/ (plist-get layout :text) (plist-get layout :line)))
                            (cdr result))))
        (message "Launcher fitted wrapped input: %S %S" lines result)
        (should (> (car lines) 2))
        (should (> (car lines) (cadr lines) 0))
        (portal-launcher-gui--check-fitted result 720 (list (1- (car lines)) (1- (cadr lines)) 5) t)))))

(ert-deftest portal-launcher-gui-minibuffer-panel-stops-at-the-screen ()
  ;; Content taller than the space below the top edge stops there, with the
  ;; prompt still shown and usable, then shrinks again.
  (portal-launcher-gui--with-panel
    (let* ((portal-launcher-size nil)
           (portal-launcher-font "Menlo 24")
           (portal-launcher-offset '(0 200))
           (portal-launcher-gui--row-limit 5)
           (many (mapcar (lambda (n) (format "al%03d" n)) (number-sequence 1 300)))
           (result (portal-launcher-gui--fit
                    (lambda () (read-from-minibuffer "Many: "))
                    (append (list #'portal-launcher-gui--record
                                  (lambda () (interactive) (setq portal-launcher-gui--row-limit 300))
                                  #'portal-launcher-gui--record)
                            (portal-launcher-gui--text "al1")
                            (list #'portal-launcher-gui--record
                                  (lambda () (interactive) (setq portal-launcher-gui--row-limit 5))
                                  #'portal-launcher-gui--record))
                    (lambda () (portal-launcher-gui--inline-rows many))))
           (layouts (cdr result)))
      (message "Launcher fitted at the screen's bottom: %S" result)
      (pcase-let ((`(,first ,tall ,typed ,last) layouts))
        (dolist (layout (list tall typed))
          ;; The bottom edge stops at the usable area's; the top stays.
          (should (= (- (plist-get layout :top) (plist-get layout :height))
                     (nth 1 (plist-get layout :area))))
          (should (equal (mapcar (lambda (key) (plist-get layout key)) '(:top :left :width :session :key))
                         (mapcar (lambda (key) (plist-get first key)) '(:top :left :width :session :key))))
          (should (> (plist-get layout :text) (plist-get layout :body)))
          (should (equal (plist-get layout :frame) (list 720 (plist-get layout :height))))
          ;; The prompt stays at the top.
          (should (= (plist-get layout :start) 1)))
        (should (equal (plist-get typed :input) "al1"))
        (should (equal (plist-get last :height) (plist-get first :height)))
        (portal-launcher-gui--check-fitted (cons (car result) (list first last)) 720 '(5 5) t)))))

(ert-deftest portal-launcher-gui-minibuffer-panel-follows-later-changes ()
  ;; A timer's change fits with no key pressed; an echo area message keeps
  ;; the input's height; a nested prompt fits, and its outer prompt again.
  (portal-launcher-gui--with-panel
    (let* ((portal-launcher-size nil)
           (portal-launcher-font "Menlo 24")
           (portal-launcher-gui--row-limit 5)
           (echo nil)
           (result
            (portal-launcher-gui--fit
             (lambda () (read-from-minibuffer "Fruit: "))
             (append
              (list #'portal-launcher-gui--record
                    (lambda ()
                      (interactive)
                      (run-with-timer 0.01 nil (lambda ()
                                                 (setq portal-launcher-gui--row-limit 2)
                                                 (funcall portal-launcher-gui--refresh))))
                    #'portal-launcher-gui--record
                    (lambda ()
                      (interactive)
                      (let ((set-message-function nil) (message-log-max nil)
                            (height (nth 3 (plist-get (portal--launcher-inspect) :actual))))
                        (message "%s" (string-join (make-list 12 "Echo area message") "\n"))
                        (redisplay t)
                        (redisplay t)
                        (setq echo (list (current-message) height
                                         (nth 3 (plist-get (portal--launcher-inspect) :actual))))))
                    #'portal-launcher-gui--record
                    (lambda () (interactive) (setq portal-launcher-gui--row-limit 5))
                    #'portal-launcher-gui--record
                    (lambda () (interactive) (read-string "Inner: "))
                    #'portal-launcher-gui--record)
              (portal-launcher-gui--text "ok")
              (list #'portal-launcher-gui--record '(36 0 "\r") #'portal-launcher-gui--record))
             (lambda () (portal-launcher-gui--inline-rows portal-launcher-gui--fruits)))))
      (message "Launcher fitted later changes: %S; echo %S" result (cdr echo))
      (pcase-let ((`(,first ,timed ,echoed ,regrown ,inner ,typed ,outer) (cdr result)))
        ;; The timer's rows were fitted before the next key was read.
        (should (= (plist-get timed :fitted) (plist-get timed :height)))
        (should (car echo))
        (should (= (nth 1 echo) (nth 2 echo) (plist-get timed :height)))
        (should (equal (plist-get typed :input) "ok"))
        (portal-launcher-gui--check-fitted
         (cons (car result) (list first timed echoed regrown inner typed outer))
         720 '(5 2 2 5 0 0 5) t))
      ;; Emacs's redisplay may see no change as an inner prompt ends: its
      ;; window last showed a buffer changed more than the outer one.
      (let ((result (portal-launcher-gui--fit
                     (lambda () (read-from-minibuffer "One\nTwo\nThree\nFour: "))
                     (list #'portal-launcher-gui--record
                           (lambda () (interactive) (read-string "Inner: "))
                           (lambda () (interactive) (dotimes (_ 50) (insert "x") (delete-char -1)))
                           #'portal-launcher-gui--record
                           '(36 0 "\r")
                           #'portal-launcher-gui--record))))
        (message "Launcher fitted after an inner prompt: %S" result)
        (portal-launcher-gui--check-fitted result 720 '(3 0 3) t)
        (portal-launcher-gui--check-unwound)))))

(ert-deftest portal-launcher-gui-minibuffer-panel-stays-on-its-display ()
  ;; Moving the pointer to another display while typing moves nothing.
  (skip-unless (fboundp 'portal-test-pointer))
  (portal-launcher-gui--with-panel
    (portal-launcher-mode 1)
    (let* ((screens (plist-get (portal--launcher-inspect) :screens))
           (pointer (portal-test-pointer))
           (portal-launcher-size nil)
           (portal-launcher-font "Menlo 24"))
      (skip-unless (cdr screens))
      (unwind-protect
          (let* ((result
                  (portal-launcher-gui--fit
                   (lambda () (read-from-minibuffer "Fruit: "))
                   (append (list #'portal-launcher-gui--record
                                 (lambda ()
                                   (interactive)
                                   (let* ((here (plist-get (car portal-launcher-gui--layouts) :screen))
                                          (there (plist-get (nth (if (= here 0) 1 0) screens) :visible)))
                                     (portal-test-pointer (+ (nth 0 there) (/ (nth 2 there) 2))
                                                          (+ (nth 1 there) (/ (nth 3 there) 2))))))
                           (cdr portal-launcher-gui--five-two-none-five))
                   (lambda () (portal-launcher-gui--inline-rows portal-launcher-gui--fruits))))
                 (layouts (cdr result)))
            (message "Launcher fitted with the pointer moved: %S" result)
            (should (cl-every (lambda (layout) (eql (plist-get layout :screen) (plist-get (car layouts) :screen)))
                              layouts))
            (portal-launcher-gui--check-fitted result 720 '(5 2 0 5) t))
        (portal-test-pointer (car pointer) (cdr pointer))))))

(ert-deftest portal-launcher-gui-minibuffer-panel-keeps-composition ()
  ;; Input-method marked text survives the panel resizing around it, as
  ;; Emacs's NS input client sees it, then commits. Timers drive this: with
  ;; marked text, every key would go to the input method.
  (skip-unless (fboundp 'portal-test-compose))
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-size nil)
          (portal-launcher-font "Menlo 24")
          (portal-launcher-gui--layouts nil)
          (portal-launcher-gui--row-limit 5)
          initial marked value)
      (cl-flet ((record ()
                  (with-current-buffer (window-buffer (active-minibuffer-window))
                    (portal-launcher-gui--record)))
                (later (seconds function) (run-with-timer seconds nil function)))
        (unwind-protect
            (setq value
                  (with-timeout (10 (error "Composition timed out"))
                    (portal-launcher-present
                     (lambda ()
                       (minibuffer-with-setup-hook
                           (lambda ()
                             (setq initial (plist-get (portal--launcher-inspect) :actual))
                             (portal-launcher-gui--inline-rows
                              '("alpha" "alpine" "alto" "also" "altar" "nihao" "nihaoma"))
                             (portal-view--with-frame-title portal-launcher--frame
                                                            #'portal-test-native-target-frame)
                             (later 0.3 (lambda () (record) (portal-test-compose "nihao")))
                             ;; While composing, the completion UI updates
                             ;; without a key: two rows instead of five.
                             (later 0.8 (lambda ()
                                          (push (portal-test-marked-text) marked)
                                          (record)
                                          (setq portal-launcher-gui--row-limit 2)
                                          (funcall portal-launcher-gui--refresh)))
                             (later 1.3 (lambda ()
                                          (push (portal-test-marked-text) marked)
                                          (record)
                                          (portal-test-compose "你好" t)))
                             (later 2.0 (lambda ()
                                          (push (portal-test-marked-text) marked)
                                          (record)
                                          (portal-test-native-post-key 36 0 "\r"))))
                         (read-from-minibuffer "Compose: ")))
                     :kind 'minibuffer)))
          (portal-test-native-target-frame nil)))
      (let ((layouts (reverse portal-launcher-gui--layouts)))
        (message "Launcher fitted composition: %S %S" (reverse marked) layouts)
        (should (equal value "你好"))
        (should (equal (reverse marked) '(t t nil)))
        ;; Emacs shows marked text in an overlay at point, not as input.
        (should (equal (mapcar (lambda (layout) (plist-get layout :input)) (take 3 layouts)) '("" "" "")))
        (portal-launcher-gui--check-fitted (cons initial (take 3 layouts)) 720 '(5 5 2) t)
        ;; The committed text's fallback font may set its own line height.
        (portal-launcher-gui--check-fitted (cons initial layouts) 720 '(5 5 2 0))))))

(ert-deftest portal-launcher-gui-minibuffer-panel-fits-vertico ()
  ;; Vertico draws its rows in an end-of-buffer before-string, with group
  ;; titles here, whatever its own window policy. Its settings stay.
  (require 'vertico)
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-size nil)
          (portal-launcher-font "Menlo 24")
          (vertico-count 5) (vertico-sort-function nil)
          (completion-styles '(basic)) (completion-category-defaults nil)
          (settings (list (default-value 'vertico-resize) (default-value 'resize-mini-windows)
                          (default-value 'max-mini-window-height) resize-mini-frames))
          (grouped (lambda (string predicate action)
                     (if (eq action 'metadata)
                         `(metadata (group-function . ,(lambda (candidate transform)
                                                         (if transform candidate
                                                           (if (string-prefix-p "alp" candidate) "Peaks" "Others"))))
                                    (annotation-function . ,(lambda (_candidate) " fruit")))
                       (complete-with-action action portal-launcher-gui--fruits string predicate)))))
      (vertico-mode 1)
      (unwind-protect
          (dolist (resize '(grow-only t nil))
            (dolist (table (list portal-launcher-gui--fruits grouped))
              (let* ((vertico-resize resize)
                     (counts nil)
                     (result (portal-launcher-gui--fit
                              (lambda () (completing-read "Fruit: " table))
                              ;; Vertico draws after a command with no input
                              ;; waiting, so a no-op command comes first.
                              (cons
                               (lambda () (interactive))
                               (mapcar (lambda (step)
                                         (if (functionp step)
                                             (lambda ()
                                               (interactive)
                                               ;; A newline starts the rows, and ends each.
                                               (push (max 0 (1- (cl-count ?\n (overlay-get vertico--candidates-ov
                                                                                           'before-string))))
                                                     counts)
                                               (portal-launcher-gui--record)
                                               (when (and (eq resize 'grow-only) (functionp table))
                                                 (portal-launcher-gui--capture
                                                  (format "minibuffer-fitted-%s" (minibuffer-contents-no-properties)))))
                                           step))
                                       portal-launcher-gui--five-two-none-five)))))
                (message "Launcher fitted Vertico %S %S: %S %S" resize (functionp table) (reverse counts) result)
                (unless (functionp table) (should (equal (reverse counts) '(5 2 0 5))))
                (portal-launcher-gui--check-fitted result 720 (reverse counts) t)))
            ;; Cancelling leaves the same settings.
            (should-not (portal-launcher-gui--present
                         (lambda () (completing-read "Fruit: " portal-launcher-gui--fruits))
                         '((53 0 "\e")) nil '(:kind minibuffer))))
        (vertico-mode -1))
      (should (equal settings (list (default-value 'vertico-resize) (default-value 'resize-mini-windows)
                                    (default-value 'max-mini-window-height) resize-mini-frames))))))

(ert-deftest portal-launcher-gui-minibuffer-panel-stock-completion ()
  (portal-launcher-gui--with-panel
    ;; Fitting its content; portal-launcher-tests.el also checks a fixed size.
    (dolist (portal-launcher-size '(nil))
      (let ((windows (window-list (window-frame ordinary) t))
            shown)
        ;; Tab completes and Return accepts, but *Completions* shows nowhere.
        (should
         (equal "alpha"
                (portal-launcher-gui--present
                 (lambda ()
                   (minibuffer-with-setup-hook
                       (lambda ()
                         (add-hook 'post-command-hook
                                   (lambda ()
                                     (push (list (minibuffer-contents)
                                                 (get-buffer-window "*Completions*" t))
                                           shown))
                                   90 t))
                     (completing-read "Pick: " '("alpha" "alps" "beta") nil t)))
                 (append (portal-launcher-gui--text "a") '((48 0 "\t") (48 0 "\t"))
                         (portal-launcher-gui--text "ha") '((36 0 "\r")))
                 nil '(:kind minibuffer))))
        (should (member '("alp" nil) shown))
        (should-not (cl-some #'cadr shown))
        (should (equal windows (window-list (window-frame ordinary) t)))))))

(ert-deftest portal-launcher-gui-buffer-panel-mode-lines ()
  (portal-launcher-gui--with-panel
    (let ((format (buffer-local-value 'mode-line-format ordinary-buffer))
          (ordinary-height (window-mode-line-height ordinary)))
      (should (> ordinary-height 0))
      (dolist (mode-line '(t nil))
        (let ((heights
               (portal-launcher-present
                (lambda ()
                  (cl-flet ((height (window) (redisplay t) (window-mode-line-height window)))
                    (let* ((first (selected-window))
                           (initial (height first))
                           (second (split-window first))
                           (split (height second)))
                      ;; Both launcher windows switch buffers; one shows the
                      ;; ordinary window's buffer.
                      (switch-to-buffer ordinary-buffer)
                      (set-window-buffer second content)
                      (with-current-buffer content (insert (format "Mode lines: %s\n" mode-line)))
                      (prog1 (list initial split (height first) (height second)
                                   (window-mode-line-height ordinary))
                        (portal-launcher-gui--capture (format "buffer-mode-line-%s" mode-line))))))
                :mode-line mode-line)))
          (message "Launcher mode lines %S: %S" mode-line heights)
          (should (equal (car (last heights)) ordinary-height))
          (should (cl-every (if mode-line (lambda (height) (> height 0)) #'zerop) (butlast heights)))
          ;; The call's split is gone, and the parameter and hook with it.
          (should (equal (window-list portal-launcher--frame 'never)
                         (list (frame-first-window portal-launcher--frame))))
          (should-not (window-parameter (frame-first-window portal-launcher--frame) 'mode-line-format))
          (should-not (memq #'portal-launcher--hide-mode-lines window-buffer-change-functions))
          (should (eq format (buffer-local-value 'mode-line-format ordinary-buffer)))
          (should (= ordinary-height (window-mode-line-height ordinary)))))
      ;; A window's own mode-line parameter outlasts both settings, and an
      ;; explicit show leaves it alone.
      (let ((window (frame-first-window portal-launcher--frame))
            (custom '("Custom mode line")))
        (set-window-parameter window 'mode-line-format custom)
        (dolist (mode-line '(nil t))
          (should (equal (if mode-line custom 'none)
                         (portal-launcher-present
                          (lambda () (window-parameter (selected-window) 'mode-line-format))
                          :mode-line mode-line)))
          (should (equal custom (window-parameter window 'mode-line-format))))
        (portal-launcher-show content)
        (should (equal custom (window-parameter window 'mode-line-format)))
        (portal-launcher-hide)))))

(ert-deftest portal-launcher-gui-alternating-kinds ()
  (require 'vertico)
  (portal-launcher-gui--with-panel
    (let ((settings (list display-buffer-alist display-buffer-overriding-action resize-mini-frames
                          window-buffer-change-functions emulation-mode-map-alists
                          enable-recursive-minibuffers default-minibuffer-frame pop-up-frames
                          completing-read-function))
          (frames (length (frame-list)))
          timings)
      ;; Presenting while an explicitly shown launcher is selected returns to
      ;; the window it was shown from, even when the frame is replaced.
      (dolist (kind '(buffer minibuffer))
        (portal-launcher-show content)
        (should (eq (selected-frame) portal-launcher--frame))
        (should (eq kind (portal-launcher-present (lambda () kind) :kind kind)))
        (should (eq (selected-window) ordinary)))
      ;; At fixed sizes, then with minibuffer panels fitting their content.
      (dolist (portal-launcher-size '((720 420) nil))
        (dolist (options '((:kind minibuffer) (:kind buffer :mode-line nil) (:kind minibuffer)
                           (:mode-line t) (:kind buffer :mode-line nil) (:kind minibuffer :mode-line nil)
                           (:kind minibuffer) ()))
          (let* ((kind (or (plist-get options :kind) 'buffer))
                 (start (float-time))
                 (state (portal-launcher-gui--present
                         (lambda ()
                           (push (list options (- (float-time) start)) timings)
                           (list (portal-launcher--kind portal-launcher--frame) (length (frame-list))
                                 (read-string "Name: ")))
                         (append (portal-launcher-gui--text "ok") '((36 0 "\r"))) nil options)))
            (should (equal state (list kind (1+ frames) "ok")))
            (should (= (length (frame-list)) (1+ frames)))
            (should (plist-get (portal--launcher-inspect) :attached))
            (should (portal-launcher--live-p kind))
            (when (eq kind 'buffer)
              (should (= 1 (length (window-list portal-launcher--frame 'never))))
              (should-not (window-parameter (frame-first-window portal-launcher--frame) 'mode-line-format)))
            (should (equal settings
                           (list display-buffer-alist display-buffer-overriding-action resize-mini-frames
                                 window-buffer-change-functions emulation-mode-map-alists
                                 enable-recursive-minibuffers default-minibuffer-frame pop-up-frames
                                 completing-read-function))))))
      (message "Launcher show times (s): %S" (nreverse timings))
      ;; A split made in an explicitly shown panel outlives a presentation;
      ;; the window the call creates does not.
      (portal-launcher-show content)
      (let ((kept (split-window (frame-first-window portal-launcher--frame))))
        (portal-launcher-hide)
        (portal-launcher-present (lambda () (split-window)) :mode-line nil)
        (should (window-live-p kept))
        (should (= 2 (length (window-list portal-launcher--frame 'never))))
        (should (eq (selected-window) ordinary)))
      ;; Ordinary prompts behave as before, in the ordinary frame, with stock
      ;; completion's list there and with Vertico.
      (dolist (enhanced '(nil t))
        (vertico-mode (if enhanced 1 -1))
        (unwind-protect
            (let (minibuffer-frame completions-frame)
              (should
               (equal "alpha"
                      (minibuffer-with-setup-hook
                          (lambda ()
                            (setq minibuffer-frame (window-frame (active-minibuffer-window)))
                            (add-hook 'post-command-hook
                                      (lambda ()
                                        (when-let* ((window (get-buffer-window "*Completions*" t)))
                                          (setq completions-frame (window-frame window))))
                                      nil t))
                        (let ((unread-command-events
                               (listify-key-sequence (kbd (if enhanced "a l p h a RET"
                                                            "a l TAB TAB h a RET")))))
                          (completing-read "Pick: " '("alpha" "alps") nil t)))))
              (should (eq minibuffer-frame (window-frame ordinary)))
              (unless enhanced (should (eq completions-frame (window-frame ordinary)))))
          (vertico-mode -1))))))

(ert-deftest portal-launcher-gui-session-nested-dismissal-and-reentry ()
  (portal-launcher-gui--with-panel
    (portal-launcher-gui--dismiss-shortcut)
    ;; A minibuffer panel at a fixed size, and fitting its content.
    (pcase-dolist (`(,kind ,portal-launcher-size) '((buffer (720 420)) (minibuffer (720 420)) (minibuffer nil)))
      (dolist (reason '(escape quit second shortcut hide delete disable))
        (message "Launcher nested dismissal: %S %S %S" kind portal-launcher-size reason)
        (let (frames continued)
          (portal-launcher-gui--present
           (lambda ()
             (interactive)
             (minibuffer-with-setup-hook
                 (lambda ()
                   (push (window-frame (active-minibuffer-window)) frames)
                   (minibuffer-with-setup-hook
                       (lambda () (push (window-frame (active-minibuffer-window)) frames))
                     (completing-read "Inner: " '("alpha") nil t)))
               (completing-read "Outer: " '("alpha") nil t))
             (setq continued t))
           (list (pcase reason ('escape '(53 0 "\e")) ('quit 'quit)
                        (_ '(30 262144 "\C-]"))))
           (lambda ()
             (pcase reason
               ('second (portal-launcher-present #'ignore))
               ('shortcut (portal-launcher-gui--press 'portal-launcher-gui))
               ('hide (portal-launcher-hide))
               ('delete (delete-frame portal-launcher--frame t))
               ('disable (portal-launcher-mode -1))))
           (list :kind kind))
          (should-not continued)
          (should (= (length frames) 2))
          (should (eq (car frames) (cadr frames)))
          (should-not (eq (car frames) (window-frame ordinary)))
          (when (frame-live-p (car frames))
            (should (eq kind (portal-launcher--kind (car frames)))))
          (should (eq ordinary (selected-window)))
          (when (eq reason 'disable) (should-not portal-launcher-mode))
          (when (memq reason '(delete disable)) (should-not (frame-live-p (car frames))))
          ;; Re-entry works, in a buffer launcher even after a minibuffer one.
          (should (eq 'again (portal-launcher-present (lambda () (interactive) 'again))))
          (should (portal-launcher--live-p 'buffer)))))))

(ert-deftest portal-launcher-gui-session-command-error ()
  (portal-launcher-gui--with-panel
    (pcase-dolist (`(,kind ,portal-launcher-size) '((buffer (720 420)) (minibuffer (720 420)) (minibuffer nil)))
      (let (read-finished)
        (should (equal '(error "Command failed")
                       (should-error
                        (portal-launcher-gui--present
                         (lambda () (read-string "Before error: ")
                           (setq read-finished t) (error "Command failed"))
                         '((36 0 "\r")) nil (list :kind kind :mode-line nil)))))
        (should read-finished))
      (should-not (active-minibuffer-window))
      (should-not portal-launcher--session)
      (should-not (plist-get (portal--launcher-inspect) :visible))
      (should (eq ordinary (selected-window)))
      (should-not (memq #'portal-launcher--hide-mode-lines window-buffer-change-functions))
      (should (eq 'again (portal-launcher-present (lambda () (interactive) 'again) :kind kind))))))

(ert-deftest portal-launcher-gui-session-focus-loss ()
  (portal-launcher-gui--with-panel
    (pcase-dolist (`(,kind ,portal-launcher-size) '((buffer (720 420)) (minibuffer (720 420)) (minibuffer nil)))
      (let (continued)
        (portal-launcher-gui--present
         (lambda () (interactive) (read-string "Focus away: ") (setq continued t))
         '((30 262144 "\C-]"))
         (lambda ()
           (portal-view--with-frame-title (window-frame ordinary) #'portal-test-native-target-frame)
           (portal-test-native-focus-target))
         (list :kind kind))
        (should-not continued)
        (should (eq ordinary (selected-window)))))))

(defvar portal-launcher-gui--prompts nil
  "For each prompt a hello command opened, whether it was in the panel.")

(defun portal-launcher-gui--hello (&rest bindings)
  "Set up the hello-world UI, with local BINDINGS of (KEY . COMMAND).
The local command n reads a name in the minibuffer and greets it."
  (switch-to-buffer (get-buffer-create "*Hello*"))
  (let ((inhibit-read-only t)) (erase-buffer) (insert "Hello world!"))
  (special-mode)
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (current-local-map))
    (keymap-set map "n" #'portal-launcher-gui--greet)
    (pcase-dolist (`(,key . ,command) bindings) (keymap-set map key command))
    (use-local-map map)))

(defun portal-launcher-gui--greet ()
  "Greet a name read from the minibuffer."
  (interactive)
  (let ((name (minibuffer-with-setup-hook
                  (lambda ()
                    (push (eq (window-frame (active-minibuffer-window)) portal-launcher--frame)
                          portal-launcher-gui--prompts))
                (read-string "Name: ")))
        (inhibit-read-only t))
    (goto-char (point-max))
    (insert "\nHello " name "!")))

(ert-deftest portal-launcher-gui-persistent-buffer ()
  (portal-launcher-gui--with-panel
    (unwind-protect
        (let ((depth (recursion-depth)) (portal-launcher-gui--prompts nil) state)
          ;; The setup function returns at once; a local command, then its
          ;; prompt, read native keys in the panel.
          (should-not
           (portal-launcher-gui--present
            #'portal-launcher-gui--hello
            (append (portal-launcher-gui--text "nok") '((36 0 "\r") (30 262144 "\C-]") (53 0 "\e")))
            (lambda ()
              (redisplay t)
              (setq state (list :session (and portal-launcher--session t)
                                :depth (- (recursion-depth) depth)
                                :visible (and (frame-visible-p portal-launcher--frame)
                                              (plist-get (portal--launcher-inspect) :visible))
                                :key (plist-get (portal--launcher-inspect) :key)
                                :window (eq (window-frame) portal-launcher--frame)
                                :buffer (buffer-name) :text (buffer-string)
                                :mode-line (window-mode-line-height)))
              (portal-launcher-gui--capture "persistent-hello"))
            '(:kind buffer :mode-line nil :keep-open t)))
          (message "Launcher persistent buffer: %S" state)
          (should (equal state '(:session t :depth 1 :visible t :key t :window t :buffer "*Hello*"
                                 :text "Hello world!\nHello ok!" :mode-line 0)))
          (should (equal portal-launcher-gui--prompts '(t)))
          (portal-launcher-gui--check-unwound)
          (should (eq ordinary (selected-window)))
          ;; Hiding kept the buffer and its contents.
          (should (equal "Hello world!\nHello ok!" (with-current-buffer "*Hello*" (buffer-string))))
          ;; Without :keep-open the panel hides as the function returns.
          (should (eq 'closed (portal-launcher-present (lambda () (portal-launcher-gui--hello) 'closed)
                                                       :mode-line nil)))
          (should-not (plist-get (portal--launcher-inspect) :visible)))
      (kill-buffer "*Hello*"))))

(ert-deftest portal-launcher-gui-persistent-dismissal-and-reentry ()
  (portal-launcher-gui--with-panel
    (portal-launcher-gui--dismiss-shortcut)
    (unwind-protect
        (dolist (prompt '(nil t))
          (dolist (reason '(escape quit second shortcut hide delete disable focus))
            (message "Launcher persistent dismissal: %S %S" (if prompt 'prompt 'buffer) reason)
            (let ((portal-launcher-gui--prompts nil) frame)
              (should-not
               (portal-launcher-gui--present
                (lambda () (setq frame portal-launcher--frame) (portal-launcher-gui--hello))
                (append (when prompt (portal-launcher-gui--text "na"))
                        (list (pcase reason ('escape '(53 0 "\e")) ('quit 'quit)
                                     (_ '(30 262144 "\C-]")))))
                (lambda ()
                  (pcase reason
                    ('second (portal-launcher-present #'ignore))
                    ('shortcut (portal-launcher-gui--press 'portal-launcher-gui))
                    ('hide (portal-launcher-hide))
                    ('delete (delete-frame portal-launcher--frame t))
                    ('disable (portal-launcher-mode -1))
                    ('focus
                     (portal-view--with-frame-title (window-frame ordinary)
                                                    #'portal-test-native-target-frame)
                     (portal-test-native-focus-target))))
                '(:mode-line nil :keep-open t)))
              (should (equal portal-launcher-gui--prompts (and prompt '(t))))
              (portal-launcher-gui--check-unwound)
              (should (eq ordinary (selected-window)))
              (should (equal "Hello world!" (with-current-buffer "*Hello*" (buffer-string))))
              (should (eq (and (frame-live-p frame) t) (not (memq reason '(delete disable)))))
              (when (eq reason 'disable) (should-not portal-launcher-mode))
              (should (eq 'again (portal-launcher-present (lambda () (interactive) 'again)))))))
      (kill-buffer "*Hello*"))))

(ert-deftest portal-launcher-gui-persistent-command-errors ()
  (portal-launcher-gui--with-panel
    (unwind-protect
        (let ((messages (with-current-buffer "*Messages*" (point-max-marker))) state)
          ;; A later command's error is reported; then a command and its
          ;; prompt still work, until Escape.
          (should-not
           (portal-launcher-gui--present
            (lambda ()
              (portal-launcher-gui--hello
               (cons "e" (lambda () (interactive) (error "Later command failed")))))
            (append (portal-launcher-gui--text "enok") '((36 0 "\r") (30 262144 "\C-]") (53 0 "\e")))
            (lambda ()
              (setq state (list (and portal-launcher--session t)
                                (plist-get (portal--launcher-inspect) :visible)
                                (buffer-string))))
            '(:keep-open t)))
          (should (equal state '(t t "Hello world!\nHello ok!")))
          (should (with-current-buffer "*Messages*"
                    (save-excursion
                      (goto-char messages)
                      (search-forward "Later command failed" nil t))))
          (portal-launcher-gui--check-unwound)
          ;; Focus lost while a command runs, then discarded with the queued
          ;; input by Emacs's error report, still hides the panel, from the
          ;; buffer and from a prompt.
          (dolist (prompt '(nil t))
            (let (queued)
              (should-not
               (portal-launcher-gui--present
                #'portal-launcher-gui--hello
                (append (when prompt (portal-launcher-gui--text "n")) '((30 262144 "\C-]")))
                (lambda ()
                  (portal-view--with-frame-title (window-frame ordinary)
                                                 #'portal-test-native-target-frame)
                  (portal-test-native-focus-target)
                  (with-timeout (3 (error "The panel did not lose focus"))
                    (while (not (portal-launcher--session-blurred portal-launcher--session))
                      (accept-process-output nil 0.05)))
                  (setq queued (and (cl-find 'portal-launcher-blur unread-command-events :key #'car-safe) t))
                  (error "Failed after focus loss"))
                '(:keep-open t)))
              (should queued)
              (portal-launcher-gui--check-unwound)
              (should (eq ordinary (selected-window)))))
          (should (eq 'again (portal-launcher-present (lambda () (interactive) 'again)))))
      (kill-buffer "*Hello*"))))

(ert-deftest portal-launcher-gui-z-session-external-focus ()
  (portal-launcher-gui--with-panel
    ;; These are already-running, independent applications. Test both external
    ;; activation during a prompt and a command that opens an app and returns.
    (let ((previous (portal-test-frontmost)))
      (dolist (options '((:kind buffer) (:kind minibuffer) (:kind buffer) (:keep-open t)))
        (portal-launcher-gui--present
         (if (plist-get options :keep-open) #'portal-launcher-gui--hello
           (lambda () (interactive) (read-string "Cancel: ")))
         '((53 0 "\e")) nil options)
        (sit-for 0.1)
        (message "Launcher %S cancellation frontmost: %S (previous %S)"
                 options (portal-test-frontmost) previous)
        (should (eql previous (portal-test-frontmost)))))
    ;; A persistent panel's command that activates another app leaves that
    ;; app in front, as the panel hides on losing focus.
    (dolist (app (list (portal-test-frontmost -1) "com.apple.finder"))
      (let (activated)
        (should app)
        (portal-launcher-gui--present
         (lambda ()
           (portal-launcher-gui--hello
            (cons "o" (lambda () (interactive) (setq activated (portal-test-frontmost app))))))
         (portal-launcher-gui--text "o") nil '(:keep-open t))
        (with-timeout (3 (error "The panel's command did not activate %S" app))
          (while (not (eql activated (portal-test-frontmost))) (sit-for 0.05)))
        (message "Launcher persistent activation frontmost: %S (expected %S)"
                 (portal-test-frontmost) activated)
        (should (eql activated (portal-test-frontmost)))
        (should (eq ordinary (selected-window)))
        ;; AppKit can report the activation once the next session watches.
        (portal-launcher-gui--settle-focus)))
    (kill-buffer "*Hello*")
    (let ((destination (portal-test-frontmost -1)) continued)
      (should destination)
      (portal-launcher-gui--present
       (lambda () (interactive) (read-string "Activate another app: ") (setq continued t))
       '((30 262144 "\C-]")) (lambda () (portal-test-frontmost destination)))
      (should-not continued)
      (should (eql destination (portal-test-frontmost))))
    (let (finder)
      (portal-launcher-present
       (lambda () (interactive) (setq finder (portal-test-frontmost "com.apple.finder"))))
      (with-timeout (3 (error "Successful app launch did not activate Finder"))
        (while (not (eql finder (portal-test-frontmost))) (sit-for 0.05)))
      (message "Launcher success frontmost: %S (expected Finder %S)" (portal-test-frontmost) finder)
      (should (eql finder (portal-test-frontmost)))
      (should (eq ordinary (selected-window))))))

(provide 'portal-launcher-gui-tests)
