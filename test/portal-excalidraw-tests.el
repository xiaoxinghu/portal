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

(provide 'portal-excalidraw-tests)
