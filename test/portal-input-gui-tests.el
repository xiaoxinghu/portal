;;; portal-input-gui-tests.el --- Real WebKit input ownership -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'portal-excalidraw-gui-tests)
(require 'portal-integration-tests)

(declare-function portal-test-responder "test-terminal-input" ())

(defconst portal-input-gui--control (ash 1 18))
(defconst portal-input-gui--command (ash 1 20))

(defmacro portal-input-gui--page (&rest body)
  "Run BODY with a page that has the keyboard in a text field.
The page records every key press, and uses Control-K itself.  Its field
has no spell checking: macOS's correction panel would hold the main thread
in a nested event loop until a key arrives, and these tests' next key comes
from that thread."
  (declare (indent 0))
  `(portal-test--with-web
     (unwind-protect
         (progn
           (select-frame-set-input-focus (selected-frame))
           (portal-open-url "data:text/html,<title>Input ready</title><input autofocus spellcheck=false><script>window.keys=[];window.ups=0;document.addEventListener('keydown',e=>{keys.push([e.key,e.ctrlKey,e.isTrusted]);if(e.ctrlKey&&e.key==='k')e.preventDefault()});document.addEventListener('keyup',e=>window.ups=(window.ups||0)+1)</script>")
           (portal-test--wait-for-page "Input ready")
           (use-local-map (copy-keymap portal-web-mode-map))
           (portal-integration-test--focus-web (selected-window) (portal-view-target))
           ,@body)
       (setq unread-command-events nil))))

(defun portal-input-gui--dispatch ()
  "Read the handoff of a chord the page did not use, and run its command."
  (let ((event (aref (with-timeout (5 (ert-fail "No chord reached Emacs"))
                      (read-key-sequence-vector nil))
                     0)))
    (ert-info ((format "Received: %S" event))
      (should (eq (car-safe event) 'portal-input-key)))
    (with-timeout (5 (ert-fail "The chord's command stalled"))
      (portal-input--dispatch event))))

(defun portal-input-gui--settled (count)
  "Wait until the page has seen COUNT key presses, and let late records in."
  (portal-terminal-test--wait
   (lambda () (eql (portal-excalidraw-gui--js "return keys.length") count)))
  (accept-process-output nil 0.2))

(defvar portal-input-gui--ran nil)
(defun portal-input-gui--mark () (interactive) (setq portal-input-gui--ran t))

(ert-deftest portal-input-gui-web-page-keeps-typing-and-the-chords-it-uses ()
  (portal-input-gui--page
    (portal-test-native-key 53 0 "\e")
    (portal-test-native-key 0 0 "a")
    (portal-test-native-key 0 (ash 1 17) "A")
    (portal-test-native-key 40 portal-input-gui--control "\C-k")
    (portal-test-native-key 11 0 "b")
    (portal-input-gui--settled 5)
    (should (portal-input--action "focused"))
    (should-not unread-command-events)
    (should (portal-excalidraw-gui--js
             "return keys.map(k=>k[0]).join()==='Escape,a,A,k,b' && keys.every(k=>k[2]) && document.querySelector('input').value==='aAb';"))))

(ert-deftest portal-input-gui-web-unused-chord-runs-in-emacs-with-what-follows ()
  (portal-input-gui--page
    (keymap-set (current-local-map) "C-c t" #'portal-input-gui--mark)
    (let ((portal-input-gui--ran nil))
      ;; Typed at once: t follows C-c to Emacs, not to the page.
      (portal-test-native-key 8 portal-input-gui--control "\C-c")
      (portal-test-native-key 17 0 "t")
      (portal-input-gui--dispatch)
      (should portal-input-gui--ran)
      ;; The page has the keyboard again.
      (should (portal-input--action "focused"))
      (portal-test-native-key 6 0 "z")
      (portal-input-gui--settled 2)
      (should (portal-excalidraw-gui--js
               "return keys.map(k=>k[0]).join()==='c,z' && document.querySelector('input').value==='z';")))))

(ert-deftest portal-input-gui-web-keys-after-a-whole-command-stay-with-emacs ()
  (portal-input-gui--page
    (keymap-set (current-local-map) "C-c" #'portal-input-gui--mark)
    (let ((portal-input-gui--ran nil))
      ;; Typed at once: C-c is a whole command, so x is Emacs's next
      ;; command, and Emacs keeps the keyboard to read it.
      (portal-test-native-key 8 portal-input-gui--control "\C-c")
      (portal-test-native-key 7 0 "x")
      (portal-input-gui--dispatch)
      (should portal-input-gui--ran)
      (should-not (portal-input--action "focused"))
      (should (eq (read-event nil nil 1) ?x))
      (should (= (portal-excalidraw-gui--js "return keys.length") 1)))))

(ert-deftest portal-input-gui-web-trigger-again-inside-a-sequence-is-emacs-s ()
  (portal-input-gui--page
    (keymap-set (current-local-map) "C-c C-c" #'portal-input-gui--mark)
    (let ((portal-input-gui--ran nil))
      (portal-test-native-key 8 portal-input-gui--control "\C-c")
      (portal-test-native-key 8 portal-input-gui--control "\C-c")
      (portal-input-gui--dispatch)
      (should portal-input-gui--ran)
      (should (portal-input--action "focused"))
      (should (= (portal-excalidraw-gui--js "return keys.length") 1)))))

(ert-deftest portal-input-gui-web-page-focusing-a-field-leaves-emacs-the-keyboard ()
  (portal-test--with-web
    (select-frame-set-input-focus (selected-frame))
    ;; Autofocus, then a script, focus the field while Emacs has the keyboard.
    (portal-open-url "data:text/html,<title>Focusing</title><input autofocus spellcheck=false><script>setTimeout(()=>{document.querySelector('input').blur();document.querySelector('input').focus()},200)</script>")
    (portal-test--wait-for-page "Focusing")
    (let ((deadline (+ (float-time) 1)))
      (while (< (float-time) deadline)
        (should-not (portal-input--action "focused"))
        (accept-process-output nil 0.05)))
    (should (portal-excalidraw-gui--js
             "return document.activeElement === document.querySelector('input');"))
    (ert-info ((portal-test-responder) :prefix "Keyboard: ")
      (portal-integration-test--emacs-input))
    ;; Given the keyboard, the page types into the field it focused.
    (portal-integration-test--focus-web (selected-window) (portal-view-target))
    (portal-test-native-key 0 0 "a")
    (portal-terminal-test--wait
     (lambda () (equal (portal-excalidraw-gui--js "return document.querySelector('input').value")
                       "a")))))

(ert-deftest portal-input-gui-web-command-period-returns-to-emacs ()
  (portal-input-gui--page
    ;; The mode line renders who has the keyboard, and follows each change:
    ;; the tag in the state's face, and the whole line tinted for the app.
    (cl-flet ((tag () (substring-no-properties (format-mode-line mode-line-process)))
              (tag-face () (get-text-property 0 'face (format-mode-line mode-line-process))))
      (portal-terminal-test--wait (lambda () (equal (tag) "[app]")))
      (should (eq (tag-face) 'portal-mode-line-app))
      (should (assq 'mode-line-active face-remapping-alist))
      (portal-test-native-key 47 portal-input-gui--command ".")
      (should-not (portal-input--action "focused"))
      (should-not (portal-input--action "pending"))
      (portal-terminal-test--wait (lambda () (equal (tag) "[emacs]")))
      (should (eq (tag-face) 'portal-mode-line-emacs))
      (should-not (assq 'mode-line-active face-remapping-alist)))
    (portal-integration-test--emacs-input)
    (portal-input-focus)
    (should (portal-input--action "focused"))
    (portal-terminal-test--wait
     (lambda () (equal (substring-no-properties (format-mode-line mode-line-process)) "[app]")))))

(ert-deftest portal-input-gui-web-configured-escape-preempts-the-page ()
  (portal-input-gui--page
    ;; This page explicitly claims C-k. Reserving it must bypass the page.
    (let ((portal-input-escape-key "C-k"))
      (portal-test-native-key 40 portal-input-gui--control "\C-k")
      (should-not (portal-input--action "focused"))
      (should (= (portal-excalidraw-gui--js "return keys.length") 0)))
    (portal-input-focus)
    (portal-test-native-key 40 portal-input-gui--control "\C-k")
    (portal-input-gui--settled 1)
    (should (portal-input--action "focused"))
    (portal-test-native-key 47 portal-input-gui--command ".")
    (should-not (portal-input--action "focused"))))

(ert-deftest portal-input-gui-web-command-c-and-v-copy-and-paste ()
  (portal-input-gui--page
    (let ((saved (gui-get-selection 'CLIPBOARD)))
      (unwind-protect
          (progn
            (should (portal-excalidraw-gui--js
                     "const i=document.querySelector('input');i.value='portal-copy';i.select();return true;"))
            (portal-test-native-key 8 portal-input-gui--command "c")
            (portal-terminal-test--wait
             (lambda () (equal (gui-get-selection 'CLIPBOARD) "portal-copy")))
            (should (portal-excalidraw-gui--js
                     "document.querySelector('input').value='';return true;"))
            (portal-test-native-key 9 portal-input-gui--command "v")
            (portal-terminal-test--wait
             (lambda () (equal (portal-excalidraw-gui--js "return document.querySelector('input').value")
                               "portal-copy")))
            (should (portal-input--action "focused"))
            (should-not unread-command-events))
        (when saved (gui-set-selection 'CLIPBOARD saved))))))

(ert-deftest portal-input-gui-web-command-selects-and-focuses-terminal ()
  (portal-input-gui--page
    (keymap-set (current-local-map) "C-c o" #'other-window)
    (let ((web-window (selected-window)))
      (select-window (split-window-right))
      (portal-terminal)
      (let ((terminal-id (portal-view-target)))
        (unwind-protect
            (progn
              (select-window web-window)
              (portal-input-focus)
              (portal-test-native-key 8 portal-input-gui--control "\C-c")
              (portal-test-native-key 31 0 "o")
              (portal-input-gui--dispatch)
              (should (eq major-mode 'portal-terminal-mode))
              (should (plist-get (portal-terminal-test--state terminal-id) :focused)))
          (portal-terminal-close-all))))))

(provide 'portal-input-gui-tests)
