;;; portal-launcher-buffer-prototype.el --- Throwaway buffer picker experiment -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; PROTOTYPE: Can one normal Portal frame look like the minibuffer picker,
;; then become a persistent result buffer? No native or production API changes.
;; Requires Vertico (including vertico-buffer). Run
;; M-x portal-launcher-buffer-prototype. Type c SPC for a simulated chat view.
;; All effects are scoped to the presentation; no shortcut is installed.

(require 'portal-launcher)
(require 'vertico-buffer)

(declare-function portal--launcher-fit "portal-launcher" (session height))

(defvar portal-launcher-buffer-prototype-count 5
  "Maximum candidate rows for this experiment.")

(defconst portal-launcher-buffer-prototype-candidates
  '("Calculator" "Calendar" "Camera" "Dictionary" "Mail" "Maps" "Notes"
    "Safari" "Terminal")
  "Fake applications: selecting one returns its name, never launches it.")

(defvar portal-launcher-buffer-prototype--route nil)
(defvar portal-launcher-buffer-prototype--height nil)

(defun portal-launcher-buffer-prototype--fit (_windows)
  "Fit the normal frame to its picker, without presenting it again.
Reuse Portal's native layout-only primitive. The ordinary frame's echo
area remains one blank row; it is included in the requested height."
  (when (and (minibufferp) portal-launcher--session
             (eq (window-frame (active-minibuffer-window)) portal-launcher--frame))
    (let* ((frame portal-launcher--frame)
           (root (frame-root-window frame))
           (height (max 100
                        (+ (cdr (window-text-pixel-size
                                 root nil nil nil (display-pixel-height frame)))
                           (- (frame-pixel-height frame)
                              (window-body-height root t))))))
      (unless (eql height portal-launcher-buffer-prototype--height)
        (setq portal-launcher-buffer-prototype--height height)
        (portal--launcher-fit
         (portal-launcher--session-native-id portal-launcher--session) height)))))

(defun portal-launcher-buffer-prototype--route ()
  "Finish the picker on c SPC; do not leave a hidden minibuffer reading."
  (when (string-prefix-p "c " (minibuffer-contents-no-properties))
    (setq portal-launcher-buffer-prototype--route 'chat)
    (exit-minibuffer)))

(defun portal-launcher-buffer-prototype--setup ()
  "Configure only this minibuffer after Vertico's buffer setup."
  (setq-local vertico-count portal-launcher-buffer-prototype-count
              truncate-lines nil)
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (current-local-map))
    (define-key map " " #'self-insert-command)
    (use-local-map map))
  (add-hook 'post-command-hook #'portal-launcher-buffer-prototype--route 80 t)
  (add-hook 'pre-redisplay-functions #'portal-launcher-buffer-prototype--fit 90 t))

(defun portal-launcher-buffer-prototype-read (prompt collection)
  "Read PROMPT and COLLECTION in the existing buffer panel's root window.
Return (chat . TEXT) on c SPC, or (selection . TEXT) on ordinary completion.
This experimental adapter uses Vertico internals and must not be treated
as a stable interface. A caller must already own a buffer presentation."
  (unless (and portal-launcher--session (portal-launcher--live-p 'buffer))
    (user-error "Prototype reader needs an active Portal buffer presentation"))
  (let ((vertico-buffer-mode t)
        (vertico-buffer-hide-prompt t)
        (vertico-buffer-display-action '(display-buffer-same-window))
        ;; Portal's default overriding action would split the panel instead.
        (display-buffer-overriding-action '((display-buffer-same-window)))
        (portal-launcher-buffer-prototype--route nil)
        (portal-launcher-buffer-prototype--height nil)
        (redisplay-function (symbol-function 'vertico-buffer--redisplay)))
    ;; Stock vertico-buffer derives candidate count from the available height.
    ;; A content-fitted panel needs the inverse: a stable row cap determines
    ;; its height, otherwise shrinking the panel also prevents later growth.
    (cl-letf (((symbol-function 'vertico-buffer--redisplay)
               (lambda (windows)
                 ;; The real mini window is already one row. Stock Vertico
                 ;; attempts to shrink it on every redisplay; in a compact
                 ;; frame whose root is below window-min-height, Emacs's
                 ;; resize clamping can request a negative minibuffer height.
                 ;; Keep that row and only scroll its duplicate prompt away.
                 (let ((vertico-buffer-hide-prompt nil))
                   (funcall redisplay-function windows))
                 (set-window-vscroll (active-minibuffer-window) 3)
                 (setq-local vertico-count portal-launcher-buffer-prototype-count
                             resize-mini-windows nil
                             truncate-lines nil))))
      (let ((input (minibuffer-with-setup-hook
                       (:append #'portal-launcher-buffer-prototype--setup)
                     (completing-read prompt collection nil nil))))
        (cons (or portal-launcher-buffer-prototype--route 'selection) input)))))

(defun portal-launcher-buffer-prototype--chat ()
  "Show an editable local chat stand-in, not a real LLM request."
  (let ((buffer (get-buffer-create "*Portal prototype chat*")))
    (switch-to-buffer buffer)
    (text-mode)
    (setq-local header-line-format nil mode-line-format nil)
    (erase-buffer)
    (insert "Chat · buffer-mode proof of concept\n\n"
            "You\nCan this picker become a chat in the same panel?\n\n"
            "Assistant (simulated — no API request)\n")
    (visual-line-mode 1)
    ;; Layout only: keep the native session, focus, and top edge unchanged.
    (portal--launcher-fit
     (portal-launcher--session-native-id portal-launcher--session) 420)
    (let* ((chunks '("Yes. This is an ordinary editable Emacs buffer. "
                     "The frame and native panel are unchanged.\n\n"
                     "A real gptel buffer can occupy this window instead. "
                     "This response is a local, timed demonstration."))
           (position (copy-marker (point)))
           (session portal-launcher--session)
           timer)
      (insert "\n\nYou\n")
      (setq timer
            (run-with-timer
             0.1 0.1
             (lambda ()
               (if (and chunks (buffer-live-p buffer)
                        (eq session portal-launcher--session))
                   (with-current-buffer buffer
                     (save-excursion
                       (goto-char position)
                       (insert (pop chunks))
                       (set-marker position (point))))
                 (cancel-timer timer)))))
      timer)))

;;;###autoload
(defun portal-launcher-buffer-prototype ()
  "Demo a compact full-buffer picker and c SPC transition in one panel.
Fake application choices are returned, never executed. Existing Portal
minibuffer-only and buffer presentations are not modified."
  (interactive)
  (let ((was-vertico vertico-mode)
        (portal-launcher-size '(720 100))
        (vertico-count portal-launcher-buffer-prototype-count)
        (vertico-sort-function nil)
        timer)
    (unwind-protect
        (progn
          (vertico-mode 1)
          ;; Keep only the result view open: don't use :keep-open t for app
          ;; choices, which must return and dismiss normally. A recursive edit
          ;; stays inside Portal's existing session catch and display rules.
          (portal-launcher-present
           (lambda ()
             (pcase (portal-launcher-buffer-prototype-read
                     "Launch: " portal-launcher-buffer-prototype-candidates)
               (`(chat . ,_)
                (setq timer (portal-launcher-buffer-prototype--chat))
                (recursive-edit))
               (`(selection . ,choice) choice)))
           :kind 'buffer :mode-line nil))
      (when timer (cancel-timer timer))
      (unless was-vertico (vertico-mode -1)))))

(provide 'portal-launcher-buffer-prototype)
;;; portal-launcher-buffer-prototype.el ends here
