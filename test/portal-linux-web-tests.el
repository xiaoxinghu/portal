;;; portal-linux-web-tests.el --- Portal's web views on Linux -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Web views in a pgtk Emacs on Wayland: a WPE WebKit page, the content of
;; native/Linux/web.c, its frames shown by the presenter of
;; native/Linux/presenter.c.  Loaded by test/linux-gui.sh after the views'
;; and terminals' suites, whose helpers these use, on the desktop of
;; test/linux-desktop.sh.  They need portal-web.so, which a build makes
;; where WPE WebKit's development files are, and WPE WebKit itself; without
;; either they are skipped, and linux-gui.sh checks what a web view says.
;;
;; The page these load is the terminals' orange, a new shade within a few
;; levels of it at every animation frame, over a pane that is green
;; underneath, so a page that covers its pane shows orange at its corners
;; and no green anywhere.  It writes what it saw to its title as JSON every
;; 100 ms: the keys, its field, clicks, scrolling and its animation frames.

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'portal-web)
(require 'portal-linux-gui-tests)
(require 'portal-linux-terminal-tests)

(defconst portal-linux-web--page
  "<!doctype html><meta charset=utf-8><title>{}</title>
<style>
html,body{margin:0;background:#f98128}
body{height:4000px}
#field{position:fixed;left:40px;top:40px;width:400px;height:60px;font-size:30px}
#link{position:fixed;left:40px;top:200px;font-size:40px}
</style>
<input id=field spellcheck=false autofocus><a id=link href=\"#clicked\">A link</a>
<script>
const state = {keys: [], frames: 0, long: 0, clicks: 0, detail: 0};
let last = 0;
requestAnimationFrame(function frame(now) {
  // A gap only while the page is shown: a hidden page draws nothing.
  if (last && now - last > 50 && document.visibilityState === 'visible') state.long++;
  last = now;
  const k = ++state.frames % 8;
  document.body.style.background = `rgb(${249 - k}, ${129 + k}, ${40 - k})`;
  requestAnimationFrame(frame);
});
document.addEventListener('visibilitychange', () => { last = 0; });
addEventListener('keydown', (event) => {
  if (event.ctrlKey && event.key === 'k') event.preventDefault();
  state.keys.push((event.ctrlKey ? 'C-' : '') + (event.altKey ? 'M-' : '') + event.key +
                  (event.defaultPrevented ? '!' : ''));
  state.keys = state.keys.slice(-20);
});
addEventListener('mousedown', (event) => { state.clicks++; state.detail = event.detail; });
setInterval(() => {
  Object.assign(state, {field: field.value, focus: document.activeElement.id,
                        scroll: Math.round(scrollY), hash: location.hash});
  document.title = JSON.stringify(state);
}, 100);
</script>"
  "The page the tests load.")

(defvar portal-linux-web--directory nil "The page's directory, for the test that runs.")

(defconst portal-linux-web--absent
  "\\`\\(?:Web views on Linux need WPE WebKit, which is not installed: install \\|This build of Portal has no web views: build it again where WPE WebKit's development files are installed\\)"
  "What a web view says where WPE WebKit or the build's web views are missing.")

(defun portal-linux-web--usable ()
  "Skip the test where this build of Portal has no web views, or WPE WebKit is missing.
Any other failure to open a web view fails the test."
  (portal-view--load)
  (let ((target (condition-case failure (portal--open "web" nil)
                  (error (if (string-match-p portal-linux-web--absent (cadr failure))
                             (ert-skip (format "No web views: %s" (cadr failure)))
                           (signal (car failure) (cdr failure)))))))
    (portal--close target)))

(defmacro portal-linux-web--with (&rest body)
  "Run BODY in a frame of one pane, with neither menu bar nor tool bar.
`portal-linux-web--open' opens pages in it; each is closed after, and the
page's directory deleted."
  (declare (indent 0))
  `(let ((menu menu-bar-mode) (tool tool-bar-mode)
         (before (portal-view-buffers 'web))
         (portal-linux-web--directory (make-temp-file "portal-linux-web-" t)))
     (portal-linux-gui--tool "grim")
     (portal-linux-gui--tool "wtype")
     (portal-linux-web--usable)
     (unwind-protect
         (save-window-excursion
           (menu-bar-mode -1)
           (tool-bar-mode -1)
           (delete-other-windows)
           ,@body)
       (dolist (buffer (append (portal-view-buffers 'web) (portal-view-buffers 'terminal)))
         (unless (memq buffer before)
           (let ((portal-terminal-confirm-kill nil)) (kill-buffer buffer))))
       (portal-linux-gui--pause 0.1)
       (discard-input)
       (setq unread-command-events nil)
       (delete-directory portal-linux-web--directory t)
       (menu-bar-mode (if menu 1 -1))
       (tool-bar-mode (if tool 1 -1)))))

(defun portal-linux-web--file (name text)
  "Write TEXT to NAME in the page's directory, and return its file URL."
  (let ((file (expand-file-name name portal-linux-web--directory)))
    (with-temp-file file (insert text))
    (concat "file://" file)))

(defun portal-linux-web--seen (&optional target)
  "What the page in TARGET last wrote to its title, as a plist, or nil."
  (let ((title (portal-linux-gui--get :title target)))
    (and title (string-prefix-p "{" title)
         (json-parse-string title :object-type 'plist :array-type 'list))))

(defun portal-linux-web--open (&optional url)
  "Open URL, or the tests' page, in the selected pane, in a new buffer.
Its pane is green underneath, and its keymap one of the test's own.
Returns the view's target once the page has loaded and shows."
  (switch-to-buffer (generate-new-buffer "*portal-linux-web*"))
  (face-remap-add-relative 'default :background portal-linux-gui--pane)
  (let ((target (portal-web-open
                 (or url (portal-linux-web--file "page.html" portal-linux-web--page)))))
    (use-local-map (make-sparse-keymap))
    (portal-linux-gui--wait (lambda () (portal-linux-gui--get :showing target)))
    (portal-linux-gui--wait (lambda () (not (portal-linux-gui--get :loading target))))
    (unless url
      (portal-linux-gui--wait (lambda () (portal-linux-web--seen target))))
    target))

(defun portal-linux-web--focus (target)
  "Give TARGET the keyboard."
  (let ((portal-linux-gui--target target))
    (portal-linux-gui--focus)))

(defun portal-linux-web--wait-for (target key predicate)
  "Wait for PREDICATE to hold of what the page in TARGET saw of KEY."
  (portal-linux-gui--wait
   (lambda () (funcall predicate (plist-get (portal-linux-web--seen target) key)))))

(defun portal-linux-web--processes (name)
  "The processes called NAME that descend from this Emacs."
  (let ((parents (make-hash-table)))
    (dolist (pid (list-system-processes))
      (when-let* ((attributes (process-attributes pid)))
        (puthash pid (cons (alist-get 'ppid attributes) (alist-get 'comm attributes))
                 parents)))
    (cl-loop for pid being the hash-keys of parents using (hash-values entry)
             when (and (equal (cdr entry) name)
                       (cl-loop for up = (car entry) then (car (gethash up parents))
                                while (and up (> up 1))
                                thereis (= up (emacs-pid))))
             collect pid)))

;;; The page

(ert-deftest portal-linux-gui-web-page-shows-in-its-pane-and-ends-with-it ()
  :tags '(:gui)
  (portal-linux-web--with
    (let* ((target (portal-linux-web--open))
           (window (selected-window)))
      (should (equal (portal-linux-gui--get :url target)
                     (concat "file://" (expand-file-name "page.html" portal-linux-web--directory))))
      (should (eql (portal-linux-gui--get :memory_frames target) 0))
      (portal-linux-terminal--covers window target)
      ;; Through a split and back.
      (set-window-buffer (split-window-below) (get-buffer-create "*scratch*"))
      (portal-linux-terminal--covers window target)
      (delete-other-windows window)
      (portal-linux-terminal--covers window target)
      ;; WebKit's processes are Emacs's, and go with the view.
      (should (portal-linux-web--processes "WPEWebProcess"))
      (kill-buffer (window-buffer window))
      (should-not (portal--inspect target))
      (portal-linux-gui--wait (lambda () (null (portal-linux-web--processes "WPEWebProcess"))))
      (portal-linux-gui--wait (lambda () (null (portal-linux-web--processes "WPENetworkProcess")))))))

(ert-deftest portal-linux-gui-web-page-outlives-its-web-process ()
  :tags '(:gui)
  (portal-linux-web--with
    (let ((target (portal-linux-web--open)))
      (let ((processes (portal-linux-web--processes "WPEWebProcess")))
        (should (= (length processes) 1))
        (signal-process (car processes) 'KILL))
      (portal-linux-gui--wait (lambda () (portal-linux-gui--get :terminated target)))
      (should (equal (portal-linux-gui--get :error target) "The page's web process stopped."))
      ;; Loading it again brings the page back, in a new process.
      (portal-web-reload)
      (portal-linux-gui--wait (lambda () (not (portal-linux-gui--get :terminated target))))
      (portal-linux-web--wait-for target :frames (lambda (frames) (and frames (> frames 10))))
      (portal-linux-terminal--covers (selected-window) target))))

(ert-deftest portal-linux-gui-web-page-plays-a-file-of-its-directory ()
  :tags '(:gui)
  "A page's media is read by its web process, which WebKit's sandbox shows its directory."
  (portal-linux-web--with
    (let ((clip (expand-file-name "clip.webm" portal-linux-web--directory)))
      (unless (eql 0 (call-process (portal-linux-gui--tool "ffmpeg") nil nil nil
                                   "-loglevel" "error" "-f" "lavfi" "-i"
                                   "testsrc=duration=4:size=320x240:rate=30"
                                   "-c:v" "libvpx" "-y" clip))
        (ert-skip "ffmpeg here makes no VP8"))
      (let ((target (portal-linux-web--open
                     (portal-linux-web--file
                      "video.html"
                      "<!doctype html><video src=clip.webm autoplay muted loop></video>
<script>setInterval(() => { const v = document.querySelector('video');
  document.title = JSON.stringify({time: v.currentTime, error: v.error && v.error.code}); }, 100);
</script>"))))
        (portal-linux-web--wait-for target :time (lambda (time) (and time (> time 1))))
        (should (eq (plist-get (portal-linux-web--seen target) :error) :null))))))

(ert-deftest portal-linux-gui-web-page-moves-to-a-file-of-another-directory ()
  :tags '(:gui)
  "A page loading a file of another directory is a web view made again, while it draws."
  (portal-linux-web--with
    (let ((target (portal-linux-web--open))
          (other (make-temp-file "portal-linux-web-other-" t)))
      (unwind-protect
          (let ((page (expand-file-name "page.html" other)))
            (with-temp-file page (insert portal-linux-web--page))
            ;; Back and forth between the two, the page animating all the while.
            (dolist (url (list (concat "file://" page)
                               (portal-linux-web--file "page.html" portal-linux-web--page)
                               (concat "file://" page)))
              (portal-web-load-url url)
              (portal-linux-gui--wait (lambda () (equal (portal-linux-gui--get :url target) url)))
              (portal-linux-web--wait-for target :frames (lambda (frames) (and frames (> frames 30))))
              (portal-linux-terminal--covers (selected-window) target)))
        (delete-directory other t)))))

;;; Busy Lisp

(ert-deftest portal-linux-gui-web-page-draws-while-lisp-is-busy ()
  :tags '(:gui)
  "WebKit runs on a thread of its own, which busy Lisp and collections leave alone."
  (portal-linux-web--with
    (let ((target (portal-linux-web--open)))
      (portal-linux-terminal--covers (selected-window) target)
      (let ((long (plist-get (portal-linux-web--seen target) :long))
            (before (portal-linux-gui--get :committed target))
            (deadline (+ (float-time) 0.5)))
        ;; Half a second of Lisp, and a collection of a few million conses.
        (while (< (float-time) deadline))
        (let ((garbage (make-list 3000000 nil))) (ignore garbage))
        (garbage-collect)
        (should (> (- (portal-linux-gui--get :committed target) before) 25))
        ;; The page never went 50 ms without an animation frame.
        (portal-linux-gui--pause 0.3)
        (should (= (plist-get (portal-linux-web--seen target) :long) long))))))

(ert-deftest portal-linux-gui-web-page-leaves-a-terminal-its-frames ()
  :tags '(:gui)
  "A terminal under output beside a page shows 60 frames a second, as the page does."
  (portal-linux-web--with
    (let* ((page (portal-linux-web--open))
           (right (split-window-right))
           (terminal (progn
                       (select-window right)
                       (portal-linux-terminal--open))))
      (portal-linux-web--focus terminal)
      (portal-linux-terminal--run terminal "yes")
      (portal-linux-gui--pause 1)
      (let ((terminal-before (portal-linux-gui--get :committed terminal))
            (page-before (portal-linux-gui--get :committed page))
            (start (float-time)))
        (portal-linux-gui--pause 2)
        (let ((seconds (- (float-time) start)))
          (ert-info ((format "Terminal %s, page %s frames in %.2f s"
                             (- (portal-linux-gui--get :committed terminal) terminal-before)
                             (- (portal-linux-gui--get :committed page) page-before) seconds))
            (should (> (/ (- (portal-linux-gui--get :committed terminal) terminal-before) seconds)
                       55))
            (should (> (/ (- (portal-linux-gui--get :committed page) page-before) seconds)
                       55))))))))

;;; Keys

(ert-deftest portal-linux-gui-web-page-takes-text-and-keeps-the-chords-it-uses ()
  :tags '(:gui)
  (portal-linux-web--with
    (let ((target (portal-linux-web--open)))
      (keymap-set (current-local-map) "C-c t" #'portal-linux-gui--mark)
      (portal-linux-web--focus target)
      (portal-linux-web--wait-for target :focus (lambda (focus) (equal focus "field")))
      (portal-linux-gui--type "hello")
      (portal-linux-web--wait-for target :field (lambda (text) (equal text "hello")))
      ;; The input method composes: a dead key and a letter make one character.
      (portal-linux-gui--type "-k" "dead_acute" "-k" "e")
      (portal-linux-web--wait-for target :field (lambda (text) (equal text "helloé")))
      ;; The page uses Control-K: it and the key after it stay with the page.
      (portal-linux-gui--type "-M" "ctrl" "-k" "k" "-m" "ctrl" "-k" "b")
      (portal-linux-web--wait-for target :field (lambda (text) (equal text "helloéb")))
      (should (member "C-k!" (plist-get (portal-linux-web--seen target) :keys)))
      (should-not unread-command-events)
      ;; It does not use Control-C: that and t are Emacs's.
      (let ((portal-linux-gui--ran nil))
        (portal-linux-gui--type "-M" "ctrl" "-k" "c" "-m" "ctrl" "-k" "t")
        (portal-linux-gui--handoff)
        (should portal-linux-gui--ran))
      (portal-linux-gui--wait (lambda () (portal-linux-gui--get :focused target)))
      (portal-linux-web--wait-for target :keys (lambda (keys) (member "C-c" keys)))
      (should (equal (plist-get (portal-linux-web--seen target) :field) "helloéb")))))

(ert-deftest portal-linux-gui-web-page-answers-an-offer-after-more-presses-than-it-keeps ()
  :tags '(:gui)
  "A busy page given more presses than Portal keeps still answers the offer after them."
  (portal-linux-web--with
    (let ((target (portal-linux-web--open
                   (portal-linux-web--file
                    "many.html"
                    "<!doctype html><title>ready</title><script>
let count = 0;
addEventListener('keydown', (event) => {
  // Busy at the first key, while the rest pile up behind it.
  if (++count === 1) { const end = performance.now() + 400; while (performance.now() < end); }
  if (event.ctrlKey && event.key === 'k') { event.preventDefault(); document.title = 'kept ' + count; }
});
</script>"))))
      (keymap-set (current-local-map) "C-k" #'portal-linux-gui--mark)
      (portal-linux-web--focus target)
      (let ((portal-linux-gui--ran nil))
        (portal-linux-gui--type (make-string 80 ?a) "-M" "ctrl" "-k" "k" "-m" "ctrl")
        (portal-linux-gui--wait
         (lambda () (equal (portal-linux-gui--get :title target) "kept 81")))
        (portal-linux-gui--wait (lambda () (not (portal-linux-gui--get :offering target))))
        (portal-linux-gui--pause 0.3)
        (should-not portal-linux-gui--ran)
        (should-not unread-command-events)))))

(ert-deftest portal-linux-gui-web-page-busy-past-an-offer-answers-only-its-own ()
  :tags '(:gui)
  "A report that comes after its offer gave up settles no later offer of the same chord."
  (portal-linux-web--with
    (let ((target (portal-linux-web--open
                   (portal-linux-web--file
                    "busy.html"
                    "<!doctype html><title>ready</title><script>
let count = 0;
addEventListener('keydown', (event) => {
  if (!event.ctrlKey || event.key !== 'k') return;
  // The first Control-K finds the page busy past the offer's second, and
  // is not used; the second is used.
  if (++count === 1) { const end = performance.now() + 2500; while (performance.now() < end); }
  else event.preventDefault();
  document.title = 'keys ' + count;
});
</script>"))))
      (keymap-set (current-local-map) "C-k" #'portal-linux-gui--mark)
      (portal-linux-web--focus target)
      (let ((portal-linux-gui--ran nil))
        ;; The first: no answer within the second, so it is Emacs's.
        (portal-linux-gui--type "-M" "ctrl" "-k" "k" "-m" "ctrl")
        (portal-linux-gui--handoff)
        (should portal-linux-gui--ran))
      ;; The second, offered while the first's report is still to come,
      ;; which says that one was not used: the second's own report keeps
      ;; it with the page.
      (portal-linux-gui--wait (lambda () (portal-linux-gui--get :focused target)))
      (let ((portal-linux-gui--ran nil))
        (portal-linux-gui--type "-M" "ctrl" "-k" "k" "-m" "ctrl")
        (portal-linux-gui--wait (lambda () (equal (portal-linux-gui--get :title target) "keys 2")))
        (portal-linux-gui--wait (lambda () (not (portal-linux-gui--get :offering target))))
        (portal-linux-gui--pause 0.3)
        (should-not portal-linux-gui--ran)
        (should-not unread-command-events)))))

;;; The pointer

(ert-deftest portal-linux-gui-web-page-takes-the-pointer-and-the-wheel ()
  :tags '(:gui)
  (portal-linux-web--with
    (let* ((target (portal-linux-web--open))
           (window (selected-window))
           (scale (portal-linux-gui--scale)))
      (portal-linux-terminal--covers window target)
      (pcase-let ((`(,left ,top . ,_) (portal-linux-gui--box window)))
        (let ((x (/ left scale)) (y (/ top scale)))
          ;; Over the field, the pointer is a text cursor; over the link, a hand.
          (portal-linux-gui--point 'move (+ x 100) (+ y 60) 'move (+ x 120) (+ y 70))
          (portal-linux-gui--wait (lambda () (equal (portal-linux-gui--get :cursor target) "text")))
          (portal-linux-gui--point 'move (+ x 60) (+ y 225))
          (portal-linux-gui--wait
           (lambda () (equal (portal-linux-gui--get :cursor target) "pointer")))
          ;; A click follows the link, and gives the view the keyboard.
          (portal-linux-gui--point 'click)
          (portal-linux-web--wait-for target :hash (lambda (hash) (equal hash "#clicked")))
          (should (portal-linux-gui--get :focused target))
          (portal-linux-gui--events)
          ;; Two clicks are a double click.
          (portal-linux-gui--point 'move (+ x 600) (+ y 400) 'click 'click)
          (portal-linux-web--wait-for target :detail (lambda (detail) (eql detail 2)))
          ;; Three notches of the wheel, one an event as a wheel sends them,
          ;; are three of WebKit's steps.
          (portal-linux-gui--point 'scroll 1 'wait 50 'scroll 1 'wait 50 'scroll 1)
          (portal-linux-web--wait-for target :scroll (lambda (scroll) (and scroll (> scroll 0))))
          (portal-linux-gui--pause 0.5)
          (let ((scroll (plist-get (portal-linux-web--seen target) :scroll)))
            (ert-info ((format "Scrolled %s pixels" scroll))
              (should (< 150 scroll 320))))
          (portal-linux-gui--events))))))

;;; Memory frames

(ert-deftest portal-linux-web-memory-page-draws-in-memory ()
  :tags '(:gui)
  "Where WebKit is told of no GPU, a page draws in memory, which the presenter shows.
Run alone by test/linux-gui.sh, in an Emacs with PORTAL_TEST_WEB_MEMORY set:
only the first page of a process decides."
  (skip-unless (getenv "PORTAL_TEST_WEB_MEMORY"))
  (portal-linux-web--with
    (let ((target (portal-linux-web--open)))
      (portal-linux-terminal--covers (selected-window) target)
      (should (> (portal-linux-gui--get :memory_frames target) 10))
      (should (= (portal-linux-gui--get :memory_frames target)
                 (portal-linux-gui--get :rendered target))))))

;;; Without WPE WebKit

(ert-deftest portal-linux-web-without-wpe-says-what-to-install ()
  :tags '(:gui)
  "Where WPE WebKit is not installed, or the build had no web views, Portal works.
Run alone by test/linux-gui.sh, in an Emacs with PORTAL_TEST_NO_WPE set,
in which WPE WebKit's library cannot be opened."
  (skip-unless (getenv "PORTAL_TEST_NO_WPE"))
  (portal-view--load)
  (let* ((before (portal--open "terminal" '(:directory "/" :test-pattern t)))
         (next (format "web:%d" (1+ (string-to-number (cadr (split-string before ":")))))))
    (portal--close before)
    (should (string-match-p portal-linux-web--absent
                            (cadr (should-error (portal--open "web" nil) :type 'error))))
    ;; A failed open leaves nothing behind, and a second fails the same way.
    (should-not (portal--inspect next))
    (should-error (portal--open "web" nil) :type 'error))
  ;; Terminals work.
  (portal-linux-terminal--with
    (portal-linux-terminal--covers (selected-window) (portal-linux-terminal--open))))

(provide 'portal-linux-web-tests)
;;; portal-linux-web-tests.el ends here
