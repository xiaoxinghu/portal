;;; launcher-workflows.el --- Isolated experiment workloads -*- lexical-binding: t; -*-
;; These commands use scratch buffers and build/ files only. No user init is loaded.
(setq native-comp-jit-compilation nil)
(require 'cl-lib)
(require 'org-capture)

(defvar portal-prototype-results nil)
(defun portal-prototype-check (label condition)
  (push (list label (if condition 'pass 'FAIL)) portal-prototype-results)
  (unless condition (error "Launcher experiment failed: %s" label)))

(defun portal-prototype-load-packages ()
  (let ((root (or (getenv "PORTAL_PROTOTYPE_ELPA")
                  (expand-file-name "elpa" user-emacs-directory))))
    (dolist (directory (directory-files root t "^[^.]"))
      (when (string-match-p "/\\(vertico\\|consult\\|marginalia\\|corfu\\|posframe\\|compat\\)-[^/]+$" directory)
        (add-to-list 'load-path directory))))
  (require 'vertico)
  (require 'consult)
  (require 'marginalia)
  (require 'corfu)
  (require 'posframe)
  (vertico-mode 1)
  (marginalia-mode 1))

(defun portal-prototype-completion ()
  (interactive)
  (portal-prototype-show)
  (portal-prototype-record (list 'completion
    (completing-read "Launcher action: " '("Open project" "Capture thought" "Hello world") nil t))))

(defun portal-prototype-capture ()
  (interactive)
  (portal-prototype-show)
  (setq org-capture-templates
        `(("t" "Prototype only" entry
           (file ,(expand-file-name "build/launcher-capture.org" portal-prototype-directory))
           "* %?" :empty-lines 1)))
  ;; Org temporarily asks for another window while expanding its template.
  ;; Keep that operation inside the launcher instead of selecting the controller.
  (let ((display-buffer-overriding-action
         '((display-buffer-same-window) (inhibit-same-window . nil))))
    (org-capture nil "t")))

(defun portal-prototype-corfu ()
  (interactive)
  (portal-prototype-show)
  (switch-to-buffer (get-buffer-create "*Launcher editing experiment*"))
  (emacs-lisp-mode)
  (erase-buffer)
  (insert "(mess")
  (corfu-mode 1)
  (completion-at-point))

(defun portal-prototype-reset-buffer ()
  (interactive)
  (portal-prototype-show)
  (set-window-buffer (frame-root-window portal-prototype-frame) (portal-prototype-buffer)))

(defun portal-prototype-workflow-event (event)
  (interactive "e")
  (call-interactively (cadr event)))
(define-key global-map [portal-prototype-workflow] #'portal-prototype-workflow-event)
(define-key global-map (kbd "<f8>") #'portal-prototype-reset-buffer)
(define-key portal-prototype-mode-map (kbd "c") #'portal-prototype-completion)
(define-key portal-prototype-mode-map (kbd "o") #'portal-prototype-capture)
(define-key portal-prototype-mode-map (kbd "e") #'portal-prototype-corfu)

(defun portal-prototype-run-checks ()
  "Exercise actual hosted frames, without requiring another GUI Emacs build."
  (interactive)
  (setq portal-prototype-results nil)
  (portal-prototype-show)
  (dolist (appearance '(dark light nil))
    (set-frame-parameter portal-prototype-frame 'ns-appearance appearance)
    (let ((actual (gethash "appearance" (json-parse-string (portal-prototype--state)))))
      (portal-prototype-check (list 'appearance appearance)
        (pcase appearance
          ('dark (string-match-p "Dark" actual))
          ('light (and (string-match-p "Aqua" actual) (not (string-match-p "Dark" actual))))
          (_ (equal actual "system"))))))
  (dolist (font '("Menlo 13" "Menlo 18" "Menlo 15"))
    (set-frame-font font nil (list portal-prototype-frame))
    (portal-prototype-resize 713 407)
    (portal-prototype-check (list 'font font)
      (equal (list (frame-pixel-width portal-prototype-frame) (frame-pixel-height portal-prototype-frame)) '(713 407))))
  (dolist (parameter '((undecorated . nil) (fullscreen . fullboth) (parent-frame . controller) (tool-bar-lines . 1)))
    (portal-prototype-check (list 'guard (car parameter))
      (condition-case nil
          (progn (modify-frame-parameters portal-prototype-frame (list parameter)) nil)
        (user-error t))))
  (let ((portal-prototype-write-log nil))
    (dotimes (_ 100)
      (portal-prototype-show)
      (portal-prototype-hide)))
  (portal-prototype-check '100-show-hide-cycles
    (and (frame-live-p portal-prototype-frame)
         (eq (gethash "visible" (json-parse-string (portal-prototype--state))) :false)))
  (dotimes (_ 20)
    (delete-frame portal-prototype-frame)
    (portal-prototype-check 'detached-after-delete
      (eq (gethash "visible" (json-parse-string (portal-prototype--state))) :false))
    (portal-prototype-show)
    (portal-prototype-check 'reattached-after-delete
      (eq (window-buffer (frame-root-window portal-prototype-frame)) (get-buffer "*Portal launcher prototype*"))))
  (setq portal-prototype-size '(720 420))
  (portal-prototype-show)
  (let ((count-before (length (frame-list))))
    (with-selected-frame portal-prototype-frame
      (posframe-show " *Launcher child*" :string "A real Emacs child frame\ninside the launcher"
                     :position (point) :width 35 :height 3 :accept-focus nil
                     :background-color "#304050"))
    (portal-prototype-check 'child-frame-created (= (length (frame-list)) (1+ count-before)))
    (posframe-delete " *Launcher child*")
    (portal-prototype-check 'child-frame-deleted (= (length (frame-list)) count-before)))
  (with-temp-file (expand-file-name "build/launcher-workflow-results.el" portal-prototype-directory)
    (pp (reverse portal-prototype-results) (current-buffer)))
  (message "Launcher checks passed: %d" (length portal-prototype-results)))

(defun portal-prototype-input-checks ()
  "Exercise nested minibuffers and Vertico through the Emacs command loop."
  (interactive)
  (portal-prototype-show)
  (portal-prototype-check 'vertico-selection
    (equal (minibuffer-with-setup-hook
               (lambda ()
                 (portal-prototype-check 'completion-in-launcher
                   (eq (window-frame (active-minibuffer-window)) portal-prototype-frame))
                 (insert "Hello")
                 (setq unread-command-events (list 13)))
             (completing-read "Action: " '("Hello world" "Capture thought") nil t))
           "Hello world"))
  (let ((enable-recursive-minibuffers t))
    (portal-prototype-check 'nested-minibuffer-return
      (equal (minibuffer-with-setup-hook
                 (lambda ()
                   (when (= (minibuffer-depth) 1)
                     (portal-prototype-check 'nested-answer
                       (equal (minibuffer-with-setup-hook
                                  (lambda ()
                                    (portal-prototype-check 'nested-in-launcher
                                      (eq (window-frame (active-minibuffer-window)) portal-prototype-frame))
                                    (insert "inner")
                                    (setq unread-command-events (list 13)))
                                (read-string "Inner: ")) "inner"))
                     (insert "outer")
                     (setq unread-command-events (list 13))))
               (read-string "Outer: ")) "outer")))
  (portal-prototype-check 'no-leaked-minibuffer (= (minibuffer-depth) 0))
  (let ((started (float-time)) fired)
    (run-at-time 0.05 nil (lambda () (setq fired (float-time))))
    ;; Intentionally keep Emacs's command loop busy; GUI-module ownership does
    ;; not provide an independent Lisp runtime or a separate AppKit event loop.
    (while (< (- (float-time) started) 0.5))
    (sit-for 0.1)
    (portal-prototype-check 'busy-emacs-delays-events
      (and fired (>= (- fired started) 0.5))))
  (with-temp-file (expand-file-name "build/launcher-workflow-results.el" portal-prototype-directory)
    (pp (reverse portal-prototype-results) (current-buffer)))
  (message "Input checks passed"))

(defun portal-prototype-child-lifecycle-check ()
  (interactive)
  (portal-prototype-show)
  (let ((before (length (frame-list))))
    (with-selected-frame portal-prototype-frame
      (posframe-show " *Launcher child deletion*" :string "Delete my parent safely"
                     :position (point) :width 30 :height 2 :accept-focus nil))
    (delete-frame portal-prototype-frame)
    (portal-prototype-check 'delete-parent-with-live-child (= (length (frame-list)) (1- before)))
    (portal-prototype-show)
    (portal-prototype-check 'recreate-after-child-deletion (= (length (frame-list)) before)))
  (with-temp-file (expand-file-name "build/launcher-workflow-results.el" portal-prototype-directory)
    (pp (reverse portal-prototype-results) (current-buffer))))

(portal-prototype-load-packages)
(provide 'launcher-workflows)
