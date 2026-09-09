;;; noteworthy-collab.el --- Real-time collaboration for Noteworthy -*- lexical-binding: t; -*-

;; Author: r0k0r
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (websocket "1.14") (typst-ts-mode "0.1") (noteworthy "0.1"))
;; Keywords: typst, collaboration, tools
;; URL: https://github.com/R0K0R/noteworthy-collab.el

;;; Commentary:
;; Real-time collaborative editing for Noteworthy Typst projects.
;; Connects to a remote server via WebSocket and uses CRDT for conflict-free sync.
;; All editing goes through the server - no local file saves.

;;; Code:

(require 'websocket)
(require 'json)
(require 'url-util)
;; cl-find-if/cl-count-if (this file) and hash-table-keys (subr-x) are used
;; below but not autoloaded.
(require 'cl-lib)
(require 'subr-x)

;; Load companion modules
(require 'noteworthy-typst)

(with-eval-after-load 'evil
  (require 'noteworthy-evil))

(require 'noteworthy-collab-layout)
(require 'noteworthy-collab-keys)
(require 'noteworthy-collab-preview)

;;; ============================================================
;;; Customization
;;; ============================================================

(defgroup noteworthy-collab nil
  "Real-time collaboration for Noteworthy."
  :group 'tools
  :prefix "noteworthy-collab-")

(defcustom noteworthy-collab-server-url "ws://localhost:8001/ws/emacs"
  "Default WebSocket URL for the collaboration server."
  :type 'string
  :group 'noteworthy-collab)

(defcustom noteworthy-collab-user-name (user-login-name)
  "Display name for collaboration sessions."
  :type 'string
  :group 'noteworthy-collab)

(defcustom noteworthy-collab-reconnect-delay 3
  "Seconds to wait before attempting reconnection."
  :type 'integer
  :group 'noteworthy-collab)

(defcustom noteworthy-collab-cursor-idle-time 0.1
  "Seconds of idle time before sending cursor position."
  :type 'number
  :group 'noteworthy-collab)

;;; ============================================================
;;; Internal Variables
;;; ============================================================

(defvar noteworthy-collab--socket nil
  "Active WebSocket connection.")

(defvar noteworthy-collab--user-id nil
  "Our user ID assigned by server.")

(defvar noteworthy-collab--user-color nil
  "Our cursor color assigned by server.")

(defvar noteworthy-collab--project-root nil
  "TRAMP path to current project root.")

(defvar noteworthy-collab--server-url nil
  "Current server URL.")

(defvar noteworthy-collab--reconnect-timer nil
  "Timer for reconnection attempts.")

(defvar noteworthy-collab--cursor-timer nil
  "Timer for debounced cursor updates.")

(defvar-local noteworthy-collab--file-path nil
  "Remote file path for this buffer (relative to project root).")

(defvar-local noteworthy-collab--applying-remote nil
  "Non-nil when applying remote changes (prevents echo).")

(defvar-local noteworthy-collab--version 0
  "Document version for this buffer.")

(defvar-local noteworthy-collab--active nil
  "Non-nil when this buffer is in collaborative mode.")

(defvar-local noteworthy-collab--synced nil
  "Non-nil once the authoritative sync for this buffer has been applied.
Cleared on join/rejoin.  Local edits made before it is set would compute
retain/delete offsets against content the server doesn't recognize, so
`noteworthy-collab--after-change' refuses to send until this is non-nil.")

(defvar-local noteworthy-collab--sync-warned nil
  "Non-nil once we've warned the user about editing before `--synced'.
Keeps that warning to once per buffer instead of once per keystroke.")

(defconst noteworthy-collab--unset :noteworthy-collab-unset
  "Sentinel distinguishing \"no saved value\" from a saved nil.
Deliberately an interned keyword, not `make-symbol': reloading this file
would mint a fresh uninterned symbol while `defvar-local' keeps the old one
as its default (defvar does not re-evaluate), so every `eq' test against it
would quietly fail -- and the stale sentinel, being truthy, would end up
assigned to `buffer-read-only'.")

(defvar-local noteworthy-collab--saved-read-only noteworthy-collab--unset
  "This buffer's own `buffer-read-only' from before we forced it read-only
while disconnected (see `noteworthy-collab--mark-buffers-read-only').  The
sentinel `noteworthy-collab--unset' means we haven't forced it.")
;; `defvar-local' does not re-evaluate on reload; refresh the default so a
;; reloaded file and its already-open buffers agree.
(setq-default noteworthy-collab--saved-read-only noteworthy-collab--unset)

(defvar noteworthy-collab--remote-cursors (make-hash-table :test 'equal)
  "Hash-table mapping user-id -> (cursor-overlay . selection-overlay).")

(defvar noteworthy-collab--remote-users (make-hash-table :test 'equal)
  "Hash-table mapping user-id -> plist of :name :color :file :line :col.")

(defvar noteworthy-collab--last-yjs-rejoin-at 0.0
  "Last timestamp when we attempted Yjs tunnel recovery.")

(defcustom noteworthy-collab-yjs-rejoin-cooldown 2.0
  "Minimum seconds between automatic Yjs tunnel recovery attempts."
  :type 'number
  :group 'noteworthy-collab)

;;; ============================================================
;;; Log Buffer
;;; ============================================================

(defvar noteworthy-collab-log-buffer "*noteworthy-collab-log*"
  "Name of the collaboration log buffer.")

(defcustom noteworthy-collab-log-max-lines 4000
  "Maximum lines to retain in the collab log buffer.
Older lines are dropped once the buffer grows past this."
  :type 'integer
  :group 'noteworthy-collab)

(defconst noteworthy-collab--log-payload-limit 500
  "Max characters of a raw JSON payload to log before eliding the rest.
A \"sync\" payload carries a whole document, and delta/cursor traffic can
fire once per keystroke -- logging either unabridged would grow the log
buffer without bound.")

(defun noteworthy-collab--truncate-for-log (str)
  "Truncate STR to `noteworthy-collab--log-payload-limit' characters."
  (if (and (stringp str) (> (length str) noteworthy-collab--log-payload-limit))
      (format "%s...[%d more chars]"
              (substring str 0 noteworthy-collab--log-payload-limit)
              (- (length str) noteworthy-collab--log-payload-limit))
    str))

(defun noteworthy-collab--log (level fmt &rest args)
  "Log message to the collab log buffer.
LEVEL is a symbol like `info', `warn', `error'.
FMT and ARGS are passed to `format'."
  (let ((msg (apply #'format fmt args))
        (timestamp (format-time-string "%H:%M:%S"))
        (level-str (upcase (symbol-name level))))
    (with-current-buffer (get-buffer-create noteworthy-collab-log-buffer)
      (goto-char (point-max))
      (let ((inhibit-read-only t))
        (insert (propertize
                 (format "[%s] " timestamp)
                 'face 'font-lock-comment-face)
                (propertize
                 (format "[%s] " level-str)
                 'face (pcase level
                         ('error 'error)
                         ('warn 'warning)
                         (_ 'font-lock-keyword-face)))
                msg "\n")
        ;; Cap the buffer so high-frequency raw-payload logging can't grow it
        ;; without bound.
        (when (> (line-number-at-pos (point-max)) noteworthy-collab-log-max-lines)
          (save-excursion
            (goto-char (point-min))
            (forward-line (- (line-number-at-pos (point-max))
                             noteworthy-collab-log-max-lines))
            (delete-region (point-min) (point)))))
      ;; Auto-scroll if visible
      (when-let ((win (get-buffer-window (current-buffer))))
        (with-selected-window win
          (goto-char (point-max)))))))

(defun noteworthy-collab-show-log ()
  "Show the collaboration log buffer."
  (interactive)
  (display-buffer (get-buffer-create noteworthy-collab-log-buffer)))

(defun noteworthy-collab-toggle-log ()
  "Toggle between vterm and collab log buffer in the terminal window."
  (interactive)
  (let* ((log-buffer noteworthy-collab-log-buffer)
         (vterm-buffer "*vterm*")
         (target-window (cl-find-if
                         (lambda (w)
                           (let ((bname (buffer-name (window-buffer w))))
                             (or (string= bname log-buffer)
                                 (string= bname vterm-buffer)
                                 (eq (buffer-local-value 'major-mode (window-buffer w))
                                     'vterm-mode))))
                         (window-list))))
    (if target-window
        (with-selected-window target-window
          (if (string= (buffer-name) log-buffer)
              (when (get-buffer vterm-buffer)
                (switch-to-buffer vterm-buffer))
            (switch-to-buffer (get-buffer-create log-buffer))))
      (message "No terminal/log window found"))))

;;; ============================================================
;;; Chat Buffer
;;; ============================================================

(defvar noteworthy-collab-chat-buffer "*noteworthy-chat*"
  "Name of the collaboration chat buffer.")

(defcustom noteworthy-collab-chat-prompt "> "
  "Prompt shown on the chat buffer's input line."
  :type 'string
  :group 'noteworthy-collab)

(defvar-local noteworthy-collab-chat--input-start nil
  "Marker at the start of the editable input line.
Everything before it is history and stays read-only; incoming messages are
inserted above it so they never disturb a half-typed line.")

(defvar noteworthy-collab-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'noteworthy-collab-chat-send)
    (define-key map (kbd "C-c C-c") #'noteworthy-collab-chat-send)
    (define-key map (kbd "C-a") #'noteworthy-collab-chat-beginning-of-input)
    map)
  "Keymap for `noteworthy-collab-chat-mode'.")

(define-derived-mode noteworthy-collab-chat-mode fundamental-mode "NW-Chat"
  "Major mode for the Noteworthy collaboration chat.
Type at the prompt and press RET to send."
  ;; No font-lock: the colours here are applied by hand per message (each
  ;; peer has their own), and font-lock would overwrite them.
  (font-lock-mode -1)
  (setq-local scroll-conservatively 101)
  (visual-line-mode 1))

(with-eval-after-load 'evil
  ;; Chat is a place to type, not to navigate: start in insert state, and let
  ;; RET send rather than open a line.
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'noteworthy-collab-chat-mode 'insert))
  (when (fboundp 'evil-define-key*)
    (evil-define-key* '(insert normal) noteworthy-collab-chat-mode-map
                      (kbd "RET") #'noteworthy-collab-chat-send)))

(defun noteworthy-collab-chat--buffer ()
  "Return the chat buffer, creating and initialising it if needed."
  (let ((buf (get-buffer-create noteworthy-collab-chat-buffer)))
    (with-current-buffer buf
      (unless (derived-mode-p 'noteworthy-collab-chat-mode)
        (noteworthy-collab-chat-mode))
      (unless (markerp noteworthy-collab-chat--input-start)
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert (propertize noteworthy-collab-chat-prompt
                              'face 'minibuffer-prompt
                              'font-lock-face 'minibuffer-prompt
                              'read-only t 'rear-nonsticky t 'front-sticky t))
          (setq noteworthy-collab-chat--input-start (point-marker))
          ;; Insertion type nil: text typed at the marker stays *after* it, so
          ;; it belongs to the input line.  (With t, the marker advances past
          ;; what you type and your line silently becomes history.)  History
          ;; inserted before the prompt still pushes the marker along, because
          ;; markers always move for insertions before them.
          (set-marker-insertion-type noteworthy-collab-chat--input-start nil))))
    buf))

(defun noteworthy-collab-chat-beginning-of-input ()
  "Move to the start of the input line, after the prompt."
  (interactive)
  (if (and (markerp noteworthy-collab-chat--input-start)
           (>= (point) noteworthy-collab-chat--input-start))
      (goto-char noteworthy-collab-chat--input-start)
    (beginning-of-line)))

(defun noteworthy-collab-chat-send ()
  "Send the text on the input line."
  (interactive)
  (let* ((start noteworthy-collab-chat--input-start)
         (text (and (markerp start)
                    (string-trim (buffer-substring-no-properties start (point-max))))))
    (cond
     ((or (null text) (string-empty-p text))
      (message "Nothing to send"))
     (t
      (let ((inhibit-read-only t))
        (delete-region start (point-max)))
      ;; No local echo: the hub broadcasts chat back to every client,
      ;; including the sender, so echoing here would double every line.
      (noteworthy-collab-send-chat text)))))

(defun noteworthy-collab--display-chat (msg)
  "Display chat message MSG in the chat buffer.
MSG contains userId, name, color, text, timestamp."
  ;; The server broadcasts the body as `text' (document_hub.send_chat); older
  ;; bridge builds used `message'.  Accept either, and never insert nil.
  (let* ((name (alist-get 'name msg))
         (color (alist-get 'color msg))
         (text (or (alist-get 'text msg) (alist-get 'message msg) ""))
         (timestamp (format-time-string "%H:%M:%S" 
                                        (seconds-to-time (/ (or (alist-get 'timestamp msg) 0) 1000))))
         (buf (get-buffer-create noteworthy-collab-chat-buffer)))
    
    (with-current-buffer buf
      (let* ((start noteworthy-collab-chat--input-start)
             ;; Insert above the prompt so a half-typed line survives.
             (at (if (markerp start)
                     (- (marker-position start) (length noteworthy-collab-chat-prompt))
                   (point-max)))
             (inhibit-read-only t)
             ;; Set both `face' and `font-lock-face': whichever mode the buffer
             ;; ends up in, one of the two is honoured.
             (line (concat (propertize (format "[%s] " timestamp)
                                       'face 'font-lock-comment-face
                                       'font-lock-face 'font-lock-comment-face)
                           (propertize (format "<%s> " name)
                                       'face `(:foreground ,color :weight bold)
                                       'font-lock-face `(:foreground ,color :weight bold))
                           text "\n")))
        (save-excursion
          (goto-char at)
          (insert (propertize line 'read-only t 'front-sticky t 'rear-nonsticky t))))
      ;; Follow the conversation only when point is not in the input line,
      ;; so scrolling back or typing is never yanked to the bottom.
      (when-let ((win (get-buffer-window buf)))
        (when (or (null noteworthy-collab-chat--input-start)
                  (< (window-point win) noteworthy-collab-chat--input-start))
          (with-selected-window win (goto-char (point-max))))))))

(defun noteworthy-collab-send-chat (message)
  "Send a chat MESSAGE to the server."
  (interactive "sChat: ")
  (when (not (string-empty-p message))
    (unless (noteworthy-collab--send
             `((type . "chat")
               (message . ,message)))
      (message "Noteworthy collab: chat message not sent -- not connected to server"))))

(defun noteworthy-collab-show-terminal ()
  "Switch bottom window to vterm."
  (interactive)
  (noteworthy-collab--switch-bottom-buffer (get-buffer "*vterm*") 'vterm))

(defun noteworthy-collab-show-debug ()
  "Switch bottom window to debug log."
  (interactive)
  (noteworthy-collab--switch-bottom-buffer (get-buffer-create noteworthy-collab-log-buffer)))

(defun noteworthy-collab-show-chat ()
  "Switch bottom window to chat."
  (interactive)
  (let ((buf (noteworthy-collab-chat--buffer)))
    (noteworthy-collab--switch-bottom-buffer buf)
    (when-let ((win (get-buffer-window buf)))
      (with-selected-window win (goto-char (point-max))))))

(defun noteworthy-collab-show-typst-log ()
  "Switch bottom window to typst log (compilation buffer)."
  (interactive)
  (let ((buf (or (get-buffer "*typst-ts-compilation*")
                 (get-buffer "*typst-compilation*")
                 (get-buffer "*noteworthy-output*")
                 (get-buffer "*typst-ws-server*")))) ;; Added user's mentioned buffer
    (if buf
        (progn
          (noteworthy-collab--switch-bottom-buffer buf)
          (with-current-buffer buf
            (goto-char (point-max))))
      (message "No typst log buffer found. Searched for: *typst-ts-compilation*, *typst-compilation*, *noteworthy-output*, *typst-ws-server*"))))

(defun noteworthy-collab--switch-bottom-buffer (buffer &optional mode-check)
  "Switch the bottom window to BUFFER.
If MODE-CHECK (symbol) is provided, it tries to find a window with that major-mode."
  (let ((target-window
         (or
          ;; The window we have used before, whatever is in it now.  Identifying
          ;; it by its current buffer only worked while that buffer was one we
          ;; recognised -- show the tinymist log there and the next M-t would
          ;; split a new window instead of cycling.
          (cl-find-if (lambda (w) (window-parameter w 'noteworthy-bottom)) (window-list))
          (cl-find-if
           (lambda (w)
             (let ((b (window-buffer w)))
               (or (string= (buffer-name b) noteworthy-collab-log-buffer)
                   (string= (buffer-name b) noteworthy-collab-chat-buffer)
                   (string= (buffer-name b) "*vterm*")
                   (with-current-buffer b
                     (or (eq major-mode 'vterm-mode)
                         (eq major-mode 'compilation-mode))))))
           (window-list)))))
    (if target-window
        (progn
          (set-window-parameter target-window 'noteworthy-bottom t)
          (with-selected-window target-window
            (when buffer (switch-to-buffer buffer))))
      ;; If not found, split editor window
      (when buffer
        (when-let ((editor-win (cl-find-if (lambda (w) (window-parameter w 'noteworthy-editor)) (window-list))))
          (select-window editor-win)
          (let ((new-win (split-window-below (floor (* 0.75 (window-height))))))
            (select-window new-win)
            (set-window-parameter new-win 'noteworthy-bottom t)
            (switch-to-buffer buffer)))))))

;;; ============================================================
;;; WebSocket Connection
;;; ============================================================

(defun noteworthy-collab--connect (url)
  "Connect to collaboration server at URL."
  (when noteworthy-collab--socket
    (websocket-close noteworthy-collab--socket)
    (setq noteworthy-collab--socket nil))
  
  (when noteworthy-collab--reconnect-timer
    (cancel-timer noteworthy-collab--reconnect-timer)
    (setq noteworthy-collab--reconnect-timer nil))
  
  (setq noteworthy-collab--server-url url)
  (noteworthy-collab--log 'info "Connecting to %s..." url)
  
  (condition-case err
      (setq noteworthy-collab--socket
            (websocket-open
             (format "%s?name=%s" url (url-hexify-string noteworthy-collab-user-name))
             :on-open #'noteworthy-collab--on-open
             :on-message #'noteworthy-collab--on-message
             :on-close #'noteworthy-collab--on-close
             :on-error #'noteworthy-collab--on-error))
    (error
     (noteworthy-collab--log 'error "Connection failed: %s" (error-message-string err))
     (noteworthy-collab--schedule-reconnect))))

(defun noteworthy-collab--on-open (_ws)
  "Handle WebSocket open."
  (noteworthy-collab--log 'info "Connected to server")
  ;; Infer preview URL from server address (default tinymist port 23625)
  (when noteworthy-collab--server-url
    (noteworthy-collab--infer-preview-url noteworthy-collab--server-url)))

(defvar noteworthy-collab--disconnecting nil
  "Non-nil while `noteworthy-collab-disconnect' is tearing the session down.
The read-only guard exists to protect edits that would be lost by an
*unexpected* drop; a deliberate disconnect must leave buffers editable.")

(defun noteworthy-collab--on-close (_ws)
  "Handle WebSocket close."
  (noteworthy-collab--log 'warn "Disconnected from server")
  (setq noteworthy-collab--socket nil)
  (unless noteworthy-collab--disconnecting
    (noteworthy-collab--mark-buffers-read-only)
    (noteworthy-collab--schedule-reconnect)))

(defun noteworthy-collab--on-error (_ws _type err)
  "Handle WebSocket error."
  (noteworthy-collab--log 'error "WebSocket error: %s" err))

(defun noteworthy-collab--on-message (_ws frame)
  "Handle incoming WebSocket message."
  (condition-case err
      (let* ((payload (websocket-frame-text frame))
             (msg (json-parse-string payload :object-type 'alist
                                      :false-object nil :null-object nil)))
        (noteworthy-collab--log 'info "RECV raw: %s" (noteworthy-collab--truncate-for-log payload))
        (noteworthy-collab--handle-message msg))
    (error
     (noteworthy-collab--log 'error "Message parse error: %s" (error-message-string err)))))

(defun noteworthy-collab--schedule-reconnect ()
  "Schedule a reconnection attempt."
  (when (and noteworthy-collab--server-url
             (not noteworthy-collab--reconnect-timer))
    (noteworthy-collab--log 'info "Reconnecting in %d seconds..." noteworthy-collab-reconnect-delay)
    (setq noteworthy-collab--reconnect-timer
          (run-with-timer noteworthy-collab-reconnect-delay nil
                          (lambda ()
                            (setq noteworthy-collab--reconnect-timer nil)
                            (when noteworthy-collab--server-url
                              (noteworthy-collab--connect noteworthy-collab--server-url)))))))

(defun noteworthy-collab--send (msg)
  "Send MSG (alist) to server as JSON.  Return non-nil on success.
Callers that act on explicit user commands (chat, join, ...) should check
the return value and report failure -- this function only logs to the
(usually hidden) log buffer."
  (cond
   ((not noteworthy-collab--socket)
    (noteworthy-collab--log 'error "SEND failed: No socket")
    nil)
   ((not (websocket-openp noteworthy-collab--socket))
    (noteworthy-collab--log 'error "SEND failed: Socket not open")
    nil)
   (t
    (let ((json-str (json-encode msg)))
      (noteworthy-collab--log 'info "SEND raw: %s" (noteworthy-collab--truncate-for-log json-str))
      (websocket-send-text noteworthy-collab--socket json-str)
      t))))

(defun noteworthy-collab-connected-p ()
  "Return non-nil if connected to server."
  (and noteworthy-collab--socket
       (websocket-openp noteworthy-collab--socket)))

;;; ============================================================
;;; Message Handling
;;; ============================================================

(defun noteworthy-collab--handle-message (msg)
  "Handle parsed message MSG from server."
  (let ((type (alist-get 'type msg)))
    (pcase type
      ("welcome"
       ;; A fresh connection means fresh ids; anything cached is from the
       ;; previous one.
       (noteworthy-collab--forget-remote-users)
       (setq noteworthy-collab--user-id (alist-get 'userId msg))
       (setq noteworthy-collab--user-color (alist-get 'color msg))
       (noteworthy-collab--update-user-cache-from-list (alist-get 'users msg))
       (noteworthy-collab--log 'info "Joined as %s (color: %s)"
                               noteworthy-collab--user-id
                               noteworthy-collab--user-color)
       ;; Rejoin current file if any
       (dolist (buf (buffer-list))
         (with-current-buffer buf
           (when (and noteworthy-collab--active noteworthy-collab--file-path)
             (noteworthy-collab--join-file-internal noteworthy-collab--file-path)))))
      
      ("sync"
       (noteworthy-collab--apply-sync msg))
      
      ("delta"
       (noteworthy-collab--apply-delta msg))
      
      ("cursor"
       (noteworthy-collab--show-cursor msg))

      ("user_joined"
       (noteworthy-collab--handle-user-presence msg))

      ("user_updated"
       (noteworthy-collab--handle-user-presence msg))

      ("user_left"
       (noteworthy-collab--handle-user-presence msg))
      
      ("users"
       (noteworthy-collab--update-users msg))
      
      ("chat"
       (noteworthy-collab--display-chat msg))

      ("saved"
       (noteworthy-collab--log 'info "Saved: %s (v%s)"
                               (alist-get 'file msg)
                               (alist-get 'version msg)))
      
      ("log"
       (let ((message (alist-get 'message msg)))
         (noteworthy-collab--log
          (intern (or (alist-get 'level msg) "info"))
          "[Server] %s" message)
         (noteworthy-collab--maybe-recover-yjs-tunnel message))))))

(defun noteworthy-collab--rejoin-active-files (&optional reason)
  "Rejoin all active file sessions.
REASON is an optional log message describing why rejoin was triggered."
  (when (noteworthy-collab-connected-p)
    (let ((joined 0)
          (seen (make-hash-table :test 'equal)))
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (when (and noteworthy-collab--active
                     noteworthy-collab--file-path
                     (not (gethash noteworthy-collab--file-path seen)))
            (puthash noteworthy-collab--file-path t seen)
            (setq joined (1+ joined))
            (noteworthy-collab--join-file-internal noteworthy-collab--file-path))))
      (when (> joined 0)
        (noteworthy-collab--log
         'warn
         "Triggered file rejoin (%s): %d active file(s)"
         (or reason "manual")
         joined)))))

(defun noteworthy-collab--maybe-recover-yjs-tunnel (message)
  "Detect Yjs tunnel failures in MESSAGE and recover by rejoining files."
  (when (and (stringp message)
             (string-match-p "Failed to forward delta to Yjs" message))
    (let ((now (float-time)))
      (when (>= (- now noteworthy-collab--last-yjs-rejoin-at)
                noteworthy-collab-yjs-rejoin-cooldown)
        (setq noteworthy-collab--last-yjs-rejoin-at now)
        (noteworthy-collab--rejoin-active-files "bridge Yjs forward failure")))))

(defun noteworthy-collab--listify (value)
  "Return VALUE as a list.
Vectors are converted to lists; other non-list values return nil."
  (cond
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t nil)))

(defun noteworthy-collab--safe-int (value default)
  "Return VALUE as an integer, falling back to DEFAULT."
  (cond
   ((integerp value) value)
   ((numberp value) (truncate value))
   ((and (stringp value)
         (string-match-p "\\`-?[0-9]+\\'" value))
    (string-to-number value))
   (t default)))

(defun noteworthy-collab--user-id-from-packet (msg)
  "Extract a user id from MSG."
  (or (alist-get 'userId msg)
      (alist-get 'id msg)
      (alist-get 'clientId msg)))

(defun noteworthy-collab--point-from-line-col (line col)
  "Translate 1-based LINE and 1-based COL to a point.

COL counts CHARACTERS, matching what `noteworthy-collab--line-col-at-pos\='
sends and what the web editor means by a column.  Not `move-to-column\=':
that counts *display* columns, so every double-width character (Korean,
CJK, emoji) before the cursor pushed the overlay one column left of where
the peer actually is."
  (save-excursion
    (goto-char (point-min))
    (forward-line (max 0 (1- (noteworthy-collab--safe-int line 1))))
    (min (+ (point) (max 0 (1- (noteworthy-collab--safe-int col 1))))
         (line-end-position))))

(defun noteworthy-collab--normalize-range (start end)
  "Clamp START and END to buffer bounds and return (START . END)."
  (let* ((min-pos (point-min))
         (max-pos (point-max))
         (clamped-start (max min-pos (min max-pos start)))
         (clamped-end (max min-pos (min max-pos end))))
    (if (> clamped-start clamped-end)
        (cons clamped-end clamped-start)
      (cons clamped-start clamped-end))))

(defun noteworthy-collab--selection-range-from-cursor (msg)
  "Extract selection range from cursor MSG as a point pair."
  (let* ((legacy-start (alist-get 'selStart msg))
         (legacy-end (alist-get 'selEnd msg))
         (start-line (or (alist-get 'selStartLine msg)
                         (and (listp legacy-start)
                              (alist-get 'line legacy-start))))
         (start-col (or (alist-get 'selStartCol msg)
                        (and (listp legacy-start)
                             (or (alist-get 'col legacy-start)
                                 (alist-get 'column legacy-start)))
                        0))
         (end-line (or (alist-get 'selEndLine msg)
                       (and (listp legacy-end)
                            (alist-get 'line legacy-end))))
         (end-col (or (alist-get 'selEndCol msg)
                      (and (listp legacy-end)
                           (or (alist-get 'col legacy-end)
                               (alist-get 'column legacy-end)))
                      0)))
    (cond
     ((and start-line end-line)
      (let* ((start-pos (noteworthy-collab--point-from-line-col start-line start-col))
             (end-pos (noteworthy-collab--point-from-line-col end-line end-col))
             (range (noteworthy-collab--normalize-range start-pos end-pos)))
        (when (/= (car range) (cdr range))
          range)))
     ((and (numberp legacy-start) (numberp legacy-end))
      (let ((range (noteworthy-collab--normalize-range legacy-start legacy-end)))
        (when (/= (car range) (cdr range))
          range))))))

(defun noteworthy-collab--line-col-at-pos (pos)
  "Return (LINE . COL) at POS.
COL is 1-based and counts characters, matching the web client.  Not
`current-column': that is a display column, and disagrees whenever the
line holds a tab or a double-width character."
  (save-excursion
    (goto-char pos)
    (cons (line-number-at-pos) (1+ (- pos (line-beginning-position))))))

(defun noteworthy-collab--store-remote-user (msg)
  "Store user identity and position fields from MSG."
  (let* ((user-id (noteworthy-collab--user-id-from-packet msg))
         (name (or (alist-get 'name msg) "unknown"))
         (color (or (alist-get 'color msg) "#FF00FF"))
         (file (alist-get 'file msg))
         (line (noteworthy-collab--safe-int (alist-get 'line msg) 1))
         (col (noteworthy-collab--safe-int
               (or (alist-get 'col msg) (alist-get 'column msg))
               0)))
    (when user-id
      (puthash user-id
               (list :name name :color color :file file :line line :col col)
               noteworthy-collab--remote-users))))

(defun noteworthy-collab--update-user-cache-from-list (users)
  "Merge USERS into `noteworthy-collab--remote-users'."
  (dolist (user (noteworthy-collab--listify users))
    (noteworthy-collab--store-remote-user user)))

(defun noteworthy-collab--replace-users-for-file (file users)
  "Make USERS the complete set of remote users in FILE.

A `users\=' packet is a snapshot, not a delta.  Merging it meant nobody
was ever removed unless a `user_left\=' happened to arrive, so a peer who
reconnected -- new id, same name -- showed up twice in the user list, and
kept a stale caret."
  (let ((present (make-hash-table :test 'equal))
        (stale nil))
    (dolist (user (noteworthy-collab--listify users))
      (let ((id (noteworthy-collab--user-id-from-packet user)))
        (when id (puthash id t present)))
      (noteworthy-collab--store-remote-user user))
    (maphash (lambda (id info)
               (when (and (equal (plist-get info :file) file)
                          (not (gethash id present)))
                 (push id stale)))
             noteworthy-collab--remote-users)
    (dolist (id stale)
      (noteworthy-collab--clear-cursor-overlays id)
      (remhash id noteworthy-collab--remote-users))))

(defun noteworthy-collab--forget-remote-users ()
  "Drop every cached peer and their carets.
Called when a session begins and ends: ids are handed out per connection,
so anything held across one is stale by definition."
  (maphash (lambda (id _info) (noteworthy-collab--clear-cursor-overlays id))
           noteworthy-collab--remote-users)
  (clrhash noteworthy-collab--remote-users))

(defun noteworthy-collab--handle-user-presence (msg)
  "Handle presence packet MSG (`user_joined`, `user_updated`, `user_left`)."
  (let* ((event (alist-get 'type msg))
         (payload (or (alist-get 'user msg) msg))
         (user-id (noteworthy-collab--user-id-from-packet payload)))
    (pcase event
      ("user_left"
       (when user-id
         (noteworthy-collab--clear-cursor-overlays user-id)
         (remhash user-id noteworthy-collab--remote-users))
       (noteworthy-collab--log 'info "Presence: user_left %s" (or user-id "unknown")))
      (_
       (noteworthy-collab--store-remote-user payload)
       (noteworthy-collab--log
        'info
        "Presence: %s %s"
        event
        (or (alist-get 'name payload) user-id "unknown"))))))

(defun noteworthy-collab--find-buffer-for-file (file-path)
  "Find buffer that is editing FILE-PATH."
  (cl-find-if (lambda (buf)
                (with-current-buffer buf
                  (and noteworthy-collab--file-path
                       (string= noteworthy-collab--file-path file-path))))
              (buffer-list)))

(defcustom noteworthy-collab-stash-dir
  (locate-user-emacs-file "noteworthy-collab-unsynced/")
  "Where buffer text is stashed when a sync would otherwise discard it."
  :type 'directory
  :group 'noteworthy-collab)

(defun noteworthy-collab--stash-unsynced (file)
  "Write the current buffer to a stash file and return its path.
Called when an incoming sync would replace text the server has never
seen -- typing into a brand-new file before its first sync arrives, for
instance.  The server's copy is authoritative and must win, or later
deltas would apply to text nobody else has; but the text is not ours to
throw away either."
  (condition-case err
      (let* ((dir (file-name-as-directory noteworthy-collab-stash-dir))
             (path (expand-file-name
                    (format "%s-%s"
                            (format-time-string "%Y%m%d-%H%M%S")
                            (file-name-nondirectory (or file (buffer-name))))
                    dir)))
        (make-directory dir t)
        (write-region (point-min) (point-max) path nil 'quiet)
        path)
    (error
     (noteworthy-collab--log 'error "Could not stash unsynced text: %s"
                             (error-message-string err))
     nil)))

(defun noteworthy-collab--apply-sync (msg)
  "Apply full sync from server."
  (let* ((file (alist-get 'file msg))
         (content (alist-get 'content msg))
         (version (alist-get 'version msg))
         (buf (noteworthy-collab--find-buffer-for-file file)))
    (when buf
      (with-current-buffer buf
        ;; This sync is about to replace the whole buffer.  If what is here
        ;; differs from what the server sent, that text exists nowhere else --
        ;; keep a copy before it goes.
        (let ((local (buffer-substring-no-properties (point-min) (point-max))))
          (when (and (> (length local) 0)
                     (not (string= local (or content ""))))
            (let ((stash (noteworthy-collab--stash-unsynced file)))
              (message "Noteworthy collab: %s replaced by the server's copy%s"
                       (buffer-name)
                       (if stash (format "; your text saved to %s" stash) ""))
              (noteworthy-collab--log 'warn "Sync replaced local text (stash: %s)"
                                      (or stash "FAILED")))))
        ;; `noteworthy-collab--applying-remote' alone stops the echo (see
        ;; `noteworthy-collab--after-change').  We deliberately do NOT bind
        ;; `inhibit-modification-hooks': that would also silence typst-preview's
        ;; and eglot's after-change hooks, which are what carry a peer's edit to
        ;; the preview and the LSP.
        ;;
        ;; A snippet's overlays/markers and every remote-cursor overlay point
        ;; into text this is about to delete outright -- clean both up before
        ;; `erase-buffer', not after.  yasnippet is optional: guard with
        ;; fboundp/bound-and-true-p so it stays that way.
        (when (and (bound-and-true-p yas-minor-mode)
                   (fboundp 'yas-active-snippets)
                   (fboundp 'yas-abort-snippet))
          (dolist (snippet (yas-active-snippets))
            (yas-abort-snippet snippet)))
        (noteworthy-collab--clear-cursor-overlays-in-buffer buf)
        ;; `erase-buffer' silently widens; save-restriction/widen makes sure
        ;; that's temporary and the user's own narrowing survives the sync.
        (save-restriction
          (widen)
          (let ((noteworthy-collab--applying-remote t)
                ;; Buffers can be forced read-only while disconnected (see
                ;; `noteworthy-collab--mark-buffers-read-only') or already be
                ;; read-only on their own; either way the sync itself must go
                ;; through.
                (inhibit-read-only t)
                (pos (point))
                (window-points (mapcar (lambda (w) (cons w (window-point w)))
                                       (get-buffer-window-list buf nil t))))
            (erase-buffer)
            (insert content)
            (setq noteworthy-collab--version version)
            ;; Try to restore position, in this window and every other window
            ;; showing the buffer.
            (goto-char (min pos (point-max)))
            (dolist (wp window-points)
              (when (window-live-p (car wp))
                (set-window-point (car wp) (min (cdr wp) (point-max)))))))
        ;; This sync is authoritative content: whatever read-only state we
        ;; imposed while disconnected (or the user's own, if that's what we
        ;; saved) can now be restored, and it's safe to let local edits
        ;; through again.
        (noteworthy-collab--restore-read-only)
        (setq noteworthy-collab--synced t)
        (setq noteworthy-collab--sync-warned nil)
        (noteworthy-collab--notify-preview)
        (noteworthy-collab--log 'info "Synced %s (v%s, %d chars)"
                                file version (length content))))))

(defun noteworthy-collab--apply-delta (msg)
  "Apply delta from remote user."
  (let* ((file (alist-get 'file msg))
         (ops (alist-get 'ops msg))
         (user-id (alist-get 'userId msg))
         (buf (noteworthy-collab--find-buffer-for-file file)))
    ;; Don't apply our own deltas (server echoes them back)
    (when (and buf 
               (not (and user-id
                         noteworthy-collab--user-id
                         (string= user-id noteworthy-collab--user-id))))
      (with-current-buffer buf
        ;; Modification hooks stay LIVE for remote edits: that is how
        ;; typst-preview pushes the buffer to tinymist (updateMemoryFiles) and
        ;; how eglot keeps the LSP mirror current.  Echo is prevented by
        ;; `noteworthy-collab--applying-remote', which
        ;; `noteworthy-collab--after-change' checks.
        ;;
        ;; Tree-sitter needs no help here: Emacs records buffer changes for
        ;; parsers below the Lisp hook layer, so the parse tree is already
        ;; up to date by the time we return.  Only fontification needs a nudge,
        ;; scoped to the text we touched.
        ;;
        ;; `--apply-ops' walks from (point-min), which under narrowing is not
        ;; absolute position 1 -- but the ops' retain/delete counts came from
        ;; the sender's absolute buffer positions.  Widen so they land on the
        ;; same text the sender meant, and restore the user's narrowing after.
        (save-restriction
          (widen)
          (let* ((noteworthy-collab--applying-remote t)
                 (range (noteworthy-collab--apply-ops ops)))
            ;; Widen by one char so a pure deletion (beg == end) still
            ;; refontifies the text that closed over the gap.
            (when range
              (font-lock-flush (max (point-min) (1- (car range)))
                               (min (point-max) (1+ (cdr range)))))))
        (noteworthy-collab--notify-preview)))))

(defun noteworthy-collab--notify-preview ()
  "Push the current buffer to a live typst-preview session.

Usually redundant: `typst-preview--send-buffer-on-type' sits on
`after-change-functions' and now fires on its own for remote edits.  This
covers the case where a preview session is attached but that buffer-local
hook is not installed."
  (cond
   ;; A standalone tinymist session we drive ourselves (see
   ;; noteworthy-collab-preview.el).
   ((noteworthy-collab-preview-connected-p)
    (noteworthy-collab-preview-push))
   ;; Otherwise a local typst-preview.el session, if one is attached but its
   ;; buffer-local after-change hook is not installed.
   ((and buffer-file-name
         (not (memq #'typst-preview--send-buffer-on-type after-change-functions))
         (fboundp 'typst-preview-connected-p)
         (fboundp 'typst-preview--send-buffer)
         (ignore-errors (typst-preview-connected-p)))
    (condition-case err
        (typst-preview--send-buffer)
      (error
       (noteworthy-collab--log 'warn "Preview notify failed: %s"
                               (error-message-string err)))))))

(defun noteworthy-collab--apply-ops (ops)
  "Apply delta OPS to current buffer with bounds checking.
OPS is a vector/list of operations like:
  [{\"retain\": 10}, {\"insert\": \"hello\"}, {\"delete\": 5}]

Return (BEG . END) covering the text actually touched, or nil if nothing
changed.  Callers use it to scope refontification."
  (let (beg end)
    (save-excursion
      (goto-char (point-min))
      (let ((ops-list (if (vectorp ops) (append ops nil) ops)))
        (dolist (op ops-list)
          (condition-case err
              (cond
               ((alist-get 'retain op)
                (let ((count (alist-get 'retain op))
                      (remaining (- (point-max) (point))))
                  ;; Clamp retain to remaining buffer
                  (forward-char (min count remaining))))
               ((alist-get 'insert op)
                (let ((start (point)))
                  (insert (alist-get 'insert op))
                  (setq beg (min (or beg start) start)
                        end (max (or end (point)) (point)))))
               ((alist-get 'delete op)
                (let* ((count (alist-get 'delete op))
                       (remaining (- (point-max) (point)))
                       (start (point)))
                  ;; Clamp delete to remaining buffer
                  (delete-char (min count remaining))
                  (setq beg (min (or beg start) start)
                        end (max (or end start) start)))))
            (error
             (noteworthy-collab--log 'warn "Op error: %s (op: %s)" err op))))))
    (when (and beg end)
      (cons beg end))))

(defun noteworthy-collab--show-cursor (msg)
  "Show remote user's cursor and selection.
MSG accepts both legacy and canonical selection fields."
  (let* ((user-id (noteworthy-collab--user-id-from-packet msg))
         (name (alist-get 'name msg))
         (color (alist-get 'color msg))
         (file (alist-get 'file msg))
         (line (noteworthy-collab--safe-int (alist-get 'line msg) 1))
         (col (noteworthy-collab--safe-int
               (or (alist-get 'col msg) (alist-get 'column msg))
               0))
         ;; If file is nil, use current buffer's file OR look up from remote-users
         (effective-file (or file 
                              noteworthy-collab--file-path
                              (plist-get (gethash user-id noteworthy-collab--remote-users) :file)))
         ;; No buffer to resolve means no buffer to draw into -- creating the
         ;; overlay in whatever happened to be `current-buffer' when the
         ;; packet arrived was the bug.
         (buf (and effective-file
                   (noteworthy-collab--find-buffer-for-file effective-file))))
    (when (and user-id
               (not (and noteworthy-collab--user-id
                         (string= user-id noteworthy-collab--user-id))))
      ;; Ensure color has a value
      (unless color (setq color "#FF00FF"))
      (unless name (setq name "unknown"))

      ;; Store user info for tracking
      (puthash user-id
               (list :name name :color color :file effective-file
                     :line line :col col)
               noteworthy-collab--remote-users)

      (when buf
        (with-current-buffer buf
          ;; Clean up old overlays for this user
          (noteworthy-collab--clear-cursor-overlays user-id)

          (let* ((cursor-pos (noteworthy-collab--point-from-line-col line col))
                 (selection-range (noteworthy-collab--selection-range-from-cursor msg))
                 (cursor-ov nil)
                 (sel-ov nil))
            ;; Create cursor overlay covering 1 character (like crdt.el)
            (setq cursor-ov (make-overlay cursor-pos (min (1+ cursor-pos) (point-max))))
            (overlay-put cursor-ov 'noteworthy-cursor t)
            (overlay-put cursor-ov 'noteworthy-user user-id)
            (overlay-put cursor-ov 'priority 100)

            ;; Just highlight the character - no name label (doesn't push text)
            (overlay-put cursor-ov 'face
                         `(:background ,color
                                       :foreground ,(face-attribute 'default :background nil 'default)))

            ;; Show name on hover only
            (overlay-put cursor-ov 'help-echo (format "%s" name))

            ;; Store user info for proximity-based name display
            (overlay-put cursor-ov 'noteworthy-name name)
            (overlay-put cursor-ov 'noteworthy-color color)

            ;; Create selection overlay when range is available
            (when selection-range
              (setq sel-ov (make-overlay (car selection-range) (cdr selection-range)))
              (overlay-put sel-ov 'noteworthy-selection t)
              (overlay-put sel-ov 'noteworthy-user user-id)
              (overlay-put sel-ov 'face `(:background ,(noteworthy-collab--fade-color color 0.3)))
              (overlay-put sel-ov 'priority 50))

            ;; Store overlays for cleanup
            (puthash user-id (cons cursor-ov sel-ov) noteworthy-collab--remote-cursors)))))))

(defun noteworthy-collab--fade-color (hex-color opacity)
  "Create a faded version of HEX-COLOR with OPACITY (0.0-1.0)."
  (if (and hex-color (string-prefix-p "#" hex-color))
      (let* ((r (string-to-number (substring hex-color 1 3) 16))
             (g (string-to-number (substring hex-color 3 5) 16))
             (b (string-to-number (substring hex-color 5 7) 16))
             ;; Blend with background (assume dark: #1a1a1a)
             (bg-r 26) (bg-g 26) (bg-b 26)
             (mix-r (round (+ (* r opacity) (* bg-r (- 1 opacity)))))
             (mix-g (round (+ (* g opacity) (* bg-g (- 1 opacity)))))
             (mix-b (round (+ (* b opacity) (* bg-b (- 1 opacity))))))
        (format "#%02x%02x%02x" mix-r mix-g mix-b))
    "#333333"))

(defun noteworthy-collab--clear-cursor-overlays (user-id)
  "Remove cursor and selection overlays for USER-ID."
  (when-let ((overlays (gethash user-id noteworthy-collab--remote-cursors)))
    (when (car overlays) (delete-overlay (car overlays)))
    (when (cdr overlays) (delete-overlay (cdr overlays)))
    (remhash user-id noteworthy-collab--remote-cursors)))

(defun noteworthy-collab--clear-cursor-overlays-in-buffer (buf)
  "Remove every remote cursor/selection overlay that lives in BUF.
Used before `erase-buffer' in `noteworthy-collab--apply-sync': overlays left
behind there would either vanish uncleanly or end up pointing at nothing."
  (let (stale)
    (maphash (lambda (user-id overlays)
               (when (or (and (car overlays) (eq (overlay-buffer (car overlays)) buf))
                         (and (cdr overlays) (eq (overlay-buffer (cdr overlays)) buf)))
                 (push user-id stale)))
             noteworthy-collab--remote-cursors)
    (dolist (user-id stale)
      (noteworthy-collab--clear-cursor-overlays user-id))))

(defun noteworthy-collab--update-users (msg)
  "Handle users list update."
  (let* ((file (alist-get 'file msg))
         (users-list (noteworthy-collab--listify (alist-get 'users msg))))
    (noteworthy-collab--replace-users-for-file file users-list)
    (noteworthy-collab--log 'info "Users in %s: %s"
                            file
                            (mapconcat (lambda (u) (or (alist-get 'name u) "unknown"))
                                       users-list
                                       ", "))))

;;; ============================================================
;;; Local Change Tracking
;;; ============================================================

(defvar-local noteworthy-collab--saved-auto-save nil
  "Saved buffer-auto-save-file-name before collab was enabled.")

(defvar noteworthy-collab--global-auto-save-disabled nil
  "Whether we've disabled global auto-save features.")

(defvar noteworthy-collab--disabled-global-features nil
  "Which global minor modes `--disable-global-auto-save' actually turned off.
A subset of (auto-save-visited-mode super-save-mode ws-butler-global-mode);
only modes that were active get recorded, so restoring doesn't turn one on
that the user never had enabled.")

(defvar noteworthy-collab--removed-focus-out-hooks nil
  "Which `focus-out-hook' functions `--disable-global-auto-save' removed.
Only functions that were actually present get recorded.")

(defun noteworthy-collab--disable-global-auto-save ()
  "Disable all global auto-save mechanisms.
Records exactly what was turned off, in `noteworthy-collab--disabled-global-features'
and `noteworthy-collab--removed-focus-out-hooks', so `noteworthy-collab-disconnect'
can put it back the way it found it."
  (unless noteworthy-collab--global-auto-save-disabled
    (setq noteworthy-collab--global-auto-save-disabled t)
    (setq noteworthy-collab--disabled-global-features nil)
    (setq noteworthy-collab--removed-focus-out-hooks nil)

    ;; Disable auto-save-visited-mode if active
    (when (bound-and-true-p auto-save-visited-mode)
      (auto-save-visited-mode -1)
      (push 'auto-save-visited-mode noteworthy-collab--disabled-global-features)
      (noteworthy-collab--log 'info "Disabled auto-save-visited-mode"))

    ;; Disable super-save-mode if active (common in Doom)
    (when (bound-and-true-p super-save-mode)
      (super-save-mode -1)
      (push 'super-save-mode noteworthy-collab--disabled-global-features)
      (noteworthy-collab--log 'info "Disabled super-save-mode"))

    ;; Disable ws-butler auto-trim (can trigger saves)
    (when (bound-and-true-p ws-butler-global-mode)
      (ws-butler-global-mode -1)
      (push 'ws-butler-global-mode noteworthy-collab--disabled-global-features)
      (noteworthy-collab--log 'info "Disabled ws-butler-global-mode"))

    ;; Remove save hooks that might auto-trigger
    (when (memq #'save-some-buffers focus-out-hook)
      (remove-hook 'focus-out-hook #'save-some-buffers)
      (push #'save-some-buffers noteworthy-collab--removed-focus-out-hooks))
    (when (memq #'doom-auto-save-non-file-buffers-h focus-out-hook)
      (remove-hook 'focus-out-hook #'doom-auto-save-non-file-buffers-h)
      (push #'doom-auto-save-non-file-buffers-h noteworthy-collab--removed-focus-out-hooks))

    (noteworthy-collab--log 'info "Global auto-save features disabled")))

(defun noteworthy-collab--restore-global-auto-save ()
  "Undo `noteworthy-collab--disable-global-auto-save'.
Restores only what that function actually recorded turning off."
  (when noteworthy-collab--global-auto-save-disabled
    (dolist (feature noteworthy-collab--disabled-global-features)
      (pcase feature
        ('auto-save-visited-mode (auto-save-visited-mode 1))
        ('super-save-mode (super-save-mode 1))
        ('ws-butler-global-mode (ws-butler-global-mode 1))))
    (dolist (fn noteworthy-collab--removed-focus-out-hooks)
      (add-hook 'focus-out-hook fn))
    (setq noteworthy-collab--disabled-global-features nil
          noteworthy-collab--removed-focus-out-hooks nil
          noteworthy-collab--global-auto-save-disabled nil)
    (noteworthy-collab--log 'info "Restored global auto-save features")))

(defun noteworthy-collab--mark-buffers-read-only ()
  "Make every active collab buffer read-only.
The server owns the file and `noteworthy-collab--apply-sync' replaces the
whole buffer on resync -- there is no merge, so anything typed while
disconnected would silently vanish.  Blocking edits is the safe failure
mode; `--apply-sync' restores each buffer's own prior read-only state once
it resyncs."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and noteworthy-collab--active
                 (not (memq noteworthy-collab--saved-read-only '(t nil))))
        (setq noteworthy-collab--saved-read-only (and buffer-read-only t))
        (setq buffer-read-only t)
        (message "Noteworthy collab: disconnected -- %s is read-only until it resyncs, to avoid losing edits"
                 (buffer-name buf))))))

(defun noteworthy-collab--setup-buffer ()
  "Setup collaboration for current buffer."
  (noteworthy-collab--log 'info "Setting up buffer: %s" (buffer-name))
  (setq noteworthy-collab--active t)
  
  ;; Disable global auto-save on first buffer setup
  (noteworthy-collab--disable-global-auto-save)
  
  ;; Disable buffer-local auto-save
  (setq noteworthy-collab--saved-auto-save buffer-auto-save-file-name)
  (setq buffer-auto-save-file-name nil)
  
  ;; Disable ws-butler for this buffer
  (when (bound-and-true-p ws-butler-mode)
    (ws-butler-mode -1))
  
  ;; Activate noteworthy-typst-mode for .typ files (triggers keybinding hooks)
  (when (and noteworthy-collab--file-path 
             (string-suffix-p ".typ" noteworthy-collab--file-path))
    (when (fboundp 'noteworthy-typst-mode)
      (noteworthy-typst-mode 1)))
  
  (noteworthy-collab--log 'info "Disabled auto-save for: %s" (buffer-name))
  
  ;; Install hooks
  (add-hook 'after-change-functions #'noteworthy-collab--after-change nil t)
  ;; Separate from --after-change on purpose: that one skips remote edits to
  ;; avoid echoing them back, while the preview wants both directions.
  (add-hook 'after-change-functions #'noteworthy-collab--push-preview-on-change nil t)
  (add-hook 'post-command-hook #'noteworthy-collab--post-command nil t)
  (add-hook 'kill-buffer-hook #'noteworthy-collab--on-kill nil t)
  (noteworthy-collab--log 'info "Hooks installed for: %s (after-change-functions has %d items)" 
                          (buffer-name)
                          (length after-change-functions)))

(defun noteworthy-collab--refresh-modtime (buffer)
  "Tell Emacs BUFFER matches its file again.
The room rewrites the file within a debounce of every edit, so the
buffer's recorded modtime goes stale constantly."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and buffer-file-name (file-exists-p buffer-file-name))
        (ignore-errors (set-visited-file-modtime))
        (set-buffer-modified-p nil)))))

(defun noteworthy-collab--supersession-advice (orig-fn filename)
  "Skip the \"changed on disk, discard your edits?\" prompt in collab buffers.

That question assumes the buffer and the file are rival versions of the
same text.  Here they are not: the server owns the file and writes it
from the shared document a moment after every edit, so the on-disk change
*is* our own text coming back.  Answering it is meaningless, and it fires
on essentially every keystroke after a peer edit."
  (if (bound-and-true-p noteworthy-collab--active)
      (ignore-errors (set-visited-file-modtime))
    (funcall orig-fn filename)))

(advice-add 'ask-user-about-supersession-threat :around
            #'noteworthy-collab--supersession-advice)

(defun noteworthy-collab--modtime-advice (orig-fn &optional buffer)
  "Report collab buffers as matching their file.

They do: the room writes the shared document to disk within a debounce of
every edit, so a differing modtime means our own text came back, not a
rival version.  Emacs otherwise asks \"changed on disk, reread?\" whenever
something revisits the file -- notably a preview click asking the editor
to jump to source -- and \"discard your edits?\" when you next type.

Reverting would be actively wrong here: it would throw away the buffer
that the CRDT session is attached to."
  (let ((buf (or buffer (current-buffer))))
    (if (buffer-live-p buf)
        (with-current-buffer buf
          (if (bound-and-true-p noteworthy-collab--active)
              t
            (funcall orig-fn buffer)))
      (funcall orig-fn buffer))))

(advice-add 'verify-visited-file-modtime :around
            #'noteworthy-collab--modtime-advice)

(defun noteworthy-collab--restore-read-only ()
  "Undo the read-only state forced on this buffer while disconnected.
Does nothing if we never forced it, so a buffer the user made read-only
themselves stays that way."
  (when (memq noteworthy-collab--saved-read-only '(t nil))
    (setq buffer-read-only noteworthy-collab--saved-read-only)
    (setq noteworthy-collab--saved-read-only noteworthy-collab--unset)))

(defun noteworthy-collab--teardown-buffer ()
  "Remove collaboration from current buffer."
  (setq noteworthy-collab--active nil)
  
  ;; Restore auto-save if it was enabled before
  (when noteworthy-collab--saved-auto-save
    (setq buffer-auto-save-file-name noteworthy-collab--saved-auto-save)
    (noteworthy-collab--log 'info "Restored auto-save for: %s" (buffer-name)))
  
  ;; A deliberate disconnect also closes the socket, which forces buffers
  ;; read-only; nothing would ever restore them, so do it here.
  (noteworthy-collab--restore-read-only)
  (setq noteworthy-collab--synced nil)

  ;; Stop shadowing this file: tinymist must fall back to the copy on disk,
  ;; which the room keeps current.
  (noteworthy-collab-preview-drop)

  ;; Remove hooks
  (remove-hook 'after-change-functions #'noteworthy-collab--after-change t)
  (remove-hook 'after-change-functions #'noteworthy-collab--push-preview-on-change t)
  (remove-hook 'post-command-hook #'noteworthy-collab--post-command t)
  (remove-hook 'kill-buffer-hook #'noteworthy-collab--on-kill t))

(defvar-local noteworthy-collab--modtime-timer nil)

(defun noteworthy-collab--schedule-modtime-refresh (&rest _)
  "Re-sync this buffer's modtime after the room has written the file.
Deliberately NOT on `after-change-functions': `set-visited-file-modtime'
stats the file, ~88ms over TRAMP, which per keystroke is the difference
between fluent and unusable.  `ask-user-about-supersession-threat' is
advised to re-sync on the rare occasion it actually matters."
  (when (and noteworthy-collab--active buffer-file-name)
    (let ((buf (current-buffer)))
      (when (timerp noteworthy-collab--modtime-timer)
        (cancel-timer noteworthy-collab--modtime-timer))
      (setq noteworthy-collab--modtime-timer
            (run-with-idle-timer
             0.6 nil (lambda () (noteworthy-collab--refresh-modtime buf)))))))

(defun noteworthy-collab--push-preview-on-change (_beg _end _len)
  "Push this buffer to a standalone tinymist session after any change.
Local and remote edits alike -- both are the CRDT-merged text."
  (when (noteworthy-collab-preview-connected-p)
    (noteworthy-collab-preview-push))
  ;; Repainting is handled by `noteworthy-collab-preview-repaint-mode', not
  ;; from here: frames land whenever tinymist finishes compiling, which is
  ;; not the same moment as an edit.
  )

(defun noteworthy-collab--after-change (beg end len)
  "Hook for after-change-functions. Send delta to server.
BEG and END are buffer positions after change.
LEN is length of deleted text."
  ;; Always log that we were called (for debugging)
  (noteworthy-collab--log 'info "after-change CALLED: beg=%d end=%d len=%d applying-remote=%s file-path=%s"
                          beg end len noteworthy-collab--applying-remote noteworthy-collab--file-path)
  ;; Use condition-case to prevent errors from propagating to other hooks
  (condition-case err
      (unless noteworthy-collab--applying-remote
        (cond
         ((not noteworthy-collab--file-path)
          (noteworthy-collab--log 'info "after-change: No file-path set (buffer: %s)" (buffer-name)))
         ;; The authoritative sync for this buffer hasn't landed yet: sending
         ;; now would compute retain/delete offsets against content the
         ;; server doesn't recognize.  Warn once, not on every keystroke.
         ((not noteworthy-collab--synced)
          (unless noteworthy-collab--sync-warned
            (setq noteworthy-collab--sync-warned t)
            (message "Noteworthy collab: %s hasn't synced yet -- this edit was NOT sent"
                     (buffer-name)))
          (noteworthy-collab--log 'warn "after-change: dropped edit, not yet synced"))
         ;; Buffers are forced read-only while disconnected (see
         ;; `noteworthy-collab--mark-buffers-read-only') specifically so we
         ;; never get here; this is the fallback for a user who forces an
         ;; edit through anyway (e.g. via `inhibit-read-only').  Warn
         ;; visibly rather than silently dropping it.
         ((not (noteworthy-collab-connected-p))
          (message "Noteworthy collab: not connected -- this edit was NOT sent and will be lost")
          (noteworthy-collab--log 'error "after-change: dropped edit, not connected"))
         (t
          (let ((inserted (buffer-substring-no-properties beg end))
                (ops '()))
            ;; Build delta ops (0-indexed positions)
            ;; Each op must be an alist for proper JSON encoding
            (when (> (1- beg) 0)
              (push `((retain . ,(1- beg))) ops))
            (when (> len 0)
              (push `((delete . ,len)) ops))
            (when (> (length inserted) 0)
              (push `((insert . ,inserted)) ops))
            ;; Send to server
            (if ops
                (let ((final-ops (vconcat (nreverse ops))))
                  (noteworthy-collab--log 'info "SEND delta: file=%s beg=%d end=%d len=%d ops=%s"
                                          noteworthy-collab--file-path beg end len final-ops)
                  (noteworthy-collab--send
                   `((type . "delta")
                     (file . ,noteworthy-collab--file-path)
                     (ops . ,final-ops))))
              (noteworthy-collab--log 'info "after-change: No ops generated (inserted='%s')" inserted))))))
    (error
     (noteworthy-collab--log 'error "after-change error: %s" (error-message-string err)))))

(defun noteworthy-collab--post-command ()
  "Post-command hook for cursor sending and remote cursor name display."
  (when noteworthy-collab--active
    ;; Debounce cursor updates
    (when noteworthy-collab--cursor-timer
      (cancel-timer noteworthy-collab--cursor-timer))
    (setq noteworthy-collab--cursor-timer
          (run-with-idle-timer noteworthy-collab-cursor-idle-time nil
                               #'noteworthy-collab--send-cursor))
    ;; Check if we're on a remote cursor and show name
    (let ((name nil))
      (dolist (ov (overlays-at (point)))
        (when (and (overlay-get ov 'noteworthy-cursor)
                   (not name))
          (setq name (overlay-get ov 'noteworthy-name))))
      (when name
        (message "%s" name)))))

(defun noteworthy-collab--send-cursor ()
  "Send cursor position (and active selection) to server."
  (when (and noteworthy-collab--file-path
             (noteworthy-collab-connected-p))
    (let ((msg `((type . "cursor")
                 (file . ,noteworthy-collab--file-path)
                 (line . ,(line-number-at-pos))
                 ;; 1-based, counting CHARACTERS.  Two separate traps here:
                 ;; `current-column' is a DISPLAY column, so it disagrees on
                 ;; any line with a tab or a double-width character; and the
                 ;; wire format is Monaco's, whose columns start at 1 --
                 ;; sending a 0-based one drew our caret one place to the
                 ;; left of where it really was, on every client.
                 (col . ,(1+ (- (point) (line-beginning-position)))))))
      ;; Add selection info in canonical line/column fields.
      ;; Keep legacy object shape for bridge compatibility during transition.
      (when (region-active-p)
        (let* ((start (noteworthy-collab--line-col-at-pos (region-beginning)))
               (end (noteworthy-collab--line-col-at-pos (region-end))))
          (setq msg
                (append
                 msg
                 `((selStartLine . ,(car start))
                   (selStartCol . ,(cdr start))
                   (selEndLine . ,(car end))
                   (selEndCol . ,(cdr end))
                   (selStart . ((line . ,(car start))
                                (col . ,(cdr start))))
                   (selEnd . ((line . ,(car end))
                              (col . ,(cdr end)))))))))
      (noteworthy-collab--send msg))))

(defun noteworthy-collab--on-kill ()
  "Hook for kill-buffer. Leave file session."
  (when noteworthy-collab--file-path
    (noteworthy-collab-leave-file)))

;;; ============================================================
;;; File Session Management
;;; ============================================================

(defun noteworthy-collab--join-file-internal (file-path)
  "Internal: Send join message for FILE-PATH.
Every join or rejoin passes through here, so this is where we clear
`noteworthy-collab--synced': the buffer isn't trustworthy again until the
matching \"sync\" arrives and `noteworthy-collab--apply-sync' sets it."
  (setq noteworthy-collab--synced nil)
  (setq noteworthy-collab--sync-warned nil)
  (unless (noteworthy-collab--send
           `((type . "join")
             (file . ,file-path)))
    (message "Noteworthy collab: failed to join %s -- not connected to server" file-path)))

(defun noteworthy-collab-join-file (file-path)
  "Join collaboration session for FILE-PATH."
  (noteworthy-collab--log 'info "join-file called: %s (buffer: %s)" file-path (buffer-name))
  (setq-local noteworthy-collab--file-path file-path)
  (noteworthy-collab--log 'info "Set buffer-local file-path to: %s" noteworthy-collab--file-path)
  (noteworthy-collab--setup-buffer)
  ;; Keep tinymist compiling the whole document: opening a page otherwise
  ;; re-points the compile at that page, without the project inputs.
  (when (fboundp 'noteworthy-collab-preview--pin-main)
    (ignore-errors (noteworthy-collab-preview--pin-main)))
  (when (noteworthy-collab-connected-p)
    (noteworthy-collab--join-file-internal file-path))
  (noteworthy-collab--log 'info "Joined: %s" file-path))

(defun noteworthy-collab-leave-file ()
  "Leave current file's collaboration session."
  (when noteworthy-collab--file-path
    (when (noteworthy-collab-connected-p)
      (noteworthy-collab--send
       `((type . "leave")
         (file . ,noteworthy-collab--file-path))))
    (noteworthy-collab--log 'info "Left: %s" noteworthy-collab--file-path)
    (noteworthy-collab--teardown-buffer)
    (setq-local noteworthy-collab--file-path nil)))

;;; ============================================================
;;; Project File Detection
;;; ============================================================

(defun noteworthy-collab--is-project-file-p (file-path)
  "Return non-nil if FILE-PATH is within the project."
  (and noteworthy-collab--project-root
       (string-prefix-p (file-truename noteworthy-collab--project-root)
                        (file-truename file-path))))

(defun noteworthy-collab--relative-path (file-path)
  "Get FILE-PATH relative to project root."
  (if noteworthy-collab--project-root
      (file-relative-name file-path noteworthy-collab--project-root)
    file-path))

(defun noteworthy-collab--on-find-file ()
  "Hook for find-file. Auto-join CRDT session for project files."
  (noteworthy-collab--log 'info "on-find-file hook: %s" (buffer-file-name))
  (when-let ((file (buffer-file-name)))
    (noteworthy-collab--log 'info "  project-root: %s" noteworthy-collab--project-root)
    (noteworthy-collab--log 'info "  is-typ?: %s" (string-suffix-p ".typ" file))
    ;; Check the cheap local suffix test before `--is-project-file-p', and
    ;; call it only once: each call is a remote stat when FILE is over
    ;; TRAMP, so this was costing every opened file two round-trips.
    (when (and noteworthy-collab--project-root
               (string-suffix-p ".typ" file))
      (let ((project-file-p (noteworthy-collab--is-project-file-p file)))
        (noteworthy-collab--log 'info "  is-project-file?: %s" project-file-p)
        (when project-file-p
          (let ((rel-path (noteworthy-collab--relative-path file)))
            (noteworthy-collab--log 'info "  rel-path: %s" rel-path)
            (noteworthy-collab-join-file rel-path)))))))

;;; ============================================================
;;; Server Status & Preview Discovery
;;; ============================================================

(defun noteworthy-collab--fetch-server-status (http-url callback)
  "Fetch server status from HTTP-URL/api/status and call CALLBACK with result.
CALLBACK is invoked exactly once, with nil on any failure (refused
connection, timeout, or a malformed response) so callers' fallback logic
always runs."
  (let ((url (concat http-url "/api/status")))
    (url-retrieve
     url
     (lambda (status)
       (if (plist-get status :error)
           (funcall callback nil)
         (goto-char (point-min))
         (if (re-search-forward "\n\n" nil t)
             (condition-case nil
                 (let ((json-data (json-parse-buffer :object-type 'alist
                                                     :false-object nil :null-object nil)))
                   (funcall callback json-data))
               (error (funcall callback nil)))
           (funcall callback nil))))
     nil t t)))



(defun noteworthy-collab--infer-preview-url (ws-url)
  "Infer preview URL from WS-URL when one has not been configured.
Assumes tinymist is running on port 23625 on the same host.

A configured URL always wins.  Guessing from the collab server's host is
wrong whenever the preview is reached another way -- notably through an
SSH tunnel, which is *required* when the project is remote: tinymist's
data plane refuses any websocket whose Origin is not localhost, and the
xwidget sends the URL it loaded from as its Origin."
  (if noteworthy-collab-preview-url
      (progn
        (noteworthy-collab--log 'info "Keeping configured preview URL: %s"
                                noteworthy-collab-preview-url)
        (noteworthy-collab-refresh-preview))
    (let* ((host (if (string-match "ws://\\([^/:]+\\)" ws-url)
                     (match-string 1 ws-url)
                   "localhost"))
           (preview-url (format "http://%s:23625" host)))
      (setq noteworthy-collab-preview-url preview-url)
      (noteworthy-collab--log 'info "Inferred preview URL: %s" preview-url)
      ;; Refresh preview if window exists
      (noteworthy-collab-refresh-preview))))

(defun noteworthy-collab--ws-to-http (ws-url)
  "Convert WebSocket URL to HTTP URL.
ws://host:port/path -> http://host:port"
  (save-match-data
    (if (string-match "^wss?://\\([^/]+\\)" ws-url)
        (let ((host-port (match-string 1 ws-url)))
          (if (string-prefix-p "wss://" ws-url)
              (concat "https://" host-port)
            (concat "http://" host-port)))
      ws-url)))

(defun noteworthy-collab--bridge-http-fallback-url (http-url)
  "Map bridge HTTP-URL on :8001 to main server URL on :8000."
  (save-match-data
    (when (string-match "^\\(https?://[^/:]+\\):8001\\'" http-url)
      (concat (match-string 1 http-url) ":8000"))))

;;; ============================================================
;;; Main Entry Points
;;; ============================================================

;;;###autoload
(defun noteworthy-remote-init (server-url tramp-path &optional pdf-path)
  "Initialize Noteworthy remote collaborative session.

SERVER-URL: WebSocket URL (e.g., ws://server:8001/ws/emacs)
TRAMP-PATH: TRAMP path to project (e.g., /ssh:server:/path/to/project)
            For localhost, use regular path like ~/Typst/project
PDF-PATH: Optional PDF file to display (can be TRAMP path)

This sets up:
- WebSocket connection to the collaboration server
- Treemacs with the project
- Auto-join CRDT sessions when opening .typ files
- Tinymist live preview (auto-discovered from server)
- Optional PDF viewer window"
  (interactive
   (let* ((url (read-string "Server URL: " noteworthy-collab-server-url))
          (project (read-directory-name "Project: " "~/"))
          (pdf (read-file-name "PDF file (optional, RET to skip): " project nil nil)))
     (list url project (if (string-empty-p pdf) nil pdf))))
  
  ;; Store project root
  (setq noteworthy-collab--project-root (file-truename tramp-path))
  
  ;; Connect to server
  (noteworthy-collab--connect server-url)
  
  ;; Setup find-file hook
  (add-hook 'find-file-hook #'noteworthy-collab--on-find-file)
  
  ;; Fetch server status to discover tinymist preview URL
  (let* ((status-url (noteworthy-collab--ws-to-http server-url))
         (fallback-status-url (noteworthy-collab--bridge-http-fallback-url status-url))
         (apply-status
          (lambda (status)
            (let* ((tinymist (alist-get 'tinymist status))
                   (running (alist-get 'running tinymist))
                   (preview-url (alist-get 'url tinymist)))
              (if (and running preview-url)
                  (progn
                    (noteworthy-collab--log 'info "Tinymist preview at: %s" preview-url)
                    (require 'noteworthy-collab-layout)
                    ;; A configured URL wins, exactly as in
                    ;; `noteworthy-collab--infer-preview-url'.  The server
                    ;; reports its own hostname, but tinymist binds 127.0.0.1
                    ;; and refuses any websocket whose Origin is not
                    ;; localhost -- so http://<host>:PORT loads nothing and
                    ;; the pane shows "Connection refused".  The tunnelled
                    ;; localhost URL is the one that works.
                    (if noteworthy-collab-preview-url
                        (noteworthy-collab--log
                         'info "Keeping configured preview URL: %s (server offered %s)"
                         noteworthy-collab-preview-url preview-url)
                      (setq noteworthy-collab-preview-url preview-url))
                    ;; Force refresh of placeholder with actual URL
                    (noteworthy-collab-refresh-preview))
                (noteworthy-collab--log 'warn "Tinymist preview not available"))))))
    (noteworthy-collab--log 'info "Querying server status: %s" status-url)
    (noteworthy-collab--fetch-server-status
     status-url
     (lambda (status)
       (if status
           (funcall apply-status status)
         (if fallback-status-url
             (progn
               (noteworthy-collab--log
                'info
                "Status not found on bridge, retrying: %s"
                fallback-status-url)
               (noteworthy-collab--fetch-server-status
                fallback-status-url
                (lambda (fallback-status)
                  (if fallback-status
                      (funcall apply-status fallback-status)
                    (noteworthy-collab--log 'warn "Tinymist preview not available")))))
           (noteworthy-collab--log 'warn "Tinymist preview not available"))))))
  
  ;; Initialize layout (will use preview URL if set)
  (run-with-timer 
   0.5 nil  ; Small delay to let status fetch complete
   (lambda ()
     (require 'noteworthy-collab-layout)
     (noteworthy-collab-layout-init tramp-path pdf-path)
     ;; Join CRDT for all already-open .typ files in the project
     (noteworthy-collab--join-open-buffers)
     (noteworthy-collab--log 'info "Initialized session: %s" tramp-path)
     (when noteworthy-collab-auto-start-preview
       (noteworthy-collab--auto-start-preview)))))

(defcustom noteworthy-collab-auto-start-preview t
  "Whether `noteworthy-remote-init' should bring the preview up too.
The preview is hosted by the tinymist language server, which takes a
while to come up over TRAMP, so this waits for it rather than failing."
  :type 'boolean
  :group 'noteworthy-collab)

(defun noteworthy-collab--auto-start-preview ()
  "Start the preview once tinymist is ready, without blocking the session."
  (let ((buf (seq-find (lambda (b)
                         (with-current-buffer b
                           (and buffer-file-name
                                (string-suffix-p ".typ" buffer-file-name))))
                       (buffer-list))))
    (if (not buf)
        (noteworthy-collab--log 'info "No .typ buffer yet; skipping preview auto-start")
      (with-current-buffer buf
        ;; typst-ts-mode normally starts the server; nudge it if it did not.
        (unless (and (bound-and-true-p lsp-mode) (ignore-errors (lsp-workspaces)))
          (ignore-errors (let ((lsp-auto-guess-root t)) (lsp)))))
      (message "Noteworthy: waiting for tinymist to start the preview...")
      (noteworthy-collab--when-lsp-ready
       buf
       (lambda ()
         (condition-case err
             (noteworthy-collab-preview-start)
           (error
            (message "Noteworthy: preview not started (%s) -- M-x noteworthy-collab-preview-start"
                     (error-message-string err)))))))))

(defun noteworthy-collab--join-open-buffers ()
  "Join CRDT session for all open .typ files in the project."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when-let ((file (buffer-file-name)))
        (when (and (string-suffix-p ".typ" file)
                   (noteworthy-collab--is-project-file-p file)
                   (not noteworthy-collab--active))
          (let ((rel-path (noteworthy-collab--relative-path file)))
            (noteworthy-collab--log 'info "Auto-joining already-open buffer: %s" rel-path)
            (noteworthy-collab-join-file rel-path)))))))

;;;###autoload
(defun noteworthy-collab-disconnect ()
  "Disconnect from collaboration server and cleanup."
  (interactive)
  (setq noteworthy-collab--disconnecting t)
  ;; Leave all active files
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when noteworthy-collab--active
        (noteworthy-collab-leave-file))))
  
  ;; Close socket
  (when noteworthy-collab--socket
    (websocket-close noteworthy-collab--socket)
    (setq noteworthy-collab--socket nil))

  ;; Peers and their carets belong to the connection that just ended.
  (noteworthy-collab--forget-remote-users)
  
  ;; Cancel timers
  (when noteworthy-collab--reconnect-timer
    (cancel-timer noteworthy-collab--reconnect-timer)
    (setq noteworthy-collab--reconnect-timer nil))
  
  ;; Remove hook
  (remove-hook 'find-file-hook #'noteworthy-collab--on-find-file)

  ;; Undo whatever global auto-save features we actually turned off
  (noteworthy-collab--restore-global-auto-save)

  ;; Drop tinymist memory overlays, so the preview follows the files on disk
  ;; again instead of a buffer we are no longer syncing.
  (noteworthy-collab-preview-disconnect)

  ;; Clear state
  (setq noteworthy-collab--project-root nil
        noteworthy-collab--server-url nil
        noteworthy-collab--user-id nil
        noteworthy-collab--user-color nil)
  
  ;; Any buffer we forced read-only is editable again by now (teardown
  ;; restored it, and --on-close no longer re-marks it).
  (setq noteworthy-collab--disconnecting nil)
  (noteworthy-collab--log 'info "Disconnected"))

;;;###autoload
(defun noteworthy-collab-end-session (&optional cleanup-tramp)
  "End the remote session cleanly.

Stops the preview on the project host, disconnects, restores the editor
state this package changed, and closes the tunnel it opened.  With a
prefix argument, also drops the TRAMP connection."
  (interactive "P")
  ;; 1. stop the preview, or it keeps compiling on the remote host
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (bound-and-true-p lsp-mode) (ignore-errors (lsp-workspaces)))
        (ignore-errors
          (lsp-request "workspace/executeCommand"
                       (list :command "tinymist.doKillPreview" :arguments (vector)))))))
  ;; 2. drop memory overlays and stop repainting
  (ignore-errors (noteworthy-collab-preview-disconnect))
  (when (bound-and-true-p noteworthy-collab-preview-repaint-mode)
    (noteworthy-collab-preview-repaint-mode -1))
  (when (bound-and-true-p noteworthy-preview-repaint-mode)
    (noteworthy-preview-repaint-mode -1))
  ;; 3. leave every file and restore read-only / auto-save state
  (ignore-errors (noteworthy-collab-disconnect))
  ;; 4. close the tunnel we opened (an externally started one is left alone)
  (when (process-live-p (bound-and-true-p noteworthy-collab-preview--tunnel-process))
    (delete-process noteworthy-collab-preview--tunnel-process)
    (setq noteworthy-collab-preview--tunnel-process nil))
  ;; 5. session buffers, including the xwidget -- that is a live WebKit process
  (dolist (buf (buffer-list))
    (let ((name (buffer-name buf)))
      (when (or (string-match-p "xwidget-webkit" name)
                (member name (list noteworthy-collab-log-buffer
                                   noteworthy-collab-chat-buffer
                                   "*noteworthy-terminal*")))
        (ignore-errors (kill-buffer buf)))))
  (when cleanup-tramp
    (ignore-errors (tramp-cleanup-all-connections)))
  (message "Noteworthy collab: session ended%s"
           (if cleanup-tramp " (TRAMP connections dropped)" "")))

;;;###autoload
(defun noteworthy-collab-status ()
  "Show current collaboration status."
  (interactive)
  (message "Noteworthy Collab: %s | User: %s | Project: %s"
           (if (noteworthy-collab-connected-p) "Connected" "Disconnected")
           (or noteworthy-collab--user-id "N/A")
           (or noteworthy-collab--project-root "N/A")))

;;;###autoload
(defun noteworthy-collab-debug ()
  "Show debug info for current buffer."
  (interactive)
  (noteworthy-collab--log 'info "=== DEBUG INFO ===")
  (noteworthy-collab--log 'info "Buffer: %s" (buffer-name))
  (noteworthy-collab--log 'info "File: %s" (buffer-file-name))
  (noteworthy-collab--log 'info "Project root: %s" noteworthy-collab--project-root)
  (noteworthy-collab--log 'info "File-path (local): %s" (if (boundp 'noteworthy-collab--file-path) noteworthy-collab--file-path "unbound"))
  (noteworthy-collab--log 'info "Active (local): %s" (if (boundp 'noteworthy-collab--active) noteworthy-collab--active "unbound"))
  (noteworthy-collab--log 'info "Connected: %s" (noteworthy-collab-connected-p))
  (noteworthy-collab--log 'info "Socket: %s" noteworthy-collab--socket)
  (noteworthy-collab--log 'info "after-change-functions (local): %d items" (length after-change-functions))
  (noteworthy-collab--log 'info "  Contains our hook: %s" (memq #'noteworthy-collab--after-change after-change-functions))
  (noteworthy-collab--log 'info "=== END DEBUG ===")
  (noteworthy-collab-toggle-log))

;;;###autoload
(defun noteworthy-collab-test-delta ()
  "Send a test delta to server (inserts and immediately deletes a space)."
  (interactive)
  (if (not (noteworthy-collab-connected-p))
      (message "Not connected!")
    (if (not noteworthy-collab--file-path)
        (message "No file path set for this buffer!")
      (let ((test-ops `[((retain . ,(1- (point)))) ((insert . " "))]))
        (noteworthy-collab--log 'info "Sending TEST delta: %s" test-ops)
        (noteworthy-collab--send
         `((type . "delta")
           (file . ,noteworthy-collab--file-path)
           (ops . ,test-ops)))
        (message "Test delta sent! Check server logs.")))))

;;;###autoload
(defun noteworthy-collab-track-user ()
  "Jump to a remote user's cursor position.
Prompts for username, auto-deduplicating if there are multiple with same name."
  (interactive)
  (let* ((users (hash-table-keys noteworthy-collab--remote-users))
         (names-alist nil))
    (if (null users)
        (message "No remote users connected")
      ;; Build list of names with deduplication
      (dolist (user-id users)
        (let* ((info (gethash user-id noteworthy-collab--remote-users))
               (base-name (plist-get info :name))
               (existing (cl-count-if (lambda (pair) 
                                        (string-prefix-p base-name (car pair)))
                                      names-alist))
               (display-name (if (> existing 0)
                                (format "%s (%d)" base-name (1+ existing))
                              base-name)))
          (push (cons display-name user-id) names-alist)))
      
      (let* ((choice (completing-read "Track user: " 
                                      (mapcar #'car names-alist) nil t))
             (user-id (cdr (assoc choice names-alist)))
             (info (gethash user-id noteworthy-collab--remote-users)))
        (when info
          (let ((file (plist-get info :file))
                (line (plist-get info :line))
                (col (plist-get info :col)))
            ;; Find or open the buffer
            (when-let ((buf (noteworthy-collab--find-buffer-for-file file)))
              (switch-to-buffer buf)
              (goto-char (point-min))
              (forward-line (1- line))
              (move-to-column col)
              (message "Jumped to %s at line %d" (plist-get info :name) line))))))))

(provide 'noteworthy-collab)

;;; noteworthy-collab.el ends here
