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
(declare-function portal-test-native-key "test-terminal-input" (code flags text &optional windowless))
(declare-function portal-test-native-target-frame "test-terminal-input" (title))
(declare-function portal-test-responder "test-terminal-input" ())
(declare-function portal-test-sheet "test-terminal-input" (&optional button text))
(declare-function portal-test-web-mock-capture "test-terminal-input" (on))
(declare-function portal-terminal-test--wait "portal-terminal-tests" (predicate))
(declare-function portal-integration-test--emacs-input "portal-integration-tests" ())

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

(defun portal-test--serve (routes)
  "Serve ROUTES on a local port, and return the server process.
ROUTES is an alist of each path to the HTTP response, headers and body,
sent before the connection closes."
  (make-network-process
   :name "portal-test-http" :server t :host 'local :service t :family 'ipv4
   :noquery t :coding 'binary
   :filter (lambda (connection request)
             (when (string-match "\\`GET \\([^ ]+\\)" request)
               (process-send-string
                connection
                (or (cdr (assoc (match-string 1 request) routes))
                    "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"))
               (delete-process connection)))))

(defun portal-test--response (headers body)
  "An HTTP response with HEADERS, a list of header lines, and BODY."
  (concat "HTTP/1.1 200 OK\r\n" (mapconcat (lambda (header) (concat header "\r\n")) headers)
          (format "Content-Length: %d\r\nConnection: close\r\n\r\n" (length body)) body))

(defun portal-test--wait-for-message (pattern start)
  "Wait for a message matching PATTERN in *Messages*, after position START."
  (let ((deadline (+ (float-time) 15)) found)
    (while (and (not (setq found (with-current-buffer (messages-buffer)
                                   (save-excursion
                                     (goto-char start)
                                     (re-search-forward pattern nil t)))))
                (< (float-time) deadline))
      (redisplay t)
      (sleep-for 0.05))
    (should found)))

;;; Camera and microphone

(defun portal-test--capture (constraints)
  "Have the visible page ask for CONSTRAINTS, getUserMedia's, with mock devices.
The page's title then says what it got, or the error's name."
  (should (portal-test-web-mock-capture t))
  (portal-excalidraw-gui--js
   (format "document.title = 'Asking';
navigator.mediaDevices.getUserMedia(%s).then(
  (stream) => {
    document.title = 'Got ' + stream.getTracks().map((track) => track.kind).sort().join(' ');
    stream.getTracks().forEach((track) => track.stop());
  },
  (error) => { document.title = error.name; });
return true;" constraints)))

(ert-deftest portal-web-pages-ask-for-the-camera-and-microphone ()
  (portal-test--with-dialogs
    (let* ((server (portal-test--serve
                    `(("/" . ,(portal-test--response '("Content-Type: text/html")
                                                     "<title>Media</title><p>Media")))))
           (port (process-contact server :service))
           (camera "Allow “127.0.0.1” to use your camera?")
           (both "Allow “127.0.0.1” to use your camera and microphone?"))
      (unwind-protect
          (progn
            ;; A hosted app may not, and is never asked.
            (portal-test--capture "{audio: true}")
            (portal-test--wait-for-page "NotAllowedError")
            (should-not (portal-test--sheet))
            ;; Another page asks, and a refusal lasts for that request only.
            (portal-open-url (format "http://127.0.0.1:%d/" port))
            (portal-test--wait-for-page "Media")
            (portal-test--capture "{video: true}")
            (let ((sheet (portal-test--wait-for-sheet camera)))
              (should (member "It may use it again until Emacs quits." (plist-get sheet :texts)))
              (should (equal (sort (plist-get sheet :buttons) #'string<) '("Allow" "Don’t Allow"))))
            ;; Escape refuses, as the sheet has the keyboard.
            (should (portal-test-native-key 53 0 "\e" t))
            (portal-test--wait-for-page "NotAllowedError")
            (portal-test--no-sheet)
            (portal-test--capture "{video: true}")
            (portal-test--wait-for-sheet camera)
            (portal-test--sheet "Allow")
            (portal-test--wait-for-page "Got video")
            ;; The grant outlives the page; the microphone needs one too.
            (portal-web-reload)
            (portal-test--wait-for-page "Media")
            (portal-test--capture "{video: true}")
            (portal-test--wait-for-page "Got video")
            (should-not (portal-test--sheet))
            ;; Hidden, the page's question waits for it.
            (let ((buffer (current-buffer)))
              (portal-test--capture "{audio: true, video: true}")
              (portal-test--wait-for-sheet both)
              (quit-window)
              (redisplay t)
              (portal-test--no-sheet)
              (switch-to-buffer buffer)
              (portal-test--wait-for-sheet both)
              (portal-test--sheet "Allow")
              (portal-test--wait-for-page "Got audio video"))
            ;; Another view of the site needs no asking; another site does.
            (portal-open-url (format "http://127.0.0.1:%d/" port))
            (portal-test--wait-for-page "Media")
            (portal-test--capture "{audio: true}")
            (portal-test--wait-for-page "Got audio")
            (should-not (portal-test--sheet))
            (portal-open-url (format "http://localhost:%d/" port))
            (portal-test--wait-for-page "Media")
            (portal-test--capture "{audio: true}")
            (portal-test--wait-for-sheet "Allow “localhost” to use your microphone?")
            ;; Closing the view refuses, and takes the sheet down.
            (kill-buffer (current-buffer))
            (portal-test--no-sheet))
        (delete-process server)))))

(ert-deftest portal-web-downloads-instead-of-failing-and-says-so ()
  (portal-test--with-web
    (let* ((directory (file-name-as-directory (make-temp-file "portal-downloads-" t)))
           (original portal-web-download-directory)
           (server (portal-test--serve
                    `(("/attribute" . ,(portal-test--response
                                        '("Content-Type: text/html")
                                        (concat "<title>Attribute</title>"
                                                "<a id='save' download='hello.txt' href='data:text/plain,hello'>Save</a>"
                                                "<script>document.getElementById('save').click()</script>")))
                      ("/report" . ,(portal-test--response
                                     '("Content-Type: text/plain"
                                       "Content-Disposition: attachment; filename=\"report.txt\"")
                                     "report"))
                      ("/archive.zip" . ,(portal-test--response '("Content-Type: application/zip") "PK"))
                      ("/broken" . ,(concat "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                                            "Content-Disposition: attachment; filename=\"broken.bin\"\r\n"
                                            "Content-Length: 100000\r\n\r\nonly a little")))))
           (base (format "http://127.0.0.1:%d" (process-contact server :service)))
           (file (lambda (name) (expand-file-name name directory))))
      (unwind-protect
          (let ((start (with-current-buffer (messages-buffer) (point-max))))
            (setopt portal-web-download-directory directory)
            ;; A link with a download attribute.
            (portal-open-url (concat base "/attribute"))
            (portal-test--wait-for-page "Attribute")
            (portal-test--wait-for-message
             (concat "^Downloaded " (regexp-quote (abbreviate-file-name (funcall file "hello.txt"))) "$")
             start)
            (should (equal (with-temp-buffer
                             (insert-file-contents-literally (funcall file "hello.txt"))
                             (buffer-string))
                           "hello"))
            ;; A response marked as an attachment, and one WebKit cannot
            ;; show, leave the page as it was.
            (let ((target (portal-view-target)))
              (dolist (download '(("/report" . "report.txt") ("/archive.zip" . "archive.zip")
                                  ("/report" . "report (1).txt")))
                (portal--web-load target (concat base (car download)))
                (portal-test--wait-for-message
                 (concat "^Downloaded "
                         (regexp-quote (abbreviate-file-name (funcall file (cdr download)))) "$")
                 start))
              (should (equal (with-temp-buffer
                               (insert-file-contents-literally (funcall file "report (1).txt"))
                               (buffer-string))
                             "report"))
              (let ((state (portal--inspect target)))
                (should (equal (plist-get state :title) "Attribute"))
                (should-not (plist-get state :error)))
              ;; Failures reach Emacs as messages, not as a dead page.
              (portal--web-load target (concat base "/broken"))
              (portal-test--wait-for-message
               (concat "^Could not download "
                       (regexp-quote (abbreviate-file-name (funcall file "broken.bin"))) ": .")
               start)
              (setopt portal-web-download-directory (funcall file "missing/"))
              (portal--web-load target (concat base "/report"))
              (portal-test--wait-for-message
               (concat "^Could not download " (regexp-quote base) "/report: No download directory "
                       (regexp-quote (funcall file "missing/")) "$")
               start)
              (let ((state (portal--inspect target)))
                (should (equal (plist-get state :title) "Attribute"))
                (should-not (plist-get state :error)))
              ;; Only complete files remain.
              (should (equal (directory-files directory nil "\\`[^.]")
                             '("archive.zip" "hello.txt" "report (1).txt" "report.txt")))))
        (setopt portal-web-download-directory original)
        (delete-process server)
        (delete-directory directory t)))))

(defmacro portal-test--with-page-scripts (&rest body)
  "Run BODY with page scripts reaching this frame's visible web view."
  (declare (indent 0))
  `(progn
     (select-frame-set-input-focus (selected-frame))
     (sit-for 0.1)
     (should (portal-view--with-frame-title (selected-frame)
                                            #'portal-test-native-target-frame))
     (unwind-protect (progn ,@body)
       (portal-test-native-target-frame nil))))

(defun portal-test--wait-for-selection (expected)
  "Wait until the page's selection is EXPECTED, its text @ its start offset."
  (portal-terminal-test--wait
   (lambda ()
     (equal (portal-excalidraw-gui--js
             "const s = getSelection();
              return s.rangeCount ? s.toString() + '@' + s.getRangeAt(0).startOffset : '';")
            expected))))

(defun portal-test--about (value expected)
  "Whether VALUE, a number of CSS pixels, is EXPECTED to the nearest pixel."
  (<= (abs (- value expected)) 1))

(defun portal-test--find (keys)
  "Run `portal-web-find', typing KEYS in its minibuffer."
  (let ((unread-command-events (listify-key-sequence (kbd keys))))
    (portal-web-find)))

(ert-deftest portal-web-finds-text-from-the-minibuffer-and-emacs-keeps-the-keyboard ()
  (portal-test--with-web
    (portal-test--with-page-scripts
      (let ((portal-web-find-history nil)
            (case-fold-search t)
            (search-upper-case t))
        (portal-open-url "data:text/html,<title>Find</title><p>apple banana apple Apple</p>")
        (portal-test--wait-for-page "Find")
        ;; C-s twice moves to the second match; RET stays on it.
        (portal-test--find "apple C-s C-s RET")
        (portal-test--wait-for-selection "apple@13")
        (portal-web-find-previous)
        (portal-test--wait-for-selection "apple@0")
        ;; An upper-case letter makes case matter.
        (portal-test--find "Apple RET")
        (portal-test--wait-for-selection "Apple@19")
        (portal-test--find "zzz RET")
        (portal-terminal-test--wait
         (lambda () (equal (current-message) "No match for \"zzz\"")))
        ;; The page never took the keyboard.
        (should-not (portal-input--action "focused"))
        (portal-integration-test--emacs-input)))))

(ert-deftest portal-web-zoom-lays-the-page-out-again-and-stays-with-its-site ()
  (portal-test--with-web
    (portal-test--with-page-scripts
      (let ((portal-web-zoom-levels nil)
            (url "data:text/html,<title>Zoom</title>"))
        (unwind-protect
            (progn
              (portal-open-url url)
              (portal-test--wait-for-page "Zoom")
              (let ((width (portal-excalidraw-gui--js "return innerWidth;")))
                (portal-web-zoom-in)
                (portal-web-zoom-in)
                (should (equal (plist-get (portal--inspect (portal-view-target)) :zoom) 125))
                ;; At 125%, the page lays out a viewport 4/5 as wide.
                (portal-terminal-test--wait
                 (lambda () (portal-test--about (portal-excalidraw-gui--js "return innerWidth;")
                                                (* width 0.8))))
                ;; A new view of the same site opens at its level.
                (kill-buffer)
                (portal-open-url url)
                (portal-test--wait-for-page "Zoom")
                (should (equal (plist-get (portal--inspect (portal-view-target)) :zoom) 125))
                (portal-terminal-test--wait
                 (lambda () (portal-test--about (portal-excalidraw-gui--js "return innerWidth;")
                                                (* width 0.8))))
                (portal-web-zoom-reset)
                (portal-terminal-test--wait
                 (lambda () (= (portal-excalidraw-gui--js "return innerWidth;") width)))))
          (portal--web-zoom "" 100))))))

(provide 'portal-tests)
