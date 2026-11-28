# Changelog

Each release, newest first. Release dates, installers, checksums, and build attestations are on [GitHub Releases](https://github.com/baros4294/bistre/releases). What each feature does in detail, and what is still partial, is in [`docs/specs/00-architecture.md`](docs/specs/00-architecture.md) (Implementation Status).

## v0.2.1

### Updating from v0.1.2

v0.1.2 reads only the old update format, so install v0.2.1 once from GitHub Releases. Later versions update in the app. Your chats and settings stay on the device.

### Projects and agents

- Projects: group chats under a name, a folder, and instructions. A chat in a project works in that folder and sends the project's instructions, shown on their own row of the context gauge. The sidebar lists each project with its chats, Settings > Projects edits them and reviews the folder's hooks, and the chat settings move a chat between projects.
- Any number of chats can reply at once. Each keeps its own Stop, live text, tool steps, and approvals; the sidebar marks a chat that is replying, waiting for you, finished while you were elsewhere, or stopped with a problem.
- Replies keep going after you close the window on desktop: a background engine serves the app, runs scheduled jobs, and stops when it has nothing to do. On Android a foreground service follows live replies.
- Scheduled runs start a real chat with the job's assistant, mode, and project, and each job chooses what happens when a tool needs approval and nobody is watching: skip it and go on, run file tools and the shell without asking in a separate worktree copy (at most 8 kept for review), or wait in the chat.
- Chat goal (`/goal`), side questions (`/btw`), Summarize into a new chat, Branch into a new chat, messages left out of the context, and a limit on how many messages are sent as history.
- Finished replies show their tool steps as one folded checklist, with the thinking between them.
- Computer use on desktop and phone use on Android: one tool for screenshots, clicks, typing, keys, and scrolling. Off by default, and every call asks first.

### Writing

- Manuscript tools: Plan scene adds a writing brief after the beats; Write summary fills the chapter summary from its scenes and lists contradictions with earlier chapters; Rewrite, Expand, Shorten, and Polish replace the selection or the whole scene in place, unsaved.
- Draft my reply writes your next message as the chat's persona into the composer, after what you already typed.
- Translate a message as a new version of it; new chats name themselves after the first reply.

### Files and media

- A file viewer for pictures, text, and documents, with Copy, Save a copy, and Open on the platforms that allow them.
- Paste and drop files and pictures into the composer; text longer than 8,000 characters joins the message as a `.txt` file.
- Studio > Files lists every file of a chat: sent, made by the AI, and edited workspace files with Rewind.
- Replies can carry pictures and speech; picture, speech, and video models can answer a chat turn, and a cut-off video job is fetched again by Try again.
- Attachments: the file type comes from the extension or the file's first bytes; a file that cannot be sent becomes a note to the model and a notice, never a silent drop.
- Chats export with their files as a zip and import back, and Erase everything on this device runs at the next start.

### Providers and models

- OpenRouter is a starter provider, with its reasoning details replayed and data collection denied on every request.
- The model catalog refreshes daily from OpenRouter and LiteLLM with prices, limits, and what each model can take in and put out.
- Provider share codes copy a provider's settings; the API key is left out unless you include it.
- Web sources a reply used are listed in Studio > Sources and Turn details.
- Turn details shows the raw request and response.
- Settings > Default models shows what paid requests were for over the last 30 days, and sets how full a chat gets before it is shortened.
- The MCP Registry can be searched from Settings > Agent; added servers start turned off.
- Skills install from a GitHub link, a folder, or a zip, and a reply can be saved as a skill.

### Appearance and settings

- Display settings: show or hide your name, the files you sent, thinking and tool cards, the model and provider, chat list dates, and the model icon; fold code blocks; set the code text size. Every display setting now changes the chat and the chat list.
- Assistants: duplicate an assistant, keep saved prompts, and set an opening message.
- Windows: a shortcut that works from any app (`Ctrl+Alt+Shift+B` by default) brings Bistre to the front on a new chat. Change it or turn it off in Settings > Shortcuts.
- Settings search finds every page by its labels.
- New app icon with no background plate.

### Changed

- Provider replies follow each provider's protocol more closely: a cut-off reply offers Continue, refusals and errors name their reason, and retries share one budget per provider.
- Each MCP server keeps one session instead of starting again for each call.
- Search keeps working when its index is damaged and finds Chinese, Japanese, and Korean text and parts of words.
- Shortening a conversation is reversible: summaries can be edited, the model can recall what was shortened, and `/compact` takes what to keep.
- Streaming, search, and long chats do less work per update. The retry notice says which try failed and counts down to the next.
- The context gauge names Workspace instructions (from `AGENTS.md`) apart from Project instructions.

### Fixed

- An update is offered only when it is newer than the installed build: the release tool refuses a tag that differs from the version built into the app, so an installed update is never offered again.
- Pasting text works when copied files or pictures cannot be read (for example on Linux without `wl-paste` or `xclip`).
- The retry notice names its reason in words instead of a raw code.
- Folder paths keep their order in right-to-left languages.

### Not yet

- Audio and video in replies have no in-app player; a web source can be copied but not opened from the app.
- The background engine has not had a live run on Linux, and Android and Linux paste and drop have not had live runs.

## v0.1.2

- Provider protocol hardening, live agent tools, the Files API, MCP 2026-07-28 support, and voice and UI upgrades.

## v0.1.1

- Windows installer, and Linux `.deb`, `.rpm`, and AppImage packages.

## v0.1.0

- First public release.
