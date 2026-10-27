;;; portal-server-tests.el --- App host process seam -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Emacs starts, handshakes with, restarts and stops the host. What the host
;; serves is tested in Bun, beside it: see host/*.test.ts.

(require 'ert)
(require 'url)
(require 'portal-server)

(when-let* ((program (getenv "PORTAL_TEST_HOST")))
  (setq portal-server-program program))

(defun portal-server-test--wait (predicate)
  "Allow asynchronous process work until PREDICATE succeeds."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defmacro portal-server-test--with-host (&rest body)
  (declare (indent 0))
  `(let ((portal-server-ready-hook nil))
     (unwind-protect (progn ,@body)
       (let ((process portal--server-process))
         (portal-stop-server)
         (when process
           (portal-server-test--wait (lambda () (not (process-live-p process)))))))))

(defun portal-server-test--get (path)
  "Fetch PATH from the real HTTP listener."
  (let* ((url-proxy-services nil)
         (buffer (url-retrieve-synchronously
                  (concat (portal-server-url) path) t t 3)))
    (should (buffer-live-p buffer))
    (unwind-protect
        (with-current-buffer buffer (buffer-string))
      (kill-buffer buffer))))

(ert-deftest portal-server-load-is-lazy ()
  (should-not (portal-server-url))
  (let ((before (process-list)))
    (load "portal-server" nil t)
    (should (equal before (process-list)))))

(ert-deftest portal-server-starts-once-and-reports-its-url ()
  (portal-server-test--with-host
    (let ((process (portal-start-server)))
      ;; Two simultaneous startup requests must share one child.
      (should (eq process (portal-start-server)))
      (portal-server-test--wait #'portal-server-url)
      (should (eq process (portal-start-server)))
      (should (string-match-p "\\`http://127\\.0\\.0\\.1:[0-9]+/[[:xdigit:]]\\{32\\}\\'"
                              (portal-server-url)))
      (should (string-match-p "HTTP/1.1 200" (portal-server-test--get "/hello")))
      (portal-stop-server)
      (portal-server-test--wait (lambda () (not (process-live-p process))))
      (should (= (process-exit-status process) 0)))))

(ert-deftest portal-server-restarts-and-recovers-after-a-crash ()
  (portal-server-test--with-host
    (let ((first (portal-start-server)))
      (portal-server-test--wait #'portal-server-url)
      (let ((second (portal-restart-server)))
        (should-not (eq first second))
        (portal-server-test--wait #'portal-server-url)
        (portal-server-test--wait (lambda () (not (process-live-p first))))
        ;; The old child's exit must leave the replacement server usable.
        (should (string-match-p "HTTP/1.1 200" (portal-server-test--get "/hello")))
        (signal-process second 'SIGKILL)
        (portal-server-test--wait (lambda () (not (portal-server-url))))
        (should-not portal--server-process)
        (let ((third (portal-start-server)))
          (should-not (eq second third))
          (portal-server-test--wait #'portal-server-url)
          (should (string-match-p "HTTP/1.1 200" (portal-server-test--get "/hello"))))))))

(ert-deftest portal-server-startup-timeout-cleans-up ()
  (let ((portal-server-program "/bin/cat")
        (portal-server-start-timeout 0.05))
    (portal-server-test--with-host
      (let ((process (portal-start-server)))
        (portal-server-test--wait (lambda () (not (process-live-p process))))
        (should-not (portal-server-url))
        (should-not portal--server-process)))))

(ert-deftest portal-server-early-exit-clears-startup ()
  (let ((portal-server-program "/usr/bin/false"))
    (portal-server-test--with-host
      (let ((process (portal-start-server)))
        ;; The sentinel runs after the process is seen to exit.
        (portal-server-test--wait (lambda () (not (process-live-p process))))
        (portal-server-test--wait (lambda () (not portal--server-process)))
        (should-not (portal-server-url))))))

(ert-deftest portal-server-readiness-can-arrive-in-pieces ()
  (let ((program (make-temp-file "portal-handshake-")))
    (unwind-protect
        (progn
          (with-temp-file program
            (insert "#!/bin/sh\nprintf '%s' '{\"type\":\"ready\",'\nsleep 0.05\n"
                    "printf '%s\\n' '\"protocol\":3,\"port\":12345,\"token\":\"0123456789abcdef0123456789abcdef\"}'\ncat >/dev/null\n"))
          (set-file-modes program #o700)
          (let ((portal-server-program program))
            (portal-server-test--with-host
              (portal-start-server)
              (portal-server-test--wait #'portal-server-url)
              (should (equal (portal-server-url)
                             "http://127.0.0.1:12345/0123456789abcdef0123456789abcdef")))))
      (delete-file program))))

(ert-deftest portal-server-rejects-incompatible-handshake ()
  (let ((program (make-temp-file "portal-handshake-")))
    (unwind-protect
        (progn
          (with-temp-file program
            (insert "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"ready\",\"protocol\":1,\"port\":12345}'\n"
                    "exec cat >/dev/null\n"))
          (set-file-modes program #o700)
          (let ((portal-server-program program))
            (portal-server-test--with-host
              (let ((process (portal-start-server)))
                (portal-server-test--wait (lambda () (not (process-live-p process))))
                (should-not (portal-server-url))))))
      (delete-file program))))

;;; portal-server-tests.el ends here
