# Changelog

All notable changes to Switchboard. The format follows [Keep a Changelog](https://keepachangelog.com), and versions follow [Semantic Versioning](https://semver.org). See [RELEASING.md](RELEASING.md) for the rules.

## [Unreleased]

### Fixed
- A server that stops now turns into a stopped row within about a second, not up to three. Switchboard notices the process is gone and scans right away.
- With stopped servers hidden, a server that just stopped used to vanish without a trace when it was the only one in its project. It now stays on the list as stopped for a minute, so you can see it happened and why.

## [1.12.0] - 2026-10-25

### Added
- Web servers show the page's own title under their name, and the page's icon beside it. The icon is fetched once per server and only from the same server, so a page can't make Switchboard call another host.

## [1.11.1] - 2026-10-25

### Fixed
- Two processes sharing one port, such as a uvicorn parent and its worker, were counted as two running servers but drew only one row. They are now one server with one row.

## [1.11.0] - 2026-10-25

### Added
- Each running server shows its memory next to how long it has been up. A server using half a core or more also shows its CPU in orange. Hover for the full numbers. They include the processes it started, and Docker containers are left out.

## [1.10.0] - 2026-10-23

### Added
- Double click a port to change it in place, or a name to rename it. Return saves, Esc cancels. A bad port keeps the field open and says why.

## [1.9.0] - 2026-10-23

### Added
- Logs have a button that shows only errors and warnings.
- Scrolling up in the logs pauses following, and a Jump to latest button brings you back. Scrolling to the end resumes it.
- Copy as curl, in the right-click menu and the share menu.

## [1.8.4] - 2026-10-22

### Fixed
- Clicking outside Switchboard, on another app's window, now closes the popover. It sometimes stayed open.

## [1.8.3] - 2026-10-22

### Fixed
- A stopped server whose folder was deleted or moved used to say "The folder is gone" and nothing else. Its row now says so, and the Start button becomes Forget.

### Fixed
- Updating no longer reports a problem when an even newer version was released since the last check.

## [1.8.2] - 2026-10-22

### Fixed
- Switchboard could quit by itself a few seconds after starting. Looking up open tmux and zellij sessions ran while the window was being drawn. It now happens in the background.

## [1.8.1] - 2026-10-22

### Fixed
- Icon buttons were hard to see in dark mode. They use a lighter purple there now.

## [1.8.0] - 2026-10-22

### Added
- Switchboard checks GitHub for a newer release at launch and every few hours. When there is one, the settings menu shows "Update to X" with a dot on the gear. For Homebrew installs it updates and restarts itself, and for a zip install it opens the download page. "Check for updates" in the settings menu turns the daily check off, and "Check for updates now" asks right away.

### Fixed
- Buttons grow to fit their label, so "Copy address" is no longer cut off.

## [1.7.0] - 2026-10-22

### Added
- Logs open inside Switchboard instead of a new Terminal window. They follow new lines, can be filtered, copied and cleared, and work for Docker containers too.
- A terminal button sends the log to Terminal, iTerm, Ghostty, Warp, kitty, Alacritty or WezTerm, whichever are installed. It remembers your pick, shows that terminal's icon and opens it in one click. "Terminal for logs" in the settings menu changes it.
- Sessions already open in tmux or zellij are listed too. The log opens there as a new window or pane.

### Fixed
- A tooltip no longer covers a menu you just opened.

## [1.6.0] - 2026-10-21

### Added
- Starting a server whose port is taken now says who holds it and offers to start on the next free port. Start stack and Start project skip taken ports and tell you which.
- MIT license.

### Fixed
- The port check called a port "in use" for up to 30 seconds after a server stopped, which could block Undo and Start. It now asks whether anything accepts connections.

### Changed
- The map and the Stop warning now separate connections that were seen from ports that only a `.env` file names, so a guess is never presented as a fact. Labels say "connected", "in .env, not seen" and "No connection seen".
- Motion: rows, panels and map nodes slide and settle with springs instead of fading, the list and the map switch with a slide, and buttons press in.
- Install notes: the first launch steps now match current macOS (Privacy & Security, Open Anyway).
- README rewritten around what you get, with a one line tagline.

## [1.5.0] - 2026-10-21

### Added
- Change port. Restarts a running server on another port, with Undo. It edits the port flag it recognises (Vite, Next.js, Laravel, Flask and others) and falls back to `PORT`.

## [1.4.1] - 2026-10-21

### Fixed
- `switchboard version` printed "dev" when run through the Homebrew link.

## [1.4.0] - 2026-10-21

### Added
- Undo after Stop and after Stop all.
- Right-click menus on rows, project headers and map nodes.
- Project boxes on the map.
- Map: drag empty space to pan, pinch or buttons to zoom, click to deselect, connection counts.

## [1.3.0] - 2026-10-21

### Added
- Shareable stack: `switchboard.json` and a `switchboard` command line (`status`, `start`, `stop`, `export`, `why`).
- Map icons by server type, draggable nodes with saved positions.
- Keyboard navigation and VoiceOver support.

## [1.2.0] - 2026-10-21

### Added
- Stack map: which servers talk to which, broken links from `.env`, a warning before stopping a server others use.
- Start stack: bring a project back in dependency order.
- "Why did it stop?" from exit status, crash reports, last output, port takeover and closed terminals.

## [1.1.0] - 2026-10-21

### Changed
- Renamed the app from LocalServer to Switchboard.

## [1.0.0] - 2026-10-21

### Added
- First release. Menu bar list of every listening port with its project, Open, Restart, Logs, Share and Stop.
