;;; portal-terminal-embark-tests.el --- The Embark adapter -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'portal-completion-testing
         (expand-file-name "portal-completion-testing"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'embark)
(require 'ibuffer)
(require 'portal-terminal-embark)
(require 'portal-terminal-sidebar)

;; `portal-completion-testing' types into a real minibuffer with Consult,
;; Vertico and Orderless on; <f10> acts there with Embark.  Actions run
;; without leaving the minibuffer, so one sequence of keys can act on the
;; same candidate several times; C-g leaves it at the end, keeping windows.
;; One test uses Embark's default, which leaves the minibuffer first.

(defmacro portal-embark-test--environment (&rest body)
  "Run BODY in `portal-completion-test--environment' with the Embark adapter on."
  (declare (indent 0))
  `(portal-completion-test--environment
     (let ((embark-quit-after-action nil)
           (read-minibuffer-restore-windows nil)
           (enable-recursive-minibuffers t)
           (embark-indicators nil)
           (global (current-global-map))
           (map (make-sparse-keymap)))
       (keymap-set map "<f10>" #'embark-act)
       (set-keymap-parent map global)
       (use-global-map map)
       (portal-terminal-embark-mode)
       (unwind-protect (progn ,@body)
         (portal-terminal-embark-mode -1)
         (use-global-map global)))
     (should-not (memq #'portal-terminal-embark-target embark-target-finders))
     (should-not (assq 'portal-terminal embark-keymap-alist))))

(defun portal-embark-test--target ()
  "Return the type and text of Embark's first target here."
  (let ((target (car (embark--targets))))
    (list (plist-get target :type) (substring-no-properties (plist-get target :target)))))

(ert-deftest portal-terminal-embark-targets-only-terminals ()
  (portal-embark-test--environment
    (let ((server (portal-completion-test--open "one/app" :title "npm run dev")))
      (with-current-buffer server (portal-terminal-rename "server"))
      (switch-to-buffer "consult-file.el")
      ;; In Consult's buffer list, a terminal is a terminal target and any other
      ;; buffer stays a buffer target, with Embark's own map.
      (should (equal (portal-completion-test--type
                      #'consult-buffer "server <f11> DEL DEL DEL DEL DEL DEL consult-file <f11> C-g"
                      #'portal-embark-test--target)
                     '((portal-terminal "server") (buffer "consult-file.el"))))
      ;; So in the picker, where candidates show the context.
      (should (equal (portal-completion-test--type #'portal-terminal-choose "npm <f11> C-g"
                                                   #'portal-embark-test--target)
                     '((portal-terminal "server"))))
      ;; And without Consult, where they have Portal's own category.
      (portal-terminal-consult-mode -1)
      (should (equal (portal-completion-test--type
                      #'portal-terminal-choose "npm <f11> DEL DEL DEL New SPC named <f11> C-g"
                      #'portal-embark-test--target)
                     `((portal-terminal "server")
                       (general ,(format "New named terminal in %s…" "app")))))
      ;; The terminal map adds to buffer actions; the buffer map is unchanged.
      (let ((terminal (embark--action-keymap 'portal-terminal nil))
            (buffer (embark--action-keymap 'buffer nil)))
        (dolist (binding '(("RET" . portal-terminal-embark-select)
                           ("d" . portal-terminal-embark-dired)
                           ("c" . portal-terminal-embark-new)
                           ("W" . portal-terminal-embark-copy-directory)
                           ("p" . portal-terminal-embark-set-project)
                           ("k" . portal-terminal-embark-kill)
                           ("r" . portal-terminal-embark-rename)
                           ("o" . switch-to-buffer-other-window)
                           ("z" . embark-bury-buffer)))
          (should (eq (keymap-lookup terminal (car binding)) (cdr binding))))
        (dolist (key '("d" "c" "W" "p"))
          (should-not (string-prefix-p "portal-" (format "%s" (keymap-lookup buffer key)))))
        (should (eq (keymap-lookup buffer "k") #'kill-buffer)))
      (should (eq (embark--default-action 'portal-terminal) #'portal-terminal-embark-select))
      ;; In Ibuffer, a terminal's line is a terminal target first.
      (ibuffer nil "*portal-embark-ibuffer*")
      (goto-char (point-min))
      (search-forward "server")
      (should (equal (portal-embark-test--target) '(portal-terminal "server")))
      (should (memq 'buffer (mapcar (lambda (target) (plist-get target :type)) (embark--targets))))
      (goto-char (point-min))
      (search-forward "consult-file.el")
      (should-not (memq 'portal-terminal
                        (mapcar (lambda (target) (plist-get target :type)) (embark--targets)))))))

(ert-deftest portal-terminal-embark-actions-follow-the-session ()
  (portal-embark-test--environment
    (let* ((portal-terminal-confirm-kill t)
           (two (portal-completion-test--path "two/app/"))
           (api (portal-completion-test--path "one/app/api/"))
           (server (portal-completion-test--open "one/app" :title "npm run dev" :pwd api))
           (other (portal-completion-test--open "one/app" :title "bun test"))
           (window (selected-window)))
      (switch-to-buffer "consult-file.el")
      ;; Rename, then act again on the same candidate: it is the same session.
      (portal-completion-test--type
       #'portal-terminal-choose
       (concat "npm <f10> r C-a C-k dev-server RET <f10> W "
               "<f10> p C-a C-k " two " RET C-g"))
      (should (equal (buffer-name server) "dev-server"))
      (should (equal (current-kill 0) api))
      (should (equal (plist-get (portal-terminal-metadata server) :project) two))
      (should (equal (plist-get (portal-terminal-metadata other) :project)
                     (portal-completion-test--path "one/app/")))
      (should (equal (buffer-name) "consult-file.el"))
      ;; Dired and another shell open in its directory, in the original
      ;; window, after the minibuffer closes, as Embark acts by default.
      (let ((embark-quit-after-action t))
        (portal-completion-test--type #'portal-terminal-choose "npm <f10> d")
        (accept-process-output nil 0.05))
      (should (eq (window-buffer window) (dired-noselect api)))
      (should (eq (selected-window) window))
      (switch-to-buffer "consult-file.el")
      (portal-completion-test--type #'portal-terminal-choose "npm <f10> c C-g")
      (let ((new (window-buffer window)))
        (should-not (memq new (list server other)))
        (should (equal (plist-get (portal-terminal-metadata new) :directory) api))
        (should (equal (plist-get (portal-terminal-metadata new) :project)
                       (portal-completion-test--path "one/app/")))
        ;; Ending one asks once each time, and ends only that session.
        (switch-to-buffer "consult-file.el")
        (let ((answers (list nil t)) (asked nil))
          ;; In batch, `y-or-n-p' reads a line, so answer it here.
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (prompt) (push prompt asked) (pop answers))))
            (portal-completion-test--type #'portal-terminal-choose "npm <f10> k <f10> k C-g"))
          (should (equal asked (make-list 2 "Kill terminal dev-server and its running shell? "))))
        (should-not (buffer-live-p server))
        (should (equal (portal-terminal-buffers) (list other new))))
      ;; RET selects it where terminals of its kind show.
      (portal-completion-test--type #'portal-terminal-choose "bun <f10> RET C-g")
      (should (eq (window-buffer window) other)))))

(ert-deftest portal-terminal-embark-exports-terminals-to-ibuffer ()
  (portal-embark-test--environment
    (let* ((server (portal-completion-test--open "one/app" :title "npm run dev"))
           (other (portal-completion-test--open "two/app")))
      (switch-to-buffer "consult-file.el")
      ;; Narrowed to terminals, candidates export as buffers.
      (portal-completion-test--type #'consult-buffer "t SPC <f10> E")
      (accept-process-output nil 0.05)
      (with-current-buffer (window-buffer)
        (should (derived-mode-p 'ibuffer-mode))
        (let (listed)
          (ibuffer-map-lines-nomodify (lambda (buffer _mark) (push buffer listed)))
          (should (equal (sort listed :key #'buffer-name)
                         (sort (list server other) :key #'buffer-name))))
        ;; Ibuffer kills a terminal the way every other tool does.
        (goto-char (point-min))
        (search-forward "two/app")
        (call-interactively #'ibuffer-mark-for-delete)
        (let ((portal-terminal-confirm-kill t) (asked nil) (name (buffer-name other)))
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt asked) t)))
            (ibuffer-do-kill-on-deletion-marks))
          ;; Ibuffer asks about its marks, and Portal about the running shell.
          (should (equal (seq-filter (lambda (prompt) (string-prefix-p "Kill terminal" prompt)) asked)
                         (list (format "Kill terminal %s and its running shell? " name)))))
        (should-not (buffer-live-p other))
        (should (buffer-live-p server))))))

(ert-deftest portal-terminal-embark-targets-the-sidebar-row-at-point ()
  (portal-embark-test--environment
    (let ((server (portal-completion-test--open "one/app"))
          (display-buffer-alist nil))
      (with-current-buffer server (portal-terminal-rename "server"))
      (portal-completion-test--open "two/app")
      (portal-terminal-sidebar-select)
      ;; The row's terminal, its bounds the row's line, on any line of it.
      (goto-char (point-min))
      (forward-char 4)
      (should (equal (portal-embark-test--target) '(portal-terminal "server")))
      (should (equal (plist-get (car (embark--targets)) :bounds)
                     (cons (point-min) (line-end-position))))
      (forward-line 1)
      (should (equal (car (portal-embark-test--target)) 'portal-terminal))
      (should-not (equal (portal-embark-test--target) '(portal-terminal "server")))
      (portal-terminal-sidebar))))

;;; portal-terminal-embark-tests.el ends here
