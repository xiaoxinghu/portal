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
  :tags '(:gui)
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
  :tags '(:gui)
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
  :tags '(:gui)
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
  :tags '(:gui)
  (portal-input-gui--page
    (keymap-set (current-local-map) "C-c C-c" #'portal-input-gui--mark)
    (let ((portal-input-gui--ran nil))
      (portal-test-native-key 8 portal-input-gui--control "\C-c")
      (portal-test-native-key 8 portal-input-gui--control "\C-c")
      (portal-input-gui--dispatch)
      (should portal-input-gui--ran)
      (should (portal-input--action "focused"))
      (should (= (portal-excalidraw-gui--js "return keys.length") 1)))))

(ert-deftest portal-input-gui-web-command-f-finds-while-emacs-has-the-keyboard ()
  :tags '(:gui)
  (portal-test--with-web
    (select-frame-set-input-focus (selected-frame))
    (portal-open-url "data:text/html,<title>Find ready</title><p>apple pie</p><input autofocus spellcheck=false>")
    (portal-test--wait-for-page "Find ready")
    (let ((target (portal-view-target))
          (portal-web-find-history nil)
          (reading 'never))
      (portal-integration-test--focus-web (selected-window) target)
      (portal-test-native-key 3 portal-input-gui--command "f")
      (let ((event (aref (with-timeout (5 (ert-fail "Command-F did not reach Emacs"))
                           (read-key-sequence-vector nil))
                         0)))
        (should (eq (car-safe event) 'portal-input-key))
        ;; The minibuffer reads with Emacs holding the keyboard.
        (minibuffer-with-setup-hook
            (lambda () (setq reading (portal-input--action "focused" target)))
          (setq unread-command-events (listify-key-sequence (kbd "pie RET")))
          (with-timeout (5 (ert-fail "Finding stalled"))
            (portal-input--dispatch event))))
      (should-not reading)
      (portal-terminal-test--wait
       (lambda () (equal (portal-excalidraw-gui--js "return getSelection().toString();") "pie")))
      ;; Once the text is found, the page has the keyboard back.
      (should (portal-input--action "focused" target)))))

(ert-deftest portal-input-gui-web-page-focusing-a-field-leaves-emacs-the-keyboard ()
  :tags '(:gui)
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
  :tags '(:gui)
  (portal-input-gui--page
    ;; The mode line renders who has the keyboard, and follows each change:
    ;; the light lit or dimmed, and the whole line tinted for the app.
    (cl-flet ((tag () (substring-no-properties (format-mode-line mode-line-process)))
              (tag-face () (get-text-property 0 'face (format-mode-line mode-line-process))))
      (portal-terminal-test--wait (lambda () (eq (tag-face) 'portal-mode-line-app)))
      (should (equal (tag) " ● "))
      (should (assq 'mode-line-active face-remapping-alist))
      (portal-test-native-key 47 portal-input-gui--command ".")
      (should-not (portal-input--action "focused"))
      (should-not (portal-input--action "pending"))
      (portal-terminal-test--wait (lambda () (eq (tag-face) 'portal-mode-line-emacs)))
      (should (equal (tag) " ○ "))
      (should-not (assq 'mode-line-active face-remapping-alist)))
    (portal-integration-test--emacs-input)
    (portal-input-focus)
    (should (portal-input--action "focused"))
    (portal-terminal-test--wait
     (lambda () (eq (get-text-property 0 'face (format-mode-line mode-line-process))
                    'portal-mode-line-app)))))

(ert-deftest portal-input-gui-web-configured-escape-preempts-the-page ()
  :tags '(:gui)
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

(ert-deftest portal-input-gui-web-double-escape-returns-to-emacs ()
  :tags '(:gui)
  (portal-input-gui--page
    (let ((portal-input-double-escape 0.5))
      ;; Escape typed slowly twice is the page's both times.
      (portal-test-native-key 53 0 "\e")
      (portal-input-gui--settled 1)
      (sleep-for 0.6)
      (portal-test-native-key 53 0 "\e")
      (portal-input-gui--settled 2)
      (should (portal-input--action "focused"))
      ;; Typed quickly, the page gets the first, and the second returns to Emacs.
      (sleep-for 0.6)
      (portal-test-native-key 53 0 "\e")
      (portal-test-native-key 53 0 "\e")
      (portal-input-gui--settled 3)
      (should-not (portal-input--action "focused"))
      (should-not unread-command-events)
      (should (portal-excalidraw-gui--js "return keys.every(k=>k[0]==='Escape')")))))

(ert-deftest portal-input-gui-web-command-c-and-v-copy-and-paste ()
  :tags '(:gui)
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
  :tags '(:gui)
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

(defun portal-input-gui--key-window-js (script)
  "Run SCRIPT in the page in the key window, returning its result.
Return `none' while the key window has no page, as while WebKit moves a
page to or from its fullscreen window."
  (if (not (portal-test-web-eval script))
      'none
    (portal-terminal-test--wait (lambda () (portal-test-web-eval nil)))
    (let ((result (json-parse-string (portal-test-web-eval nil) :object-type 'plist
                                     :false-object nil :null-object nil)))
      (should-not (plist-get result :error))
      (plist-get result :value))))

(defun portal-input-gui--typed (key)
  "Wait until the page in the key window has seen KEY, a key name, last."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (equal (portal-input-gui--key-window-js "return keys.at(-1);") key))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (unless (equal (portal-input-gui--key-window-js "return keys.at(-1);") key)
      (ert-fail (format "The page saw %S, not %s last, with the keyboard in %s"
                        (portal-input-gui--key-window-js "return keys;") key
                        (portal-test-responder))))))

(defmacro portal-input-gui--fullscreen-page (&rest body)
  "Run BODY with an app-host page whose button fills it and goes fullscreen.
The page records each key press in `keys'.  Leave fullscreen afterwards,
so that no fullscreen window outlives the test."
  (declare (indent 0))
  `(portal-test--with-web
     (skip-unless (file-executable-p (portal-server-program-file)))
     (unwind-protect
         (progn
           (select-frame-set-input-focus (selected-frame))
           (sit-for 0.1)
           (portal-hello)
           (portal-test--wait-for-page "Hello, world!")
           (portal-excalidraw-gui--js
            "const button = document.createElement('button');
             button.style.cssText = 'position:fixed;inset:0;width:100%;height:100%';
             button.onclick = () => document.documentElement.requestFullscreen();
             document.body.append(button);
             window.keys = [];
             document.addEventListener('keydown', (e) => keys.push(e.key), true);
             return true;")
           ,@body)
       (setq unread-command-events nil)
       (when-let* ((target (portal-view-target))
                   ((plist-get (portal--inspect target) :fullscreen)))
         (portal-input-gui--key-window-js "await document.exitFullscreen(); return true;")
         (portal-terminal-test--wait
          (lambda () (not (plist-get (portal--inspect target) :fullscreen))))))))

(defun portal-input-gui--fullscreen (fullscreen)
  "Wait until the selected pane's page is FULLSCREEN, and its window has the keyboard.
Fullscreen, that is WebKit's window, done entering, with the page focused
in it; otherwise the page is back in its pane in the key window."
  (let ((target (portal-view-target)))
    (portal-terminal-test--wait
     (lambda ()
       (and (equal (plist-get (portal--inspect target) :fullscreen) (and fullscreen "in"))
            (eq (portal-input-gui--key-window-js
                 "return !!document.fullscreenElement && document.hasFocus();")
                fullscreen))))))

(defun portal-input-gui--emacs-got-nothing ()
  "Check that no key reached Emacs."
  (should-not (read-event nil nil 0.3)))

(defun portal-input-gui--fills-pane ()
  "Whether the selected pane's page is shown at the pane's size."
  (let ((edges (window-inside-pixel-edges)))
    (and (portal-test--shown (portal-view-target) (selected-window))
         (equal (portal-input-gui--key-window-js "return [innerWidth, innerHeight];")
                (vector (- (nth 2 edges) (nth 0 edges)) (- (nth 3 edges) (nth 1 edges)))))))

(ert-deftest portal-input-gui-web-fullscreen-keeps-the-keyboard-and-escape-leaves-it ()
  :tags '(:gui)
  (portal-input-gui--fullscreen-page
    ;; With a long double escape, an Escape counted in fullscreen would
    ;; make the next one return to Emacs.
    (let ((portal-input-double-escape 10)
          (target (portal-view-target)))
      ;; Clicking the page's button gives the page the keyboard, and Emacs
      ;; selects its pane while it goes fullscreen.
      (should (portal-test-native-click 50 50))
      (portal-input-gui--fullscreen t)
      (portal-terminal-test--wait (lambda () unread-command-events))
      (portal-input--select (pop unread-command-events))
      (should (portal-input--action "focused"))
      ;; Every key in fullscreen is the page's, even those it does not use.
      (portal-test-native-key 49 0 " ")
      (portal-input-gui--typed " ")
      (portal-test-native-key 124 (ash 1 23) (string #xF703))
      (portal-input-gui--typed "ArrowRight")
      (portal-test-native-key 0 0 "a")
      (portal-input-gui--typed "a")
      (portal-input-gui--emacs-got-nothing)
      ;; Escape leaves fullscreen; the page is back in its pane, with the keyboard.
      (portal-test-native-key 53 0 "\e")
      (portal-input-gui--fullscreen nil)
      (should (portal-input-gui--fills-pane))
      (should (plist-get (portal--inspect target) :focused))
      (should (portal-input--action "focused"))
      ;; The next Escape is the page's, the first of a pair.
      (portal-test-native-key 53 0 "\e")
      (portal-input-gui--typed "Escape")
      (accept-process-output nil 0.2)
      (should (portal-input--action "focused"))
      (portal-test-native-key 11 0 "b")
      (portal-input-gui--typed "b")
      (portal-test-native-key 47 portal-input-gui--command ".")
      (should-not (portal-input--action "focused"))
      (portal-integration-test--emacs-input))))

(ert-deftest portal-input-gui-web-fullscreen-returns-to-where-emacs-put-the-page ()
  :tags '(:gui)
  (portal-input-gui--fullscreen-page
    (let ((target (portal-view-target)))
      ;; A script, here Emacs's, can make the page fullscreen while Emacs
      ;; has the keyboard.  Keys in fullscreen are still the page's.
      (should-not (portal-input--action "focused"))
      (portal-excalidraw-gui--js "document.documentElement.requestFullscreen(); return true;")
      (portal-input-gui--fullscreen t)
      (portal-test-native-key 7 0 "x")
      (portal-input-gui--typed "x")
      (portal-input-gui--emacs-got-nothing)
      ;; Emacs shrinks the page's pane meanwhile; the page stays fullscreen.
      (split-window-below)
      (redisplay t)
      (should (plist-get (portal--inspect target) :fullscreen))
      (should (eq (portal-input-gui--key-window-js "return !!document.fullscreenElement;") t))
      ;; Leaving, the page fills its smaller pane, and Emacs has the keyboard.
      (portal-input-gui--key-window-js "await document.exitFullscreen(); return true;")
      (portal-input-gui--fullscreen nil)
      (should (portal-input-gui--fills-pane))
      (should-not (plist-get (portal--inspect target) :focused))
      (should-not (portal-input--action "focused"))
      (portal-integration-test--emacs-input)
      ;; Hidden while fullscreen, it is hidden once back.
      (delete-other-windows)
      (portal-excalidraw-gui--js "document.documentElement.requestFullscreen(); return true;")
      (portal-input-gui--fullscreen t)
      (let ((buffer (current-buffer)))
        (switch-to-buffer "*scratch*")
        (redisplay t)
        (portal-input-gui--key-window-js "await document.exitFullscreen(); return true;")
        (portal-terminal-test--wait
         (lambda () (not (plist-get (portal--inspect target) :fullscreen))))
        (should-not (plist-get (portal--inspect target) :visible))
        ;; WebKit's window goes, Emacs gets the keyboard, and then the page
        ;; leaves the pane.
        (portal-terminal-test--wait
         (lambda () (string-prefix-p "EmacsView in " (portal-test-responder))))
        (portal-terminal-test--wait
         (lambda () (eq (portal-input-gui--key-window-js "return true;") 'none)))
        (portal-integration-test--emacs-input)
        (switch-to-buffer buffer)
        (redisplay t))
      (should (portal-input-gui--fills-pane)))))

(ert-deftest portal-input-gui-web-fullscreen-page-keeps-the-keyboard-in-another-frame ()
  :tags '(:gui)
  (portal-input-gui--fullscreen-page
    (let* ((buffer (current-buffer))
           (target (portal-view-target))
           (home (selected-frame))
           (frame (make-frame)))
      (unwind-protect
          (progn
            (select-frame-set-input-focus home)
            (sit-for 0.1)
            (should (portal-test-native-click 50 50))
            (portal-input-gui--fullscreen t)
            (setq unread-command-events nil)
            ;; Emacs shows the page in another frame meanwhile, and gives it
            ;; the keyboard there.
            (select-frame frame)
            (switch-to-buffer buffer)
            (redisplay t)
            (should (equal (portal-view-target) target))
            (portal-input-focus)
            (should (portal-input--action "focused"))
            (let* ((owners nil)
                   (watch (lambda (_symbol value operation _where)
                            (when (eq operation 'set) (push value owners)))))
              (add-variable-watcher 'portal-input--focused watch)
              (unwind-protect
                  (progn
                    (portal-test-native-key 53 0 "\e")
                    ;; Back, the page has the keyboard in that frame, and
                    ;; never lost it on the way.
                    (portal-terminal-test--wait
                     (lambda () (and (not (plist-get (portal--inspect target) :fullscreen))
                                     (plist-get (portal--inspect target) :focused))))
                    (accept-process-output nil 0.3)
                    (should-not (memq nil owners)))
                (remove-variable-watcher 'portal-input--focused watch)))
            (should (portal-test--shown target (selected-window)))
            (should (portal-input--action "focused")))
        (delete-frame frame)))))

(ert-deftest portal-input-gui-web-fullscreen-page-closes-with-its-buffer ()
  :tags '(:gui)
  (portal-input-gui--fullscreen-page
    (let ((target (portal-view-target)))
      (should (portal-test-native-click 50 50))
      (portal-input-gui--fullscreen t)
      (setq unread-command-events nil)
      (kill-buffer)
      (should-not (portal--inspect target))
      ;; The page leaves fullscreen first, and its window goes: Emacs gets
      ;; the keyboard.
      (portal-terminal-test--wait
       (lambda () (string-prefix-p "EmacsView in " (portal-test-responder))))
      (should (eq (portal-input-gui--key-window-js "return true;") 'none))
      (portal-integration-test--emacs-input))))

(provide 'portal-input-gui-tests)
