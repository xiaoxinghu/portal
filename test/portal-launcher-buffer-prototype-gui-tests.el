;;; portal-launcher-buffer-prototype-gui-tests.el --- Prototype evidence -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Real event-loop input; run only in the VM with the native test injector.
(require 'portal-launcher-gui-tests)
(require 'portal-launcher-buffer-prototype)

(declare-function portal--launcher-inspect "portal-launcher" ())

(defun portal-launcher-buffer-prototype-test--snapshot (name)
  "Capture NAME and return observable panel layout."
  (portal-launcher-gui--settle)
  (portal-launcher-gui--capture name)
  (let* ((frame portal-launcher--frame)
         (root (frame-root-window frame))
         (native (portal--launcher-inspect)))
    (list :frame frame :session (plist-get native :session)
          :kind (portal-launcher--kind frame)
          :size (list (frame-pixel-width frame) (frame-pixel-height frame))
          :actual (plist-get native :actual)
          :mode-line (window-mode-line-height root)
          :clipped (- (cdr (window-text-pixel-size root nil nil nil nil t))
                      (window-body-height root t))
          :candidate-rows (and (active-minibuffer-window)
                               (1- (cl-count ?\n (overlay-get vertico--candidates-ov 'before-string))))
          :buffer (window-buffer root)
          :input (and (active-minibuffer-window) (minibuffer-contents-no-properties))
          :root-is-input (and (active-minibuffer-window)
                              (eq (window-buffer root)
                                  (window-buffer (active-minibuffer-window))))
          :key (plist-get native :key))))

(ert-deftest portal-launcher-buffer-prototype-gui-baseline ()
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-size nil)
          (portal-launcher-font "Menlo 18")
          (vertico-count 5) (vertico-sort-function nil)
          (completion-styles '(basic))
          (minibuffer-history nil)
          layouts)
      (vertico-mode 1)
      (unwind-protect
          (should
           (equal "Calendar"
                  (portal-launcher-gui--present
                   (lambda () (completing-read "Launch: " portal-launcher-buffer-prototype-candidates))
                   (append '((30 262144 "\C-]"))
                           (portal-launcher-gui--text "Cal")
                           '((30 262144 "\C-]") (125 0 "\uf701") (36 0 "\r")))
                   (lambda ()
                     (push (portal-launcher-buffer-prototype-test--snapshot
                            (if layouts "02-minibuffer-filtered" "01-minibuffer-picker")) layouts))
                   '(:kind minibuffer))))
        (vertico-mode -1))
      (message "Prototype baseline: %S" (reverse layouts))
      (should (> (cadr (plist-get (cadr layouts) :size))
                 (cadr (plist-get (car layouts) :size)))))))

(ert-deftest portal-launcher-buffer-prototype-gui-picker ()
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-font "Menlo 18")
          (completion-styles '(basic))
          (minibuffer-history nil)
          (old-redisplay (symbol-function 'vertico-buffer--redisplay))
          layouts)
      (should
       (equal "Calendar"
              (portal-launcher-gui--drive
               #'portal-launcher-buffer-prototype
               (append '((30 262144 "\C-]"))
                       (portal-launcher-gui--text "Cal")
                       '((30 262144 "\C-]") (125 0 "\uf701") (36 0 "\r")))
               (lambda ()
                 (push (portal-launcher-buffer-prototype-test--snapshot
                        (if layouts "04-buffer-filtered" "03-buffer-picker")) layouts)))))
      (should (eq old-redisplay (symbol-function 'vertico-buffer--redisplay)))
      (should-not vertico-mode)
      (dolist (layout layouts)
        (should (eq (plist-get layout :kind) 'buffer))
        (should (plist-get layout :root-is-input))
        (should (plist-get layout :key))
        (should (<= (plist-get layout :clipped) 0))
        (should (zerop (plist-get layout :mode-line))))
      (should (= 5 (plist-get (cadr layouts) :candidate-rows)))
      (should (= 2 (plist-get (car layouts) :candidate-rows)))
      (should (> (cadr (plist-get (cadr layouts) :size))
                 (cadr (plist-get (car layouts) :size))))
      (let ((first (plist-get (cadr layouts) :actual))
            (second (plist-get (car layouts) :actual)))
        (should (= (car first) (car second)))
        (should (= (+ (nth 1 first) (nth 3 first))
                   (+ (nth 1 second) (nth 3 second)))))
      (message "Prototype full-buffer: %S" (reverse layouts)))))

(ert-deftest portal-launcher-buffer-prototype-gui-shrink-regrow-and-no-match ()
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-font "Menlo 18")
          (completion-styles '(basic))
          (minibuffer-history nil)
          layouts)
      (should
       (equal "zzzz"
              (portal-launcher-gui--drive
               #'portal-launcher-buffer-prototype
               (append '((30 262144 "\C-]"))
                       (portal-launcher-gui--text "Cal")
                       '((30 262144 "\C-]") (51 0 "\177") (51 0 "\177") (51 0 "\177")
                         (30 262144 "\C-]"))
                       (portal-launcher-gui--text "zzzz")
                       '((30 262144 "\C-]") (36 0 "\r")))
               (lambda ()
                 (push (portal-launcher-buffer-prototype-test--snapshot
                        (format "buffer-sizing-%d" (length layouts))) layouts)))))
      (setq layouts (nreverse layouts))
      (should (equal (plist-get (nth 0 layouts) :size) (plist-get (nth 2 layouts) :size)))
      (should (> (cadr (plist-get (nth 0 layouts) :size))
                 (cadr (plist-get (nth 1 layouts) :size))))
      (should (equal "zzzz" (plist-get (nth 3 layouts) :input)))
      (message "Prototype shrink/regrow: %S" layouts))))

(ert-deftest portal-launcher-buffer-prototype-gui-transition ()
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-font "Menlo 18")
          (completion-styles '(basic))
          (minibuffer-history nil)
          layouts)
      (unwind-protect
          (progn
            (should-not
             (portal-launcher-gui--drive
              #'portal-launcher-buffer-prototype
              (append '((30 262144 "\C-]"))
                      (portal-launcher-gui--text "c ")
                      (portal-launcher-gui--text "hello")
                      '((30 262144 "\C-]") (53 0 "\e")))
              (lambda ()
                ;; Show the start of the transcript for the evidence image.
                ;; Typing was delivered normally at the editable prompt below.
                (when layouts (goto-char (point-min)))
                (push (portal-launcher-buffer-prototype-test--snapshot
                       (if layouts "05-buffer-chat" "buffer-before-chat")) layouts))))
            (should (= 2 (length layouts)))
            (should (eq (plist-get (car layouts) :frame) (plist-get (cadr layouts) :frame)))
            (should (eql (plist-get (car layouts) :session) (plist-get (cadr layouts) :session)))
            (should-not (plist-get (car layouts) :input))
            (should (equal '(720 420) (plist-get (car layouts) :size)))
            (let ((text (with-current-buffer "*Portal prototype chat*" (buffer-string))))
              (should (string-match-p "ordinary editable Emacs buffer" text))
              (should (string-match-p "hello" text)))
            (message "Prototype transition: %S" (reverse layouts)))
        (when (get-buffer "*Portal prototype chat*") (kill-buffer "*Portal prototype chat*"))))))

(ert-deftest portal-launcher-buffer-prototype-gui-cancel-and-reenter ()
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-font "Menlo 18")
          (old-buffer-mode vertico-buffer-mode))
      (should-not (portal-launcher-gui--drive #'portal-launcher-buffer-prototype '((53 0 "\e"))))
      (should-not vertico-mode)
      (should (eq old-buffer-mode vertico-buffer-mode))
      (should (equal "Calculator"
                     (portal-launcher-gui--drive #'portal-launcher-buffer-prototype '((36 0 "\r")))))
      (portal-launcher-gui--check-unwound))))

(provide 'portal-launcher-buffer-prototype-gui-tests)
