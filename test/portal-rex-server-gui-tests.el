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
    (let ((session (portal-rex-server-gui-tests--new-session server "parity"))
          (connection (portal-rex-connect (portal-real-rex-socket server))))
      (unwind-protect
          (progn
            (portal-rex-parity-check connection)
            (portal-rex-parity-check-block
             connection session
             (with-current-buffer (car (portal-rex-buffers connection session))
               portal-rex-block-id)))
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

(declare-function portal--terminal-text "portal-terminal" (target))
(declare-function portal--terminal-paste "portal-terminal" (target text &optional enter))
(declare-function portal-test-native-key "test-terminal-input" (code flags text &optional windowless))

(defun portal-rex-server-gui-tests--screen (server session block)
  "Return the screen and history of BLOCK in SESSION as SERVER has them, as text."
  (plist-get (portal-rex-server-gui-tests--api server "com.superlogical.terminal.format"
                                               :session_id session :block_id block
                                               :args '(:format "text"))
             :content))

(defun portal-rex-server-gui-tests--keys (&rest keys)
  "Type KEYS, each (CODE FLAGS TEXT), into the view with the keyboard."
  (dolist (key keys)
    (should (apply #'portal-test-native-key key))
    (accept-process-output nil 0.03)))

(ert-deftest portal-rex-server-gui-shows-a-block-and-types-in-it ()
  :tags '(:gui)
  ;; What only a real server shows: its first paint of a block that ran
  ;; before Emacs came, typing at its shell, and its answers to a program's
  ;; queries, which the terminal leaves to it, so the program gets one.
  (portal-real-rex-with (server)
    (let* ((session (plist-get (portal-real-rex-cli server "new" "shown" "--shell" "none" "--json"
                                                    "--" "/bin/sh")
                               :session_id))
           (connection (portal-rex-connect (portal-real-rex-socket server)))
           (buffer (car (portal-rex-buffers connection session)))
           (block (buffer-local-value 'portal-rex-block-id buffer))
           (screen (lambda () (portal-rex-server-gui-tests--screen server session block))))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            ;; Another client types into the block before Emacs shows it.
            (portal-rex-server-gui-tests--api server "com.superlogical.terminal.write"
                                              :session_id session :block_id block
                                              :args '(:data "echo before-$((6*7))\r"))
            (portal-rex-server-gui-tests--wait (lambda () (string-search "before-42" (funcall screen))))
            (switch-to-buffer buffer)
            (redisplay t)
            (let ((target portal-view--target)
                  (shows (lambda (text)
                           (portal-rex-server-gui-tests--wait
                            (lambda () (string-search text (portal--terminal-text portal-view--target)))))))
              (should target)
              (portal-rex-server-gui-tests--wait
               (lambda () (equal (plist-get (plist-get (portal--inspect target) :rex) :state) "live")))
              ;; The first paint has what the block showed, and the block has
              ;; the pane's size.
              (funcall shows "before-42")
              (let ((state (portal--inspect target))
                    (size (portal-rex-server-gui-tests--api
                           server "com.superlogical.terminal.size" :session_id session :block_id block)))
                (should (equal (list (plist-get size :columns) (plist-get size :rows))
                               (list (plist-get state :columns) (plist-get state :rows)))))
              ;; Typed in Emacs, it reaches the shell, and its output Emacs.
              (select-frame-set-input-focus (selected-frame))
              (portal-terminal-focus)
              (portal-rex-server-gui-tests--keys '(14 0 "e") '(8 0 "c") '(4 0 "h") '(31 0 "o")
                                                 '(49 0 " ") '(17 0 "t") '(16 0 "y")
                                                 '(35 0 "p") '(14 0 "e") '(2 0 "d") '(36 0 "\r"))
              (portal-rex-server-gui-tests--wait
               (lambda () (string-match-p "^typed$" (funcall screen))))
              (funcall shows "\ntyped\n")
              ;; A query: the server answers it, and the terminal does not.
              (portal--terminal-paste target "printf '\\033[c'; read -r a; printf 'got:%s:\\n' \"$a\" | cat -v" t)
              (funcall shows "^[[?")
              (portal--terminal-paste target " " t)
              (portal-rex-server-gui-tests--wait
               (lambda () (string-match-p "^got:" (funcall screen))))
              (should (string-match-p "^got:\\^\\[\\[\\?[0-9;]*c:$" (funcall screen)))
              ;; vim opens and quits, and leaves nothing behind for the shell.
              (portal--terminal-paste target "vim -u NONE -N" t)
              (portal-rex-server-gui-tests--wait
               (lambda () (string-match-p "^~" (funcall screen))))
              (funcall shows "\n~")
              (portal-rex-server-gui-tests--keys '(53 0 "\e") (list 41 (ash 1 17) ":") '(12 0 "q")
                                                 (list 18 (ash 1 17) "!") '(36 0 "\r"))
              (portal--terminal-paste target "echo after-vim" t)
              (portal-rex-server-gui-tests--wait
               (lambda () (string-match-p "^after-vim$" (funcall screen))))
              (should (string-match-p "\\$ echo after-vim$" (funcall screen)))
              (funcall shows "after-vim\n")
              ;; Emacs's screen is the server's.
              (let ((ours (portal--terminal-text target)))
                (dolist (line '("before-42" "typed" "after-vim"))
                  (should (string-match-p (format "^%s$" line) ours))))))
        (mapc #'portal-rex-disconnect (portal-rex-connections))))))

(provide 'portal-rex-server-gui-tests)
;;; portal-rex-server-gui-tests.el ends here
