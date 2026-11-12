;;; portal-rex-server-gui-tests.el --- Portal against a real Rex server -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; The real-server tier, run by test/rex-server-gui.sh in graphical Emacs:
;; what the fake cannot prove, that Portal and a real Rex server understand
;; each other.  Each test starts a throwaway server of its own through
;; test/portal-real-rex.el and stops it; none touches another server.  A
;; task that builds on a real server's behaviour adds its check here.

(require 'ert)
(require 'portal-rex)
(require 'portal-real-rex)
(require 'portal-rex-parity)

(defun portal-rex-server-gui-tests--wait (done)
  "Let Emacs idle until DONE returns non-nil, and fail after 10 seconds.
Messages arrive by the module's record, as between commands."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall done)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall done))))

(defun portal-rex-server-gui-tests--new-session (server label)
  "Create a session called LABEL on SERVER with rex, and return its ID.
Its one block runs cat, without a login shell."
  (plist-get (portal-real-rex-cli server "new" label "--shell" "none" "--json" "--" "/bin/cat")
             :session_id))

(ert-deftest portal-rex-server-gui-matches-the-fake ()
  :tags '(:gui)
  ;; The same checks run against the fake in the `rex' suite.
  (portal-real-rex-with (server)
    (portal-rex-server-gui-tests--new-session server "parity")
    (let ((connection (portal-rex-connect (portal-real-rex-socket server))))
      (unwind-protect (portal-rex-parity-check connection)
        (portal-rex-disconnect connection)))))

(ert-deftest portal-rex-server-gui-sees-a-session-made-elsewhere ()
  :tags '(:gui)
  (portal-real-rex-with (server)
    (let* (events
           (portal-rex-event-functions
            (list (lambda (_connection event) (push (plist-get event :payload) events))))
           (connection (portal-rex-connect (portal-real-rex-socket server))))
      (unwind-protect
          (progn
            (should (equal (portal-rex-connection-sessions connection) []))
            (should (equal (portal-rex-call connection "session.list") '(:sessions [])))
            ;; Another client makes a session; its event reaches an idle Emacs.
            (let* ((id (portal-rex-server-gui-tests--new-session server "elsewhere"))
                   (created
                    (lambda ()
                      (cl-find-if (lambda (event)
                                    (and (equal (plist-get event :type) "session_created")
                                         (equal (plist-get (plist-get (plist-get event :payload)
                                                                      :session)
                                                           :session_id)
                                                id)))
                                  events))))
              (portal-rex-server-gui-tests--wait created)
              (should (equal (plist-get (plist-get (plist-get (funcall created) :payload) :session)
                                        :label)
                             "elsewhere"))
              (should (equal (portal-rex-call connection "session.list")
                             `(:sessions [(:session_id ,id :label "elsewhere")])))
              ;; Disconnecting ends nothing on the server.
              (portal-rex-disconnect connection)
              (should-not (portal-rex-live-p connection))
              (should-not (portal-rex-connections))
              (should (equal (plist-get (portal-real-rex-cli server "ls" "--json") :sessions)
                             `[(:session_id ,id :label "elsewhere")]))))
        (mapc #'portal-rex-disconnect (portal-rex-connections))))))

(provide 'portal-rex-server-gui-tests)
;;; portal-rex-server-gui-tests.el ends here
