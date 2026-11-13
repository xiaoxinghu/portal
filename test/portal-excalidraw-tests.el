;;; portal-excalidraw-tests.el --- Drawing persistence contract -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'cl-lib)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-excalidraw)

(defconst portal-excalidraw-test--scene
  "{\"type\":\"excalidraw\",\"version\":2,\"elements\":[{\"id\":\"image\",\"type\":\"image\",\"fileId\":\"asset\"}],\"appState\":{},\"files\":{\"asset\":{\"dataURL\":\"data:image/png;base64,AAAA\"}}}")

(defmacro portal-excalidraw-test--buffer (&rest body)
  (declare (indent 0))
  `(with-temp-buffer
     (cl-letf (((symbol-function 'portal-excalidraw--start) #'ignore))
       (portal-excalidraw-mode))
     (unwind-protect (progn ,@body)
       (setq portal-excalidraw--ready nil)
       (set-buffer-modified-p nil))))

(ert-deftest portal-excalidraw-rejects-invalid-data-before-replacing-buffer ()
  (portal-excalidraw-test--buffer
    (let ((before (buffer-string)))
      (should-error (portal-excalidraw--scene "{\"type\":\"other\",\"elements\":[]}"))
      (should (equal before (buffer-string)))
      (should-not (buffer-modified-p)))))

(ert-deftest portal-excalidraw-initial-load-and-undo-track-saved-scene ()
  (portal-excalidraw-test--buffer
    (portal-excalidraw--message (list :type "loaded" :json portal-excalidraw--empty))
    (should portal-excalidraw--ready)
    (should-not (buffer-modified-p))
    (portal-excalidraw--message '(:type "dirty"))
    (should (buffer-modified-p))
    (portal-excalidraw--message (list :type "change" :json portal-excalidraw-test--scene))
    (should (buffer-modified-p))
    (should (string-match-p "data:image/png;base64,AAAA" (buffer-string)))
    (portal-excalidraw--message (list :type "change" :json portal-excalidraw--empty))
    (should-not (buffer-modified-p))))

(ert-deftest portal-excalidraw-save-flushes-pending-edits-and-embeds-images ()
  (let ((file (make-temp-file "portal-drawing-" nil ".excalidraw")) sent)
    (unwind-protect
        (portal-excalidraw-test--buffer
          (setq buffer-file-name file portal-excalidraw--ready t)
          (set-visited-file-modtime)
          (cl-letf (((symbol-function 'portal-web-send)
                     (lambda (message)
                       (push message sent)
                       (when (equal (plist-get message :type) "snapshot")
                         (portal-excalidraw--message
                          (list :type "snapshot" :request (plist-get message :request)
                                :json portal-excalidraw-test--scene))))))
            (portal-excalidraw-save)
            (should-not (buffer-modified-p))
            (should (equal (plist-get (car sent) :type) "saved"))
            (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                           (concat portal-excalidraw-test--scene "\n")))))
      (delete-file file))))

(ert-deftest portal-excalidraw-failed-save-keeps-drawing-modified ()
  (portal-excalidraw-test--buffer
    (setq portal-excalidraw--ready t)
    (let (sent)
      (cl-letf (((symbol-function 'portal-web-send)
                 (lambda (message)
                   (push message sent)
                   (when (equal (plist-get message :type) "snapshot")
                     (portal-excalidraw--message
                      (list :type "snapshot" :request (plist-get message :request)
                            :json portal-excalidraw-test--scene)))))
                ((symbol-function 'save-buffer) (lambda (&rest _) (error "Disk full"))))
        (should-error (portal-excalidraw-save))
        (should (buffer-modified-p))
        (should (equal (plist-get (car sent) :type) "error"))
        (should-not (cl-find "saved" sent :key (lambda (message) (plist-get message :type)) :test #'equal))))))

(ert-deftest portal-excalidraw-late-snapshot-cannot-overwrite-newer-scene ()
  (portal-excalidraw-test--buffer
    (setq portal-excalidraw--request 2)
    (portal-excalidraw--scene portal-excalidraw-test--scene)
    (portal-excalidraw--message (list :type "snapshot" :request 1 :json portal-excalidraw--empty))
    (should (string-match-p "base64,AAAA" (buffer-string)))
    (should-not portal-excalidraw--reply)))

(ert-deftest portal-excalidraw-normal-save-aborts-if-snapshot-fails ()
  (let ((file (make-temp-file "portal-drawing-" nil ".excalidraw" portal-excalidraw--empty)))
    (unwind-protect
        (portal-excalidraw-test--buffer
          (setq buffer-file-name file portal-excalidraw--ready t
                portal-excalidraw--error "Editor stopped")
          (set-visited-file-modtime)
          (portal-excalidraw--scene portal-excalidraw-test--scene)
          (should-error (save-buffer))
          (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                         portal-excalidraw--empty)))
      (delete-file file))))

(ert-deftest portal-excalidraw-untitled-drawing-requires-discard-confirmation ()
  (portal-excalidraw-test--buffer
    (portal-excalidraw--scene portal-excalidraw-test--scene)
    (let ((native-comp-enable-subr-trampolines nil) asked)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) (setq asked t) nil)))
        (should-not (portal-excalidraw--query-kill))
        (should asked)))))

(ert-deftest portal-excalidraw-reopen-preserves-unsaved-buffer ()
  (portal-excalidraw-test--buffer
    (portal-excalidraw--scene portal-excalidraw-test--scene)
    (setq portal-excalidraw--error "WebKit stopped")
    (cl-letf (((symbol-function 'portal-excalidraw--start) #'ignore))
      (portal-excalidraw-reopen))
    (should-not portal-excalidraw--error)
    (should (buffer-modified-p))
    (should (string-match-p "base64,AAAA" (buffer-string)))))

(ert-deftest portal-excalidraw-revert-replaces-the-buffer-with-the-saved-drawing ()
  (let ((file (make-temp-file "portal-drawing-" nil ".excalidraw" portal-excalidraw--empty))
        (starts 0))
    (unwind-protect
        (portal-excalidraw-test--buffer
          (setq buffer-file-name file)
          (set-visited-file-modtime)
          (portal-excalidraw--scene portal-excalidraw-test--scene)
          (should (buffer-modified-p))
          (cl-letf (((symbol-function 'portal-excalidraw--start) (lambda () (cl-incf starts))))
            (revert-buffer nil t))
          (should (equal (buffer-string) portal-excalidraw--empty))
          (should-not (buffer-modified-p))
          (should (= starts 1)))
      (delete-file file))))

(ert-deftest portal-excalidraw-revert-takes-a-file-changed-on-disk-without-asking ()
  (let ((file (make-temp-file "portal-drawing-" nil ".excalidraw" portal-excalidraw--empty)))
    (unwind-protect
        (portal-excalidraw-test--buffer
          (setq buffer-file-name file
                buffer-file-truename (abbreviate-file-name (file-truename file)))
          (set-file-times file (time-subtract nil 60))
          (set-visited-file-modtime)
          (portal-excalidraw--scene portal-excalidraw--empty t)
          (should-not (buffer-modified-p))
          ;; Another program saves the drawing.
          (write-region portal-excalidraw-test--scene nil file nil 'silent)
          (cl-letf (((symbol-function 'ask-user-about-supersession-threat)
                     (lambda (_) (ert-fail "Asked whether to edit the buffer")))
                    ((symbol-function 'portal-excalidraw--start) #'ignore))
            (revert-buffer nil t))
          (should (equal (buffer-string) portal-excalidraw-test--scene))
          (should-not (buffer-modified-p)))
      (delete-file file))))

(defun portal-excalidraw-test--screen-tag ()
  "What the drawing's own part of `mode-line-process' says.
Batch Emacs formats no mode line; the graphical tests read the real one."
  (mapconcat (lambda (part)
               (or (and (eq (car-safe part) :eval) (eval (cadr part) t)) ""))
             mode-line-process ""))

(ert-deftest portal-excalidraw-mode-line-follows-the-screen-the-page-shows ()
  (portal-excalidraw-test--buffer
    (portal-excalidraw--message (list :type "loaded" :json portal-excalidraw--empty))
    (should (equal portal-excalidraw--mode "draw"))
    (should (equal (portal-excalidraw-test--screen-tag) ""))
    (portal-excalidraw--message '(:type "mode" :mode "arrange"))
    (should (equal portal-excalidraw--mode "arrange"))
    (should (equal (portal-excalidraw-test--screen-tag) ":Arrange"))
    ;; The keyboard's light still comes first.
    (should (eq (cadr mode-line-process) 'portal-input-mode-line-process))
    (let ((unread-command-events nil))
      (portal-excalidraw--message '(:type "mode" :mode "present")))
    (should (equal (portal-excalidraw-test--screen-tag) ":Present"))
    (portal-excalidraw--message '(:type "mode" :mode "slideshow"))
    (should (equal portal-excalidraw--mode "present"))
    (should-not portal-excalidraw--error)
    (portal-excalidraw--message '(:type "mode" :mode "draw"))
    (should (equal (portal-excalidraw-test--screen-tag) ""))
    (should-not (buffer-modified-p))))

(ert-deftest portal-excalidraw-arrange-and-draw-ask-the-page-for-their-screen ()
  (portal-excalidraw-test--buffer
    (let (sent)
      (cl-letf (((symbol-function 'portal-web-send) (lambda (message) (push message sent))))
        (should-error (portal-excalidraw-arrange) :type 'user-error)
        (should-not sent)
        (setq portal-excalidraw--ready t)
        (portal-excalidraw-arrange)
        (should (equal (pop sent) '(:type "mode" :mode "arrange")))
        ;; The mode line waits for the page to say so.
        (should (equal portal-excalidraw--mode "draw"))
        (portal-excalidraw-draw)
        (should (equal (pop sent) '(:type "mode" :mode "draw")))
        (setq portal-excalidraw--error "WebKit stopped")
        (should-error (portal-excalidraw-arrange) :type 'user-error)
        (should-not sent)
        (should-not (buffer-modified-p))))))

(ert-deftest portal-excalidraw-reopened-drawing-comes-back-in-the-editor ()
  (portal-excalidraw-test--buffer
    (setq portal-excalidraw--ready t)
    (portal-excalidraw--message '(:type "mode" :mode "arrange"))
    (cl-letf (((symbol-function 'portal-excalidraw--flush) #'ignore)
              ((symbol-function 'portal-excalidraw--start) #'ignore))
      (portal-excalidraw-reopen))
    (should (equal portal-excalidraw--mode "draw"))
    ;; So does a page that loads again by itself.
    (portal-excalidraw--message '(:type "mode" :mode "arrange"))
    (cl-letf (((symbol-function 'portal-web-send) #'ignore))
      (portal-excalidraw--message '(:type "ready")))
    (should (equal portal-excalidraw--mode "draw"))))

(ert-deftest portal-excalidraw-loads-the-drawing-into-its-hosted-app-over-the-bridge ()
  (portal-fake-native-reset)
  (cl-letf (((symbol-function 'portal-start-server) #'ignore)
            ((symbol-function 'portal-server-url) (lambda () "http://127.0.0.1:1/token")))
    (save-window-excursion
      (portal-excalidraw)
      (let ((buffer (current-buffer))
            (target (portal-view-target)))
        (unwind-protect
            (let ((state (portal--inspect target)))
              (should (equal (plist-get state :options) '(:inspectable t :hosted t)))
              (should (equal (plist-get state :url) "http://127.0.0.1:1/token/excalidraw/"))
              (portal-fake-native-post target "{\"type\":\"ready\"}")
              (portal-fake-native-send (format "bridge %s\n" target))
              (should (equal (json-parse-string (cadr (car (portal-fake-native-calls 'portal--web-send)))
                                                :object-type 'plist)
                             (list :type "load" :json portal-excalidraw--empty :name "untitled")))
              (portal-fake-native-post target (json-serialize (list :type "loaded" :json portal-excalidraw-test--scene)))
              (portal-fake-native-send (format "bridge %s\n" target))
              (should portal-excalidraw--ready)
              (should (string-match-p "base64,AAAA" (buffer-string))))
          (with-current-buffer buffer
            (setq portal-excalidraw--ready nil)
            (set-buffer-modified-p nil))
          (kill-buffer buffer))
        (should-not (portal-fake-native-targets))))))

;; Presenting: the slide window, its frame, and each way it ends.  The fake
;; module opens the window as WebKit would when the page calls window.open,
;; and a pane stands in for the frame, which batch Emacs cannot make.

(ert-deftest portal-excalidraw-present-asks-the-page-and-stops-presenting-asks-back ()
  (portal-excalidraw-test--buffer
    (let (sent)
      (cl-letf (((symbol-function 'portal-web-send) (lambda (message) (push message sent))))
        (should-error (portal-excalidraw-present) :type 'user-error)
        (setq portal-excalidraw--ready t)
        (portal-excalidraw-present)
        (should (equal (pop sent) '(:type "mode" :mode "present")))
        (should-error (portal-excalidraw-stop-presenting) :type 'user-error)
        (should-not sent)
        ;; A notice is said, and is no failure of the drawing.
        (let ((inhibit-message t))
          (portal-excalidraw--message '(:type "notice" :message "No slides")))
        (should-not portal-excalidraw--error)))))

(defvar portal-excalidraw-test--frames nil
  "The frames presenting asked to delete, newest first.")
(defvar portal-excalidraw-test--alist nil
  "The `display-buffer' alist the slide window was shown with.")

(defmacro portal-excalidraw-test--presenting (&rest body)
  "Run BODY with a drawing presenting, its slide window open.
In BODY, `drawing' is the drawing's buffer, `target' its view, `slides'
the slide window's buffer, `window' its view and `frame' the frame its
pane is in, and `pixelwise' what `frame-resize-pixelwise' was before.
Deleting a frame is recorded in `portal-excalidraw-test--frames'."
  (declare (indent 0))
  `(let ((initial-buffers (buffer-list))
         (pixelwise frame-resize-pixelwise)
         (portal-excalidraw-test--frames nil)
         (portal-excalidraw-test--alist nil)
         (display-buffer-alist nil)
         (unread-command-events nil))
     (portal-fake-native-reset)
     (cl-letf (((symbol-function 'portal-start-server) #'ignore)
               ((symbol-function 'portal-server-url) (lambda () "http://127.0.0.1:1/token"))
               ((symbol-function 'display-buffer-pop-up-frame)
                (lambda (buffer alist)
                  (setq portal-excalidraw-test--alist alist)
                  (or (display-buffer-pop-up-window buffer alist)
                      (display-buffer-use-some-window
                       buffer (cons '(inhibit-same-window . t) alist)))))
               ((symbol-function 'delete-frame)
                (lambda (frame &rest _)
                  (push frame portal-excalidraw-test--frames)
                  (run-hook-with-args 'delete-frame-functions frame))))
       (save-window-excursion
         (delete-other-windows)
         (unwind-protect
             (progn
               (portal-excalidraw)
               (let* ((drawing (current-buffer))
                      (target (portal-view-target)))
                 (portal-fake-native-post
                  target (json-serialize (list :type "loaded" :json portal-excalidraw--empty)))
                 (portal-fake-native-send (format "bridge %s\n" target))
                 (should portal-excalidraw--ready)
                 (portal-view-sync)
                 (portal-excalidraw-present)
                 ;; The page opens the slide window, then shows the console.
                 (let ((window (portal-fake-native-open-window
                                target "http://127.0.0.1:1/token/excalidraw/audience")))
                   (portal-fake-native-post target "{\"type\":\"mode\",\"mode\":\"present\"}")
                   (portal-fake-native-send (format "bridge %s\n" target))
                   (portal-excalidraw-test--run-events)
                   (let* ((slides (portal-view--target-buffer window))
                          (frame (window-frame (get-buffer-window slides))))
                     ,@body))))
           (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
             (when (buffer-live-p buffer) ; A drawing kills its slide window.
               (with-current-buffer buffer
                 (when (derived-mode-p 'portal-excalidraw-mode)
                   (setq portal-excalidraw--ready nil)
                   (set-buffer-modified-p nil)))
               (kill-buffer buffer)))
           (setq frame-resize-pixelwise pixelwise))))
     (should-not (portal-fake-native-targets))))

(defun portal-excalidraw-test--run-events ()
  "Run the commands that native records queued, as the command loop would."
  (while unread-command-events
    (let ((event (pop unread-command-events)))
      (funcall (lookup-key global-map (vector (car event))) event))))

(defun portal-excalidraw-test--sent (target)
  "The messages Emacs sent TARGET's page, oldest first, as plists."
  (mapcar (lambda (call) (json-parse-string (cadr call) :object-type 'plist))
          (seq-filter (lambda (call) (equal (car call) target))
                      (portal-fake-native-calls 'portal--web-send))))

(defun portal-excalidraw-test--told-to-arrange (target)
  "Whether TARGET's page was last told to show Arrange."
  (equal (car (last (portal-excalidraw-test--sent target))) '(:type "mode" :mode "arrange")))

(defun portal-excalidraw-test--gone (drawing slides frame)
  "Check that DRAWING's slide window SLIDES and its FRAME are gone."
  (should-not (buffer-live-p slides))
  (should (equal portal-excalidraw-test--frames (list frame)))
  (when (buffer-live-p drawing)
    (with-current-buffer drawing
      (should-not portal-excalidraw--slides)
      (should-not portal-excalidraw--slides-frame)
      (should-not (buffer-modified-p)))))

(ert-deftest portal-excalidraw-presenting-shows-the-slide-window-in-a-bare-frame ()
  (portal-excalidraw-test--presenting
    ;; The drawing keeps its slide window, a page with no bridge.
    (should (equal (buffer-local-value 'portal-web-opener slides) drawing))
    (with-current-buffer drawing
      (should (eq portal-excalidraw--slides slides))
      (should (eq portal-excalidraw--slides-frame frame))
      (should (equal portal-excalidraw--mode "present")))
    ;; Its frame has nothing of Emacs, and resizes to the pixel.
    (let ((parameters (alist-get 'pop-up-frame-parameters portal-excalidraw-test--alist)))
      (should (assq 'minibuffer parameters))
      (should-not (alist-get 'minibuffer parameters))
      (should (equal (alist-get 'tool-bar-lines parameters) 0))
      (should (equal (alist-get 'name parameters)
                     (format "%s: Slides" (buffer-name drawing)))))
    (should (eq (window-parameter (get-buffer-window slides) 'mode-line-format) 'none))
    (should frame-resize-pixelwise)
    ;; The console has the keyboard back.
    (should (eq (window-buffer) drawing))
    (should (plist-get (portal--inspect target) :focused))
    (should-not (plist-get (portal--inspect window) :focused))
    (should-not (buffer-modified-p drawing))))

(ert-deftest portal-excalidraw-stopping-closes-the-slide-window ()
  (portal-excalidraw-test--presenting
    (with-current-buffer drawing (portal-excalidraw-stop-presenting))
    (portal-excalidraw-test--gone drawing slides frame)
    (should (portal-excalidraw-test--told-to-arrange target))
    ;; The page answers that it shows Arrange.
    (portal-fake-native-post target "{\"type\":\"mode\",\"mode\":\"arrange\"}")
    (portal-fake-native-send (format "bridge %s\n" target))
    (with-current-buffer drawing
      (should (equal portal-excalidraw--mode "arrange"))
      (should-not portal-excalidraw--error))
    (should (equal portal-excalidraw-test--frames (list frame)))))

(ert-deftest portal-excalidraw-the-page-stopping-closes-the-slide-window ()
  ;; Escape or Stop in the console, or Escape in the slide window.
  (portal-excalidraw-test--presenting
    (let ((told (length (portal-excalidraw-test--sent target))))
      (portal-fake-native-post target "{\"type\":\"mode\",\"mode\":\"arrange\"}")
      (portal-fake-native-send (format "bridge %s\n" target))
      (portal-excalidraw-test--gone drawing slides frame)
      ;; The page is in Arrange already, and is not told again.
      (should (= (length (portal-excalidraw-test--sent target)) told)))))

(ert-deftest portal-excalidraw-killing-the-slide-window-stops-presenting ()
  (portal-excalidraw-test--presenting
    (kill-buffer slides)
    (portal-excalidraw-test--gone drawing slides frame)
    (should (portal-excalidraw-test--told-to-arrange target))))

(ert-deftest portal-excalidraw-deleting-the-slide-frame-stops-presenting ()
  (portal-excalidraw-test--presenting
    ;; The frame goes by itself: only Emacs hears it.
    (run-hook-with-args 'delete-frame-functions frame)
    (should-not (buffer-live-p slides))
    (should-not portal-excalidraw-test--frames)
    (with-current-buffer drawing
      (should-not portal-excalidraw--slides)
      (should-not portal-excalidraw--slides-frame))
    (should (portal-excalidraw-test--told-to-arrange target))))

(ert-deftest portal-excalidraw-the-slide-window-closing-itself-stops-presenting ()
  (portal-excalidraw-test--presenting
    (portal-fake-native-send (format "closed %s\n" window))
    (portal-excalidraw-test--run-events)
    (should-not (portal--inspect window))
    (should-not (buffer-live-p slides))
    (with-current-buffer drawing (should-not portal-excalidraw--slides))
    (should (memq frame portal-excalidraw-test--frames))
    (should (portal-excalidraw-test--told-to-arrange target))))

(ert-deftest portal-excalidraw-killing-the-drawing-kills-its-slide-window ()
  (portal-excalidraw-test--presenting
    (with-current-buffer drawing
      (setq portal-excalidraw--ready nil)
      (set-buffer-modified-p nil))
    (kill-buffer drawing)
    (portal-excalidraw-test--gone drawing slides frame)
    (should-not (portal--inspect window))
    ;; Frames resize as they did before presenting.
    (should (eq frame-resize-pixelwise pixelwise))))

(ert-deftest portal-excalidraw-a-new-major-mode-kills-the-slide-window ()
  (portal-excalidraw-test--presenting
    (with-current-buffer drawing
      (setq portal-excalidraw--ready nil)
      (fundamental-mode))
    (portal-excalidraw-test--gone drawing slides frame)))

(ert-deftest portal-excalidraw-reopening-the-drawing-kills-its-slide-window ()
  (portal-excalidraw-test--presenting
    (with-current-buffer drawing
      (cl-letf (((symbol-function 'portal-excalidraw--flush) #'ignore))
        (portal-excalidraw-reopen))
      (should (equal portal-excalidraw--mode "draw")))
    (portal-excalidraw-test--gone drawing slides frame)))

(ert-deftest portal-excalidraw-a-slide-window-not-shown-when-presenting-stopped-closes ()
  ;; Present, then Escape at once: the page opens the window and leaves
  ;; Present before Emacs gets to show the window.
  (portal-excalidraw-test--presenting
    (with-current-buffer drawing (portal-excalidraw-stop-presenting))
    (portal-fake-native-post target "{\"type\":\"mode\",\"mode\":\"arrange\"}")
    (portal-fake-native-send (format "bridge %s\n" target))
    (setq portal-excalidraw-test--frames nil)
    (let ((late (portal-fake-native-open-window
                 target "http://127.0.0.1:1/token/excalidraw/audience")))
      (dolist (mode '("present" "arrange"))
        (portal-fake-native-post target (json-serialize (list :type "mode" :mode mode)))
        (portal-fake-native-send (format "bridge %s\n" target)))
      (portal-excalidraw-test--run-events)
      ;; It is closed without being shown.
      (should-not (portal--inspect late))
      (should-not (portal-view--target-buffer late))
      (should-not portal-excalidraw-test--frames)
      (with-current-buffer drawing
        (should-not portal-excalidraw--slides)
        (should (equal portal-excalidraw--mode "arrange"))))
    ;; The next Present's window stays, even shown before the page says so.
    (let ((next (portal-fake-native-open-window
                 target "http://127.0.0.1:1/token/excalidraw/audience")))
      (portal-excalidraw-test--run-events)
      (should (buffer-live-p (portal-view--target-buffer next)))
      (with-current-buffer drawing
        (should (eq portal-excalidraw--slides (portal-view--target-buffer next)))))))

(ert-deftest portal-excalidraw-ending-a-drawing-closes-slide-windows-not-yet-shown ()
  ;; The page opened a window, and Emacs has not shown it when the drawing's
  ;; view closes: it must not outlive the drawing as a buffer of its own.
  (dolist (end (list (lambda (drawing) (kill-buffer drawing))
                     (lambda (drawing) (with-current-buffer drawing (fundamental-mode)))
                     (lambda (drawing)
                       (with-current-buffer drawing
                         (cl-letf (((symbol-function 'portal-excalidraw--flush) #'ignore))
                           (portal-excalidraw-reopen))))))
    (portal-excalidraw-test--presenting
      (let ((late (portal-fake-native-open-window
                   target "http://127.0.0.1:1/token/excalidraw/audience"))
            (buffers (length (buffer-list))))
        (with-current-buffer drawing
          (setq portal-excalidraw--ready nil)
          (set-buffer-modified-p nil))
        (funcall end drawing)
        (portal-excalidraw-test--run-events)
        (should-not (portal--inspect late))
        (should-not (portal-view--target-buffer late))
        (should-not (buffer-live-p slides))
        ;; Only the slide window's buffer went, and the drawing's if killed.
        (should (<= (length (buffer-list)) (1- buffers)))))))

(ert-deftest portal-excalidraw-presenting-again-after-reopening-shows-the-slide-window ()
  (portal-excalidraw-test--presenting
    ;; Present, and reopen before Emacs shows the window.
    (with-current-buffer drawing (portal-excalidraw-stop-presenting))
    (portal-fake-native-post target "{\"type\":\"mode\",\"mode\":\"arrange\"}")
    (portal-fake-native-send (format "bridge %s\n" target))
    (portal-fake-native-open-window target "http://127.0.0.1:1/token/excalidraw/audience")
    (portal-fake-native-post target "{\"type\":\"mode\",\"mode\":\"present\"}")
    (portal-fake-native-send (format "bridge %s\n" target))
    (with-current-buffer drawing
      (cl-letf (((symbol-function 'portal-excalidraw--flush) #'ignore))
        (portal-excalidraw-reopen)))
    (portal-excalidraw-test--run-events)
    ;; The new page presents.
    (let ((page (buffer-local-value 'portal-view--target drawing)))
      (portal-fake-native-post
       page (json-serialize (list :type "loaded" :json portal-excalidraw--empty)))
      (portal-fake-native-send (format "bridge %s\n" page))
      (let ((window (portal-fake-native-open-window
                     page "http://127.0.0.1:1/token/excalidraw/audience")))
        (portal-fake-native-post page "{\"type\":\"mode\",\"mode\":\"present\"}")
        (portal-fake-native-send (format "bridge %s\n" page))
        (portal-excalidraw-test--run-events)
        (should (buffer-live-p (portal-view--target-buffer window)))
        (with-current-buffer drawing
          (should (eq portal-excalidraw--slides (portal-view--target-buffer window)))
          (should (equal portal-excalidraw--mode "present")))))))

(ert-deftest portal-excalidraw-a-page-that-loads-again-ends-presenting ()
  (portal-excalidraw-test--presenting
    (portal-fake-native-post target "{\"type\":\"ready\"}")
    (portal-fake-native-send (format "bridge %s\n" target))
    (portal-excalidraw-test--gone drawing slides frame)
    (with-current-buffer drawing (should (equal portal-excalidraw--mode "draw")))))

(provide 'portal-excalidraw-tests)
