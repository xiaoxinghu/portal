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

(defun portal-rex-server-gui-tests--api (server method &rest payload)
  "Call METHOD with PAYLOAD on SERVER as another client, and return its result."
  (json-parse-string (portal-real-rex-cli server "api" "call" method (json-serialize payload))
                     :object-type 'plist))

(ert-deftest portal-rex-server-gui-buffers-follow-the-server ()
  :tags '(:gui)
  ;; What only a real server can show: which events it sends when another
  ;; client makes, relabels, detaches and closes blocks, and that the
  ;; buffers follow them.
  (portal-real-rex-with (server)
    (let* ((session (portal-rex-server-gui-tests--new-session server "work"))
           (connection (portal-rex-connect (portal-real-rex-socket server)))
           (names (lambda ()
                    (sort (mapcar #'buffer-name (portal-rex-buffers connection)) #'string<)))
           (named (lambda (&rest wanted)
                    (portal-rex-server-gui-tests--wait
                     (lambda () (equal (funcall names) wanted)))))
           (listed (lambda (session)
                     (mapcar (lambda (block)
                               (list (plist-get block :label) (plist-get block :placement)))
                             (plist-get (portal-rex-server-gui-tests--api
                                         server "session.list_blocks" :session_id session)
                                        :blocks)))))
      (unwind-protect
          (progn
            ;; The block the session started with, under the label the
            ;; server gave it.
            (should (equal (funcall names) '("*rex: work/shell*")))
            ;; Another client opens a window with one block.
            (let* ((made (portal-real-rex-cli server "run" "-s" "work" "--shell" "none"
                                              "--focus=false" "--label" "api" "--json"
                                              "--" "/bin/cat"))
                   (block (aref (plist-get made :block_ids) 0))
                   buffer)
              (funcall named "*rex: work/api*" "*rex: work/shell*")
              (setq buffer (portal-rex-block-buffer connection block))
              (should (equal (buffer-name buffer) "*rex: work/api*"))
              (with-current-buffer buffer
                (should (eq portal-rex-block-connection connection))
                (should (equal portal-rex-block-id block))
                (should (equal portal-rex-session-id session)))
              ;; It relabels the block in its window.
              (portal-rex-server-gui-tests--api server "session.set_block_label" :session_id session
                                                :block_id block :label "logs")
              (funcall named "*rex: work/logs*" "*rex: work/shell*")
              (should (eq (portal-rex-block-buffer connection block) buffer))
              ;; A detached block keeps its buffer.
              (portal-rex-server-gui-tests--api server "session.detach_block" :session_id session
                                                :block_id block)
              (should (equal (funcall listed session)
                             '(("shell" "placed") ("logs" "detached"))))
              (portal-rex-server-gui-tests--wait
               (lambda () (null (portal-rex-connection-lists connection))))
              (funcall named "*rex: work/logs*" "*rex: work/shell*")
              ;; Its new label sends no event: the buffer has it once
              ;; something else makes Portal ask, as renaming the session does.
              (portal-rex-server-gui-tests--api server "session.set_block_label" :session_id session
                                                :block_id block :label "hidden")
              (portal-rex-server-gui-tests--api server "session.set_label" :session_id session
                                                :label "play")
              (funcall named "*rex: play/hidden*" "*rex: play/shell*")
              (should (eq (portal-rex-block-buffer connection block) buffer))
              (should (equal (portal-rex-connection-sessions connection)
                             `[(:session_id ,session :label "play")]))
              ;; Closed, it loses its buffer.
              (portal-rex-server-gui-tests--api server "block.close" :session_id session
                                                :block_id block)
              (funcall named "*rex: play/shell*")
              (should-not (buffer-live-p buffer)))
            ;; A second session, with the same label as the first, and its
            ;; end.
            (let ((second (portal-rex-server-gui-tests--new-session server "play")))
              (funcall named "*rex: play/shell*" "*rex: play/shell*<2>")
              (should (equal (portal-rex-connection-sessions connection)
                             `[(:session_id ,session :label "play")
                               (:session_id ,second :label "play")]))
              (portal-rex-server-gui-tests--api server "session.destroy" :session_id session)
              (portal-rex-server-gui-tests--wait
               (lambda () (null (portal-rex-buffers connection session))))
              (should (equal (mapcar (lambda (buffer)
                                       (buffer-local-value 'portal-rex-session-id buffer))
                                     (portal-rex-buffers connection))
                             (list second)))
              (should (equal (portal-rex-connection-sessions connection)
                             `[(:session_id ,second :label "play")]))
              ;; Disconnecting kills the buffers and ends nothing.
              (portal-rex-disconnect connection)
              (should-not (portal-rex-buffers))
              (should (equal (funcall listed second) '(("shell" "placed"))))))
        (mapc #'portal-rex-disconnect (portal-rex-connections))))))

(provide 'portal-rex-server-gui-tests)
;;; portal-rex-server-gui-tests.el ends here
