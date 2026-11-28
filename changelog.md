# Changelog

Each release, newest first. Release dates, installers, checksums, and build attestations are on [GitHub Releases](https://github.com/baros4294/bistre/releases).

## v0.2.0

### Updating from v0.1.2

v0.1.2 reads only the old update format, so install v0.2.0 once from GitHub Releases. Later versions update in the app. Your chats and settings stay on the device.

### New

- Projects: group chats under a name, a folder, and instructions. A chat in a project works in its folder and sends the project's instructions, shown on their own row of the context gauge. The sidebar lists each project with its chats, Settings > Projects edits them (including the folder's hooks), and the chat settings move a chat between projects.
- Scheduled runs choose what happens when a tool needs approval and nobody is watching: skip it and go on, run file tools and the shell without asking in a separate worktree copy, or wait in the chat.
- Writing tools in the manuscript: Plan scene adds a writing brief after the beats, Write summary fills the chapter summary and lists contradictions with earlier chapters, and Rewrite, Expand, Shorten, and Polish replace the selection or the whole scene in place, unsaved. Draft my reply writes your next message into the composer after what you typed.
- Windows: a shortcut that works from any app (`Ctrl+Alt+Shift+B` by default) brings Bistre to the front on a new chat. Change it or turn it off in Settings > Shortcuts.
- Any number of chats can reply at once. The sidebar marks chats that are replying, waiting for you, finished, or stopped with a problem, and an approval waits in its own chat.
- Replies keep going after you close the window on desktop (a background engine) and while the app is in the background on Android.
- A file viewer, paste and drop of files and pictures, a chat's files in Studio > Files, sent picture thumbnails, and generated pictures on replies.
- Skills install from a GitHub link, a folder, or a file, and a reply can be saved as a skill.
- Provider share codes copy a provider's settings, with the API key left out unless you include it.
- Display settings: show or hide your name, the files you sent, thinking and tool cards, the model and provider, chat list dates, and more. Every display setting now changes the chat and the chat list.
- Settings > Updates & Storage exports every chat with its files as a zip, and can erase everything on the device at the next start.

### Changed

- Provider replies follow each provider's protocol more closely: a cut-off reply offers Continue, refusals and errors name their reason, and retries share one budget per provider.
- MCP servers keep one session each instead of restarting per call, and their reads are bounded.
- Streaming, search, and long chats use less work per update. The retry notice says which try failed and counts down to the next.
- The context gauge names Workspace instructions (from `AGENTS.md`) apart from Project instructions.
- New app icon with no background plate.

### Fixed

- An update is offered only when the release is newer than the installed build: the release tool refuses a tag that differs from the version compiled into the app, so an installed update is never offered again.
- The retry notice names its reason in words instead of a raw code.
- Settings search finds every settings page by its labels.
- Folder paths keep their order in right-to-left languages.

## v0.1.2

- Provider protocol hardening, live agent tools, the Files API, MCP 2026-07-28 support, and voice and UI upgrades.

## v0.1.1

- Windows installer, and Linux `.deb`, `.rpm`, and AppImage packages.

## v0.1.0

- First public release.
