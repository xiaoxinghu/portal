;;; portal-server.el --- Shared Bun UI host -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'json)
(require 'subr-x)
(require 'portal-build)

(defcustom portal-server-program nil
  "Standalone UI host executable, including its Bun runtime.
nil means the host in Portal's build, or in the runtime downloaded in its
place: see `portal-build-directory' and `portal-download-runtime'."
  :type '(choice (const :tag "Portal's build" nil) file)
  :group 'portal)

(defcustom portal-server-start-timeout 5
  "Seconds to wait asynchronously for the UI host to become ready."
  :type 'number
  :group 'portal)

(defun portal-server-program-file ()
  "Return the absolute file name of the UI host that `portal-start-server' runs."
  (expand-file-name (or portal-server-program (portal-build-native-file "portal-host"))))

(defvar portal-server-ready-hook nil
  "Hook run when the shared UI host is ready, including after a restart.")
(defvar portal--server-process nil "The shared UI host process, if started.")

(defun portal-server-url ()
  "Return the ready UI host's base URL, including its access token, or nil."
  (when (and portal--server-process
             (process-live-p portal--server-process))
    (process-get portal--server-process 'url)))

(defun portal--server-cancel-timer (process property)
  "Cancel PROCESS's timer stored in PROPERTY."
  (when-let* ((timer (process-get process property)))
    (cancel-timer timer)
    (process-put process property nil)))

(defun portal--server-report (text)
  "Record TEXT in the host log and report it in the echo area."
  (with-current-buffer (get-buffer-create "*portal-server*")
    (goto-char (point-max))
    (insert "\n" text "\n"))
  (message "%s (see *portal-server*)" text))

(defun portal--server-fail (process reason)
  "Terminate PROCESS after a startup failure with REASON."
  (process-put process 'failure reason)
  (when (process-live-p process) (delete-process process)))

(defun portal--server-record (process record)
  "Handle one parsed protocol RECORD from the current app host PROCESS."
  (let ((port (plist-get record :port)) (token (plist-get record :token)))
    (unless (and (not (process-get process 'url))
                 (equal (plist-get record :type) "ready")
                 (equal (plist-get record :protocol) 3)
                 (integerp port) (< 0 port 65536)
                 (stringp token)
                 (string-match-p "\\`[[:xdigit:]]\\{32\\}\\'" token))
      (error "Invalid UI host readiness message"))
    (process-put process 'url (format "http://127.0.0.1:%d/%s" port token))
    (portal--server-cancel-timer process 'startup-timer)
    (message "Portal UI server ready")
    (run-hooks 'portal-server-ready-hook)))

(defun portal--server-filter (process output)
  "Read newline-delimited JSON from PROCESS, including partial and batched records."
  (when (eq process portal--server-process)
    (condition-case err
        (let ((pending (concat (process-get process 'pending) output)) end)
          (while (setq end (string-match "\n" pending))
            (let ((line (substring pending 0 end)))
              (when (> (string-bytes line) 65536) (error "Oversized UI host record"))
              (setq pending (substring pending (1+ end)))
              (portal--server-record process (json-parse-string line :object-type 'plist))))
          (when (> (string-bytes pending) 65536) (error "Oversized UI host record"))
          (process-put process 'pending pending))
      (error (portal--server-fail process (error-message-string err))))))

(defun portal--server-sentinel (process event)
  "Handle PROCESS exiting with EVENT, without restarting it automatically."
  (when (memq (process-status process) '(exit signal failed))
    (portal--server-cancel-timer process 'startup-timer)
    (portal--server-cancel-timer process 'stop-timer)
    (when (eq process portal--server-process)
      (setq portal--server-process nil)
      (portal--server-report
       (format "Portal UI server stopped: %s"
               (or (process-get process 'failure) (string-trim event)))))))

;;;###autoload
(defun portal-start-server ()
  "Start the shared UI host asynchronously, or reuse the running process.
The ready hook runs after the server has bound its HTTP listener."
  (interactive)
  (unless (and portal--server-process (process-live-p portal--server-process))
    (unless portal-server-program
      ;; Linux has no hosted apps yet, so its build makes no host to offer.
      (unless portal-build--host
        (user-error "Portal has no hosted apps on %s yet, so it has no app host"
                    (if (eq system-type 'gnu/linux) "Linux" system-type)))
      ;; Portal's own host is usable only as part of a complete, current
      ;; build, or of the runtime that serves in its place.
      (portal-build-ensure))
    (let* ((program (portal-server-program-file))
           (default-directory (file-name-directory program)))
      (unless (file-executable-p program)
        (user-error "Build the Portal UI host with M-x portal-build: %s" program))
      (setq portal--server-process
            (make-process :name "portal-server" :command (list program)
                          :connection-type 'pipe :coding 'utf-8-unix :noquery t
                          :stderr (get-buffer-create "*portal-server*")
                          :filter #'portal--server-filter
                          :sentinel #'portal--server-sentinel))
      (let ((process portal--server-process))
        (process-put process 'startup-timer
                     (run-at-time portal-server-start-timeout nil
                                  (lambda ()
                                    (when (and (eq process portal--server-process)
                                               (not (process-get process 'url)))
                                      (portal--server-fail process "Startup timed out"))))))
      (message "Starting Portal UI server…")))
  portal--server-process)

;;;###autoload
(defun portal-stop-server ()
  "Stop the UI host, giving it a bounded interval to shut down gracefully."
  (interactive)
  (when-let* ((process portal--server-process))
    ;; Detach first: a late sentinel from this process must not reset a new host.
    (setq portal--server-process nil)
    (portal--server-cancel-timer process 'startup-timer)
    (when (process-live-p process)
      (process-put process 'stop-timer
                   (run-at-time 1.5 nil
                                (lambda ()
                                  (when (process-live-p process)
                                    (delete-process process)))))
      (process-send-eof process))))

;;;###autoload
(defun portal-restart-server ()
  "Restart the shared UI host.
Hosted apps that have already loaded keep their page; press g to reload one."
  (interactive)
  (portal-stop-server)
  (portal-start-server))

(defun portal--server-exit ()
  "Stop the host on Emacs exit without waiting for its event loop."
  (when (and portal--server-process (process-live-p portal--server-process))
    (process-send-eof portal--server-process)))

(add-hook 'kill-emacs-hook #'portal--server-exit)

(provide 'portal-server)
;;; portal-server.el ends here
