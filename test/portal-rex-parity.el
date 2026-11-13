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
(require 'portal-terminal)

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

(defun portal-rex-parity-check-sessions (connection directory)
  "Check the commands that change CONNECTION's server, and what it then says.
A session made, two terminals started in it in DIRECTORY, one of them
renamed, the session renamed and destroyed, each by Portal's own command
and each followed by the buffers.  The server has no session labelled
parity-made beforehand, and nothing else changes it meanwhile."
  (let* ((session (portal-rex-session-create connection "  parity-made "))
         (listed (lambda ()
                   (mapcar (lambda (block) (list (plist-get block :label) (plist-get block :placement)))
                           (plist-get (portal-rex-call connection "session.list_blocks"
                                                       (list :session_id session))
                                      :blocks))))
         (names (lambda ()
                  (sort (mapcar #'buffer-name (portal-rex-buffers connection session)) #'string<)))
         first second)
    ;; Made, trimmed, empty, and known at once.
    (should (string-prefix-p "session:" session))
    (should (equal (portal-rex-find-session connection "parity-made") session))
    (should (member (list :session_id session :label "parity-made")
                    (append (plist-get (portal-rex-call connection "session.list") :sessions) nil)))
    (should (equal (funcall listed) nil))
    ;; A label the server refuses, in its own words.
    (should (string-match-p "\\`Cannot rename Rex session parity-made: .+"
                            (cadr (should-error (portal-rex-session-rename connection session "a\nb")
                                                :type 'user-error))))
    ;; Two terminals, each in a window of its own, with their buffers.
    (save-window-excursion
      (setq first (portal-rex-new-terminal connection session directory)
            second (portal-rex-new-terminal connection session directory))
      (should (eq (window-buffer (selected-window)) second)))
    (should-not (eq first second))
    (dolist (buffer (list first second))
      (with-current-buffer buffer
        (should (eq portal-rex-block-connection connection))
        (should (equal portal-rex-session-id session))
        (should (equal default-directory (file-name-as-directory directory)))))
    (should (equal (funcall listed) '(("shell" "placed") ("shell" "placed"))))
    (should (equal (funcall names) '("*rex: parity-made/shell*" "*rex: parity-made/shell*<2>")))
    ;; One renamed as any terminal is, which relabels its block.
    (with-current-buffer second (portal-terminal-rename " api "))
    (should (equal (buffer-name second) "*rex: parity-made/api*"))
    (should (member '("api" "placed") (funcall listed)))
    ;; The session renamed, and its buffers with it.
    (portal-rex-session-rename connection session "parity-renamed")
    (should (equal (portal-rex--session-label connection session) "parity-renamed"))
    (should (equal (funcall names) '("*rex: parity-renamed/api*" "*rex: parity-renamed/shell*")))
    ;; Destroyed: its blocks end, and their buffers go.
    (should (portal-rex-session-destroy connection session))
    (should-not (buffer-live-p first))
    (should-not (buffer-live-p second))
    (should-not (portal-rex--session connection session))
    (should-not (seq-find (lambda (known) (equal (plist-get known :session_id) session))
                          (plist-get (portal-rex-call connection "session.list") :sessions)))))

(provide 'portal-rex-parity)
;;; portal-rex-parity.el ends here
