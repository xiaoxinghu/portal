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
(require 'bookmark)

(defvar desktop-save-buffer)

(declare-function portal--rex-open "portal-rex" (path name version))
(declare-function portal--rex-request "portal-rex" (id method payload))
(declare-function portal--rex-receive "portal-rex" (id))
(declare-function portal--rex-wait "portal-rex" (id milliseconds))
(declare-function portal--rex-close "portal-rex" (id))

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
their answers: attaching, claiming the block, asking its terminal's
title, directory and processes, sizing it, a ticket for its stream, its
screen in VT form read in parts, typing and a focus event.  The block's
program runs and has set no title; its screen in VT form, with its
palette, is longer than 16 bytes."
  (let ((attached (portal-rex-call connection "session.attach" (list :session_id session-id))))
    (should (string-prefix-p "client:" (plist-get attached :client_id)))
    (should (plist-member attached :view)))
  (let ((owners (plist-get (portal-rex-call connection "session.own_block"
                                            (list :session_id session-id :block_ids (vector block-id)
                                                  :mode "take"))
                           :blocks)))
    (should (equal (plist-get (aref owners 0) :block_id) block-id)))
  (let ((block (list :session_id session-id :block_id block-id)))
    ;; What the terminal reports, which its events then follow.
    (should (equal (portal-rex-call connection "com.superlogical.terminal.title"
                                    (append block '(:args nil)))
                   '(:title "")))
    (let ((pwd (portal-rex-call connection "com.superlogical.terminal.pwd"
                                (append block '(:args nil)))))
      (should (or (null pwd) (stringp (plist-get pwd :pwd)))))
    (let* ((process (portal-rex-call connection "com.superlogical.terminal.process"
                                     (append block '(:args nil))))
           (foreground (plist-get process :foreground)))
      (should (eq (plist-get process :last_exit) :null))
      (when foreground
        (should (integerp (plist-get foreground :pid)))
        (should (stringp (or (plist-get foreground :script) (plist-get foreground :argv0)
                             (plist-get foreground :name))))))
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

(defun portal-rex-parity--open (socket)
  "Connect to the Rex server on SOCKET as another client, and return its ID.
It is a client of its own, as Rex's app is, reached through the native
module's connection primitives alone, outside `portal-rex-connections'."
  (let ((id (portal--rex-open socket "Parity" "1"))
        welcome)
    (while (not welcome)
      (unless (portal--rex-wait id 5000) (error "No welcome from the Rex server"))
      (dolist (text (cdr (portal--rex-receive id)))
        (let ((message (json-parse-string text :object-type 'plist :null-object nil)))
          (when (equal (plist-get message :type) "welcome") (setq welcome message)))))
    (cons id (plist-get (plist-get welcome :client) :id))))

(defun portal-rex-parity--call (other method payload)
  "Call METHOD with PAYLOAD as the client OTHER, and return its result.
Signal an error with the server's message if it fails."
  (let ((number (number-to-string
                 (portal--rex-request (car other) method (json-serialize payload))))
        response)
    (while (not response)
      (unless (portal--rex-wait (car other) 5000) (error "No answer to %s" method))
      (dolist (text (cdr (portal--rex-receive (car other))))
        (let ((message (json-parse-string text :object-type 'plist :null-object nil)))
          (when (equal (plist-get message :id) number) (setq response message)))))
    (when (plist-get response :error)
      (error "%s: %s" method (plist-get (plist-get response :error) :message)))
    (plist-get response :payload)))

(defun portal-rex-parity-check-owners (connection socket session-id block-id)
  "Check how the block BLOCK-ID of SESSION-ID follows its owner's size.
Emacs's CONNECTION and another client, on the server at SOCKET, claim
and size the block in turn, as the native module claims a shown block
and sends its pane's size: the block has its owner's size, a client's
size waits until it owns the block, and the server tells CONNECTION of
each change of owner.  CONNECTION has attached to the session, and
nothing else claims the block meanwhile."
  (let* ((me (plist-get (plist-get (portal-rex-connection-welcome connection) :client) :id))
         (block (list :session_id session-id :block_id block-id))
         (owner (lambda (result)
                  (should (equal (plist-get (aref (plist-get result :blocks) 0) :block_id) block-id))
                  (plist-get (aref (plist-get result :blocks) 0) :owner)))
         (grid (lambda ()
                 (let ((size (portal-rex-call connection "com.superlogical.terminal.size"
                                              (append block '(:args nil)))))
                   (list (plist-get size :columns) (plist-get size :rows)))))
         (resize (lambda (call columns rows)
                   (funcall call "com.superlogical.terminal.resize"
                            (append block (list :args (list :columns columns :rows rows
                                                            :cell_width_px 8 :cell_height_px 16))))))
         (events nil)
         (portal-rex-event-functions
          (list (lambda (_connection event)
                  (let ((inner (plist-get (plist-get (plist-get event :payload) :payload) :event)))
                    (when (and (equal (plist-get inner :type) "block_owner_changed")
                               (equal (plist-get (plist-get inner :payload) :block_id) block-id))
                      (push (plist-get inner :payload) events))))))
         (other (portal-rex-parity--open socket)))
    (unwind-protect
        (let ((call (lambda (method payload) (portal-rex-call connection method payload)))
              (as-other (lambda (method payload) (portal-rex-parity--call other method payload))))
          ;; Emacs takes the block at its size.
          (should (equal (funcall owner (portal-rex-call connection "session.own_block"
                                                         (list :session_id session-id
                                                               :block_ids (vector block-id)
                                                               :mode "take")))
                         me))
          (funcall resize call 90 30)
          (should (equal (funcall grid) '(90 30)))
          ;; The other client asks for a size and requests the block: it
          ;; stays Emacs's, at Emacs's size.
          (funcall as-other "session.attach" (list :session_id session-id))
          (funcall resize as-other 70 20)
          (should (equal (funcall owner (funcall as-other "session.own_block"
                                                 (list :session_id session-id
                                                       :block_ids (vector block-id)
                                                       :mode "request")))
                         me))
          (should (equal (funcall grid) '(90 30)))
          ;; It takes the block: the block has its size, with no other call,
          ;; and Emacs hears of the new owner.
          (setq events nil)
          (should (equal (funcall owner (funcall as-other "session.own_block"
                                                 (list :session_id session-id
                                                       :block_ids (vector block-id)
                                                       :mode "take")))
                         (cdr other)))
          (should (equal (funcall grid) '(70 20)))
          (portal-rex-call connection "server.version")
          (should (equal (mapcar (lambda (event) (list (plist-get event :owner) (plist-get event :reason)))
                                 events)
                         (list (list (cdr other) "take"))))
          ;; Emacs's size while it does not own the block waits; a request
          ;; does not win it back.
          (funcall resize call 100 32)
          (should (equal (funcall grid) '(70 20)))
          (should (equal (funcall owner (portal-rex-call connection "session.own_block"
                                                         (list :session_id session-id
                                                               :block_ids (vector block-id)
                                                               :mode "request")))
                         (cdr other)))
          ;; Another client's name, as client.inspect gives it.
          (should (equal (plist-get (plist-get (plist-get (portal-rex-call connection "client.inspect"
                                                                           (list :client_id (cdr other)))
                                                          :client)
                                               :info)
                                    :name)
                         "Parity"))
          ;; A take alone gives Emacs its size back.
          (setq events nil)
          (should (equal (funcall owner (portal-rex-call connection "session.own_block"
                                                         (list :session_id session-id
                                                               :block_ids (vector block-id)
                                                               :mode "take")))
                         me))
          (should (equal (funcall grid) '(100 32)))
          (should (equal (mapcar (lambda (event) (plist-get event :owner)) events) (list me)))
          ;; The other client takes the block and leaves: the block comes
          ;; back to Emacs, in line for it, at Emacs's size.
          (funcall as-other "session.own_block"
                   (list :session_id session-id :block_ids (vector block-id) :mode "take"))
          (should (equal (funcall grid) '(70 20)))
          (setq events nil)
          (portal--rex-close (car other))
          (setq other nil)
          (let ((deadline (+ (float-time) 5)))
            (while (and (not events) (< (float-time) deadline))
              (portal-rex-call connection "server.version")))
          (should (equal (mapcar (lambda (event) (list (plist-get event :owner) (plist-get event :reason)))
                                 events)
                         (list (list me "disconnect"))))
          (should (equal (funcall grid) '(100 32))))
      (when other (portal--rex-close (car other))))))

(defun portal-rex-parity-check-reattach (connection block-id)
  "Check that the block BLOCK-ID's buffer finds it again by ID after Emacs reconnects.
CONNECTION is to the block's server, which disconnects.  The desktop's
record makes a placeholder without the server; restoring connects
without waiting, and the placeholder becomes the block's buffer, under
its name; a bookmark jumps to it.  Return the new connection."
  (let* ((socket (portal-rex-connection-socket connection))
         (old (portal-rex-block-buffer connection block-id))
         (name (buffer-name old))
         (record (with-current-buffer old (funcall desktop-save-buffer nil)))
         (bookmark (with-current-buffer old (portal-rex-bookmark-make-record)))
         placeholder again)
    (should (equal (alist-get 'block record) block-id))
    (should (equal (alist-get 'server record) (abbreviate-file-name socket)))
    (portal-rex-disconnect connection)
    (should-not (buffer-live-p old))
    (setq placeholder (portal-rex-desktop-restore nil name record))
    (unwind-protect
        (progn
          (should (equal (buffer-name placeholder) name))
          (should (eq (buffer-local-value 'major-mode placeholder) 'portal-rex-placeholder-mode))
          (should (string-search block-id (with-current-buffer placeholder (buffer-string))))
          (portal-rex--restore)
          (setq again (cl-find socket portal-rex--connections
                               :key #'portal-rex-connection-socket :test #'equal))
          (should again)
          (should (portal-rex--await again (lambda () (not (portal-rex-connection-opening again)))
                                     10))
          (should (portal-rex-live-p again))
          (should (eq (portal-rex-block-buffer again block-id) placeholder))
          (with-current-buffer placeholder
            (should (eq major-mode 'portal-terminal-mode))
            (should (equal portal-rex-block-id block-id))
            (should (equal (buffer-name) name)))
          (should (eq (save-current-buffer (portal-rex-bookmark-jump bookmark) (current-buffer))
                      placeholder))
          again)
      (when (buffer-live-p placeholder)
        (with-current-buffer placeholder
          (unless portal-rex-block-id (kill-buffer placeholder)))))))

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

(defun portal-rex-parity-check-kill (connection session-id block-id)
  "Check that killing the buffer of an idle block ends it, without a question.
The block BLOCK-ID of SESSION-ID on CONNECTION's server runs a shell at
its prompt, under login, as a shell block on macOS does; nothing else
changes the session meanwhile.  The two replies Portal asks for have the
shapes it relies on, the block reads as idle, its buffer goes at once,
and the block closes on the server."
  (let* ((block (list :session_id session-id :block_id block-id :args nil))
         (mode (portal-rex-call connection "com.superlogical.terminal.input_mode" block))
         (process (portal-rex-call connection "com.superlogical.terminal.process" block))
         (child (plist-get process :child))
         (foreground (plist-get process :foreground))
         (buffer (portal-rex-block-buffer connection block-id))
         (blocks (portal-rex-connection-blocks connection)))
    ;; A line editor reads: raw input, with signals.
    (should (equal (list (plist-get mode :echo) (plist-get mode :canonical) (plist-get mode :signals))
                   '(:false :false t)))
    ;; The shell is login's direct child.
    (should (eq (plist-get process :last_exit) :null))
    (should (equal (plist-get child :name) "login"))
    (should (eql (plist-get child :user_id) 0))
    (should (integerp (plist-get foreground :pid)))
    (should (string-prefix-p "-" (plist-get foreground :argv0)))
    (should (equal (mapcar (lambda (process) (plist-get process :pid))
                           (plist-get process :ancestors))
                   (list (plist-get child :pid))))
    (should (equal (portal-rex--block-state connection session-id block-id)
                   (list :state 'idle :program (file-name-nondirectory
                                                (substring (plist-get foreground :argv0) 1)))))
    ;; Killed with the option at its default, it asks nothing, and goes.
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (prompt) (ert-fail (list "Asked" prompt)))))
      (let ((portal-terminal-confirm-kill t))
        (should (kill-buffer buffer))))
    (should-not (buffer-live-p buffer))
    ;; The block closes, and its event finds the buffer gone.
    (should (portal-rex--await connection (lambda () (not (gethash block-id blocks))) 5))
    (should-not (seq-find (lambda (listed) (equal (plist-get listed :block_id) block-id))
                          (plist-get (portal-rex-call connection "session.list_blocks"
                                                      (list :session_id session-id))
                                     :blocks)))))

(provide 'portal-rex-parity)
;;; portal-rex-parity.el ends here
