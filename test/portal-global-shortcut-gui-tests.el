;;; portal-global-shortcut-gui-tests.el --- Global shortcuts in the real command loop -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Run only in a disposable graphical Emacs with the newly built module and
;; build/test-terminal-input.dylib.  `portal-test-hotkey' sends a hot key
;; event to the production Carbon handler in this process, so these tests
;; cover the handler, the core, the pipe and the command loop, but not a
;; physical key press: test/global-shortcut-smoke.sh needs a person for that.

(require 'ert)
(require 'portal-global-shortcut)
(declare-function portal-test-hotkey "test-terminal-input" (hotkey pressed))
(declare-function portal-test-frontmost "test-terminal-input" (&optional app))
(declare-function portal--shortcuts "portal-global-shortcut" ())

(defmacro portal-global-shortcut-gui--with (&rest body)
  "Run BODY with no global shortcut set, and remove every one afterwards."
  (declare (indent 0))
  `(progn
     (skip-unless (and (eq window-system 'ns) (fboundp 'portal-test-hotkey)))
     (portal-view--load)
     (discard-input)
     (should-not portal-global-shortcut--registrations)
     (unwind-protect (progn ,@body)
       (portal-global-shortcut--remove-all))
     (should-not (portal--shortcuts))))

(defun portal-global-shortcut-gui--hotkey (name)
  "The native hot key of the global shortcut NAME, for the injector."
  (let ((id (cadr (assq name portal-global-shortcut--registrations))))
    (plist-get (cl-find id (portal--shortcuts) :key (lambda (shortcut) (plist-get shortcut :id)))
               :hotkey)))

(defun portal-global-shortcut-gui--press (&rest names)
  "Press and release the chords of NAMES, as Carbon reports them; read the records."
  (dolist (name names)
    (let ((hotkey (portal-global-shortcut-gui--hotkey name)))
      (should (portal-test-hotkey hotkey t))
      (should (portal-test-hotkey hotkey nil))))
  (portal-view--read-records))

(defun portal-global-shortcut-gui--command-loop ()
  "Let the real command loop run what is queued, as in ordinary use, then return."
  (let ((timer (run-at-time 0.3 nil #'exit-recursive-edit))
        (debug-on-error nil))
    (unwind-protect (recursive-edit) (cancel-timer timer))))

(ert-deftest portal-global-shortcut-gui-two-shortcuts-from-another-app ()
  :tags '(:gui)
  (portal-global-shortcut-gui--with
    (let ((calls nil)
          (frames (frame-list))
          (window (selected-window))
          (previous (portal-test-frontmost))
          other)
      (portal-global-shortcut-set
       'gui-plain "Control-Option-Command-F13"
       (let ((label 'plain)) (lambda () (push (list label (portal-test-frontmost)) calls))))
      (portal-global-shortcut-set
       'gui-command "Control-Option-Command-F14"
       (lambda () (interactive) (push (list 'command (portal-test-frontmost)) calls)))
      (should-not (portal-view-buffers))
      (should-not (bound-and-true-p portal-launcher--frame))
      (unwind-protect
          (progn
            ;; Another application has the keyboard, as when a person presses:
            ;; the one in front already, or Finder while Emacs is.
            (setq other (if (eql previous (emacs-pid))
                            (portal-test-frontmost "com.apple.finder")
                          previous))
            (with-timeout (3 (error "Another application did not become frontmost"))
              (while (not (eql other (portal-test-frontmost))) (sit-for 0.05)))
            (portal-global-shortcut-gui--press 'gui-command 'gui-plain)
            ;; The filter only queued the presses.
            (should-not calls)
            (should (= 2 (cl-count 'portal-global-shortcut unread-command-events :key #'car-safe)))
            (portal-global-shortcut-gui--command-loop)
            (message "Global shortcut calls: %S (other app %S, Emacs %S)" calls other (emacs-pid))
            (should (equal calls `((plain ,other) (command ,other))))
            (should (eql other (portal-test-frontmost)))
            (should (equal frames (frame-list)))
            (should (eq window (selected-window))))
        (unless (eql other previous)
          (portal-test-frontmost previous)
          (with-timeout (3 (message "Could not make %S frontmost again" previous))
            (while (not (eql previous (portal-test-frontmost))) (sit-for 0.05))))))))

(ert-deftest portal-global-shortcut-gui-errors-replacement-and-removal ()
  :tags '(:gui)
  (portal-global-shortcut-gui--with
    (let ((calls nil))
      (portal-global-shortcut-set 'gui-broken "Control-Option-Command-F13"
                                  (lambda () (push 'broken calls) (error "Broken shortcut")))
      (portal-global-shortcut-set 'gui-working "Control-Option-Command-F14"
                                  (lambda () (push 'old calls)))
      ;; The command loop reports an error as for any command, and runs the
      ;; next press.
      (portal-global-shortcut-gui--press 'gui-broken 'gui-working)
      (portal-global-shortcut-gui--command-loop)
      (should (equal calls '(old broken)))
      (setq calls nil)
      (let ((hotkey (portal-global-shortcut-gui--hotkey 'gui-working)))
        ;; A press from before the function changed is ignored, though the
        ;; native registration of the chord stays.
        (portal-global-shortcut-gui--press 'gui-working)
        (portal-global-shortcut-set 'gui-working "Control-Option-Command-F14"
                                    (lambda () (push 'new calls)))
        (should (eql hotkey (portal-global-shortcut-gui--hotkey 'gui-working)))
        (portal-global-shortcut-gui--command-loop)
        (should-not calls)
        (portal-global-shortcut-gui--press 'gui-working)
        (portal-global-shortcut-gui--command-loop)
        (should (equal calls '(new)))
        ;; A removed shortcut's hot key is no longer handled at all.
        (should (eq (portal-global-shortcut-remove 'gui-working) t))
        (should-not (portal-test-hotkey hotkey t))
        (portal-view--read-records)
        (should-not unread-command-events)
        (portal-global-shortcut-gui--press 'gui-broken)
        (portal-global-shortcut-gui--command-loop)
        (should (equal calls '(broken new)))))))

(ert-deftest portal-global-shortcut-gui-held-and-repeated-presses ()
  :tags '(:gui)
  (portal-global-shortcut-gui--with
    (let ((calls 0))
      (portal-global-shortcut-set 'gui-count "Control-Option-Command-F15"
                                  (lambda () (cl-incf calls)))
      (let ((hotkey (portal-global-shortcut-gui--hotkey 'gui-count)))
        ;; While a chord is held, the system repeats its press.
        (dotimes (_ 3) (should (portal-test-hotkey hotkey t)))
        (should (portal-test-hotkey hotkey nil))
        (portal-view--read-records)
        (should (= 1 (length unread-command-events)))
        ;; A press while the first still waits is dropped.
        (portal-global-shortcut-gui--press 'gui-count)
        (portal-global-shortcut-gui--command-loop)
        (should (= calls 1))
        (portal-global-shortcut-gui--press 'gui-count)
        (portal-global-shortcut-gui--command-loop)
        (should (= calls 2))))))

(ert-deftest portal-global-shortcut-gui-runs-during-a-prompt ()
  :tags '(:gui)
  (portal-global-shortcut-gui--with
    (let (depths)
      (portal-global-shortcut-set 'gui-exit "Control-Option-Command-F16"
                                  (lambda ()
                                    (interactive)
                                    (push (minibuffer-depth) depths)
                                    (exit-minibuffer)))
      (should (equal "" (with-timeout (5 (error "The shortcut did not run in the prompt"))
                          (minibuffer-with-setup-hook
                              (lambda ()
                                (run-at-time 0.1 nil #'portal-global-shortcut-gui--press 'gui-exit))
                            (read-string "Global shortcut test: ")))))
      (should (equal depths '(1))))))

(provide 'portal-global-shortcut-gui-tests)
;;; portal-global-shortcut-gui-tests.el ends here
