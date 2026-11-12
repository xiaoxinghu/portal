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
The handshake, `server.version', `session.list' and `session.list_blocks',
with the buffers Portal made of them.  The server has at least one
session, the first of them at least one block, and none comes or goes
meanwhile."
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
      (should (stringp (plist-get session :label))))
    ;; A session's blocks, each of which has its buffer.
    (let* ((session (aref sessions 0))
           (blocks (plist-get (portal-rex-call connection "session.list_blocks"
                                               (list :session_id (plist-get session :session_id)))
                              :blocks)))
      (should (vectorp blocks))
      (should (> (length blocks) 0))
      (seq-doseq (block blocks)
        (should (string-prefix-p "block:" (plist-get block :block_id)))
        (should (stringp (plist-get block :label)))
        (should (stringp (plist-get block :placement)))
        (let ((buffer (portal-rex-block-buffer connection (plist-get block :block_id))))
          (should (string-prefix-p (format "*rex: %s/%s*" (plist-get session :label)
                                           (plist-get block :label))
                                   (buffer-name buffer)))
          (should (equal (buffer-local-value 'portal-rex-session-id buffer)
                         (plist-get session :session_id)))))))
  ;; A session the server does not have.
  (let ((failure (should-error
                  (portal-rex-call connection "session.list_blocks"
                                   '(:session_id "session:00000000-0000-7000-8000-000000000000"))
                  :type 'portal-rex-error)))
    (should (equal (plist-get (nth 2 failure) :code) "session_not_found"))
    (should (eql (plist-get (nth 2 failure) :status) 404)))
  (let ((failure (should-error (portal-rex-call connection "no.such_method")
                               :type 'portal-rex-error)))
    (should (equal (plist-get (nth 2 failure) :code) "method_not_found"))
    (should (stringp (plist-get (nth 2 failure) :message)))
    (should (eql (plist-get (nth 2 failure) :status) 404))))

(defun portal-rex-parity-check-block (connection session-id block-id)
  "Check the calls that show the block BLOCK-ID of SESSION-ID, as the core makes them.
The native module makes these calls itself, on CONNECTION, and reads
their answers: attaching, claiming the block, sizing it, a ticket for its
stream, its screen in VT form read in parts, typing and a focus event.
The block's screen in VT form, with its palette, is longer than 16 bytes."
  (let ((attached (portal-rex-call connection "session.attach" (list :session_id session-id))))
    (should (string-prefix-p "client:" (plist-get attached :client_id)))
    (should (plist-member attached :view)))
  (let ((owners (plist-get (portal-rex-call connection "session.own_block"
                                            (list :session_id session-id :block_ids (vector block-id)
                                                  :mode "take"))
                           :blocks)))
    (should (equal (plist-get (aref owners 0) :block_id) block-id)))
  (let ((block (list :session_id session-id :block_id block-id)))
    (should-not (portal-rex-call connection "com.superlogical.terminal.resize"
                                 (append block '(:args (:columns 81 :rows 25 :cell_width_px 8
                                                        :cell_height_px 16)))))
    ;; 16 bytes, written as 22 base64url characters.
    (should (string-match-p "\\`[A-Za-z0-9_-]\\{22\\}\\'"
                            (plist-get (portal-rex-call connection "data.connect"
                                                        (append block '(:data_ref_id "terminal"
                                                                        :subprotocol "rex.data.terminal.v1")))
                                       :ticket)))
    (let* ((first (portal-rex-call connection "com.superlogical.terminal.format"
                                   (append block '(:args (:format "vt" :extra_palette t
                                                          :max_bytes 16)))))
           (id (plist-get first :id))
           (content (plist-get first :content)))
      (should (stringp content))
      (should (<= (string-bytes content) 16))
      (should (integerp id))
      (let ((rest (portal-rex-call connection "com.superlogical.terminal.blob_read"
                                   (append block (list :args (list :id id :offset (string-bytes content)
                                                                   :max_bytes 16))))))
        (should (equal (plist-get rest :id) id))
        (should (stringp (plist-get rest :data)))
        (should (memq (plist-get rest :eof) '(t :false)))))
    (should (equal (portal-rex-call connection "com.superlogical.terminal.write"
                                    (append block '(:args (:data ""))))
                   '(:bytes_written 0)))
    (portal-rex-call connection "block.event"
                     (append block '(:event (:type "focus" :payload (:action "in")))))))

(provide 'portal-rex-parity)
;;; portal-rex-parity.el ends here
