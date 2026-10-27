;;; portal-launcher-recipe-tests.el --- The launcher guide's launcher.el recipe -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Optional integration smoke test, outside CTest: Portal does not need
;; launcher.el.  Run with test/launcher-recipe.sh, which puts the package on
;; `load-path', in a disposable graphical Emacs.  The guide's recipe runs in
;; the real panel and reads native keys.  The input test mocks Spotlight,
;; `open' and the browser; the launch test uses real Spotlight and `open' to
;; activate Finder, which is already running.

(require 'portal-launcher-gui-tests)
(require 'launcher)
(require 'vertico)
(require 'orderless)
(require 'marginalia)
(declare-function portal-test-frontmost "test-terminal-input" (&optional app))

(defun portal-launcher-recipe--layout ()
  "Whether the active minibuffer is the panel's only window, its prompt on top."
  (let ((frame portal-launcher--frame)
        (mini (active-minibuffer-window)))
    (and (eq (window-frame mini) frame)
         (eq (portal-launcher--kind frame) 'minibuffer)
         (equal (window-list frame t) (list mini))
         (= (cadr (window-pixel-edges mini)) (frame-internal-border-width frame)))))

(ert-deftest portal-launcher-recipe-input-rules ()
  :tags '(:gui)
  (skip-unless (fboundp 'portal-test-hotkey))
  (portal-launcher-gui--with-panel
    (portal-launcher-gui--example "launcher-app")
    (let* ((launcher--apps '(("Calculator" . "/System/Applications/Calculator.app")
                             ("Calendar" . "/System/Applications/Calendar.app")))
           (launcher--current-entries nil)
           ;; One directory, so that a refresh is one Spotlight query.
           (launcher-app-directories '("/System/Applications"))
           (reader completing-read-function)
           (scans 0) actions layouts)
      (cl-letf (((symbol-function 'call-process)
                 (lambda (&rest arguments) (push arguments actions) 0))
                ((symbol-function 'browse-url) (lambda (url &rest _) (push url actions)))
                ((symbol-function 'process-lines)
                 (lambda (&rest _) (cl-incf scans) (mapcar #'cdr launcher--apps))))
        (cl-flet ((launch (strokes &optional prefix)
                    (let ((minibuffer-setup-hook
                           (cons (lambda () (push (portal-launcher-recipe--layout) layouts))
                                 minibuffer-setup-hook)))
                      (portal-launcher-gui--drive
                       (lambda ()
                         (let ((current-prefix-arg prefix))
                           (call-interactively 'my/app-launcher)))
                       strokes)))
                  (open (name)
                    (list "open" nil nil nil "-a" (cdr (assoc name launcher--apps)))))
          (dolist (enhanced '(nil t))
            (let ((completion-styles (if enhanced '(orderless basic) '(basic)))
                  (completion-category-defaults nil)
                  (vertico-sort-function #'identity))
              (vertico-mode (if enhanced 1 -1))
              (marginalia-mode (if enhanced 1 -1))
              (unwind-protect
                  (progn
                    (launch (append (portal-launcher-gui--text "Calculator") '((36 0 "\r"))))
                    (should (equal (pop actions) (open "Calculator")))
                    ;; In stock completion, the wrapper's Space inserts the
                    ;; space that word completion would have consumed.
                    (launch (append (portal-launcher-gui--text "!gh portal launcher") '((36 0 "\r"))))
                    (should (equal (pop actions) "https://github.com/search?q=portal%20launcher"))
                    ;; A bang without a query, an empty result and Escape
                    ;; close the panel without an action.
                    (launch (append (portal-launcher-gui--text "!g") '((36 0 "\r"))))
                    (launch (append (portal-launcher-gui--text "!gh ") '((36 0 "\r"))))
                    (launch '((53 0 "\e")))
                    (let ((launcher-bangs nil) (minibuffer-history nil))
                      (launch '((36 0 "\r")))
                      ;; With Vertico, Return accepts the highlighted app
                      ;; without typed text, the first or one chosen with
                      ;; arrows. Stock completion returns "", which cancels.
                      (when enhanced
                        (should (equal (pop actions) (open "Calculator")))
                        (launch '((125 0 "") (36 0 "\r")))
                        (should (equal (pop actions) (open "Calendar")))
                        (launch '((125 0 "") (126 0 "") (36 0 "\r")))
                        (should (equal (pop actions) (open "Calculator")))))
                    (should-not actions))
                (vertico-mode -1)
                (marginalia-mode -1))))
          ;; A prefix argument rebuilds the index before prompting.
          (should (= scans 0))
          (launch (append (portal-launcher-gui--text "Calendar") '((36 0 "\r"))) '(4))
          (should (= scans 1))
          (should (equal (pop actions) (open "Calendar")))
          ;; The recipe's global shortcut runs the same command.
          (portal-launcher-gui--drive
           (lambda () (portal-launcher-gui--press 'app-launcher))
           (append (portal-launcher-gui--text "Calculator") '((36 0 "\r")))
           nil t)
          (should (equal (pop actions) (open "Calculator")))
          (should-not actions)))
      ;; Each prompt was the panel's only window, starting at its top:
      ;; six stock, eight with Vertico and one refreshing.
      (should (= (length layouts) 15))
      (should (cl-every #'identity layouts))
      (should (eq reader completing-read-function))
      (should (eq ordinary (selected-window)))
      (should-not launcher--current-entries))))

(defun portal-launcher-recipe--activate (app)
  "Activate APP, a PID or bundle ID, wait until it is in front and return its PID."
  (let ((pid (portal-test-frontmost app)))
    (with-timeout (3 (error "%S did not become frontmost" app))
      (while (not (eql pid (portal-test-frontmost)))
        (accept-process-output nil 0.05)))
    (portal-launcher-gui--settle-focus)
    pid))

(ert-deftest portal-launcher-recipe-real-launch-and-focus ()
  :tags '(:gui)
  ;; Real Spotlight and `open', from another app in front: Escape leaves it
  ;; in front, and launching Finder, already running, gives Finder focus as
  ;; the panel hides.
  (skip-unless (fboundp 'portal-test-frontmost))
  (portal-launcher-gui--with-panel
    (portal-launcher-gui--example "launcher-app")
    (let* ((launcher--apps nil)
           (launcher--current-entries nil)
           (finder (portal-launcher-recipe--activate "com.apple.finder"))
           ;; Another app than Finder, which is in front.
           (other (portal-launcher-recipe--activate (portal-test-frontmost -1))))
      (should-not (eql finder other))
      (portal-launcher-gui--drive 'my/app-launcher '((53 0 "\e")))
      (portal-launcher-gui--settle-focus)
      (should (eql other (portal-test-frontmost)))
      (should (assoc "Finder" launcher--apps))
      (portal-launcher-gui--drive
       'my/app-launcher (append (portal-launcher-gui--text "Finder") '((36 0 "\r"))))
      (with-timeout (3 (error "Finder did not become frontmost"))
        (while (not (eql finder (portal-test-frontmost)))
          (accept-process-output nil 0.05)))
      (message "Launcher recipe: Finder %S in front after %S; %d apps indexed"
               finder (cdr (assq 'comm (process-attributes other))) (length launcher--apps))
      (should (eq ordinary (selected-window)))
      (portal-launcher-gui--settle-focus))))

(provide 'portal-launcher-recipe-tests)
;;; portal-launcher-recipe-tests.el ends here
