;;; portal-rex.el --- Connections to Rex servers -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Emacs as a client of Rex, the terminal multiplexer: a connection to a Rex
;; server, calls of its methods, and its events (docs/rex.md).  Nothing here
;; shows a terminal yet, and Portal's own terminals need no Rex.
;;
;; The native module carries the messages: a WebSocket over the server's Unix
;; socket, read off Emacs's thread (docs/architecture.md).  It says hello and
;; writes each request; this file reads what the server answers.  Messages
;; wait in the module until Emacs takes them, announced by a "rex ID" record
;; on the notification pipe, and are handled strictly in the order they
;; arrived: a response runs its callback, an event runs
;; `portal-rex-event-functions'.
;;
;; JSON crosses as `json-parse-string' and `json-serialize' have it, with
;; objects as plists: arrays are vectors, and null and false are `:null' and
;; `:false'.  What a method takes and returns is in Rex's own reference,
;; https://www.superlogical.com/rex/docs/reference/api.

(require 'cl-lib)
(require 'portal-view)

(declare-function portal--rex-open "portal-rex" (path name version))
(declare-function portal--rex-request "portal-rex" (id method payload))
(declare-function portal--rex-receive "portal-rex" (id))
(declare-function portal--rex-wait "portal-rex" (id milliseconds))
(declare-function portal--rex-close "portal-rex" (id))

(defgroup portal-rex nil
  "Rex servers, whose terminals outlive Emacs."
  :group 'portal
  :prefix "portal-rex-")

(defcustom portal-rex-socket "~/Library/Application Support/rex/server.sock"
  "The Unix socket of this Mac's Rex server.
`portal-rex-connect' connects to it unless given another."
  :type 'file)

(defcustom portal-rex-timeout 5
  "How many seconds to wait for a Rex server's answer.
`portal-rex-connect' waits this long for the server to take the
connection, and `portal-rex-call' for its response, unless given a
timeout of its own.  Emacs does nothing else meanwhile."
  :type 'number)

(defvar portal-rex-event-functions nil
  "Abnormal hook run for each event a Rex server sends.
Each function is called with the connection the event arrived on and the
event, a plist such as

  (:type \"event\" :seq 7
   :payload (:type \"session_created\"
             :payload (:session (:session_id \"session:01a1…\" :label \"work\"))))

Events of one connection arrive in the order the server sent them, their
`:seq' rising by one, and every function sees one event before any sees
the next.  An event of one session is wrapped again, as a
\"session_event\" whose payload names the session and holds the event.
The functions run from a process filter, or inside a `portal-rex-call'
that was waiting when the event arrived, in both cases with quitting
inhibited, so they must never prompt.  One that calls `portal-rex-call'
itself gets its answer; the events that arrive while it waits run once
it has returned.")

(define-error 'portal-rex-error "Rex error")

(cl-defstruct (portal-rex-connection (:constructor portal-rex--make-connection)
                                     (:copier nil))
  "A connection to a Rex server."
  (id nil :documentation "The native module's number for it, or nil once it has ended.")
  (socket nil :documentation "The server's Unix socket, an absolute file name.")
  (state 'connecting
         :documentation "`connecting', `attaching', `ready' or `closed'.")
  (welcome nil :documentation "The server's welcome, with the `:api_revision' it speaks.")
  (sessions nil
            :documentation "The server's sessions when the connection began to receive
events, a vector of plists with `:session_id' and `:label'.  Nothing
keeps it current.")
  (calls nil :documentation "Requests without a response, newest first, as (NUMBER . FUNCTION).")
  (inbox nil :documentation "Messages received and not yet handled, oldest first.")
  (held nil :documentation "Events that arrived before the sessions did, newest first.")
  (handling nil :documentation "Whether an event's functions are running.")
  (resume nil :documentation "The timer that will finish what a non-local exit left, or nil.")
  (reason nil :documentation "Why it ended, once it has, when anything said."))

(defvar portal-rex--connections nil
  "The connections that have not ended, oldest first.")

(defun portal-rex-connections ()
  "Return the connections to Rex servers that are ready, oldest first."
  (cl-remove-if-not #'portal-rex-live-p portal-rex--connections))

(defun portal-rex-live-p (connection)
  "Return non-nil if CONNECTION takes calls and delivers events."
  (and (portal-rex--ready-p connection) (portal-rex-connection-id connection) t))

(defun portal-rex--ready-p (connection)
  "Return non-nil if CONNECTION's events run the hook.
That outlasts `portal-rex-live-p' by the events that had arrived when the
connection ended, which run before it is reported lost."
  (eq (portal-rex-connection-state connection) 'ready))

(defun portal-rex--named (connection)
  "Return CONNECTION's socket as people read it."
  (abbreviate-file-name (portal-rex-connection-socket connection)))

(defun portal-rex--connection (connection)
  "Return CONNECTION, or the one live connection for nil."
  (or connection
      (pcase (portal-rex-connections)
        ('nil (user-error "Not connected to a Rex server; use M-x portal-rex-connect"))
        (`(,only) only)
        (_ (error "Several Rex servers are connected; name the connection")))))

;;; Messages

(defun portal-rex--failure (code message)
  "Return a response that failed in Emacs with CODE and MESSAGE.
It has the shape of a server's error, with a code no server sends."
  (list :type "response" :error (list :code code :message message)))

(defun portal-rex--parse (text)
  "Return the message TEXT as a plist, or nil if it is not a JSON object."
  (let ((value (condition-case nil (json-parse-string text :object-type 'plist)
                 (error nil))))
    (and (consp value) (keywordp (car value)) value)))

(defun portal-rex--pump (connection)
  "Take what waits on CONNECTION from the native module, and handle it.
The end of the connection joins the queue behind its last messages, as
\(:type ended :reason REASON).

Quitting is inhibited from here down, as Emacs inhibits it in a process
filter, which is the other place this runs: a quit that cut in between
the module handing messages over and their handlers returning would lose
them.  It takes effect once this returns, in whoever waits."
  (let ((inhibit-quit t))
    (portal-rex--pump-1 connection)))

(defun portal-rex--pump-1 (connection)
  "Do `portal-rex--pump' for CONNECTION, with quitting inhibited."
  (when-let* ((id (portal-rex-connection-id connection)))
    (pcase-let ((`(,reason . ,texts) (portal--rex-receive id))
                (messages nil))
      ;; Once the module gives a reason, it has forgotten the connection.
      (when reason (setf (portal-rex-connection-id connection) nil))
      (while texts
        (if-let* ((message (portal-rex--parse (pop texts))))
            (push message messages)
          ;; A server that sends anything else is not one to go on with:
          ;; what it sent after that is dropped with the connection.
          (when (portal-rex-connection-id connection)
            (setf (portal-rex-connection-id connection) nil)
            (ignore-errors (portal--rex-close id)))
          (setq reason "The server sent a message that is not JSON"
                texts nil)))
      (setf (portal-rex-connection-inbox connection)
            (nconc (portal-rex-connection-inbox connection)
                   (nreverse messages)
                   (and reason (list (list :type 'ended :reason reason)))))))
  (portal-rex--drain connection))

(defun portal-rex--next (connection)
  "Remove and return the next of CONNECTION's waiting messages to handle.
That is the oldest, except while an event's functions run: then it is
the oldest that is not an event, and the end of the connection stays
where it is, behind the events before it, once it has failed the
requests still waiting, so that whoever waits for one returns."
  (let ((inbox (portal-rex-connection-inbox connection)))
    (if (not (portal-rex-connection-handling connection))
        (pop (portal-rex-connection-inbox connection))
      (when-let* ((message (cl-find-if-not (lambda (waiting)
                                             (equal (plist-get waiting :type) "event"))
                                           inbox)))
        (if (eq (plist-get message :type) 'ended)
            (ignore (portal-rex--fail-calls connection (plist-get message :reason)))
          (setf (portal-rex-connection-inbox connection) (delq message inbox))
          message)))))

(defun portal-rex--drain (connection)
  "Handle CONNECTION's waiting messages, oldest first.
Events run one at a time: every function of the hook sees one before any
sees the next.  So when one of those functions waits for the server, as
`portal-rex-call' does, or lets Emacs read its pipes, only what is not
an event is handled from in here, and the events that arrived meanwhile
keep their places until the function returns."
  (let (message finished)
    (unwind-protect
        (progn
          (while (setq message (portal-rex--next connection))
            (portal-rex--handle connection message))
          (setq finished t))
      (unless finished (portal-rex--resume-later connection)))))

(defun portal-rex--resume-later (connection)
  "Finish soon what a non-local exit left of CONNECTION's messages.
Quitting is inhibited while they are handled, but a hook function or a
callback can still leave another way, as when its error opens the
debugger and the debugger is left.  Nothing may ever ask for this
connection again: its messages, the end among them, are in Emacs already."
  (unless (portal-rex-connection-resume connection)
    (setf (portal-rex-connection-resume connection)
          (run-at-time 0 nil #'portal-rex--resume connection))))

(defun portal-rex--resume (connection)
  "Handle what was left of CONNECTION's messages, or of its failing requests."
  (setf (portal-rex-connection-resume connection) nil)
  (let ((inhibit-quit t))
    (if (eq (portal-rex-connection-state connection) 'closed)
        (portal-rex--fail-calls connection (portal-rex-connection-reason connection))
      (portal-rex--drain connection))))

(defun portal-rex--handle (connection message)
  "Handle MESSAGE, which arrived on CONNECTION."
  (pcase (plist-get message :type)
    ("welcome" (setf (portal-rex-connection-welcome connection) message))
    ("response"
     (let* ((id (plist-get message :id))
            (call (and (stringp id)
                       (assq (string-to-number id) (portal-rex-connection-calls connection)))))
       (when call
         (setf (portal-rex-connection-calls connection)
               (delq call (portal-rex-connection-calls connection)))
         (portal-rex--run (cdr call) message))))
    ("event"
     (if (not (portal-rex--ready-p connection))
         (push message (portal-rex-connection-held connection))
       (setf (portal-rex-connection-handling connection) t)
       (unwind-protect
           (portal-rex--run #'run-hook-with-args 'portal-rex-event-functions connection message)
         (setf (portal-rex-connection-handling connection) nil))))
    ('ended (portal-rex--ended connection (plist-get message :reason)))
    ;; Anything else is from a newer server.
    (_ nil)))

(defun portal-rex--run (function &rest arguments)
  "Call FUNCTION with ARGUMENTS, only reporting an error.
The messages after this one must still be handled."
  (with-demoted-errors "Portal Rex: %S"
    (apply function arguments)))

(defun portal-rex--end (connection reason)
  "End CONNECTION from this side, because of REASON.
A connection that has ended keeps the reason it had."
  (when-let* ((id (portal-rex-connection-id connection)))
    (setf (portal-rex-connection-id connection) nil)
    (ignore-errors (portal--rex-close id)))
  (portal-rex--ended connection reason))

(defun portal-rex--fail-calls (connection reason)
  "Fail every request still waiting on CONNECTION, oldest first, with REASON.
One whose function exits non-locally leaves the rest to be failed soon."
  (let (finished)
    (unwind-protect
        (progn
          (while-let ((call (car (last (portal-rex-connection-calls connection)))))
            (setf (portal-rex-connection-calls connection)
                  (delq call (portal-rex-connection-calls connection)))
            (portal-rex--run (cdr call) (portal-rex--failure "portal_disconnected" reason)))
          (setq finished t))
      (unless finished (portal-rex--resume-later connection)))))

(defun portal-rex--ended (connection reason &optional quiet)
  "Note that CONNECTION has ended because of REASON, the first time only.
A connection that was ready is reported lost in the echo area, unless
QUIET.  Every request still waiting fails, oldest first."
  (unless (eq (portal-rex-connection-state connection) 'closed)
    (let ((ready (portal-rex--ready-p connection))
          (inhibit-quit t))
      (setf (portal-rex-connection-id connection) nil
            (portal-rex-connection-state connection) 'closed
            (portal-rex-connection-reason connection) reason
            (portal-rex-connection-inbox connection) nil
            (portal-rex-connection-held connection) nil
            portal-rex--connections (delq connection portal-rex--connections))
      (unless portal-rex--connections
        (remove-hook 'kill-emacs-hook #'portal-rex--disconnect-all))
      (when (and ready (not quiet))
        (message "Lost the Rex server at %s: %s" (portal-rex--named connection) reason))
      (portal-rex--fail-calls connection reason))))

(defun portal-rex--record (id &rest _)
  "Handle the record that messages wait on the native connection ID."
  (let* ((id (string-to-number id))
         (connection (cl-find id portal-rex--connections :key #'portal-rex-connection-id)))
    (if connection
        (portal-rex--pump connection)
      ;; A connection this file has forgotten, as after it was loaded again.
      (ignore-errors (portal--rex-close id)))))

(setf (alist-get "rex" portal-view-feature-record-handlers nil nil #'equal)
      #'portal-rex--record)

(defun portal-rex--await (connection done timeout)
  "Handle CONNECTION's messages until DONE returns non-nil, and return that.
Return nil if it has not after TIMEOUT seconds, or once the connection
has ended.  The wait blocks Emacs in short turns, and a quit gets through
between them, never while messages are taken and handled."
  (let ((deadline (+ (float-time) timeout)) result)
    (portal-rex--pump connection)
    (while (and (not (setq result (funcall done)))
                (portal-rex-connection-id connection)
                (< (float-time) deadline))
      (portal--rex-wait (portal-rex-connection-id connection)
                        (max 1 (min 50 (ceiling (* 1000 (- deadline (float-time)))))))
      (portal-rex--pump connection))
    result))

;;; Calls

(defun portal-rex--request (connection method payload function)
  "Ask CONNECTION's server to run METHOD with PAYLOAD; return the request's number.
FUNCTION is called with the response, a plist, once it arrives; if the
connection ends first, with one whose `:error' says so."
  (unless (portal-rex-connection-id connection)
    (signal 'portal-rex-error
            (list (format "%s: not connected to the Rex server at %s" method
                          (portal-rex--named connection))
                  (list :code "portal_disconnected"))))
  (let* ((json (if payload (json-serialize payload) "{}"))
         ;; Sending and noting who waits are one step.
         (inhibit-quit t)
         (number (portal--rex-request (portal-rex-connection-id connection) method json)))
    (push (cons number function) (portal-rex-connection-calls connection))
    number))

(defun portal-rex-call-async (connection method payload callback)
  "Ask CONNECTION's Rex server to run METHOD with PAYLOAD, and return at once.
CONNECTION is one that `portal-rex-connect' returned, or nil for the only
one.  METHOD is a string such as \"session.list\".  PAYLOAD is the
method's arguments as a plist that `json-serialize' takes, such as
\(:session_id \"session:01a1…\" :label \"api\"), or nil for none.

CALLBACK is called with RESULT and ERROR once the server answers: RESULT
is what the method returned, parsed as `json-parse-string' does with
objects as plists, and ERROR is nil.  When the call failed, RESULT is nil
and ERROR is the server's error, a plist with `:code', such as
\"method_not_found\", `:message' and `:status'; a connection that ends
first gives the code \"portal_disconnected\".  CALLBACK runs as the
functions of `portal-rex-event-functions' do, so it must never prompt."
  (portal-rex--request (portal-rex--connection connection) method payload
                       (lambda (response)
                         (funcall callback (plist-get response :payload)
                                  (plist-get response :error))))
  nil)

(defun portal-rex-call (connection method &optional payload timeout)
  "Ask CONNECTION's Rex server to run METHOD with PAYLOAD, and return its result.
The arguments and the result are as for `portal-rex-call-async', which
does not wait.  This waits for the answer, for at most TIMEOUT seconds,
by default `portal-rex-timeout', handling the events and responses that
arrive before it, in order; called from `portal-rex-event-functions',
it leaves those events until the function that called it returns.

A call the server refuses signals `portal-rex-error', with a sentence and
the server's error, a plist with `:code', `:message' and `:status'.  So
does a call with no answer in time, with the code \"portal_timeout\", and
one whose connection ended, with \"portal_disconnected\"."
  (let* ((connection (portal-rex--connection connection))
         (timeout (or timeout portal-rex-timeout))
         response
         (number (portal-rex--request connection method payload
                                      (lambda (message) (setq response message)))))
    (unwind-protect
        (unless (portal-rex--await connection (lambda () response) timeout)
          (setq response (portal-rex--failure "portal_timeout"
                                              (format "no answer within %s seconds" timeout))))
      ;; However the wait ends, a quit included, an answer that comes later
      ;; finds no one waiting.
      (setf (portal-rex-connection-calls connection)
            (assq-delete-all number (portal-rex-connection-calls connection))))
    (when-let* ((failure (plist-get response :error)))
      (signal 'portal-rex-error
              (list (format "%s: %s" method (plist-get failure :message)) failure)))
    (plist-get response :payload)))

;;; Connecting

(defun portal-rex--attached (connection response)
  "Make CONNECTION ready with RESPONSE, the server's answer to attaching.
The sessions it lists are as they were after the response's seq: the
events held meanwhile that came later follow, and the rest are in them.
Those that follow go to the front of the inbox, which is being drained,
so a handler that waits for the server finds them ahead of anything newer."
  (if-let* ((failure (plist-get response :error)))
      (portal-rex--end connection (format "The server sends no events: %s"
                                          (plist-get failure :message)))
    (let ((seq (or (plist-get response :seq) 0))
          (held (nreverse (portal-rex-connection-held connection))))
      (setf (portal-rex-connection-held connection) nil
            (portal-rex-connection-sessions connection)
            (plist-get (plist-get response :payload) :sessions)
            (portal-rex-connection-state connection) 'ready
            (portal-rex-connection-inbox connection)
            (nconc (cl-delete-if-not (lambda (event) (> (or (plist-get event :seq) 0) seq))
                                     held)
                   (portal-rex-connection-inbox connection))))))

(defun portal-rex--disconnect-all ()
  "Disconnect from every Rex server, as Emacs exits."
  (dolist (connection (copy-sequence portal-rex--connections))
    (ignore-errors (portal-rex-disconnect connection))))

;;;###autoload
(defun portal-rex-connect (&optional socket)
  "Connect to the Rex server on the Unix socket SOCKET, and return the connection.
SOCKET defaults to `portal-rex-socket', this Mac's server; with a prefix
argument, read it.  Emacs can be connected to several servers at once,
and connecting again to one returns the connection it has.

Once connected, `portal-rex-call' and `portal-rex-call-async' call the
server's methods, and `portal-rex-event-functions' runs for each event
of the server and of its sessions.  The connection's
`portal-rex-connection-sessions' are the sessions the server had then."
  (interactive
   (list (and current-prefix-arg
              (read-file-name "Rex server socket: "
                              (file-name-directory (expand-file-name portal-rex-socket))
                              nil t))))
  (let* ((socket (expand-file-name (or socket portal-rex-socket)))
         (existing (cl-find socket (portal-rex-connections)
                            :key #'portal-rex-connection-socket :test #'equal)))
    (cond
     (existing
      (when (called-interactively-p 'any)
        (message "Already connected to the Rex server at %s" (portal-rex--named existing)))
      existing)
     ((not (file-exists-p socket))
      (user-error "No Rex server is running: there is no socket at %s"
                  (abbreviate-file-name socket)))
     (t
      (portal-view--load)
      (let ((connection (portal-rex--open socket)))
        (when (called-interactively-p 'any)
          (let ((count (length (portal-rex-connection-sessions connection))))
            (message "Connected to the Rex server at %s, which has %d session%s"
                     (portal-rex--named connection) count (if (= count 1) "" "s"))))
        connection)))))

(defun portal-rex--open (socket)
  "Return a new, ready connection to the Rex server on SOCKET, or signal why not."
  (let* ((id (portal--rex-open socket "Portal" (or (portal-build-version) "0")))
         (connection (portal-rex--make-connection :id id :socket socket))
         (name (abbreviate-file-name socket)))
    (setq portal-rex--connections (append portal-rex--connections (list connection)))
    (add-hook 'kill-emacs-hook #'portal-rex--disconnect-all)
    ;; Whatever stops the wait, a quit included, leaves no half-made connection.
    (unwind-protect
        (when (and (portal-rex--await connection
                                      (lambda () (portal-rex-connection-welcome connection))
                                      portal-rex-timeout)
                   (portal-rex-connection-id connection))
          (setf (portal-rex-connection-state connection) 'attaching)
          (portal-rex--request connection "session.attach_all" '(:event_scope "session")
                               (lambda (response) (portal-rex--attached connection response)))
          (portal-rex--await connection (lambda () (portal-rex-live-p connection))
                             portal-rex-timeout))
      (unless (portal-rex-live-p connection)
        (portal-rex--end connection nil)))
    (cond
     ((portal-rex-live-p connection) connection)
     ((portal-rex-connection-reason connection)
      (user-error "Cannot connect to the Rex server at %s: %s" name
                  (portal-rex-connection-reason connection)))
     (t (user-error "The Rex server at %s did not answer within %s seconds" name
                    portal-rex-timeout)))))

(defun portal-rex--read-connection ()
  "Return the live connection the user means, reading it if there are several."
  (let ((connections (portal-rex-connections)))
    (cond
     ((null connections) (user-error "Not connected to a Rex server"))
     ((null (cdr connections)) (car connections))
     (t (let ((name (completing-read "Disconnect from Rex server: "
                                     (mapcar #'portal-rex--named connections) nil t)))
          (cl-find name connections :key #'portal-rex--named :test #'equal))))))

;;;###autoload
(defun portal-rex-disconnect (connection)
  "Disconnect from the Rex server of CONNECTION.
Interactively, from the one connected server, or one read from the
minibuffer.  The server and what runs on it carry on; requests still
waiting fail with the code \"portal_disconnected\"."
  (interactive (list (portal-rex--read-connection)))
  (unless (eq (portal-rex-connection-state connection) 'closed)
    (let ((id (portal-rex-connection-id connection)))
      (setf (portal-rex-connection-id connection) nil)
      (when id (portal--rex-close id)))
    (portal-rex--ended connection "Disconnected" t)
    (when (called-interactively-p 'any)
      (message "Disconnected from the Rex server at %s" (portal-rex--named connection)))))

(provide 'portal-rex)
;;; portal-rex.el ends here
