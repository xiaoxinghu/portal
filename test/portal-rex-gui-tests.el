;;; portal-rex-gui-tests.el --- Rex connections in graphical Emacs -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; The seam that batch Emacs cannot show: with nobody waiting on a
;; connection, the native module tells Emacs through the notification pipe
;; that messages wait, from the main run loop.  The server is
;; test/fake-rex-server.py on a socket of its own, never the user's Rex
;; server; test/portal-rex-tests.el covers the client's behavior in batch.

(require 'ert)
(require 'portal-rex)
(require 'portal-fake-rex)

(defun portal-rex-gui-tests--wait (done)
  "Let Emacs idle, as between commands, until DONE returns non-nil.
Nothing here asks a connection for its messages: only the module's
record can bring them."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall done)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall done))))

(defun portal-rex-gui-tests--messages (function)
  "Call FUNCTION and return what it added to *Messages*."
  (let ((start (with-current-buffer (messages-buffer) (point-max))))
    (funcall function)
    (with-current-buffer (messages-buffer)
      (buffer-substring-no-properties start (point-max)))))

(ert-deftest portal-rex-gui-commands-connect-and-disconnect ()
  :tags '(:gui)
  (portal-fake-rex-with (server)
    (let* ((portal-rex-socket (portal-fake-rex-socket server))
           (name (abbreviate-file-name portal-rex-socket)))
      (unwind-protect
          (progn
            (should (equal (portal-rex-gui-tests--messages
                            (lambda () (call-interactively #'portal-rex-connect)))
                           (format "Connected to the Rex server at %s, which has 1 session\n"
                                   name)))
            (should (equal (plist-get (portal-rex-call nil "session.list") :sessions)
                           [(:session_id "session:fake-1" :label "fake")]))
            (should (equal (portal-rex-gui-tests--messages
                            (lambda () (call-interactively #'portal-rex-connect)))
                           (format "Already connected to the Rex server at %s\n" name)))
            (should (= (length (portal-rex-connections)) 1))
            (should (equal (portal-rex-gui-tests--messages
                            (lambda () (call-interactively #'portal-rex-disconnect)))
                           (format "Disconnected from the Rex server at %s\n" name)))
            (should (equal (plist-get (portal-fake-rex-take server :disconnected) :code) 1000))
            (should-not (portal-rex-connections))
            (should-error (call-interactively #'portal-rex-disconnect) :type 'user-error))
        (mapc #'portal-rex-disconnect (portal-rex-connections))))))

(ert-deftest portal-rex-gui-records-bring-messages-to-an-idle-emacs ()
  :tags '(:gui)
  (portal-fake-rex-with (left right)
    (let* (seen answers
           (portal-rex-event-functions
            (list (lambda (from event)
                    (push (cons from (plist-get (plist-get event :payload) :type)) seen))))
           (first (portal-rex-connect (portal-fake-rex-socket left)))
           (second (portal-rex-connect (portal-fake-rex-socket right))))
      (unwind-protect
          (progn
            ;; Events, from two servers, each with its connection, in order.
            (portal-fake-rex-command left :event '(:type "one"))
            (portal-fake-rex-command left :event '(:type "two"))
            (portal-fake-rex-command right :event '(:type "three"))
            (portal-rex-gui-tests--wait (lambda () (= (length seen) 3)))
            (should (equal (mapcar #'cdr (cl-remove second (reverse seen) :key #'car))
                           '("one" "two")))
            (should (equal (cl-remove first seen :key #'car) (list (cons second "three"))))
            ;; A call's answer runs its callback.
            (portal-rex-call-async first "session.list" nil
                                   (lambda (result failure) (push (list result failure) answers)))
            (portal-rex-call-async first "no.such_method" nil
                                   (lambda (result failure) (push (list result failure) answers)))
            (portal-rex-gui-tests--wait (lambda () (= (length answers) 2)))
            (should (plist-get (car (nth 1 answers)) :sessions))
            (should (equal (plist-get (cadr (nth 0 answers)) :code) "method_not_found"))
            ;; A waiting call takes its answer itself; the record that
            ;; follows it finds nothing and harms nothing.
            (should (portal-rex-call second "server.version"))
            (portal-rex-gui-tests--wait (lambda () t))
            (portal-fake-rex-command right :event '(:type "four"))
            (portal-rex-gui-tests--wait (lambda () (equal (cdar seen) "four")))
            ;; A server that goes is reported once, with Emacs idle, and the
            ;; other connection carries on.
            (let ((said (portal-rex-gui-tests--messages
                         (lambda ()
                           (portal-fake-rex-command left :drop t)
                           (portal-rex-gui-tests--wait
                            (lambda () (not (portal-rex-live-p first))))
                           (portal-rex-gui-tests--wait (lambda () t))))))
              (should (equal said
                             (format "Lost the Rex server at %s: The connection to the server was lost\n"
                                     (abbreviate-file-name (portal-fake-rex-socket left))))))
            (should (equal (portal-rex-connections) (list second)))
            (should (portal-rex-call second "session.list")))
        (mapc #'portal-rex-disconnect (portal-rex-connections))))))

(provide 'portal-rex-gui-tests)
;;; portal-rex-gui-tests.el ends here
