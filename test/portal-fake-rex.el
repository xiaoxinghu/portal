;;; portal-fake-rex.el --- Drive the fake Rex server from Emacs -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Starts test/fake-rex-server.py, which documents its commands and reports,
;; on a socket in a temporary directory, for tests of any tier: batch Emacs
;; and graphical.  A test scripts the server with `portal-fake-rex-command'
;; and reads what a client sent it with `portal-fake-rex-take'.  Tests never
;; connect to a real Rex server.

(require 'cl-lib)

(cl-defstruct (portal-fake-rex (:constructor portal-fake-rex--make) (:copier nil))
  "A running fake Rex server."
  process
  (socket nil :documentation "The Unix socket it listens on.")
  directory
  (reports nil :documentation "Its reports not yet taken, oldest first, as plists.")
  (pending "" :documentation "The start of a report whose end is still to come."))

(defconst portal-fake-rex--script
  (expand-file-name "fake-rex-server.py"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The fake server's program.")

(defun portal-fake-rex--filter (server text)
  "Add the reports that TEXT completes to SERVER's."
  (let* ((lines (split-string (concat (portal-fake-rex-pending server) text) "\n"))
         (complete (butlast lines)))
    (setf (portal-fake-rex-pending server) (car (last lines))
          (portal-fake-rex-reports server)
          (nconc (portal-fake-rex-reports server)
                 (mapcar (lambda (line) (json-parse-string line :object-type 'plist))
                         complete)))))

(defun portal-fake-rex-start ()
  "Start a fake Rex server and return it once it listens."
  (let* ((directory (make-temp-file "prx" t))
         (server (portal-fake-rex--make :directory directory
                                        :socket (expand-file-name "s" directory)))
         (process-connection-type nil))
    (setf (portal-fake-rex-process server)
          (make-process :name "fake-rex-server" :noquery t :connection-type 'pipe
                        :coding 'utf-8-unix
                        :command (list (or (getenv "PORTAL_TEST_PYTHON") "python3") "-B"
                                       portal-fake-rex--script (portal-fake-rex-socket server))
                        :stderr (get-buffer-create " *fake-rex-server errors*")
                        :filter (lambda (_process text)
                                  (portal-fake-rex--filter server text))))
    (portal-fake-rex-take server :listening)
    server))

(defun portal-fake-rex-stop (server)
  "Stop SERVER and remove its socket's directory."
  (when (process-live-p (portal-fake-rex-process server))
    (delete-process (portal-fake-rex-process server)))
  (delete-directory (portal-fake-rex-directory server) t))

(defun portal-fake-rex-command (server &rest command)
  "Send SERVER the COMMAND, a plist that `json-serialize' takes.
For example (:event (:type \"session_created\" :payload (...)))."
  (process-send-string (portal-fake-rex-process server)
                       (concat (json-serialize command) "\n")))

(defun portal-fake-rex-take (server key &optional seconds)
  "Wait for SERVER's next report that has KEY, and return it.
KEY is a keyword such as :hello, or a function that says whether a report
is the one.  Reports before it stay for a later take.  Fail after
SECONDS, by default 5."
  (let ((wanted (if (functionp key) key (lambda (report) (plist-member report key))))
        (deadline (+ (float-time) (or seconds 5)))
        found)
    (while (not (setq found (cl-find-if wanted (portal-fake-rex-reports server))))
      (when (or (> (float-time) deadline)
                (not (process-live-p (portal-fake-rex-process server))))
        (error "The fake Rex server reported no %s; it has %S, and said %S" key
               (portal-fake-rex-reports server)
               (with-current-buffer " *fake-rex-server errors*" (buffer-string))))
      (accept-process-output (portal-fake-rex-process server) 0.05))
    (setf (portal-fake-rex-reports server) (delq found (portal-fake-rex-reports server)))
    found))

(defun portal-fake-rex-request (server method)
  "Wait for the next request for METHOD that SERVER reports, and return it.
The request is a plist with :id, :method and :payload."
  (plist-get (portal-fake-rex-take
              server (lambda (report)
                       (equal (plist-get (plist-get report :request) :method) method)))
             :request))

(defmacro portal-fake-rex-with (servers &rest body)
  "Run BODY with each symbol in SERVERS bound to a new fake Rex server.
The servers stop afterwards, whatever BODY does."
  (declare (indent 1))
  (if (null servers)
      `(progn ,@body)
    `(let ((,(car servers) (portal-fake-rex-start)))
       (unwind-protect (portal-fake-rex-with ,(cdr servers) ,@body)
         (portal-fake-rex-stop ,(car servers))))))

(provide 'portal-fake-rex)
;;; portal-fake-rex.el ends here
