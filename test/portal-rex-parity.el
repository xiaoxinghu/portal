;;; portal-rex-parity.el --- What the fake and a real Rex server must both show -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Assertions that run against both servers: the fake, in the `rex' suite
;; (test/portal-rex-tests.el), and a real one, in the real-server tier
;; (test/portal-rex-server-gui-tests.el).  The fake is written from what a
;; real server was seen to send; when the real server moves on, these fail
;; there, and the fake is brought into line.  They check the shapes Portal
;; relies on, not values only one server has.

(require 'ert)
(require 'seq)
(require 'portal-rex)

(defun portal-rex-parity-check (connection)
  "Check what the server of CONNECTION says, as Portal relies on it.
The handshake, `server.version' and `session.list'.  The server has at
least one session, and none comes or goes meanwhile."
  (let ((welcome (portal-rex-connection-welcome connection)))
    (should (equal (plist-get welcome :type) "welcome"))
    (should (equal (plist-get welcome :protocol) "rex.control.v1"))
    ;; The revision Portal speaks, which a newer server translates to.
    (should (eql (plist-get welcome :api_revision) 12))
    (should (integerp (plist-get welcome :api_server_revision)))
    (should (>= (plist-get welcome :api_server_revision) 12))
    (should (string-prefix-p "client:" (plist-get (plist-get welcome :client) :id)))
    (should (stringp (plist-get (plist-get welcome :client) :reconnect_token)))
    (should (natnump (plist-get (plist-get welcome :limits) :max_message_bytes))))
  (let ((version (portal-rex-call connection "server.version")))
    (should (stringp (plist-get version :rex_version)))
    (should (stringp (plist-get version :platform)))
    (should (integerp (plist-get version :api_revision))))
  (let ((sessions (plist-get (portal-rex-call connection "session.list") :sessions)))
    (should (vectorp sessions))
    (should (> (length sessions) 0))
    (should (equal sessions (portal-rex-connection-sessions connection)))
    (seq-doseq (session sessions)
      (should (string-prefix-p "session:" (plist-get session :session_id)))
      (should (stringp (plist-get session :label)))))
  (let ((failure (should-error (portal-rex-call connection "no.such_method")
                               :type 'portal-rex-error)))
    (should (equal (plist-get (nth 2 failure) :code) "method_not_found"))
    (should (stringp (plist-get (nth 2 failure) :message)))
    (should (eql (plist-get (nth 2 failure) :status) 404))))

(provide 'portal-rex-parity)
;;; portal-rex-parity.el ends here
