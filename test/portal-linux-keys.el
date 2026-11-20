;;; portal-linux-keys.el --- The test key injector's calls, on Linux -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; The graphical suites that run on both systems type with the three calls
;; of test/terminal-input.m, the macOS injector: `portal-test-native-key',
;; `portal-test-native-target-frame' and `portal-test-native-focus-target'.
;; test/gui-ert.sh loads this file in their place on Linux, where the
;; suites run on the desktop of test/linux-desktop.sh: a key is typed with
;; wtype, through the compositor and GDK as a person's is, into the window
;; that has that desktop's keyboard, which is the test's Emacs.
;;
;; A key is named by the text it types, as each call gives it, and its
;; flags; the macOS key code is not needed.  wtype returns before Emacs has
;; read what it typed, so each call lets Emacs read for a moment after.

(defconst portal-linux-keys--modifiers
  '((17 . "shift") (18 . "ctrl") (19 . "alt") (20 . "logo"))
  "The modifier of each bit of a macOS key's flags, as wtype names it.")

(defconst portal-linux-keys--named
  '((?\r . "Return") (?\e . "Escape") (?\t . "Tab") (?\d . "BackSpace"))
  "Keys typed by name, by the character they type.")

(defun portal-linux-keys--arguments (flags text)
  "wtype's arguments for the key that types TEXT with the macOS FLAGS."
  (let* ((character (and (= (length text) 1) (aref text 0)))
         (control (and character (< 0 character 27)
                       (not (assq character portal-linux-keys--named))))
         (modifiers (delq nil (mapcar (lambda (bit)
                                        (and (/= 0 (logand flags (ash 1 (car bit))))
                                             ;; Shift is in the text already.
                                             (not (and (= (car bit) 17)
                                                       (not (assq character portal-linux-keys--named))))
                                             (cdr bit)))
                                      portal-linux-keys--modifiers)))
         (key (cond ((assq character portal-linux-keys--named)
                     (list "-k" (cdr (assq character portal-linux-keys--named))))
                    ;; Control-C and its like, typed as the letter with Control.
                    (control (list (string (+ character 96))))
                    (t (list text)))))
    (when (and control (not (member "ctrl" modifiers)))
      (push "ctrl" modifiers))
    (append (mapcan (lambda (modifier) (list "-M" modifier)) modifiers)
            key
            (mapcan (lambda (modifier) (list "-m" modifier)) (reverse modifiers)))))

(defun portal-test-native-key (code flags text &optional windowless)
  "Type the key that types TEXT with the macOS FLAGS; CODE is not needed.
WINDOWLESS, a key for no window, is the injector's alone: nil then.
Return non-nil once Emacs has had a moment to read it."
  (ignore code)
  (unless windowless
    (let ((wtype (or (executable-find "wtype") (error "Typing on Linux needs wtype"))))
      (when (eql 0 (apply #'call-process wtype nil nil nil
                          (portal-linux-keys--arguments flags text)))
        (let ((deadline (+ (float-time) 0.15)))
          (while (< (float-time) deadline)
            (accept-process-output nil 0.02)))
        t))))

(defun portal-test-native-target-frame (title)
  "Keys go to the window with the desktop's keyboard, whatever TITLE says."
  (ignore title)
  t)

(defun portal-test-native-focus-target ()
  "Give the selected frame the desktop's keyboard."
  (select-frame-set-input-focus (selected-frame))
  (let ((deadline (+ (float-time) 0.2)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.02)))
  t)

(provide 'portal-linux-keys)
;;; portal-linux-keys.el ends here
