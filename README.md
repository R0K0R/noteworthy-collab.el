# noteworthy-collab.el

Real-time collaborative editing for [Noteworthy](https://github.com/sihooleebd/noteworthy) Typst projects.

## Features

- **CRDT-based sync** - Conflict-free real-time collaboration via pycrdt (Yjs-compatible)
- **Remote editing** - Edit files on remote servers via TRAMP
- **Full Noteworthy integration** - Treemacs file browser, smart Typst editing, Evil keybindings
- **Live preview** - Port-forwarded tinymist preview via xwidget
- **Log buffer** - Debug output similar to `*ws-typst-server*`

## Requirements

### Emacs
- Emacs 29.1+
- `websocket.el`
- [`noteworthy.el`](https://github.com/R0K0R/noteworthy.el) — provides
  `noteworthy-typst` and `noteworthy-evil`, which this package builds on
- `typst-ts-mode`
- `treemacs`
- `vterm` (optional, for terminal)
- `xwidget` support (optional, for preview)

### Server
- Python 3.10+
- Noteworthy Studio running (`noteworthy -g`, port 8000)
- The Emacs bridge running (`noteworthy.bridge.server`, port 8001) — Emacs
  talks to the bridge, never to Studio directly

## Installation

### With Doom Emacs

In `~/.doom.d/modules/app/noteworthy/packages.el`:

```elisp
;; From a local checkout:
(package! noteworthy-collab
  :recipe (:local-repo "~/Typst/noteworthy-collab.el"))

;; Or from GitHub, once published:
;; (package! noteworthy-collab
;;   :recipe (:type git :host github :repo "R0K0R/noteworthy-collab.el"))
```

In `~/.doom.d/modules/app/noteworthy/config.el`:

```elisp
(require 'noteworthy-collab)
```

### Manual

Clone this repository and add to your load path:

```elisp
(add-to-list 'load-path "/path/to/noteworthy-collab.el")
(require 'noteworthy-collab)
```

## Usage

### Start a collaborative session

```elisp
M-x noteworthy-remote-init
  Server URL: ws://yourserver:8001/ws/emacs
  Project: /ssh:yourserver:/home/user/calculus-1
```

This will:
1. Connect to the collaboration server via WebSocket
2. Open treemacs with the remote project (via TRAMP)
3. Setup terminal and preview windows
4. Auto-join CRDT sessions when opening `.typ` files

### Commands

| Command | Description |
|---------|-------------|
| `noteworthy-remote-init` | Start remote collaborative session |
| `noteworthy-collab-disconnect` | Disconnect from server |
| `noteworthy-collab-status` | Show connection status |
| `noteworthy-collab-toggle-log` | Toggle between terminal and log buffer |
| `noteworthy-collab-show-log` | Show log buffer |
| `noteworthy-collab-show-chat` | Show the chat buffer (`M-t c`) |
| `noteworthy-collab-show-terminal` | Show the vterm window (`M-t t`) |
| `noteworthy-collab-show-typst-log` | Show the Typst compile log (`M-t l`) |
| `noteworthy-collab-track-user` | Follow another user's cursor (`M-t u`) |
| `noteworthy-collab-send-chat` | Send a chat message |
| `noteworthy-collab-debug` | Dump connection/session state |

### Configuration

```elisp
;; Default server URL
(setq noteworthy-collab-server-url "ws://localhost:8001/ws/emacs")

;; Your display name
(setq noteworthy-collab-user-name "YourName")

;; Preview URL (port-forwarded tinymist)
(setq noteworthy-collab-preview-url "http://localhost:23625")

;; Terminal command (optional)
(setq noteworthy-collab-terminal-cmd '("/bin/bash"))
```

### Server Setup

1. Start Noteworthy Studio on your remote machine:

```bash
cd /path/to/your/noteworthy/project
noteworthy -g -p 8000
```

2. Start the Emacs bridge alongside it (this is what `/ws/emacs` is served by):

```bash
uvicorn noteworthy.bridge.server:app --port 8001
```

3. Port-forward tinymist preview (optional):

```bash
ssh -L 23625:localhost:23625 yourserver
```

4. Connect from Emacs using `noteworthy-remote-init`

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Emacs (noteworthy-collab.el)                │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ Typst Buffer │  │ Treemacs     │  │ *noteworthy-collab-  │  │
│  │ (CRDT sync)  │  │ (via TRAMP)  │  │  log* buffer         │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
│         │                 │                                     │
│         │ WebSocket       │ SSH/TRAMP                          │
└─────────┼─────────────────┼─────────────────────────────────────┘
          │                 │
          ▼                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                       Remote Server                             │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ pycrdt CRDT  │  │ Project      │  │ tinymist             │  │
│  │ Hub          │──│ Files        │──│ (LSP + Preview)      │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## WebSocket Protocol

All messages are JSON:

```json
// Join file session
{"type": "join", "file": "content/1/5.typ"}

// Send edit delta
{"type": "delta", "ops": [{"retain": 100}, {"insert": "hello"}]}

// Cursor position
{"type": "cursor", "line": 42, "col": 10}
```

## License

MIT
