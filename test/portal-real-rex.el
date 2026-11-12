;;; portal-real-rex.el --- Start throwaway real Rex servers for tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; The harness of the real-server tier, test/rex-server-gui.sh.  Each server
;; is Rex's own program, PORTAL_TEST_REX, run on a socket in a temporary
;; directory of its own, in PORTAL_TEST_REX_DIRECTORY when that is set,
;; which is also its home and its state, with no
;; configuration and nothing restored or saved: it touches no other Rex
;; server and none of a user's Rex state, and stopping it ends its blocks.
;; Its `rex' commands, through `portal-real-rex-cli', reach it alone.
;; test/portal-fake-rex.el drives the fake server, which tests use unless
;; the real server's behaviour is the point.

(require 'cl-lib)

(cl-defstruct (portal-real-rex (:constructor portal-real-rex--make) (:copier nil))
  "A running throwaway Rex server."
  process
  (socket nil :documentation "The Unix socket it listens on.")
  directory)

(defun portal-real-rex-program ()
  "Return the rex program that PORTAL_TEST_REX names, or signal an error."
  (let ((program (getenv "PORTAL_TEST_REX")))
    (unless (and program (file-executable-p program))
      (error "Set PORTAL_TEST_REX to Rex Server's rex program, not %S" program))
    program))

(defun portal-real-rex--environment (directory)
  "Return `process-environment' for rex run by the server in DIRECTORY.
Its home is in DIRECTORY, and no variable of Rex or XDG's leads it to
another server or to the user's files."
  (cons (concat "HOME=" (expand-file-name "home" directory))
        (cl-remove-if (lambda (variable)
                        (string-match-p "\\`\\(?:HOME\\|REX_[A-Z_]*\\|XDG_[A-Z_]*\\)=" variable))
                      process-environment)))

(defun portal-real-rex--output (server)
  "Return what SERVER has printed so far."
  (with-current-buffer (process-buffer (portal-real-rex-process server)) (buffer-string)))

(defun portal-real-rex-start ()
  "Start a Rex server of its own and return it once it is ready."
  (let* ((directory (let ((temporary-file-directory
                            (file-name-as-directory
                             (or (getenv "PORTAL_TEST_REX_DIRECTORY") temporary-file-directory))))
                       (make-temp-file "rex" t)))
         (server (portal-real-rex--make :directory directory
                                        :socket (expand-file-name "s" directory)))
         (process-environment (portal-real-rex--environment directory))
         ;; Its home is another, so "~" must not appear in its directory.
         (default-directory (file-name-as-directory directory))
         (deadline (+ (float-time) 10))
         ready)
    (unwind-protect
        (progn
          (make-directory "home")
          (setf (portal-real-rex-process server)
                (make-process :name "rex-server" :noquery t :connection-type 'pipe
                              :buffer (generate-new-buffer " *rex-server*")
                              :command (list (portal-real-rex-program) "server" "run"
                                             "--listen" (concat "unix://" (portal-real-rex-socket server))
                                             "--state-dir" (expand-file-name "state")
                                             "--restore=false" "--config" "/dev/null")))
          (while (not (setq ready (string-search "Rex server ready"
                                                 (portal-real-rex--output server))))
            (when (or (> (float-time) deadline)
                      (not (process-live-p (portal-real-rex-process server))))
              (error "The Rex server did not start: %s" (portal-real-rex--output server)))
            (accept-process-output (portal-real-rex-process server) 0.05))
          server)
      (unless ready (portal-real-rex-stop server)))))

(defun portal-real-rex-stop (server)
  "Stop SERVER, which ends its blocks' programs, and remove its directory."
  (when-let* ((process (portal-real-rex-process server)))
    (let ((deadline (+ (float-time) 5)))
      (when (process-live-p process)
        (signal-process process 'TERM)
        (while (and (process-live-p process) (< (float-time) deadline))
          (accept-process-output process 0.05))
        (delete-process process))
      (kill-buffer (process-buffer process))))
  (delete-directory (portal-real-rex-directory server) t))

(defun portal-real-rex-cli (server &rest arguments)
  "Run rex with ARGUMENTS against SERVER alone, and return what it printed.
With \"--json\" among ARGUMENTS, return the output parsed, objects as
plists.  Signal an error with the output when rex fails."
  (let ((process-environment (portal-real-rex--environment (portal-real-rex-directory server)))
        (default-directory (file-name-as-directory (portal-real-rex-directory server))))
    (with-temp-buffer
      (let ((status (apply #'call-process (portal-real-rex-program) nil t nil
                           "-S" (concat "unix://" (portal-real-rex-socket server))
                           "--autostart=false" arguments)))
        (unless (eql status 0)
          (error "rex %s failed (%s): %s" (string-join arguments " ") status (buffer-string)))
        (if (not (member "--json" arguments))
            (buffer-string)
          (goto-char (point-min))
          (json-parse-buffer :object-type 'plist))))))

(defmacro portal-real-rex-with (servers &rest body)
  "Run BODY with each symbol in SERVERS bound to a new Rex server.
The servers stop afterwards, whatever BODY does."
  (declare (indent 1))
  (if (null servers)
      `(progn ,@body)
    `(let ((,(car servers) (portal-real-rex-start)))
       (unwind-protect (portal-real-rex-with ,(cdr servers) ,@body)
         (portal-real-rex-stop ,(car servers))))))

(provide 'portal-real-rex)
;;; portal-real-rex.el ends here
