;;; noteworthy-collab-preview.el --- Drive a standalone tinymist preview -*- lexical-binding: t; -*-

;; Author: r0k0r
;; Keywords: typst, collaboration, preview

;;; Commentary:
;; Talks to a tinymist preview server that runs *independently* of the
;; Noteworthy GUI server -- started by hand on the machine that holds the
;; project, not through /api/tinymist/start.  That matters: the GUI server
;; owns a single process shared by every client, so pushing one editor's
;; buffer into it would show your unsaved text to everyone.  A session you
;; started is yours.
;;
;; Such a session sees the project two ways at once:
;;
;;   * the filesystem, for every file you do not have open -- including the
;;     CRDT room's debounced writes from other peers, and
;;   * memory overlays pushed over its control plane, for the buffers you do
;;     have open.
;;
;; The overlay is always the CRDT-merged text, so it cannot diverge from what
;; the room will write; it just arrives sooner.  Verified against tinymist
;; 0.15.2: an overlay shadows the file on disk until `removeMemoryFiles',
;; which is why `noteworthy-collab-preview-drop' matters on leave/kill.
;;
;; Start the server yourself, e.g. over TRAMP from the project root:
;;
;;   tinymist preview --no-open --root . \
;;     --data-plane-host 127.0.0.1:23625 --control-plane-host 127.0.0.1:23626 \
;;     templates/core/parser.typ
;;
;; then forward both ports and point this at the control plane:
;;
;;   ssh -L 23625:localhost:23625 -L 23626:localhost:23626 yourserver

;;; Code:

;; Deliberately NOT `with-lsp-workspace': that is a macro, so it must be
;; available when this file is byte-compiled or the call is left as a function
;; call and dies at runtime with "Invalid function: with-lsp-workspace" -- which
;; is exactly what a packaging build produced.  It expands to nothing more than
;; a let on `lsp--cur-workspace', so bind that directly and depend on no macro.
(defvar lsp--cur-workspace)

(require 'websocket)
(require 'json)
;; cl-pushnew and seq-filter below are not autoloaded.
(require 'cl-lib)
(require 'seq)

(defcustom noteworthy-collab-preview-control-url "ws://localhost:23626"
  "Control-plane WebSocket URL of a standalone tinymist preview session."
  :type 'string
  :group 'noteworthy-collab)

(defcustom noteworthy-collab-preview-push-delay 0.15
  "Idle seconds before pushing a changed buffer to the preview."
  :type 'number
  :group 'noteworthy-collab)

(defcustom noteworthy-collab-tinymist-log "logs/tinymist.log"
  "Path of the tinymist preview log, relative to the project root.
The preview runs on the machine holding the project, so its log lives
there too -- this is the only place its compile output appears."
  :type 'string
  :group 'noteworthy-collab)

(defun noteworthy-collab-typst-inputs (root)
  "Return the typst `--input' flags for the project at ROOT, as a list.

Mirrors `noteworthy.py --print-inputs': chapters are the numeric
directories under content/, pages the numeric .typ files inside them, and
page-folders is keyed by chapter *index* rather than folder name.  Without
these the template falls back to 0-based names and looks for files that do
not exist.  Computed with plain file operations so it works over TRAMP,
where running the script would mean a remote process."
  (let* ((content (expand-file-name "content" root))
         (ch-dirs (when (file-directory-p content)
                    (sort (seq-filter
                           (lambda (d) (and (string-match-p "\\`[0-9]+\\'" d)
                                            (file-directory-p (expand-file-name d content))))
                           (directory-files content nil "\\`[^.]"))
                          (lambda (a b) (< (string-to-number a) (string-to-number b))))))
         (ch-folders nil) (pg-alist nil) (idx 0))
    (dolist (ch ch-dirs)
      (let* ((dir (expand-file-name ch content))
             (pages (sort (delq nil (mapcar (lambda (f)
                                              (when (string-match "\\`\\([0-9]+\\)\\.typ\\'" f)
                                                (match-string 1 f)))
                                            (directory-files dir nil nil)))
                          (lambda (a b) (< (string-to-number a) (string-to-number b))))))
        (when pages
          (push ch ch-folders)
          (push (cons (number-to-string idx) (vconcat pages)) pg-alist)
          (setq idx (1+ idx)))))
    (list "--input" (format "chapter-folders=%s" (json-encode (vconcat (nreverse ch-folders))))
          "--input" (format "page-folders=%s" (json-encode (nreverse pg-alist))))))

(defcustom noteworthy-collab-preview-data-port 23627
  "Port the LSP-hosted preview serves its page and data plane on.
Reach it over an SSH tunnel: tinymist refuses websockets whose Origin is
not localhost, so a hostname URL loads the page and never streams it."
  :type 'integer
  :group 'noteworthy-collab)

(defcustom noteworthy-collab-preview-control-port 23628
  "Control-plane port requested when starting the preview.
Note the LSP-hosted preview currently ignores this and opens only the
data plane; scrolling goes through `tinymist.scrollPreview' instead."
  :type 'integer
  :group 'noteworthy-collab)

(defcustom noteworthy-collab-preview-tunnel-host 'auto
  "Host to forward the preview ports from, or nil to manage tunnels yourself.
`auto\=' takes the host from the project root, so a project opened as
/sshx:yulee:... tunnels to yulee."
  :type '(choice (const :tag "Take it from the project root" auto)
                 (const :tag "Do not manage a tunnel" nil)
                 (string :tag "Host"))
  :group 'noteworthy-collab)

(defvar noteworthy-collab-preview--tunnel-process nil)

(defvar noteworthy-collab-preview--inputs nil
  "Chapter/page mapping the running language server was started with.
The mapping travels in initializationOptions and is only read once, so a
chapter or page added since then is invisible until the server restarts.")

(defun noteworthy-collab-preview--tunnel-target ()
  "Return the host to tunnel to, or nil."
  (pcase noteworthy-collab-preview-tunnel-host
    ('nil nil)
    ('auto (and (bound-and-true-p noteworthy-collab-project-root)
                (file-remote-p noteworthy-collab-project-root 'host)))
    (host host)))

(defun noteworthy-collab-preview--port-listening-p (port)
  "Return non-nil if something accepts connections on localhost PORT."
  (condition-case nil
      (let ((proc (open-network-stream "nw-port-probe" nil "127.0.0.1" port)))
        (delete-process proc) t)
    (error nil)))

;;;###autoload
(defun noteworthy-collab-preview-ensure-tunnel ()
  "Forward the preview ports from the project host, if needed.

The preview must be reached over localhost -- tinymist refuses any
websocket whose Origin is not localhost, so pointing the pane at a
hostname loads the page and never streams the document."
  (interactive)
  (let ((host (noteworthy-collab-preview--tunnel-target))
        (data noteworthy-collab-preview-data-port)
        (control noteworthy-collab-preview-control-port))
    (cond
     ((null host) nil)
     ((process-live-p noteworthy-collab-preview--tunnel-process)
      noteworthy-collab-preview--tunnel-process)
     ((noteworthy-collab-preview--port-listening-p data)
      (noteworthy-collab--log 'info "Preview port %d already forwarded" data)
      t)
     (t
      (setq noteworthy-collab-preview--tunnel-process
            (start-process "noteworthy-preview-tunnel" " *noteworthy-preview-tunnel*"
                           "ssh" "-N"
                           "-o" "ExitOnForwardFailure=yes"
                           "-L" (format "%d:127.0.0.1:%d" data data)
                           "-L" (format "%d:127.0.0.1:%d" control control)
                           host))
      (set-process-query-on-exit-flag noteworthy-collab-preview--tunnel-process nil)
      (sleep-for 2)
      (message "Preview tunnel to %s on %d/%d" host data control)
      noteworthy-collab-preview--tunnel-process))))

(defcustom noteworthy-collab-preview-id "default_preview"
  "Preview task id used by `tinymist.scrollPreview'.
`tinymist.doStartPreview' names the primary preview this."
  :type 'string
  :group 'noteworthy-collab)

(defcustom noteworthy-collab-preview-auto-repaint t
  "Whether to force the preview xwidget to repaint after edits.
Emacs only redraws an xwidget when something touches its window, so a
preview that has just recompiled sits stale until the mouse moves over
it."
  :type 'boolean
  :group 'noteworthy-collab)

(defcustom noteworthy-collab-preview-repaint-interval 0.5
  "Seconds between repaint nudges while a burst is active."
  :type 'number
  :group 'noteworthy-collab)

(defcustom noteworthy-collab-preview-repaint-duration 2.0
  "How long to keep nudging after a change.
Long enough to cover tinymist recompiling and pushing the new frames."
  :type 'number
  :group 'noteworthy-collab)

(defvar noteworthy-collab-preview--repaint-timer nil)
(defvar noteworthy-collab-preview--repaint-until 0)

(defun noteworthy-collab-preview--xwidget-windows ()
  "Return (BUFFER . WINDOW) pairs for displayed webkit xwidgets."
  (delq nil
        (mapcar (lambda (buf)
                  (when (string-match-p "xwidget-webkit" (buffer-name buf))
                    (let ((win (get-buffer-window buf t)))
                      (and win (cons buf win)))))
                (buffer-list))))

(defcustom noteworthy-collab-preview-repaint-method 'js
  "How to make the preview xwidget repaint.

`js\=' asks the page itself to repaint -- a scroll nudge plus a throwaway
transform, ~0.01ms, and it makes WebKit produce a genuinely new frame,
which is what Emacs needs in order to blit anything.
`light\=' only marks the window dirty and redisplays: free, but Emacs
happily redraws the stale pixmap, so it often changes nothing.
`resize\=' forces a full WebKit relayout: ~780ms per call on a remote
preview, enough to make typing visibly stutter.  Last resort."
  :type '(choice (const :tag "Nudge the page from JS (free)" js)
                 (const :tag "Redisplay the window (free, often ineffective)" light)
                 (const :tag "Resize the widget (slow, last resort)" resize))
  :group 'noteworthy-collab)

(defun noteworthy-collab-preview-repaint ()
  "Make the preview xwidget repaint now."
  (interactive)
  (dolist (pair (noteworthy-collab-preview--xwidget-windows))
    (let ((buf (car pair)) (win (cdr pair)))
      (when (eq noteworthy-collab-preview-repaint-method 'js)
        (with-current-buffer buf
          (let ((xw (ignore-errors (xwidget-webkit-current-session))))
            (when xw
              ;; Scroll by a pixel and back, then flip a transform on and off
              ;; next frame: either produces a new frame, and both are
              ;; visually identity operations.
              (ignore-errors
                (xwidget-webkit-execute-script
                 xw (concat "(function(){var e=document.scrollingElement||document.documentElement;"
                            "var y=e.scrollTop;e.scrollTop=y+1;e.scrollTop=y;"
                            "var b=document.body;if(b){b.style.transform='translateZ(0)';"
                            "requestAnimationFrame(function(){b.style.transform='';});}})();")))))))
      (when (eq noteworthy-collab-preview-repaint-method 'resize)
        (with-current-buffer buf
          (let ((xw (ignore-errors (xwidget-webkit-current-session))))
            (when xw
              (let ((w (window-pixel-width win))
                    (h (window-pixel-height win)))
                (ignore-errors (xwidget-resize xw (max 1 (1- w)) h))
                (ignore-errors (xwidget-resize xw w h)))))))
      (force-window-update win)))
  (when (memq noteworthy-collab-preview-repaint-method '(light resize))
    (redisplay t)))

(defun noteworthy-collab-preview--repaint-tick ()
  "Repaint if a preview is on screen; otherwise do nothing.
Deliberately not driven by editing hooks: frames arrive whenever tinymist
finishes compiling -- after a peer\'s edit, a config change, a font
change -- not only after something you typed."
  (when (noteworthy-collab-preview--xwidget-windows)
    (noteworthy-collab-preview-repaint)))

;;;###autoload
(define-minor-mode noteworthy-collab-preview-repaint-mode
  "Keep the preview xwidget repainting on its own.

Emacs only blits an xwidget when its window is touched, so a preview that
has recompiled sits stale until the mouse crosses it.  There is no Emacs
setting for this -- xwidget.el has no damage-to-redisplay path -- so a
timer asks the page to produce a frame instead.  With
`noteworthy-collab-preview-repaint-method\=' set to `js\=' a tick costs
about 0.01ms and does nothing at all when no preview is displayed."
  :global t
  :group 'noteworthy-collab
  (when (timerp noteworthy-collab-preview--repaint-timer)
    (cancel-timer noteworthy-collab-preview--repaint-timer)
    (setq noteworthy-collab-preview--repaint-timer nil))
  (when noteworthy-collab-preview-repaint-mode
    (setq noteworthy-collab-preview--repaint-timer
          (run-with-timer noteworthy-collab-preview-repaint-interval
                          noteworthy-collab-preview-repaint-interval
                          #'noteworthy-collab-preview--repaint-tick))))

(defun noteworthy-collab-preview-ensure-repaint ()
  "Make sure something is keeping the preview xwidget repainted.
Prefers noteworthy.el\'s own repaint mode when that package provides it,
so the two do not each run a timer."
  (when noteworthy-collab-preview-auto-repaint
    (cond
     ((fboundp 'noteworthy-preview-repaint-mode)
      (unless (bound-and-true-p noteworthy-preview-repaint-mode)
        (noteworthy-preview-repaint-mode 1)))
     ((not noteworthy-collab-preview-repaint-mode)
      (noteworthy-collab-preview-repaint-mode 1)))))

(defun noteworthy-collab-preview-repaint-burst ()
  "Compatibility shim for older callers."
  (noteworthy-collab-preview-ensure-repaint))

(defvar noteworthy-collab-preview--socket nil)
(defvar noteworthy-collab-preview--timer nil)
(defvar noteworthy-collab-preview--pending nil
  "Buffers whose content still needs pushing.")
(defvar noteworthy-collab-preview--overlaid nil
  "Server-side paths we currently shadow with a memory overlay.")

(defun noteworthy-collab-preview-connected-p ()
  "Return non-nil when the control plane is connected."
  (and noteworthy-collab-preview--socket
       (websocket-openp noteworthy-collab-preview--socket)))

(defun noteworthy-collab-preview--server-path (file)
  "Return FILE as tinymist sees it, i.e. without any TRAMP prefix."
  (when file
    (or (file-remote-p file 'localname) (expand-file-name file))))

(defun noteworthy-collab-preview--buffer-text ()
  (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max))))

(defun noteworthy-collab-preview--send (payload)
  (when (noteworthy-collab-preview-connected-p)
    (condition-case err
        (websocket-send-text noteworthy-collab-preview--socket (json-encode payload))
      (error (noteworthy-collab--log 'warn "Preview send failed: %s"
                                     (error-message-string err))))))

(defun noteworthy-collab-preview--push-buffers (buffers)
  "Send an updateMemoryFiles overlay for BUFFERS."
  (let (files)
    (dolist (buf buffers)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((path (noteworthy-collab-preview--server-path buffer-file-name)))
            (when path
              (push (cons path (noteworthy-collab-preview--buffer-text)) files)
              (cl-pushnew path noteworthy-collab-preview--overlaid :test #'equal))))))
    (when files
      (noteworthy-collab-preview--send `(("event" . "updateMemoryFiles")
                                         ("files" . ,files))))))

(defun noteworthy-collab-preview--flush ()
  (setq noteworthy-collab-preview--timer nil)
  (let ((buffers noteworthy-collab-preview--pending))
    (setq noteworthy-collab-preview--pending nil)
    (noteworthy-collab-preview--push-buffers buffers)))

(defun noteworthy-collab-preview-push (&optional buffer)
  "Queue BUFFER (default current) for a debounced overlay push."
  (let ((buf (or buffer (current-buffer))))
    (when (and (noteworthy-collab-preview-connected-p) (buffer-file-name buf))
      (cl-pushnew buf noteworthy-collab-preview--pending)
      (when noteworthy-collab-preview--timer
        (cancel-timer noteworthy-collab-preview--timer))
      (setq noteworthy-collab-preview--timer
            (run-with-idle-timer noteworthy-collab-preview-push-delay nil
                                 #'noteworthy-collab-preview--flush)))))

(defun noteworthy-collab-preview-drop (&optional file)
  "Drop the memory overlay for FILE so tinymist reads it from disk again."
  (let ((path (noteworthy-collab-preview--server-path (or file (buffer-file-name)))))
    (when (and path (member path noteworthy-collab-preview--overlaid))
      (setq noteworthy-collab-preview--overlaid
            (delete path noteworthy-collab-preview--overlaid))
      (noteworthy-collab-preview--send `(("event" . "removeMemoryFiles")
                                         ("files" . [,path]))))))

(defun noteworthy-collab-preview--sync-all ()
  "Answer tinymist's syncEditorChanges with every joined buffer."
  (noteworthy-collab-preview--push-buffers
   (seq-filter (lambda (buf)
                 (with-current-buffer buf
                   (and (bound-and-true-p noteworthy-collab--file-path)
                        buffer-file-name)))
               (buffer-list))))

(defun noteworthy-collab-preview--on-message (_ws frame)
  (let* ((payload (ignore-errors (json-parse-string (websocket-frame-text frame)
                                           :object-type 'alist
                                           :false-object nil :null-object nil)))
         (event (alist-get 'event payload)))
    (pcase event
      ("syncEditorChanges" (noteworthy-collab-preview--sync-all))
      ("compileStatus"
       (let ((kind (alist-get 'kind payload)))
         (unless (equal kind "Compiling")
           (noteworthy-collab--log 'info "[preview] %s" kind)))))))

;;;###autoload
(defun noteworthy-collab-preview-connect (&optional url)
  "Connect to a standalone tinymist preview control plane at URL."
  (interactive (list (read-string "Control plane: " noteworthy-collab-preview-control-url)))
  (let ((target (or url noteworthy-collab-preview-control-url)))
    (noteworthy-collab-preview-disconnect)
    (setq noteworthy-collab-preview--overlaid nil)
    (condition-case err
        (setq noteworthy-collab-preview--socket
              (websocket-open
               target
               ;; tinymist warns on a missing Origin and calls it a future
               ;; hard error.
               :custom-header-alist '(("Origin" . "http://localhost"))
               :on-message #'noteworthy-collab-preview--on-message
               :on-close (lambda (_ws)
                           (setq noteworthy-collab-preview--socket nil
                                 noteworthy-collab-preview--overlaid nil)
                           (noteworthy-collab--log 'warn "Preview control plane closed"))))
      (error
       (noteworthy-collab--log 'error "Preview connect failed: %s" (error-message-string err))
       nil))
    (when (noteworthy-collab-preview-connected-p)
      (noteworthy-collab--log 'info "Preview control plane: %s" target)
      (noteworthy-collab-preview--sync-all)
      ;; The xwidget is created by the layout at init, so its page was very
      ;; likely loaded while tinymist was still down -- it would sit on
      ;; "connection refused" forever, since connecting the control plane says
      ;; nothing to an already-loaded page. Reload it now that we know the
      ;; preview is actually answering.
      (when (fboundp 'noteworthy-collab-refresh-preview)
        (ignore-errors (noteworthy-collab-refresh-preview)))
      (message "Noteworthy preview connected: %s" target)
      t)))

(defun noteworthy-collab--lsp-ready-p ()
  "Return non-nil when the LSP in this buffer can take executeCommand."
  (and (bound-and-true-p lsp-mode)
       (ignore-errors (lsp-workspaces))
       (ignore-errors
         (let ((caps (lsp--server-capabilities)))
           (and caps (lsp-get caps :executeCommandProvider))))))

(defun noteworthy-collab--when-lsp-ready (buffer fn &optional attempts)
  "Run FN in BUFFER once its language server is ready, polling once a second."
  (let ((attempts (or attempts 40)))
    (if (not (buffer-live-p buffer))
        nil
      (with-current-buffer buffer
        (cond
         ((noteworthy-collab--lsp-ready-p) (funcall fn))
         ((<= attempts 0)
          (message "Noteworthy: tinymist did not come back -- M-x noteworthy-collab-preview-start when it does"))
         (t
          (run-at-time 1 nil #'noteworthy-collab--when-lsp-ready
                       buffer fn (1- attempts))))))))

(defun noteworthy-collab-preview--master-file ()
  "Return the project's master .typ as the remote host sees it."
  (let ((master (or (bound-and-true-p noteworthy-collab-master-file)
                    (and (bound-and-true-p noteworthy-collab-project-root)
                         (expand-file-name "templates/core/parser.typ"
                                           noteworthy-collab-project-root)))))
    (and master (or (file-remote-p master 'localname) master))))

(defun noteworthy-collab-preview--page-alive-p ()
  "Return non-nil if a preview is already answering on the data port."
  (let ((url (format "http://localhost:%d/" noteworthy-collab-preview-data-port)))
    (condition-case nil
        (with-timeout (3 nil)
          (let ((buf (url-retrieve-synchronously url t t 3)))
            (when buf
              (prog1 (with-current-buffer buf
                       (goto-char (point-min))
                       (looking-at-p "HTTP/1.[01] 200"))
                (kill-buffer buf)))))
      (error nil))))

;;;###autoload
(cl-defun noteworthy-collab-preview-start (&optional force)
  "Ask the tinymist LSP to host the preview for this project.

The preview is served by the language server, not by a standalone
`tinymist preview\=' -- that one\='s data plane is broken in 0.15.x and
never completes a websocket handshake."
  (interactive "P")
  (let ((root (or (and (bound-and-true-p noteworthy-collab-project-root)
                       (or (file-remote-p noteworthy-collab-project-root 'localname)
                           noteworthy-collab-project-root))
                  (user-error "No project root -- run `noteworthy-remote-init\=' first")))
        (main (noteworthy-collab-preview--master-file)))
    (unless (and (bound-and-true-p lsp-mode) (ignore-errors (lsp-workspaces)))
      (user-error "No tinymist LSP in this buffer -- open a .typ file in the project"))
    (noteworthy-collab-preview-ensure-tunnel)
    ;; Pick up chapters/pages added since the server started.  Their mapping
    ;; only reaches tinymist through initializationOptions, so a changed
    ;; structure means restarting it -- otherwise the preview renders an
    ;; outline that no longer matches the files.
    (let ((now (ignore-errors (noteworthy-collab-typst-inputs
                               (or (bound-and-true-p noteworthy-collab-project-root)
                                   default-directory)))))
      (when (and now noteworthy-collab-preview--inputs
                 (not (equal now noteworthy-collab-preview--inputs))
                 (not force))
        (setq noteworthy-collab-preview--inputs now)
        (message "Noteworthy: structure changed, restarting tinymist...")
        (cl-return-from noteworthy-collab-preview-start
          (noteworthy-collab-reload-structure)))
      (setq noteworthy-collab-preview--inputs now))
    ;; Reuse a preview that is already serving.  Killing and immediately
    ;; re-binding the same port is what makes doStartPreview hang: the old
    ;; task has not released it yet, and tinymist has been seen to panic in
    ;; tool/preview/http.rs and take the whole language server with it.
    (when (and (not force) (noteworthy-collab-preview--page-alive-p))
      (noteworthy-collab-preview-ensure-repaint)
      (noteworthy-collab-refresh-preview)
      (message "Preview already running on port %d" noteworthy-collab-preview-data-port)
      (cl-return-from noteworthy-collab-preview-start
        (list :dataPlanePort noteworthy-collab-preview-data-port :reused t)))
    (ignore-errors
      (let ((lsp--cur-workspace (noteworthy-collab-preview--tinymist-workspace)))
        (lsp-request "workspace/executeCommand"
                     (list :command "tinymist.doKillPreview" :arguments (vector)))))
    ;; Let the old task release the port before asking for a new one.
    (sleep-for 2)
    (let* ((lsp-response-timeout 30)
           (res (let ((lsp--cur-workspace (noteworthy-collab-preview--tinymist-workspace)))
                 (lsp-request
                "workspace/executeCommand"
                (list :command "tinymist.doStartPreview"
                      :arguments
                      (vector (vector "--data-plane-host"
                                      (format "127.0.0.1:%d" noteworthy-collab-preview-data-port)
                                      "--control-plane-host"
                                      (format "127.0.0.1:%d" noteworthy-collab-preview-control-port)
                                      "--invert-colors" "never"
                                      "--root" (directory-file-name root)
                                      main)))))))
      ;; Keep the whole document as the compile target; otherwise focusing a
      ;; page leaves the preview with nothing to render.
      (ignore-errors (noteworthy-collab-preview--pin-main main))
      (noteworthy-collab-preview-ensure-repaint)
      (noteworthy-collab-refresh-preview)
      (message "Preview hosted on port %s"
               (or (plist-get res :dataPlanePort) noteworthy-collab-preview-data-port))
      res)))

(defun noteworthy-collab-preview--pin-main (&optional file)
  "Pin FILE (default the project master) as tinymist\'s compile target.

Always done, never asked for: the preview renders whatever the primary
compile task produces, and focusing a page re-points that task at the
single file *and drops the project inputs* -- so the template compiles
without the chapter/page mapping, fails, and the preview falls back to
\"document is not ready\".  Pinning keeps the whole document as the target
regardless of which page has focus."
  (let ((main (or file (noteworthy-collab-preview--master-file))))
    (when (and main
               (bound-and-true-p lsp-mode)
               (ignore-errors (lsp-workspaces)))
      (condition-case err
          (progn
            (let ((lsp--cur-workspace (noteworthy-collab-preview--tinymist-workspace)))
              (lsp-request "workspace/executeCommand"
                           (list :command "tinymist.pinMain" :arguments (vector main))))
            (noteworthy-collab--log 'info "Pinned compile target: %s" main)
            t)
        (error
         (noteworthy-collab--log 'warn "Could not pin main (%s)" (error-message-string err))
         nil)))))

;;;###autoload
(defun noteworthy-collab-reload-structure ()
  "Pick up chapters/pages added or removed since the session started.

The chapter/page mapping travels in the language server\'s
initializationOptions, which are only read once, at startup -- so a new
page is invisible to the preview until the server is restarted.  This
restarts it and re-hosts the preview."
  (interactive)
  (let ((buf (current-buffer)))
    (unless (and (bound-and-true-p lsp-mode) (ignore-errors (lsp-workspaces)))
      (user-error "No tinymist LSP in this buffer -- open a .typ file in the project"))
    (message "Noteworthy: restarting tinymist to pick up the new structure...")
    (ignore-errors
      (let ((lsp--cur-workspace (noteworthy-collab-preview--tinymist-workspace)))
        (lsp-request "workspace/executeCommand"
                     (list :command "tinymist.doKillPreview" :arguments (vector)))))
    (ignore-errors (lsp-workspace-shutdown (car (lsp-workspaces))))
    (run-at-time
     2 nil
     (lambda ()
       (with-current-buffer buf
         (let ((lsp-auto-guess-root t)) (ignore-errors (lsp)))
         ;; Wait for the server to actually be able to take commands rather
         ;; than guessing at a delay: over TRAMP it can take a good while, and
         ;; asking too early fails with "does not support method
         ;; workspace/executeCommand".
         (noteworthy-collab--when-lsp-ready
          buf
          (lambda ()
            (condition-case err
                (progn (noteworthy-collab-preview-start)
                       (message "Noteworthy: structure reloaded"))
              (error
               (message "Noteworthy: preview not restarted (%s) -- M-x noteworthy-collab-preview-start"
                        (error-message-string err)))))))))))

;;;###autoload
(defun noteworthy-collab-preview--tinymist-workspace ()
  "A live tinymist workspace from the session, whatever buffer we are in."
  (or (car (ignore-errors (lsp-workspaces)))
      (seq-find (lambda (w)
                  (string-match-p "tinymist"
                                  (format "%s" (lsp--workspace-server-id w))))
                (ignore-errors (lsp--session-workspaces (lsp-session))))))

(defun noteworthy-collab-preview-scroll-to-point ()
  "Scroll the preview to the cursor position (typst-preview's panelScrollTo).

`noteworthy-typst-send-position' cannot do this here: it goes through
`typst-preview--local-master', a session typst-preview.el spawned itself.
Ours is a tinymist on the project's machine that we talk to over the
control plane, and the path has to be the one *that* host sees."
  (interactive)
  ;; Two ways this used to do nothing, which is why it "worked sometimes":
  ;; pressed in the preview pane there is no file, and pressed in a content
  ;; file whose own LSP had not started yet the cond fell through to "No
  ;; preview to scroll".  Neither needs to fail: the event names the file
  ;; explicitly, and any tinymist workspace for the project can carry it.
  (let ((src (if buffer-file-name
                 (current-buffer)
               (seq-find (lambda (b)
                           (let ((f (buffer-local-value 'buffer-file-name b)))
                             (and f (string-suffix-p ".typ" f))))
                         (buffer-list)))))
    (unless src (user-error "No Typst buffer to scroll from"))
    (unless (eq src (current-buffer))
      (set-buffer src)))
  (let* ((path (noteworthy-collab-preview--server-path buffer-file-name))
         (line (1- (line-number-at-pos)))
         (char (max 0 (- (point) (line-beginning-position))))
         (event (list :event "panelScrollTo" :filepath path
                      :line line :character char)))
    (cond
     ;; A preview hosted by the tinymist LSP has no control-plane socket --
     ;; it ignores --control-plane-host and takes scroll requests as a
     ;; command instead. The buffer needs no pushing either: lsp-mode's
     ;; didChange already gave the server this text.
     ;; Any tinymist workspace in the session will do -- requiring one in THIS
     ;; buffer meant a just-opened content file could not scroll until
     ;; something else had started its LSP.
     ((noteworthy-collab-preview--tinymist-workspace)
      ;; Report what the server says.  This used to pass `ignore\=' as the
      ;; callback, so a preview id that no longer existed -- after a preview
      ;; restart, say -- failed in total silence, and M-o simply did nothing.
      (let ((lsp--cur-workspace (noteworthy-collab-preview--tinymist-workspace)))
        (lsp-request-async "workspace/executeCommand"
                           (list :command "tinymist.scrollPreview"
                                 :arguments (vector noteworthy-collab-preview-id event))
                           #'ignore :mode 'detached
                           :error-handler
                           (lambda (err)
                             (message "Preview scroll refused (id %s): %s"
                                      noteworthy-collab-preview-id err))))
      (message "Preview -> %s:%d:%d" (file-name-nondirectory path) (1+ line) char))
     ;; A standalone preview does have a control plane; talk to it directly.
     ((noteworthy-collab-preview-connected-p)
      (noteworthy-collab-preview--push-buffers (list (current-buffer)))
      (noteworthy-collab-preview--send
       `(("event" . "panelScrollTo") ("filepath" . ,path)
         ("line" . ,line) ("character" . ,char)))
      (message "Preview -> %s:%d:%d" (file-name-nondirectory path) (1+ line) char))
     (t
      (user-error "No preview to scroll -- start one, or connect with `noteworthy-collab-preview-connect'")))))

;;;###autoload
(defun noteworthy-collab-send-position ()
  "Scroll the preview to point, whichever preview is in use.
Falls back to `noteworthy-typst-send-position' for a local
typst-preview.el session, which is all that command knows about."
  (interactive)
  (if (or (and (bound-and-true-p lsp-mode) (ignore-errors (lsp-workspaces)))
          (noteworthy-collab-preview-connected-p))
      (noteworthy-collab-preview-scroll-to-point)
    (if (fboundp 'noteworthy-typst-send-position)
        (call-interactively 'noteworthy-typst-send-position)
      (user-error "No preview session to scroll"))))

;;;###autoload
(cl-defun noteworthy-collab-show-tinymist-log ()
  "Show the tinymist preview log for this project, tailing it live.
Opens it over TRAMP when the project is remote, so compile warnings and
errors are visible without leaving Emacs."
  (interactive)
  ;; When the preview is hosted by the tinymist LSP (tinymist.doStartPreview)
  ;; its output goes to the server's stderr buffer, not to a file on the
  ;; project host -- prefer that when it exists.
  (let* ((lsp-buf (car (seq-filter (lambda (b) (string-match-p "tinymist.*stderr" (buffer-name b)))
                                   (buffer-list))))
         (root (bound-and-true-p noteworthy-collab--project-root))
         (file (and root (expand-file-name noteworthy-collab-tinymist-log root))))
    (when lsp-buf
      (with-current-buffer lsp-buf (goto-char (point-max)))
      (if (fboundp 'noteworthy-collab--switch-bottom-buffer)
          (noteworthy-collab--switch-bottom-buffer lsp-buf)
        (pop-to-buffer lsp-buf)))
    (when lsp-buf
      (cl-return-from noteworthy-collab-show-tinymist-log lsp-buf))
    (unless root
      (user-error "No project root -- run `noteworthy-remote-init' first"))
    (unless (file-exists-p file)
      (user-error "No tinymist log at %s (is the preview running?)" file))
    (let ((buf (find-file-noselect file)))
      (with-current-buffer buf
        (setq buffer-read-only t)
        (goto-char (point-max))
        ;; Tail it, so a compile that fails while you watch shows up.
        (unless (bound-and-true-p auto-revert-tail-mode)
          (auto-revert-tail-mode 1)))
      (if (fboundp 'noteworthy-collab--switch-bottom-buffer)
          (noteworthy-collab--switch-bottom-buffer buf)
        (pop-to-buffer buf))
      buf)))

;;;###autoload
(defun noteworthy-collab-preview-disconnect ()
  "Close the control-plane connection, dropping every overlay first."
  (interactive)
  (when (noteworthy-collab-preview-connected-p)
    (dolist (path (copy-sequence noteworthy-collab-preview--overlaid))
      (noteworthy-collab-preview--send `(("event" . "removeMemoryFiles")
                                         ("files" . [,path]))))
    (ignore-errors (websocket-close noteworthy-collab-preview--socket)))
  (setq noteworthy-collab-preview--socket nil
        noteworthy-collab-preview--overlaid nil))

(provide 'noteworthy-collab-preview)
;;; noteworthy-collab-preview.el ends here
