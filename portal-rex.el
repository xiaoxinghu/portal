;;; portal-rex.el --- Connections to Rex servers -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Emacs as a client of Rex, the terminal multiplexer: a connection to a Rex
;; server, calls of its methods, its events, and a buffer for each of its
;; blocks, following the server, which shows its block's screen once a
;; window shows it (docs/rex.md).  Portal's own terminals need no Rex.
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
(require 'seq)
(require 'portal-view)
(require 'portal-terminal)
(eval-when-compile (require 'ibuf-ext))

(declare-function portal--rex-open "portal-rex" (path name version))
(declare-function portal--rex-request "portal-rex" (id method payload))
(declare-function portal--rex-receive "portal-rex" (id))
(declare-function portal--rex-wait "portal-rex" (id milliseconds))
(declare-function portal--rex-close "portal-rex" (id))
(declare-function portal--rex-show "portal-rex" (id target session-id block-id))
(declare-function portal--inspect "portal-view" (target))
(declare-function ibuffer-current-buffer "ibuffer" (&optional must-be-live))
(declare-function ibuffer-update "ibuffer" (arg &optional silent))
(declare-function ibuffer-push-filter "ibuf-ext" (filter-specification))

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
it has returned.

Portal has followed the event by then: the connection's sessions have
the change, and the buffer of a closed block is gone.  The buffer of a
new block comes a moment later, once the server has said what the block
is called.")

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
            :documentation "The server's sessions, a vector of plists with `:session_id' and
`:label', in the server's order.  The server's events keep it current.")
  (blocks (make-hash-table :test #'equal)
          :documentation "Each block's buffer, by block ID.  A buffer killed by hand stays
here, dead, until its block closes: its block gets no second buffer.")
  (lists nil
         :documentation "The sessions whose blocks the server is being asked for, as
\(SESSION-ID AGAIN . CLOSED): whether to ask again once the answer
comes, and the IDs of the blocks closed since asking.")
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
           (progn
             ;; Portal follows the event first, so the hook's functions find
             ;; the sessions and the buffers as the event left them.
             (portal-rex--run #'portal-rex--follow connection message)
             (portal-rex--run #'run-hook-with-args 'portal-rex-event-functions
                              connection message))
         (setf (portal-rex-connection-handling connection) nil))))
    ('ended (portal-rex--ended connection (plist-get message :reason)))
    ;; Anything else is from a newer server.
    (_ nil)))

(defun portal-rex--run (function &rest arguments)
  "Call FUNCTION with ARGUMENTS, only reporting an error.
The messages after this one must still be handled."
  (with-demoted-errors "Portal Rex: %S"
    (apply function arguments)))

(defun portal-rex--end (connection reason &optional quiet)
  "End CONNECTION from this side, because of REASON, as one step.
A connection that has ended keeps the reason it had.  QUIET is as for
`portal-rex--ended'."
  (let ((inhibit-quit t))
    (when-let* ((id (portal-rex-connection-id connection)))
      (setf (portal-rex-connection-id connection) nil)
      (ignore-errors (portal--rex-close id)))
    (portal-rex--ended connection reason quiet)))

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
QUIET.  Its blocks' buffers are killed, which ends nothing on the
server.  Every request still waiting fails, oldest first."
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
        (remove-hook 'kill-emacs-hook #'portal-rex--disconnect-all)
        (remove-hook 'window-buffer-change-functions #'portal-rex--show-shown))
      (when (and ready (not quiet))
        (message "Lost the Rex server at %s: %s" (portal-rex--named connection) reason))
      (portal-rex--run #'portal-rex--forget-blocks connection)
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
         response number)
    ;; However the wait ends, a quit included, an answer that comes later
    ;; finds no one waiting.  The request is made inside that promise, with
    ;; quitting inhibited until its number is known.
    (unwind-protect
        (progn
          (let ((inhibit-quit t))
            (setq number (portal-rex--request connection method payload
                                              (lambda (message) (setq response message)))))
          (unless (portal-rex--await connection (lambda () response) timeout)
            (setq response (portal-rex--failure
                            "portal_timeout" (format "no answer within %s seconds" timeout)))))
      (when number
        (setf (portal-rex-connection-calls connection)
              (assq-delete-all number (portal-rex-connection-calls connection)))))
    (when-let* ((failure (plist-get response :error)))
      (signal 'portal-rex-error
              (list (format "%s: %s" method (plist-get failure :message)) failure)))
    (plist-get response :payload)))

;;; Sessions and blocks

;; While Emacs is connected to a server, each block on it has exactly one
;; buffer, and `switch-to-buffer' and Ibuffer are the list of them.  A
;; buffer knows its block by three variables; its session is one of them,
;; an attribute as a directory is, and its name carries both labels.
;;
;; The server's events say that a block has come or gone, never what one
;; is called: `block_created' carries only an ID, a label changed in a
;; window arrives as `session_view_changed', which follows almost any
;; change, and a detached block's new label sends nothing.  So each of
;; those events asks the session for all its blocks, `session.list_blocks',
;; and the buffers are made to match the answer.

(defvar-local portal-rex-block-connection nil
  "The connection to the Rex server of this buffer's block, or nil.
It is non-nil exactly in the buffer of a block.")

(defvar-local portal-rex-block-id nil
  "The ID of this buffer's block on its Rex server, or nil.
A block's ID never changes and is never reused.")

(defvar-local portal-rex-session-id nil
  "The ID of the session of this buffer's block, or nil.
A block stays in one session for its whole life.  `portal-rex-session-label'
returns what the session is called now.")

(defvar-local portal-rex--block-label nil
  "The label of this buffer's block, as its server last gave it.")

(defvar-local portal-rex--show-failure nil
  "Why this block's screen could not be shown the last time, or nil.")

;; A buffer is its block's whatever mode it is put in.
(dolist (variable '(portal-rex-block-connection portal-rex-block-id portal-rex-session-id
                    portal-rex--block-label portal-rex--show-failure))
  (put variable 'permanent-local t))

(defvar portal-rex--killing nil
  "Non-nil while Portal kills a block's buffer because its block or server went.")

(defun portal-rex-buffers (&optional connection session-id)
  "Return the buffers of the blocks on CONNECTION's Rex server.
Without CONNECTION, those of every connected server.  With SESSION-ID,
only the blocks of that session."
  (cl-loop for connection in (if connection (list connection) portal-rex--connections)
           nconc (cl-loop for buffer being the hash-values
                          of (portal-rex-connection-blocks connection)
                          when (and (buffer-live-p buffer)
                                    (or (null session-id)
                                        (equal (buffer-local-value 'portal-rex-session-id buffer)
                                               session-id)))
                          collect buffer)))

(defun portal-rex-block-buffer (connection block-id)
  "Return the buffer of the block BLOCK-ID on CONNECTION's server, or nil."
  (let ((buffer (gethash block-id (portal-rex-connection-blocks connection))))
    (and (buffer-live-p buffer) buffer)))

(defun portal-rex--session (connection session-id)
  "Return the session SESSION-ID as CONNECTION's sessions have it, or nil."
  (seq-find (lambda (session) (equal (plist-get session :session_id) session-id))
            (portal-rex-connection-sessions connection)))

(defun portal-rex--session-label (connection session-id)
  "Return what CONNECTION's server calls the session SESSION-ID, or nil."
  (plist-get (portal-rex--session connection session-id) :label))

(defun portal-rex-session-label (&optional buffer)
  "Return the label of the Rex session that BUFFER's block is in, or nil.
BUFFER defaults to the current buffer; one that is not a block's has none."
  (let ((buffer (or buffer (current-buffer))))
    (when-let* (((buffer-live-p buffer))
                (connection (buffer-local-value 'portal-rex-block-connection buffer)))
      (portal-rex--session-label connection
                                 (buffer-local-value 'portal-rex-session-id buffer)))))

(defun portal-rex--label-session (connection session-id label)
  "Call the session SESSION-ID LABEL in CONNECTION's sessions.
A session that is not among them joins them, last."
  (let ((sessions (append (portal-rex-connection-sessions connection) nil))
        (old (portal-rex--session connection session-id))
        (new (list :session_id session-id :label label)))
    (setf (portal-rex-connection-sessions connection)
          (vconcat (if old (cl-substitute new old sessions) (append sessions (list new)))))))

(defun portal-rex--drop-session (connection session-id)
  "Take the session SESSION-ID out of CONNECTION's sessions."
  (setf (portal-rex-connection-sessions connection)
        (vconcat (remq (portal-rex--session connection session-id)
                       (append (portal-rex-connection-sessions connection) nil)))))

(defun portal-rex--move-session (connection session-id before)
  "Move the session SESSION-ID to before BEFORE in CONNECTION's sessions.
BEFORE is another session's ID; without it, the session goes last."
  (when-let* ((session (portal-rex--session connection session-id)))
    (let* ((others (remq session (append (portal-rex-connection-sessions connection) nil)))
           (place (or (cl-position (portal-rex--session connection before) others)
                      (length others))))
      (setf (portal-rex-connection-sessions connection)
            (vconcat (seq-take others place) (list session) (seq-drop others place))))))

(defun portal-rex--buffer-name (connection session-id label)
  "Return the name of the buffer of a block called LABEL.
The block is in the session SESSION-ID on CONNECTION's server.  Every
connection is to a server on this Mac, so the name carries no host."
  (format "*rex: %s/%s*" (or (portal-rex--session-label connection session-id) session-id)
          label))

(defun portal-rex--describe-block ()
  "Make the current buffer's text say which block it is the buffer of.
While the buffer has its terminal view, its text is the view's placard
instead, which this leaves alone."
  (unless portal-view--target
    (with-silent-modifications
      (erase-buffer)
      (insert (format "Rex block %s, in session %s.\n%s on the server at %s\n\n%s\n"
                      portal-rex--block-label
                      (or (portal-rex-session-label) portal-rex-session-id)
                      portal-rex-block-id
                      (portal-rex--named portal-rex-block-connection)
                      (if portal-rex--show-failure
                          (format "Its screen could not be shown: %s\nShowing the buffer again tries again."
                                  portal-rex--show-failure)
                        "Its screen is shown here once a window shows this buffer."))))))

(defun portal-rex--buffer-killed ()
  "Say what killing this block's buffer by hand leaves on its server.
On `kill-buffer-hook' in a block's buffer.  The dead buffer stays in its
connection's blocks, so nothing makes the block another."
  (when (and portal-rex-block-connection (not portal-rex--killing)
             (eq (portal-rex-block-buffer portal-rex-block-connection portal-rex-block-id)
                 (current-buffer)))
    (message "Killed only the buffer: block %s still runs on its Rex server, and gets a buffer again when Emacs next connects"
             portal-rex--block-label)))
(put 'portal-rex--buffer-killed 'permanent-local-hook t)

(defun portal-rex--make-buffer (connection session-id block-id label)
  "Make and return the buffer of the block BLOCK-ID, called LABEL.
The block is in the session SESSION-ID on CONNECTION's server.  The
buffer is in `portal-terminal-mode', as the terminal view that will show
the block needs, and has no view."
  (let ((buffer (generate-new-buffer (portal-rex--buffer-name connection session-id label)))
        ready)
    (unwind-protect
        (with-current-buffer buffer
          (portal-terminal-mode)
          (setq portal-rex-block-connection connection
                portal-rex-block-id block-id
                portal-rex-session-id session-id
                portal-rex--block-label label
                ;; Not the directory of whichever buffer was current when
                ;; the server spoke.
                default-directory (expand-file-name "~/"))
          (add-hook 'kill-buffer-hook #'portal-rex--buffer-killed nil t)
          ;; Killing the buffer ends no program: the block runs on.
          (setq-local portal-terminal-confirm-kill nil)
          ;; Its name is its block's, which renaming the terminal changes.
          (setq portal-terminal--renamer #'portal-rex--renamer)
          (portal-rex--describe-block)
          (puthash block-id buffer (portal-rex-connection-blocks connection))
          (setq ready t))
      (unless ready
        (let ((portal-rex--killing t)) (kill-buffer buffer))))
    buffer))

(defun portal-rex--rename-buffer (buffer &optional label)
  "Name BUFFER after its session's label and its block's, which is now LABEL."
  (with-current-buffer buffer
    (when label (setq portal-rex--block-label label))
    (rename-buffer (portal-rex--buffer-name portal-rex-block-connection portal-rex-session-id
                                            portal-rex--block-label)
                   t)
    (portal-rex--describe-block)))

(defun portal-rex--untangle-names (connection session-id)
  "Give SESSION-ID's buffers on CONNECTION their plain names where they are free.
A buffer that Emacs named *rex: S/B*<2>, as another had the name then,
takes *rex: S/B* once no buffer has it, as when the other's block is
relabelled or closes.  A name given by hand stays."
  (dolist (buffer (portal-rex-buffers connection session-id))
    (with-current-buffer buffer
      (let ((plain (portal-rex--buffer-name connection session-id portal-rex--block-label)))
        (when (and (string-match-p (concat "\\`" (regexp-quote plain) "<[0-9]+>\\'") (buffer-name))
                   (not (get-buffer plain)))
          (rename-buffer plain))))))

(defun portal-rex--kill-buffer (connection block-id)
  "Forget CONNECTION's block BLOCK-ID, and kill its buffer if it has one.
The block has gone, or the connection has: nothing asks, whatever is on
`kill-buffer-query-functions', and nothing is said to the server."
  (let ((buffer (gethash block-id (portal-rex-connection-blocks connection))))
    (remhash block-id (portal-rex-connection-blocks connection))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((portal-rex--killing t)
              (kill-buffer-query-functions nil))
          (kill-buffer buffer))))))

(defun portal-rex--forget-blocks (connection)
  "Kill every buffer of CONNECTION's blocks, which has ended."
  (setf (portal-rex-connection-lists connection) nil)
  (dolist (block-id (hash-table-keys (portal-rex-connection-blocks connection)))
    (portal-rex--kill-buffer connection block-id)))

(defun portal-rex--list-blocks (connection session-id)
  "Ask CONNECTION's server for the blocks of SESSION-ID, for `portal-rex--listed'.
One request for a session is out at a time.  Asked for again meanwhile,
the session is asked once more when that answer comes, as the answer may
be older than the change that asked."
  (when (portal-rex-connection-id connection)
    (if-let* ((asked (assoc session-id (portal-rex-connection-lists connection))))
        (setcar (cdr asked) t)
      (portal-rex--request connection "session.list_blocks" (list :session_id session-id)
                           (lambda (response)
                             (portal-rex--listed connection session-id response)))
      (push (list session-id nil) (portal-rex-connection-lists connection)))))

(defun portal-rex--listed (connection session-id response)
  "Make CONNECTION's buffers of SESSION-ID match RESPONSE, its list of blocks.
A block without a buffer gets one, a buffer whose block is not listed is
killed, and one whose block has a new label is renamed.  A block that
closed while the server was asked gets none, though an answer from before
it closed lists it: an ID is never reused.  Neither does one whose buffer
was killed by hand."
  (let* ((asked (assoc session-id (portal-rex-connection-lists connection)))
         (failure (plist-get response :error))
         (payload (plist-get (plist-get response :payload) :blocks))
         ;; A server may say null for none.
         (blocks (and (vectorp payload) payload)))
    (setf (portal-rex-connection-lists connection)
          (delq asked (portal-rex-connection-lists connection)))
    ;; Without ASKED, the session was destroyed or the connection has ended.
    (when (and asked (portal-rex--ready-p connection))
      (cond
       ;; A session destroyed meanwhile says so in an event.
       ((equal (plist-get failure :code) "session_not_found"))
       (failure (message "Cannot list the blocks of Rex session %s: %s"
                         (or (portal-rex--session-label connection session-id) session-id)
                         (plist-get failure :message)))
       (t
        (let ((listed (seq-keep (lambda (block) (plist-get block :block_id)) blocks)))
          (dolist (buffer (portal-rex-buffers connection session-id))
            (let ((block-id (buffer-local-value 'portal-rex-block-id buffer)))
              (unless (member block-id listed)
                (portal-rex--kill-buffer connection block-id)))))
        (seq-doseq (block blocks)
          (let* ((block-id (plist-get block :block_id))
                 (label (plist-get block :label))
                 (buffer (and (stringp block-id)
                              (gethash block-id (portal-rex-connection-blocks connection)))))
            (cond
             ((not (and (stringp block-id) (stringp label))))
             ((member block-id (cddr asked)))
             ((null buffer) (portal-rex--make-buffer connection session-id block-id label))
             ((not (buffer-live-p buffer)))
             ((not (equal label (buffer-local-value 'portal-rex--block-label buffer)))
              (portal-rex--rename-buffer buffer label)))))
        (portal-rex--untangle-names connection session-id)))
      (when (cadr asked)
        (portal-rex--list-blocks connection session-id)))))

(defun portal-rex--follow (connection event)
  "Bring CONNECTION's sessions and its blocks' buffers up to date with EVENT.
An event of a session that the connection does not know is left alone:
`session_created' lists a new session's blocks."
  (let* ((payload (plist-get event :payload))
         (fields (plist-get payload :payload)))
    (pcase (plist-get payload :type)
      ("session_created"
       (when-let* ((session (plist-get fields :session))
                   (session-id (plist-get session :session_id)))
         (portal-rex--label-session connection session-id (or (plist-get session :label) ""))
         (portal-rex--list-blocks connection session-id)))
      ("session_destroyed"
       (let ((session-id (plist-get fields :session_id)))
         (dolist (buffer (portal-rex-buffers connection session-id))
           (portal-rex--kill-buffer connection
                                    (buffer-local-value 'portal-rex-block-id buffer)))
         (setf (portal-rex-connection-lists connection)
               (cl-delete session-id (portal-rex-connection-lists connection)
                          :key #'car :test #'equal))
         (portal-rex--drop-session connection session-id)))
      ("session_moved"
       (portal-rex--move-session connection (plist-get fields :session_id)
                                 (plist-get fields :before_session_id)))
      ("session_event"
       (let* ((session-id (plist-get fields :session_id))
              (inner (plist-get fields :event))
              (changed (plist-get inner :payload)))
         (when (portal-rex--session connection session-id)
           (pcase (plist-get inner :type)
             ("session_label_changed"
              (when-let* ((label (plist-get changed :label)))
                (portal-rex--label-session connection session-id label)
                (mapc #'portal-rex--rename-buffer
                      (portal-rex-buffers connection session-id))))
             ((or "block_created" "session_view_changed")
              (portal-rex--list-blocks connection session-id))
             ("block_closed"
              (when-let* ((block-id (plist-get changed :block_id)))
                (portal-rex--kill-buffer connection block-id)
                (when-let* ((asked (assoc session-id
                                          (portal-rex-connection-lists connection))))
                  (push block-id (cddr asked))))))))))))

(defun portal-rex--session-labels ()
  "Return the labels of every connected server's sessions, each once."
  (delete-dups
   (cl-loop for connection in (portal-rex-connections)
            append (mapcar (lambda (session) (plist-get session :label))
                           (portal-rex-connection-sessions connection)))))

(with-eval-after-load 'ibuf-ext
  (define-ibuffer-filter portal-rex-session
      "Limit current view to buffers of Rex blocks in the session labelled QUALIFIER."
    (:description "Rex session"
     :reader (let ((default (portal-rex-session-label (ibuffer-current-buffer))))
               (completing-read (format-prompt "Filter by Rex session" default)
                                (portal-rex--session-labels) nil nil nil nil default)))
    (equal (portal-rex-session-label buf) qualifier)))

;;; Showing a block

;; A buffer is made without its screen.  The first time a window shows it,
;; it gets a terminal view, a fed one: the native module attaches to the
;; block's session, claims the block, sizes it to the pane, paints the
;; screen the server describes and feeds it the block's output from then
;; on, and types into the block what the terminal encodes (docs/rex.md).
;; The bytes never cross Emacs.  The view, and the block's stream with it,
;; stay until the buffer goes, shown or not, so a buffer shown again is
;; current at once.

(defvar portal-rex--failed-shows nil
  "The buffers that failed to show their blocks while windows still show them.
They try again once no window shows them, and one does again.")

(defun portal-rex--show-shown (&optional _frame)
  "Give each block's buffer that a window shows its terminal view.
On `window-buffer-change-functions' while Emacs is connected to a server.
A buffer whose view could not open waits until a window shows it again."
  (dolist (window (window-list-1 nil 'nomini t))
    (let ((buffer (window-buffer window)))
      (when (and (buffer-local-value 'portal-rex-block-connection buffer)
                 (not (buffer-local-value 'portal-view--target buffer))
                 (not (memq buffer portal-rex--failed-shows))
                 (eq (portal-rex-block-buffer
                      (buffer-local-value 'portal-rex-block-connection buffer)
                      (buffer-local-value 'portal-rex-block-id buffer))
                     buffer))
        (portal-rex--show buffer window))))
  (setq portal-rex--failed-shows
        (cl-remove-if-not (lambda (buffer) (get-buffer-window buffer t)) portal-rex--failed-shows)))

(defun portal-rex--show (buffer window)
  "Open BUFFER's terminal view and show its block in it, in WINDOW's frame.
A failure is written in the buffer, not signalled: this runs from a
window change hook."
  (with-current-buffer buffer
    (let ((connection portal-rex-block-connection)
          target)
      (condition-case failure
          (progn
            (portal-terminal--connect)
            ;; It opens at the size of this frame's text, as any terminal does.
            (setq portal-terminal--points
                  (portal-terminal--text-size buffer (window-frame window)))
            (portal-view-placard "terminal" "This block's terminal has closed; the block runs on.")
            (setq target (portal-view-open 'terminal
                                           (list :fed t :theme portal-terminal-theme
                                                 :points portal-terminal--points)))
            (portal--rex-show (portal-rex-connection-id connection) target
                              portal-rex-session-id portal-rex-block-id)
            (setq portal-rex--show-failure nil)
            (add-hook 'window-state-change-functions #'portal-terminal--resize-shown 90))
        (error
         (when portal-view--target (portal-view-close))
         (push buffer portal-rex--failed-shows)
         (setq portal-rex--show-failure (error-message-string failure))
         (portal-rex--describe-block)
         (message "Cannot show Rex block %s: %s" portal-rex--block-label
                  portal-rex--show-failure))))))

(defun portal-rex--block-shown (target &rest _)
  "Note how showing TARGET's block went, from the native module's record.
A block whose screen could not be shown loses its view, and its buffer
says why; one whose stream ended keeps its last screen."
  (when-let* ((state (plist-get (portal--inspect target) :rex)))
    (pcase (plist-get state :state)
      ("failed"
       (setq portal-rex--show-failure (plist-get state :reason))
       (push (current-buffer) portal-rex--failed-shows)
       (portal-view-close)
       (portal-rex--describe-block)
       (message "Cannot show Rex block %s: %s" portal-rex--block-label portal-rex--show-failure))
      ("ended"
       ;; A block that closed takes its buffer with it, as its event says.
       (message "Rex block %s: %s" portal-rex--block-label (plist-get state :reason))))))

(setf (alist-get "rex-block" portal-view-record-handlers nil nil #'equal)
      #'portal-rex--block-shown)

;;; Connecting

(defun portal-rex--attached (connection response)
  "Make CONNECTION ready with RESPONSE, the server's answer to attaching.
The sessions it lists are as they were after the response's seq: the
events held meanwhile that came later follow, and the rest are in them.
Those that follow go to the front of the inbox, which is being drained,
so a handler that waits for the server finds them ahead of anything newer.
Each session is asked for its blocks, which makes their buffers."
  (if-let* ((failure (plist-get response :error)))
      (portal-rex--end connection (format "The server sends no events: %s"
                                          (plist-get failure :message)))
    (let ((seq (or (plist-get response :seq) 0))
          (held (nreverse (portal-rex-connection-held connection)))
          (sessions (plist-get (plist-get response :payload) :sessions)))
      (setf (portal-rex-connection-held connection) nil
            (portal-rex-connection-sessions connection) (if (vectorp sessions) sessions [])
            (portal-rex-connection-state connection) 'ready
            (portal-rex-connection-inbox connection)
            (nconc (cl-delete-if-not (lambda (event) (> (or (plist-get event :seq) 0) seq))
                                     held)
                   (portal-rex-connection-inbox connection)))
      (seq-doseq (session (portal-rex-connection-sessions connection))
        (portal-rex--list-blocks connection (plist-get session :session_id))))))

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

Each block on the server gets a buffer, named *rex: SESSION/BLOCK* from
the two labels, and from then on the buffers follow the server: one
comes with a new block, goes when its block closes or its session is
destroyed, and is renamed with either label.  `portal-rex-buffers'
returns them.  A buffer shows its block's screen, a terminal you can
type in, once a window shows the buffer, and keeps it up to date from
then on, shown or not.

Once connected, `portal-rex-call' and `portal-rex-call-async' call the
server's methods, and `portal-rex-event-functions' runs for each event
of the server and of its sessions.  The connection's
`portal-rex-connection-sessions' are the server's sessions, kept current."
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
  (let ((name (abbreviate-file-name socket))
        (version (or (portal-build-version) "0"))
        connection finished)
    ;; Whatever stops this, a quit included, leaves no half-made connection:
    ;; the connection is made inside that promise, with quitting inhibited
    ;; until Emacs knows it.
    (unwind-protect
        (progn
          (let ((inhibit-quit t))
            (setq connection (portal-rex--make-connection
                              :id (portal--rex-open socket "Portal" version) :socket socket)
                  portal-rex--connections (append portal-rex--connections (list connection)))
            (add-hook 'kill-emacs-hook #'portal-rex--disconnect-all)
            (add-hook 'window-buffer-change-functions #'portal-rex--show-shown))
          (when (and (portal-rex--await connection
                                        (lambda () (portal-rex-connection-welcome connection))
                                        portal-rex-timeout)
                     (portal-rex-connection-id connection))
            (setf (portal-rex-connection-state connection) 'attaching)
            (portal-rex--request connection "session.attach_all" '(:event_scope "session")
                                 (lambda (response) (portal-rex--attached connection response)))
            (when (portal-rex--await connection (lambda () (portal-rex-live-p connection))
                                     portal-rex-timeout)
              ;; The buffers, so that they are there when this returns.  A
              ;; server slow to list a session's blocks is still connected:
              ;; its buffers come when the answer does.
              (portal-rex--await connection
                                 (lambda () (null (portal-rex-connection-lists connection)))
                                 portal-rex-timeout)))
          (setq finished t))
      (when (and connection (not (and finished (portal-rex-live-p connection))))
        (portal-rex--end connection nil t)))
    (cond
     ((portal-rex-live-p connection) connection)
     ((portal-rex-connection-reason connection)
      (user-error "Cannot connect to the Rex server at %s: %s" name
                  (portal-rex-connection-reason connection)))
     (t (user-error "The Rex server at %s did not answer within %s seconds" name
                    portal-rex-timeout)))))

(defun portal-rex--read-connection (&optional prompt)
  "Return the live connection the user means, reading it if there are several.
PROMPT reads it, by default for disconnecting."
  (let ((connections (portal-rex-connections)))
    (cond
     ((null connections)
      (user-error "Not connected to a Rex server; use M-x portal-rex-connect"))
     ((null (cdr connections)) (car connections))
     (t (let ((name (completing-read (or prompt "Disconnect from Rex server: ")
                                     (mapcar #'portal-rex--named connections) nil t)))
          (cl-find name connections :key #'portal-rex--named :test #'equal))))))

;;;###autoload
(defun portal-rex-disconnect (connection)
  "Disconnect from the Rex server of CONNECTION.
Interactively, from the one connected server, or one read from the
minibuffer.  Its blocks' buffers are killed.  The server and what runs
on it carry on; requests still waiting fail with the code
\"portal_disconnected\"."
  (interactive (list (portal-rex--read-connection)))
  (unless (eq (portal-rex-connection-state connection) 'closed)
    (portal-rex--end connection "Disconnected" t)
    (when (called-interactively-p 'any)
      (message "Disconnected from the Rex server at %s" (portal-rex--named connection)))))

;;; Sessions and terminals from Emacs

;; The primitives of changing what a server has: sessions made, renamed and
;; destroyed, a terminal started in a session, a block renamed.  Portal
;; decides nothing about what a session is for: which session a new
;; terminal joins is `portal-rex-session-function''s, the user's to set.
;; Each command changes the server and lets the buffers follow it as they
;; follow any client's change, waiting for the server's events so that the
;; change is there in Emacs when the command returns.

(defcustom portal-rex-session-function #'portal-rex-session-default
  "Function that returns the session a new Rex terminal starts in.
`portal-rex-new-terminal' calls it with the connection to the server,
in the buffer it was started from, and starts the terminal in the
session whose ID it returns.  It may create the session, with
`portal-rex-session-create', and may prompt.

The default, `portal-rex-session-default', takes the current buffer's
session when that buffer is a block's, and otherwise reads one.  The
Rex guide, docs/rex.md, has a function that gives each project a
session named after it."
  :type 'function)

(defun portal-rex--command-connection ()
  "Return the connection a command means.
That of the current buffer's block, else the only connection, else one
read from the minibuffer."
  (if (and portal-rex-block-connection (portal-rex-live-p portal-rex-block-connection))
      portal-rex-block-connection
    (portal-rex--read-connection "Rex server: ")))

(defun portal-rex--ask (connection what method &optional payload)
  "Return what METHOD with PAYLOAD gives on CONNECTION's server, for a command.
A call the server refuses is a `user-error' saying WHAT could not be
done, with the server's own words, such as at a limit of its."
  (condition-case failure
      (portal-rex-call connection method payload)
    (portal-rex-error
     (user-error "%s: %s" what (or (plist-get (nth 2 failure) :message) (cadr failure))))))

(defun portal-rex--session-name (connection session-id)
  "Return the session SESSION-ID of CONNECTION as a message names it."
  (or (portal-rex--session-label connection session-id) session-id))

(defun portal-rex-find-session (connection label)
  "Return the ID of the first of CONNECTION's sessions labelled LABEL, or nil.
The server lets sessions share a label, and keeps them in its own order."
  (plist-get (seq-find (lambda (session) (equal (plist-get session :label) label))
                       (portal-rex-connection-sessions (portal-rex--connection connection)))
             :session_id))

(defun portal-rex--session-choices (connection)
  "Return CONNECTION's sessions as completion choices, (NAME . SESSION-ID).
A session's name is its label; a label that several share is followed
by each one's ID."
  (let ((sessions (append (portal-rex-connection-sessions connection) nil)))
    (mapcar (lambda (session)
              (let ((label (plist-get session :label)))
                (cons (if (> (cl-count label sessions :test #'equal
                                       :key (lambda (other) (plist-get other :label)))
                             1)
                          (format "%s (%s)" label (plist-get session :session_id))
                        label)
                      (plist-get session :session_id))))
            sessions)))

(defun portal-rex--read-session (connection prompt)
  "Read one of CONNECTION's sessions with PROMPT, and return its ID.
The current buffer's session is the default."
  (let* ((choices (or (portal-rex--session-choices connection)
                      (user-error "The Rex server at %s has no sessions"
                                  (portal-rex--named connection))))
         (default (and (eq portal-rex-block-connection connection)
                       (car (rassoc portal-rex-session-id choices))))
         (name (completing-read (format-prompt prompt default) choices nil t nil nil default)))
    (or (cdr (assoc name choices))
        (user-error "No Rex session is called %s" name))))

(defun portal-rex-session-default (connection)
  "Return the session a new terminal on CONNECTION's server starts in.
The current buffer's session when that buffer is a block's on that
server.  Otherwise one read from the minibuffer, completing over the
server's sessions: a name that none has creates a session with it."
  (if (and (eq portal-rex-block-connection connection) portal-rex-session-id)
      portal-rex-session-id
    (let* ((choices (portal-rex--session-choices connection))
           (name (string-trim (completing-read "Rex session for the terminal (a new name creates one): "
                                               choices))))
      (cond
       ((string-empty-p name) (user-error "Name a Rex session for the terminal"))
       ((cdr (assoc name choices)))
       ((portal-rex-find-session connection name))
       (t (portal-rex-session-create connection name))))))

;;;###autoload
(defun portal-rex-session-create (connection label)
  "Create a session called LABEL on CONNECTION's Rex server, and return its ID.
CONNECTION is nil for the only one.  An empty or nil LABEL lets the
server choose one, such as quiet-meadow.  The session starts empty; it
is among the connection's sessions when this returns.  The server lets
two sessions share a label."
  (interactive
   (list (portal-rex--command-connection)
         (read-string "New Rex session's label (empty for one the server chooses): ")))
  (let* ((connection (portal-rex--connection connection))
         (label (and label (string-trim label)))
         (id (plist-get (portal-rex--ask connection "Cannot create a Rex session" "session.create"
                                         (and label (not (string-empty-p label))
                                              (list :label label)))
                        :session_id)))
    (unless (stringp id)
      (user-error "Cannot create a Rex session: the server gave no session ID"))
    ;; Its event usually comes before the answer; if it has not, wait.
    (unless (portal-rex--await connection (lambda () (portal-rex--session connection id))
                               portal-rex-timeout)
      (portal-rex--label-session connection id (or label "")))
    (when (called-interactively-p 'any)
      (message "Created Rex session %s" (portal-rex--session-name connection id)))
    id))

;;;###autoload
(defun portal-rex-session-rename (connection session-id label)
  "Call the session SESSION-ID on CONNECTION's Rex server LABEL.
Interactively, read the session, by default the current buffer's, and
its new label.  The session's buffers are renamed as the server says it
has changed.  An empty LABEL gives back the label the server chose when
it made the session."
  (interactive
   (let* ((connection (portal-rex--command-connection))
          (session-id (portal-rex--read-session connection "Rename Rex session")))
     (list connection session-id
           (read-string (format "Rename Rex session %s to: "
                                (portal-rex--session-name connection session-id))
                        (portal-rex--session-label connection session-id)))))
  (let ((connection (portal-rex--connection connection)))
    (portal-rex--ask connection
                     (format "Cannot rename Rex session %s"
                             (portal-rex--session-name connection session-id))
                     "session.set_label" (list :session_id session-id :label (or label "")))
    nil))

;;;###autoload
(defun portal-rex-session-destroy (connection session-id &optional confirm)
  "Destroy the session SESSION-ID on CONNECTION's Rex server, ending its blocks.
Every program in the session ends, as when a terminal window closes, and
its blocks' buffers are killed.  With CONFIRM, as interactively, ask
first, naming how many blocks will end.  Interactively, read the
session, by default the current buffer's.  Return non-nil if the session
was destroyed."
  (interactive
   (let ((connection (portal-rex--command-connection)))
     (list connection (portal-rex--read-session connection "Destroy Rex session") t)))
  (let* ((connection (portal-rex--connection connection))
         (name (portal-rex--session-name connection session-id)))
    (when (or (not confirm)
              (let ((count (length (plist-get (portal-rex--ask connection
                                                               (format "Cannot destroy Rex session %s" name)
                                                               "session.list_blocks"
                                                               (list :session_id session-id))
                                              :blocks))))
                (yes-or-no-p (format "Destroy Rex session %s%s? " name
                                     (pcase count
                                       (0 ", which has no blocks")
                                       (1 " and end its one block")
                                       (_ (format " and end its %d blocks" count)))))))
      (portal-rex--ask connection (format "Cannot destroy Rex session %s" name)
                       "session.destroy" (list :session_id session-id))
      ;; The server answers once the session has gone, and its events say so.
      (portal-rex--await connection (lambda () (not (portal-rex--session connection session-id)))
                         portal-rex-timeout)
      (when confirm (message "Destroyed Rex session %s" name))
      t)))

(defun portal-rex--blocks-listed (connection session-id)
  "Ask CONNECTION's server for SESSION-ID's blocks, and wait for the answer.
Its buffers then match what the server says, names included."
  (portal-rex--list-blocks connection session-id)
  (portal-rex--await connection
                     (lambda () (not (assoc session-id (portal-rex-connection-lists connection))))
                     portal-rex-timeout))

;;;###autoload
(defun portal-rex-new-terminal (connection session-id &optional directory)
  "Start a shell in a new terminal in session SESSION-ID of CONNECTION's server.
The shell starts in DIRECTORY, by default `default-directory'.  Show the
terminal's buffer in the selected window, and return it.

Interactively, the server is the current buffer's block's, or the only
one, or one read, and the session is the one `portal-rex-session-function'
returns.  The block has a window of its own in the session, a tab in
Rex's app, which does not become the session's active one."
  (interactive
   (let ((connection (portal-rex--command-connection)))
     (list connection (funcall portal-rex-session-function connection))))
  (let* ((connection (portal-rex--connection connection))
         (directory (file-name-as-directory (expand-file-name (or directory default-directory))))
         (name (portal-rex--session-name connection session-id))
         result block-id buffer)
    (when (file-remote-p directory)
      (user-error "Start a Rex terminal in a local directory, not %s" directory))
    (setq result (portal-rex--ask
                  connection (format "Cannot start a terminal in Rex session %s" name)
                  "session.new_window"
                  (list :session_id session-id
                        :layout (list :block (list :flavor "com.superlogical.terminal.shell"
                                                   :options (list :cwd (directory-file-name directory))))
                        :focus :false))
          block-id (let ((ids (plist-get result :block_ids)))
                     (and (vectorp ids) (> (length ids) 0) (aref ids 0))))
    (unless (stringp block-id)
      (user-error "Started a terminal in Rex session %s, but the server gave no block ID" name))
    ;; Its buffer comes as any block's does, once the server has listed it.
    (unless (portal-rex-block-buffer connection block-id)
      (portal-rex--blocks-listed connection session-id))
    (setq buffer (or (portal-rex-block-buffer connection block-id)
                     (user-error "Started block %s in Rex session %s, but its buffer has not come"
                                 block-id name)))
    (with-current-buffer buffer
      (setq default-directory directory))
    (pop-to-buffer-same-window buffer)
    ;; A graphical Emacs opens the block's view as it shows the buffer.
    (when (display-graphic-p)
      (redisplay t)
      (when (buffer-local-value 'portal-view--target buffer)
        (with-current-buffer buffer (portal-terminal-focus))))
    buffer))

;;;###autoload
(defun portal-rex-block-rename (label)
  "Call the current buffer's Rex block LABEL, on its server.
The buffer's name follows, as it follows any change of the label.  An
empty LABEL gives the block a default label made from its ID.
`portal-terminal-rename' does this in a block's buffer."
  (interactive
   (progn (portal-rex--this-block)
          (list (read-string "Rename Rex block: " portal-rex--block-label))))
  (let ((connection (portal-rex--this-block))
        (session-id portal-rex-session-id))
    (portal-rex--ask connection (format "Cannot rename Rex block %s" portal-rex--block-label)
                     "session.set_block_label"
                     (list :session_id session-id :block_id portal-rex-block-id :label (or label "")))
    ;; A block in a window is relabelled with an event, a detached one
    ;; without: either way, asking for the session's blocks renames it.
    (portal-rex--blocks-listed connection session-id)
    nil))

(defun portal-rex--this-block ()
  "Return the connection of the current buffer's Rex block, or signal why not."
  (cond
   ((not portal-rex-block-connection) (user-error "Not the buffer of a Rex block"))
   ((not (portal-rex-live-p portal-rex-block-connection))
    (user-error "The Rex server of this block is not connected"))
   (t portal-rex-block-connection)))

(defun portal-rex--renamer (&optional label)
  "Rename this buffer's block LABEL, for `portal-terminal-rename'.
Without LABEL, return the block's label, to start from."
  (if label (portal-rex-block-rename label) portal-rex--block-label))

(provide 'portal-rex)
;;; portal-rex.el ends here
