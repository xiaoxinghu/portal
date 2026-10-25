;;; portal-tests.el --- Real WebKit loading checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in a disposable graphical Emacs, with portal.el already loaded.  Web
;; buffers and placement are tested in batch by portal-web-tests.el.

(require 'ert)
(require 'portal)

(declare-function portal--inspect "portal-view" (target))
(declare-function portal--web-load "portal-web" (target url))
(declare-function portal-excalidraw-gui--js "portal-excalidraw-gui-tests" (script))
(declare-function portal-terminal-test--wait "portal-terminal-tests" (predicate))
(declare-function portal-test-native-click "test-terminal-input" (x y))
(declare-function portal-test-native-target-frame "test-terminal-input" (title))
(declare-function portal-test-responder "test-terminal-input" ())
(declare-function portal-test-sheet "test-terminal-input" (&optional button text))

(defmacro portal-test--with-web (&rest body)
  "Run BODY in one window, then kill the web buffers it opened."
  (declare (indent 0))
  `(progn
     (skip-unless (eq window-system 'ns))
     (let ((buffers (portal-view-buffers 'web)))
       (save-window-excursion
         (unwind-protect
             (progn (delete-other-windows) ,@body)
           (dolist (buffer (portal-view-buffers 'web))
             (unless (memq buffer buffers) (kill-buffer buffer))))))))

(defun portal-test--wait-for-page (title &optional target)
  "Wait for web view TARGET to finish loading a page titled TITLE.
TARGET defaults to the selected pane's view.  Return its state."
  (let ((target (or target (portal-view-target)))
        (deadline (+ (float-time) 15))
        state)
    (while (progn
             (redisplay t)
             (setq state (portal--inspect target))
             (and (< (float-time) deadline)
                  (not (and (equal (plist-get state :title) title)
                            (not (plist-get state :loading))))))
      (sleep-for 0.05))
    (should (equal (plist-get state :title) title))
    (should-not (plist-get state :loading))
    (should-not (plist-get state :error))
    state))

(defun portal-test--shown (target window)
  "Whether web view TARGET is visible within WINDOW's text area."
  (redisplay t)
  (let ((state (portal--inspect target)))
    (and (plist-get state :visible)
         (equal (plist-get state :edges) (window-inside-pixel-edges window)))))

(ert-deftest portal-web-runs-javascript-and-keeps-its-page-while-hidden ()
  (portal-test--with-web
    (portal-open-url
     "data:text/html,<title>Initial</title><h1>WebKit works</h1><script>document.title='JS works'</script>")
    (portal-test--wait-for-page "JS works")
    (let ((buffer (current-buffer))
          (target (portal-view-target)))
      (should (portal-test--shown target (selected-window)))
      (quit-window)
      (redisplay t)
      (should-not (plist-get (portal--inspect target) :visible))
      (switch-to-buffer buffer)
      (should (portal-test--shown target (selected-window)))
      (portal-test--wait-for-page "JS works")
      (kill-buffer buffer)
      (should-not (portal--inspect target)))))

(ert-deftest portal-web-about-draws-with-webgl-even-after-losing-it-and-learns-when-it-is-hidden ()
  (portal-test--with-web
    (skip-unless (file-executable-p (portal-server-program-file)))
    (select-frame-set-input-focus (selected-frame))
    (sit-for 0.1)
    ;; Page scripts run in this frame's visible web view.
    (should (portal-view--with-frame-title (selected-frame)
                                           #'portal-test-native-target-frame))
    (unwind-protect
        (let ((buffer (progn (portal-about) (current-buffer)))
              (target (portal-view-target)))
          (portal-test--wait-for-page "About Portal")
          (should (equal (portal-excalidraw-gui--js
                          "return document.documentElement.dataset.renderer;")
                         "webgl"))
          (should (string-search emacs-version
                                 (portal-excalidraw-gui--js
                                  "return document.getElementById('term').textContent;")))
          ;; WebKit may drop the context; the portal draws again once it is back.
          (should (equal (portal-excalidraw-gui--js
                          "const canvas = document.getElementById('gl');
                           const gl = canvas.getContext('webgl');
                           const lose = gl.getExtension('WEBGL_lose_context');
                           const event = (name) => new Promise((done) => {
                             canvas.addEventListener(name, done, { once: true });
                             setTimeout(done, 2000);
                           });
                           const lost = event('webglcontextlost');
                           lose.loseContext();
                           await lost;
                           // WebKit allows a restore only once the loss event is done.
                           await new Promise((done) => setTimeout(done));
                           const restored = event('webglcontextrestored');
                           lose.restoreContext();
                           await restored;
                           // Read the portal's centre after the page's next frame.
                           const pixel = new Uint8Array(4);
                           await new Promise((done) => requestAnimationFrame(() => {
                             gl.readPixels(canvas.width >> 1, canvas.height >> 1, 1, 1,
                                           gl.RGBA, gl.UNSIGNED_BYTE, pixel);
                             done();
                           }));
                           return !gl.isContextLost() && pixel[3] > 0
                             && pixel[0] + pixel[1] + pixel[2] > 0;")
                         t))
          ;; The page stops animating when told it is hidden.
          (portal-excalidraw-gui--js
           "window.hiddenSeen = false;
            document.addEventListener('visibilitychange', () => {
              if (document.hidden) window.hiddenSeen = true;
            });
            return true;")
          (quit-window)
          (redisplay t)
          (sleep-for 0.5)
          (switch-to-buffer buffer)
          (portal-test--wait-for-page "About Portal" target)
          (should (portal-test--shown target (selected-window)))
          (should (portal-excalidraw-gui--js "return window.hiddenSeen;")))
      (portal-test-native-target-frame nil))))

(defun portal-test--user-agent (options)
  "Open a web view with OPTIONS in a new buffer and return its page's user agent."
  (portal-web--visit nil "user agent"
                     (lambda ()
                       (portal-web--open
                        "data:text/html,<script>document.title='UA '+navigator.userAgent</script>"
                        options)))
  (let ((deadline (+ (float-time) 15))
        state)
    (while (progn
             (redisplay t)
             (setq state (portal--inspect (portal-view-target)))
             (and (< (float-time) deadline)
                  (not (and (string-prefix-p "UA " (or (plist-get state :title) ""))
                            (not (plist-get state :loading))))))
      (sleep-for 0.05))
    (should (string-prefix-p "UA " (or (plist-get state :title) "")))
    (substring (plist-get state :title) 3)))

(ert-deftest portal-web-ordinary-pages-claim-safari-and-hosted-apps-do-not ()
  ;; Google refuses to sign in to a page whose user agent does not claim Safari.
  (portal-test--with-web
    (let ((ordinary (portal-test--user-agent nil))
          (hosted (portal-test--user-agent '(:hosted t))))
      (should (string-match-p " Version/[0-9.]+ Safari/[0-9.]+\\'" ordinary))
      (should (string-prefix-p hosted ordinary))
      (should-not (string-match-p "Safari" hosted)))))

(ert-deftest portal-web-loads-local-file-with-relative-javascript ()
  (portal-test--with-web
    (let* ((directory (make-temp-file "portal-web-" t))
           (file (expand-file-name "Résumé #%?.HTML" directory)))
      (unwind-protect
          (progn
            (with-temp-file file
              (insert "<title>Initial</title><script src='script.js'></script>"))
            (with-temp-file (expand-file-name "script.js" directory)
              (insert "document.title = 'Local assets work';"))
            (with-temp-buffer
              (setq buffer-file-name file)
              (call-interactively #'portal-render-html))
            (portal-test--wait-for-page "Local assets work"))
        (delete-directory directory t)))))

(ert-deftest portal-web-loads-again-and-rejects-invalid-urls ()
  (portal-test--with-web
    (portal-open-url "data:text/html,<title>First</title>")
    (let ((target (portal-view-target)))
      (portal-test--wait-for-page "First")
      (should-error (portal--web-load target 42) :type 'wrong-type-argument)
      (dolist (url '("relative/path" "javascript:alert(1)" "https://"))
        (should-error (portal--web-load target url)))
      (should-error (portal--web-load "web:999999" "about:blank"))
      (portal-test--wait-for-page "First")
      (portal--web-load target "data:text/html,<title>Second</title>")
      (portal-test--wait-for-page "Second"))))

;; Safari's Develop menu lists exactly the pages WebKit marks inspectable.
(ert-deftest portal-web-inspectable-follows-the-option ()
  (portal-test--with-web
    (skip-unless (version<= "13.3" (car (process-lines "sw_vers" "-productVersion"))))
    (let ((original portal-web-inspectable))
      (unwind-protect
          (progn
            (setq portal-web-inspectable t)
            (portal-open-url "data:text/html,<title>Inspectable</title>")
            (should (plist-get (portal-test--wait-for-page "Inspectable") :inspectable))
            (setq portal-web-inspectable nil)
            (portal-open-url "data:text/html,<title>Closed</title>")
            (let ((state (portal-test--wait-for-page "Closed")))
              (should (plist-member state :inspectable))
              (should-not (plist-get state :inspectable))))
        (setq portal-web-inspectable original)))))

;;; JavaScript dialogs

(defmacro portal-test--with-dialogs (&rest body)
  "Run BODY with the app host's dialogs page in the selected pane.
The test-only injector targets its frame, where the page's sheets show."
  (declare (indent 0))
  `(portal-test--with-web
     (skip-unless (file-executable-p (portal-server-program-file)))
     (select-frame-set-input-focus (selected-frame))
     (sit-for 0.1)
     (should (portal-view--with-frame-title (selected-frame)
                                            #'portal-test-native-target-frame))
     (unwind-protect
         (progn
           (portal-web--visit-hosted "/dialogs" "dialogs")
           (portal-test--wait-for-page "Dialogs")
           ,@body)
       (portal-test-native-target-frame nil)
       ;; A click into the page asks Emacs to select its pane.
       (setq unread-command-events nil))))

(defun portal-test--sheet (&optional button text)
  "The sheet on the targeted frame, as a plist, or nil without one.
With BUTTON, press its button so titled instead, after putting TEXT, if
given, in its text field."
  (if button
      (should (portal-test-sheet button text))
    (let ((json (portal-test-sheet)))
      (and json (json-parse-string json :object-type 'plist :array-type 'list
                                   :false-object nil :null-object nil)))))

(defun portal-test--wait-for-sheet (text)
  "Wait for a sheet on the targeted frame saying TEXT, and return it."
  (let (sheet)
    (portal-terminal-test--wait
     (lambda () (member text (plist-get (setq sheet (portal-test--sheet)) :texts))))
    sheet))

(defun portal-test--no-sheet ()
  "Wait for the targeted frame to have no sheet."
  (portal-terminal-test--wait (lambda () (not (portal-test--sheet)))))

(defun portal-test--click (id)
  "Click the dialogs page's element ID with the real mouse.
A dialog it opens holds the page until answered, so no script may wait
on the page meanwhile."
  (let ((point (portal-excalidraw-gui--js
                (format "const r = document.getElementById(%S).getBoundingClientRect();
                         return [Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2)];"
                        id))))
    (should (portal-test-native-click (aref point 0) (aref point 1)))))

(ert-deftest portal-web-dialogs-give-the-page-its-answers ()
  (portal-test--with-dialogs
    (portal-test--click "alert")
    (let ((sheet (portal-test--wait-for-sheet "Hello from the page")))
      (should (member "127.0.0.1 says" (plist-get sheet :texts)))
      (should (equal (plist-get sheet :buttons) '("OK")))
      (should-not (plist-get sheet :field))
      ;; The keyboard is the sheet's, for Return and Escape.
      (should (plist-get sheet :key)))
    (portal-test--sheet "OK")
    (portal-test--wait-for-page "alert: closed")
    (portal-test--no-sheet)
    ;; The page has the keyboard back, and its next click is its own.
    (portal-terminal-test--wait
     (lambda () (string-match-p "WebPage in \\*portal: dialogs\\*" (portal-test-responder))))
    (dolist (case '(("Cancel" "confirm: false") ("OK" "confirm: true")))
      (portal-test--click "confirm")
      (should (member "Cancel" (plist-get (portal-test--wait-for-sheet "Keep going?") :buttons)))
      (portal-test--sheet (car case))
      (portal-test--wait-for-page (cadr case)))
    (portal-test--click "prompt")
    (should (equal (plist-get (portal-test--wait-for-sheet "Your name?") :field) "Ada"))
    (portal-test--sheet "OK" "Grace Hopper")
    (portal-test--wait-for-page "prompt: \"Grace Hopper\"")
    (portal-test--click "prompt")
    (portal-test--wait-for-sheet "Your name?")
    (portal-test--sheet "Cancel")
    (portal-test--wait-for-page "prompt: null")))

(ert-deftest portal-web-dialog-waits-while-its-page-is-hidden ()
  (portal-test--with-dialogs
    (let ((buffer (current-buffer))
          (target (portal-view-target)))
      (portal-test--click "prompt")
      (portal-test--wait-for-sheet "Your name?")
      (quit-window)
      (redisplay t)
      (should-not (plist-get (portal--inspect target) :visible))
      (portal-test--no-sheet)
      ;; Shown again, the page still waits on the same question.
      (switch-to-buffer buffer)
      (should (equal (plist-get (portal-test--wait-for-sheet "Your name?") :field) "Ada"))
      (portal-test--sheet "OK")
      (portal-test--wait-for-page "prompt: \"Ada\"" target)
      ;; Closing the view answers its dialog and takes the sheet down.
      (portal-test--click "confirm")
      (portal-test--wait-for-sheet "Keep going?")
      (kill-buffer buffer)
      (should-not (portal--inspect target))
      (portal-test--no-sheet))))

(ert-deftest portal-web-asks-before-leaving-a-page-that-guards-it ()
  (portal-test--with-dialogs
    (let ((target (portal-view-target)))
      ;; WebKit asks only for a page the user has used, as a click does.
      (portal-test--click "guard")
      (portal-terminal-test--wait
       (lambda () (portal-excalidraw-gui--js "return document.getElementById('guard').checked;")))
      ;; Following a link and reloading both ask; staying keeps the page.
      (dolist (leave (list (lambda () (portal-test--click "leave"))
                           (lambda () (portal-web-reload))))
        (funcall leave)
        (let ((sheet (portal-test--wait-for-sheet "Leave this page?")))
          (should (member "Stay on Page" (plist-get sheet :buttons))))
        (portal-test--sheet "Stay on Page")
        (portal-test--no-sheet)
        (should (portal-excalidraw-gui--js
                 "return location.pathname.endsWith('/dialogs')
                   && document.getElementById('guard').checked;")))
      (portal-test--click "leave")
      (portal-test--wait-for-sheet "Leave this page?")
      (portal-test--sheet "Leave Page")
      (portal-test--wait-for-page "Hello, world!" target))))

(provide 'portal-tests)
