;;; portal-terminal-choose-gui-tests.el --- Choosing terminals with real keys -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Real native terminals, keys and focus with the Consult adapter, Vertico and
;; Orderless, from `build/elpa' (see docs/testing.md).  Keys are AppKit events for
;; this frame's window, typed as a person types: each once Emacs is idle, as
;; Vertico, like Consult, skips its work while input is pending.  From a
;; focused terminal, a native binding starts the picker.  C-] records the
;; state from inside the minibuffer; ESC ESC ESC cancels.

(require 'portal-gui-testing)
(declare-function portal-test-native-key "test-terminal-input" (code flags text &optional windowless))
(declare-function portal-test-native-post-key "test-terminal-input" (code flags text &optional windowless))
(declare-function portal-test-native-target-frame "test-terminal-input" (title))
(declare-function portal--inspect "portal-view" (target))
(declare-function vertico-mode "vertico" (&optional arg))
(declare-function portal-terminal-consult-mode "portal-terminal-consult" (&optional arg))

(defconst portal-choose-gui--codes
  '((?a . 0) (?s . 1) (?d . 2) (?h . 4) (?z . 6) (?e . 14) (?o . 31) (?i . 34)
    (?p . 35) (?q . 12) (?t . 17) (?w . 13) (?n . 45) (?- . 27) (?\s . 49))
  "US keyboard key codes of the characters the tests type.")

(defun portal-choose-gui--text (text)
  "Return the strokes that type TEXT."
  (mapcar (lambda (char) (list (alist-get char portal-choose-gui--codes) 0 (string char))) text))

(defconst portal-choose-gui--preview (list 47 (ash 1 19) ".") "M-.")
(defconst portal-choose-gui--probe (list 30 (ash 1 18) "\C-]") "C-], which records.")
(defconst portal-choose-gui--accept '(36 0 "\r") "RET.")
(defconst portal-choose-gui--cancel (make-list 3 '(53 0 "\e")) "ESC ESC ESC.")

(defvar portal-choose-gui--probe-function #'ignore "What the probe key records.")
(defvar portal-choose-gui--probes nil "The records, newest first.")

(defun portal-choose-gui--record ()
  "Record what `portal-choose-gui--probe-function' returns now."
  (interactive)
  (push (funcall portal-choose-gui--probe-function) portal-choose-gui--probes))

(defmacro portal-choose-gui--environment (&rest body)
  "Run BODY in one window with the Consult adapter, Vertico and Orderless on."
  (declare (indent 0))
  `(progn
     (skip-unless (and (eq window-system 'ns) (fboundp 'portal-test-native-key)
                       (require 'consult nil t) (require 'vertico nil t)
                       (require 'orderless nil t)))
     (require 'portal-terminal-consult)
     (let ((completion-styles '(orderless basic))
           (completion-category-defaults nil)
           (global (current-global-map))
           (map (make-sparse-keymap))
           (buffers (buffer-list)))
       (keymap-set map "C-]" #'portal-choose-gui--record)
       (set-keymap-parent map global)
       (use-global-map map)
       (portal-terminal-consult-mode)
       (vertico-mode)
       (unwind-protect
           (save-window-excursion
             (delete-other-windows)
             (select-frame-set-input-focus (selected-frame))
             (sit-for 0.1)
             ;; Other frames the test makes must not take the keys.
             (should (portal-view--with-frame-title (selected-frame)
                                                    #'portal-test-native-target-frame))
             ,@body)
         (portal-test-native-target-frame nil)
         (vertico-mode -1)
         (portal-terminal-consult-mode -1)
         (use-global-map global)
         (portal-terminal-close-all)
         (dolist (buffer (buffer-list))
           (unless (memq buffer buffers) (kill-buffer buffer)))))))

(defun portal-choose-gui--stuck ()
  "Describe a picker that did not finish: its input and who has the keyboard."
  (list "The picker did not finish"
        (when-let* ((window (active-minibuffer-window)))
          (with-current-buffer (window-buffer window) (minibuffer-contents-no-properties)))
        (mapcar (lambda (buffer)
                  (list (buffer-name buffer)
                        (plist-get (portal--inspect (buffer-local-value 'portal-view--target buffer))
                                   :focused)))
                (portal-view-buffers 'terminal))))

(defun portal-choose-gui--typing (strokes run)
  "Call RUN while STROKES are typed, and return what the probe recorded."
  (setq portal-choose-gui--probes nil)
  (let* ((timer nil)
         (stuck nil)
         (next (lambda ()
                 (if strokes
                     (apply #'portal-test-native-post-key (pop strokes))
                   (cancel-timer timer))))
         ;; Describe a stall while it lasts; the timeout leaves the minibuffer.
         (watch (run-with-timer 14 nil (lambda () (setq stuck (portal-choose-gui--stuck))))))
    (setq timer (run-with-idle-timer 0.05 t next))
    (unwind-protect
        (with-timeout (15 (ert-fail (list stuck strokes)))
          (condition-case nil (funcall run) (quit nil)))
      (cancel-timer timer)
      (cancel-timer watch))
    (should-not strokes)
    (should-not (active-minibuffer-window))
    (reverse portal-choose-gui--probes)))

(defun portal-choose-gui--from-emacs (command probe &rest strokes)
  "Run COMMAND while STROKES are typed; return what PROBE recorded."
  (let ((portal-choose-gui--probe-function probe))
    (portal-choose-gui--typing strokes command)))

(defun portal-choose-gui--from-terminal (probe &rest strokes)
  "Press Command-J in the focused terminal, then type STROKES.
Return what PROBE recorded."
  (select-frame-set-input-focus (selected-frame))
  (portal-terminal-focus)
  (should (portal-test-native-key 38 (ash 1 20) "j" t))
  (let* ((keys (with-timeout (3 (ert-fail "The native binding did not wake Emacs"))
                 (read-key-sequence-vector nil)))
         (event (aref keys 0))
         (portal-choose-gui--probe-function probe))
    (should (eq (car-safe event) 'portal-input-binding))
    (portal-choose-gui--typing strokes (lambda () (portal-input--dispatch event)))))

(defun portal-choose-gui--open (name)
  "Start a terminal named NAME in the selected window; return its buffer."
  (portal-terminal-new)
  (portal-terminal-rename name)
  (current-buffer))

(defun portal-choose-gui--view (buffer)
  "Return where BUFFER's view is and whether it has the keyboard.
Where is the window showing BUFFER at the view's edges, in any frame, nil
when the view is hidden, or `elsewhere'."
  (redisplay t)
  (let* ((state (portal-terminal-test--state (buffer-local-value 'portal-view--target buffer)))
         (edges (plist-get state :edges)))
    (list (and (plist-get state :visible)
               (or (seq-find (lambda (window)
                               (and (eq (window-buffer window) buffer)
                                    (equal (append (window-inside-pixel-edges window) nil) edges)))
                             (window-list-1 nil 'nomini t))
                   'elsewhere))
          (and (plist-get state :focused) t))))

(defun portal-choose-gui--untouched (&rest buffers)
  "Check that no shell of BUFFERS received the typed filter."
  (dolist (buffer buffers)
    (should-not (string-search "pqz" (portal-terminal-test--text
                                      (buffer-local-value 'portal-view--target buffer))))))

(ert-deftest portal-choose-gui-preview-from-emacs-and-another-frame ()
  (portal-choose-gui--environment
    (let* ((window (selected-window))
           (shown (portal-choose-gui--open "pqz-shown"))
           (hidden (portal-choose-gui--open "pqz-hidden"))
           (file (get-buffer-create "*portal-choose-gui*"))
           ;; It shows a terminal, but keys stay with this frame.
           (frame (make-frame '((no-accept-focus . t))))
           (remote (frame-selected-window frame))
           (probe (lambda ()
                    (list (buffer-name (window-buffer window)) (portal-choose-gui--view hidden)
                          (portal-choose-gui--view shown) (minibuffer-contents-no-properties)))))
      (unwind-protect
          (progn
            (set-window-buffer remote shown)
            (select-frame-set-input-focus (window-frame window))
            (select-window window)
            (switch-to-buffer file)
            (set-window-buffer (split-window-right) file)
            (should (equal (portal-choose-gui--view shown) (list remote nil)))
            ;; M-. previews without the keyboard; typing continues in the minibuffer.
            (should (equal (apply #'portal-choose-gui--from-emacs #'portal-terminal-choose probe
                                  (append (portal-choose-gui--text "pqz hid")
                                          (list portal-choose-gui--probe portal-choose-gui--preview
                                                portal-choose-gui--probe)
                                          (portal-choose-gui--text "den")
                                          (list portal-choose-gui--probe)
                                          portal-choose-gui--cancel))
                           `(("*portal-choose-gui*" (nil nil) (,remote nil) "pqz hid")
                             ("pqz-hidden" (,window nil) (,remote nil) "pqz hid")
                             ("pqz-hidden" (,window nil) (,remote nil) "pqz hidden"))))
            (should (eq (window-buffer window) file))
            (should (equal (portal-choose-gui--view hidden) '(nil nil)))
            ;; A terminal shown in another frame moves into the preview and back.
            (should (equal (apply #'portal-choose-gui--from-emacs #'portal-terminal-choose probe
                                  (append (portal-choose-gui--text "pqz sho")
                                          (list portal-choose-gui--preview portal-choose-gui--probe)
                                          portal-choose-gui--cancel))
                           `(("pqz-shown" (nil nil) (,window nil) "pqz sho"))))
            (should (equal (portal-choose-gui--view shown) (list remote nil)))
            ;; Accepting selects it here, where it now stays.
            (apply #'portal-choose-gui--from-emacs #'portal-terminal-choose #'ignore
                   (append (portal-choose-gui--text "pqz sho")
                           (list portal-choose-gui--preview portal-choose-gui--accept)))
            (should (eq (window-buffer window) shown))
            (should (equal (portal-choose-gui--view shown) (list window nil)))
            (portal-choose-gui--untouched shown hidden))
        (delete-frame frame)))))

(ert-deftest portal-choose-gui-preview-from-a-focused-terminal ()
  (portal-terminal-test--native-maps
    (portal-choose-gui--environment
      (portal-terminal-bind-key portal-terminal-native-map "s-j" #'portal-terminal-choose)
      (let* ((window (selected-window))
             (target (portal-choose-gui--open "pqz-target"))
             (origin (portal-choose-gui--open "origin"))
             (probe (lambda ()
                      (list (buffer-name (window-buffer window)) (portal-choose-gui--view target)
                            (portal-choose-gui--view origin)))))
        ;; Cancelling a preview returns to the terminal, with the keyboard.
        (should (equal (apply #'portal-choose-gui--from-terminal probe
                              (append (portal-choose-gui--text "pqz")
                                      (list portal-choose-gui--preview portal-choose-gui--probe)
                                      portal-choose-gui--cancel))
                       `(("pqz-target" (,window nil) (nil nil)))))
        (should (eq (window-buffer window) origin))
        (should (equal (portal-choose-gui--view origin) (list window t)))
        ;; Accepting gives the chosen terminal the keyboard once the minibuffer closes.
        (should (equal (apply #'portal-choose-gui--from-terminal probe
                              (append (portal-choose-gui--text "pqz")
                                      (list portal-choose-gui--preview portal-choose-gui--probe
                                            portal-choose-gui--accept)))
                       `(("pqz-target" (,window nil) (nil nil)))))
        (should (eq (window-buffer window) target))
        (should (equal (portal-choose-gui--view target) (list window t)))
        (should (equal (portal-choose-gui--view origin) '(nil nil)))
        (portal-choose-gui--untouched target origin)))))

(ert-deftest portal-choose-gui-preview-from-a-quick-panel ()
  (portal-terminal-test--native-maps
    (portal-choose-gui--environment
      (portal-terminal-bind-key portal-terminal-native-map "s-j" #'portal-terminal-choose)
      (let* ((window (selected-window))
             (target (portal-choose-gui--open "pqz-target"))
             (editing (portal-choose-gui--open "editing")))
        (portal-terminal-quick--show (file-name-as-directory temporary-file-directory))
        (let* ((panel (selected-window))
               (quick (current-buffer))
               (probe (lambda ()
                        (list (buffer-name (window-buffer window)) (buffer-name (window-buffer panel))
                              (portal-choose-gui--view target)))))
          ;; The editing window previews; cancelling returns to the panel.
          (should (equal (apply #'portal-choose-gui--from-terminal probe
                                (append (portal-choose-gui--text "pqz")
                                        (list portal-choose-gui--preview portal-choose-gui--probe)
                                        portal-choose-gui--cancel))
                         `(("pqz-target" ,(buffer-name quick) (,window nil)))))
          (should (eq (selected-window) panel))
          (should (eq (window-buffer window) editing))
          (should (equal (portal-choose-gui--view quick) (list panel t)))
          ;; Accepting opens the terminal there, with the keyboard; the panel stays.
          (apply #'portal-choose-gui--from-terminal #'ignore
                 (append (portal-choose-gui--text "pqz") (list portal-choose-gui--accept)))
          (should (eq (selected-window) window))
          (should (eq (window-buffer window) target))
          (should (eq (window-buffer panel) quick))
          (should (equal (portal-choose-gui--view target) (list window t)))
          (portal-choose-gui--untouched target quick))))))

(provide 'portal-terminal-choose-gui-tests)
;;; portal-terminal-choose-gui-tests.el ends here
