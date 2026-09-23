# Agent Island: handoff

Agent Island is a native macOS app (Swift 6.4, SwiftUI, SwiftPM, macOS 26+) that shows every active Claude Code session and Codex thread as a small circle beside the MacBook notch. The approved plan is at `~/.claude/plans/i-want-to-make-dapper-hammock.md`.

## Where things stand

Everything in the plan is built. `swift build` is clean and 49 tests passed on the last run. This file covers what is left: tasks 5–10 in the next section, then the checks that need a person at the machine.

> **Update (2026-09-23): tasks 5–10 are done.** 63 tests pass, and both `swift build -c release` and `./scripts/bundle.sh release` finish with no warnings. The task text below is kept as it was written.
> - **5.** `BubbleViews.swift`, the fixtures folder and its `resources:` line, and the stray `.DS_Store` files are gone.
> - **6.** `README.md` is written.
> - **7.** `scripts/simulate.sh` exists and was checked headlessly against `--probe 34`. Every step landed, including the red flash reverting to working.
>   - `--probe` now takes a duration, prints only changes, and shows `(tucked)`, `(leaving)`, and the animation mode.
> - **8.** The Watch toggles are live (`IslandModel.setWatching`), and hook events of a switched-off agent are dropped. Checked with `--probe 5 -watchClaude NO`.
> - **9.** The fix was confirmed: a fully tucked island now drops to `paused`. It used to stay at 60fps.
>   - The tuck and emerge rules moved into `IslandCore/Model/CircleMotion.swift`, with tests.
>   - Switching back to "Stay out" now brings tucked circles out. It didn't before.
>   - The peek zone widens to cover every circle while peeking, so the far circles stay reachable.
>   - Checked with `--probe 24 -visibility popThenTuck -tuckAfter 3`.
> - **10.** Tests for the `PetCatalog` cache were added. The Codex-app tests now skip properly with `.enabled(if:)`, where before they failed. The image sheets were re-rendered and look right.
>
> Bugs found and fixed along the way:
> - The registry retired *every* Claude session it didn't list, including hook-only (headless or SDK) sessions. It now retires only sessions it listed before.
> - The `PetCatalog` image cache now keys on the cache directory and re-extracts a sheet that macOS purged.
> - Codex hooks no longer pick up an inherited `CLAUDE_EFFORT`.
>
> **Also added (2026-09-23): a main window**, `Window/MainWindowController.swift` plus `Views/MainWindow/`.
> - Pages: Agents, Island settings, and Hooks. Hooks shows whether the installed hooks point at another copy of the app and offers Repair.
> - The window stays hidden until you open the app from Finder or Spotlight, or choose *Open Agent Island…* in the menu. The app shows in the Dock only while the window is open.
> - The first-run hooks alert is gone; the first launch opens on the Hooks page instead.
> - The app icon is drawn in code and packed into the bundle by `bundle.sh`.
> - `--render` now also writes `window-*.png`. The Liquid Glass sidebar comes out blank there because glass can't be captured; its rows are present.
> - Checked live: a cold launch opens the window and makes the app a Foreground app, and reopening while it runs reuses the window. Not yet checked by a person: that closing the window removes the Dock icon.
>
> **Also added (2026-09-23): left-side circles, dragging, and a purple ultra ring.**
> - Circles now line up left of the notch; the side is a setting. Newest sits next to the notch. `IslandCore/Model/IslandArrangement.swift` holds which circle is on which side, and in what order.
> - Every circle rests on its own springs (`IslandCore/Model/SpringMotion.swift`, a closed-form damped spring that can be retargeted mid-flight). Circles glide to close gaps and make room.
> - Presses on circles are handled in AppKit (`IslandHostingView` in `NotchPanel.swift`). A press that moves more than 4pt becomes a drag. On release, the circle is thrown with 60% of the pointer's speed and lands on an underdamped spring.
> - `--render` writes `drag.png`, drawn by hand, and `drag-model.png`, which drives the real model with made-up pointer events and draws what it decided. Both look right.
> - The ultra tier (ultracode and Codex ultra) draws a purple ring and aurora (`IslandStyle.ultra`).
> - Not yet checked by a person: dragging with a real mouse or trackpad.
>
> **Also added (2026-09-23): click-to-open cards.** Hover now only swells a circle, on a spring. Clicking pours the circle into a card (`IslandLayout.cardFrame`, driven by a spring). The card shows the latest tool call, a git `+x −y` for the session's folder (`IslandCore/Util/GitDiffStat.swift`), and the mode (`AgentSession.modeLabel`, from Claude's `permission_mode` or Codex's `sandbox_policy`). Clicking the card opens the chat. Clicking the circle again only closes the card, and so does any click outside the app (a global mouse-down monitor).
> - Claude reports its activity after each tool finishes (PostToolUse), because the installed PreToolUse matcher covers only AskUserQuestion and ExitPlanMode.
>
> Still open, and small:
> - A circle can now be hidden from the Agents page (the × button), but there is still no right-click menu on the circle itself.
> - Fixed: the menu's hook buttons used to swallow errors. A failure now opens the Hooks page, which shows the error.
> - The peek hysteresis still needs a check with a real pointer. It is part of "Needs a person" item 1.
>
> **Also added (2026-09-23): a white spinner while a slash command runs.** `AgentSession.command` (a `SlashCommand`) is set by three new Claude hooks, and `isRunningCommand` swaps the mascot, effort light, and ring for a white 8-spoke spinner in a blinking ring (`IslandCanvas.drawCommandSpinner`). `--render` writes `command.png`.
> - Checked against Claude Code 2.1.280 headlessly: `/compact` fires PreCompact and PostCompact but *not* UserPromptSubmit. A typed prompt command fires UserPromptExpansion (with `command_name`), then UserPromptSubmit with the raw `/name args` prompt.
> - The transcript writes a command's lines only once it is over: `compact_boundary` on success, a `system`/`local_command` line on failure or cancel. Those end the spinner too, but only if written after the command started, because a transcript's first read replays old ones. A command silent for 15 minutes is dropped as a last resort.
> - PostCompact never fires inside a subagent, so a subagent's PreCompact is ignored.
> - The app adds missing events to its own installed hooks at launch (`HookManager.updateInstalledHooks`).
> - `simulate.sh` now walks `/compact` and a `/review` with a permission prompt in it. Every step landed under `--probe`.
> - Not yet checked by a person: a real `/compact` in a live session.
>
> **Also added (2026-09-23): answering and replying from the card.** The card's chevron drops it down (`detailsOpenness`, a spring, grows it to 320×440) to show the waiting question or plan, a timeline, and a message field (`Views/CardDetails.swift`).
> - Checked against Claude Code 2.1.280's code:
>   - PermissionRequest hooks race the dialog in every interactive path (terminal and the desktop app's SDK sessions). The first answer wins.
>   - AskUserQuestion is answered by `allow` with `updatedInput.answers`, keyed by question text. ExitPlanMode is approved by `allow` echoing the input; ExitPlanMode then restores the mode from before planning by itself. `deny` with a message keeps Claude planning.
>   - `asyncRewake` hooks run in the background when the session is interactive or has streaming input, and exit 2 queues stderr as the next message. `rewakeMessage` and `rewakeSummary` set the framing. The hook `timeout` is not capped.
>   - Claude.app's `claude://code/continue` takes no prompt, so there is no URL route in.
> - Wire protocol (`HookReply`, `HookReplyChannel`): the helper writes, half-closes, and waits up to 2s for `K`; then `O…` goes to stdout, exit 0, and `W…` goes to stderr, exit 2. EOF means no answer.
> - `IslandModel` holds `asks` and `wakeChannels`, lets them go when the question is answered in the chat or a new turn starts, and cancels a `Stop` from any session without a registry pid (headless runs).
> - Timeline: `ActivityItem`s from transcripts (`ClaudeTranscriptWatcher.activity`) and Codex rollouts (`CodexRolloutParser.message`), 80 per session, kept by the model, not the reducer.
> - The panel now `canBecomeKey` with `becomesKeyOnlyIfNeeded`, so only the text field takes focus. Clicks on the card go to SwiftUI; only circles are handled in AppKit.
> - `--render` writes `conversation.png` through a hidden window, since ImageRenderer leaves scroll views and text fields blank.
> - Tests: the reply JSON, decoding, a socket round trip, and the real helper binary against a test server (decision, wake, quiet, and no app). Live under `--probe`: a waiting question showed, then was let go when answered elsewhere; a headless `Stop` was let go in 0.04s.
> - **Not yet checked by a person:** clicking and typing on the live card, with a real pointer and keyboard (`scripts/simulate.sh ask` sets it up); a real session answering from the card; a real message waking a session.
>
> **Also fixed and added (2026-09-23): opening the exact chat, and pasting messages into it.**
> - **Bug:** `claude://code/continue?session=` only takes the Claude app's own id, `local_<uuid>` (`hostSessionId` in the registry file). We passed the Claude Code session id, and Claude.app logged `code entry link invalid ?session` for every click (see `~/Library/Logs/Claude/main.log`). `AgentSession.claudeAppLink` now builds the link from `hostSessionID`. Checked live: opening this session's `local_` link logged nothing, where a bad id logs the warning.
> - `ChatPaster`: for a chat in the Claude app, Return on the card opens the chat, waits for Claude to be frontmost, finds the message box through Accessibility (focused `AXTextArea` in the lower half of the window, or the lowest one, focused first; Electron's tree is switched on with `AXManualAccessibility`), pastes with ⌘V via `CGEvent.postToPid`, confirms the text is in the box, and presses Return. It never sends when the box already held text. The clipboard is put back afterwards.
> - No Accessibility permission, or no box found: the chat opens and the message stays on the clipboard, with a note on the card. `IslandSettings.pasteSends` (Island page) makes Return only paste.
> - Terminal sessions still use the Stop hook's `asyncRewake`.
> - **Not yet checked by a person:** the paste itself. This environment has no Accessibility permission, so it has never run against a real Claude window. Ad-hoc signing means the permission has to be granted again after each rebuild.

**Already working**
- **Detection.**
  - The `~/.claude/sessions/*.json` registry, plus effort and ultracode read from each session's process arguments.
  - Claude transcript tailing.
  - Codex rollout tailing, plus titles from `~/.codex/state_*.sqlite`.
  - The hook socket, fed by the `agent-island-hook` binary. Hooks were tested end to end with piped payloads.
- **Drawing.**
  - A metaball liquid layer that makes each circle emerge from, and retract into, the notch.
  - The whole island is drawn in one canvas renderer (`Views/IslandCanvas.swift`): Clawd, decoded from the CLI's block characters; the Codex pet, read from `ChatGPT.app`'s `app.asar` at runtime; status rings; and an effort light for every tier, including the ultra aurora.
  - A hover card.
- **Performance, release build.** CPU is about 0.1% idle. While an agent works it is about 3.5–4%.
  - The frame rate adapts: 60fps while a circle emerges or retracts, 24fps for 25 seconds after a status change, then 12fps.
  - The window is the height of the menu bar strip (about 54pt) and grows to 170pt only while the hover card is open.

**Build and run**
```bash
swift build && swift test
./scripts/bundle.sh release          # → build/AgentIsland.app
open build/AgentIsland.app           # add --args --demo for scripted fake sessions
```
Command-line flags (all in `AgentIslandApp.swift`):

| Flag | What it does |
|---|---|
| `--demo` | Fake sessions that cycle through every status |
| `--render <dir>` | Writes the island to PNG files offscreen, then exits |
| `--probe` | Prints the notch geometry and the sessions it finds, then exits |
| `--diagnose` | Logs rebuild and render rates per second to stderr |
| `--install-hooks` / `--uninstall-hooks` | Adds or removes the Claude hooks, then exits |

**Before you start**
- A copy launched with `--diagnose` may still be running. Run `pkill -x AgentIsland` first. Only one copy can run at a time; the lock is `~/Library/Application Support/AgentIsland/instance.lock`.
- `screencapture` fails in agent sessions because they don't have Screen Recording permission. To check visuals, run `--render <dir>`, crop the result with `sips -c <height> <width> file.png`, and open the PNG with the Read tool.

---

## Tasks 5–10

### 5. Delete dead code
- Delete `Sources/AgentIsland/Views/BubbleViews.swift`. Its three types, `StatusRing`, `EffortAura`, and the private `Sparks`, are unused since `IslandCanvas` replaced them. `StatusRing` and `Sparks` are only referenced inside that same file.
- Keep `ClawdView` and `CodexPetView` in `Views/Mascots.swift`. The render mode's mascot sheet (`RenderMode.mascotSheet`) still uses them.
- Remove the empty `Tests/IslandCoreTests/Fixtures/.keep`, and the `resources: [.copy("Fixtures")]` line in `Package.swift`, unless a real fixture gets added.
- Delete the stray `Sources/.DS_Store`.
- **Done when:** `swift build` passes and `grep -rn "EffortAura\|StatusRing\|AgentBubbleView" Sources` finds nothing.

### 6. Write a README
Create `README.md` at the repo root. Cover:
- **What it is.** One paragraph, plus the table of statuses and colors from the plan.
- **Install.**
  - Build with `./scripts/bundle.sh release`.
  - Move the app to `/Applications` (optional).
  - Launch it and answer the first-run dialog that offers to add hooks.
- **Hooks.**
  - The app adds entries to `~/.claude/settings.json` that run `agent-island-hook claude` with `async: true`, so they never block a turn or print output.
  - It backs up the original to `settings.json.agent-island.bak` first.
  - Remove the hooks from the menu bar menu, or with `--uninstall-hooks`.
  - **The hook command is an absolute path into the app bundle. If the app moves, reinstall the hooks.**
  - Codex hooks go to `~/.codex/hooks/hooks.json`, are opt-in from the menu, and Codex may ask you to trust them.
- **What gets detected.**
  - Only Claude Code sessions (the Code tab in Claude.app, and the terminal CLI) and Codex threads. Plain claude.ai or ChatGPT chats are not visible locally.
  - Subagents roll up into the circle of the session that started them.
- **Mascot art.**
  - Clawd is redrawn from the CLI's block characters.
  - Codex pets are read at runtime from the installed `ChatGPT.app` or from `~/.codex/pets`, and cached in `~/Library/Caches/AgentIsland`. None of that art is copied into the repo.
- **Developer flags.** The table above.
- **Known limits.**
  - Circles cover some menu-bar items (at most 4 per side).
  - Only one display is supported.
  - CPU figures as listed above.

### 7. Write `scripts/simulate.sh`
The plan calls for this script and it does not exist yet. It should drive every status through the real hook path, so the socket, the decoding, and the reducer are exercised together.
- Pipe JSON payloads into `build/AgentIsland.app/Contents/MacOS/agent-island-hook claude` (or `codex`), with one fixed `session_id` and a `sleep` between steps.
- Walk through these steps. The payload shapes are in `Tests/IslandCoreTests/ParsingTests.swift`:
  1. `UserPromptSubmit` with `"effort":{"level":"max"}`
  2. `PermissionRequest` for `Bash` → question
  3. `PostToolUse` → back to working
  4. `PreToolUse` for `ExitPlanMode` → plan
  5. `PostToolUseFailure` with `"is_interrupt":false` → a red flash, then back to working
  6. `StopFailure` → error
  7. `UserPromptSubmit`, then `Stop` → complete
  8. `SessionEnd` → the circle retracts
- Add a second session on `codex` that runs at the same time, so both sides of the notch fill.
- **Gotcha: run each hook call as `env -u CLAUDE_EFFORT …`.** The helper forwards `CLAUDE_EFFORT` from its environment, and the reducer lets it override the payload's effort. Inside a Claude Code shell that variable is set, so it would override the effort you passed.
- Optional: `AGENT_ISLAND_SOCKET=/path` points the helper at a different socket.
- **Done when:** with the app running, `./scripts/simulate.sh` visibly steps one circle through every status. Headless alternative: start `--probe` in the background, run the script, and check the printed statuses.

### 8. Make the Watch Claude / Watch Codex toggles take effect immediately
- **The bug.** `IslandModel.startWatchers()` (around line 129) reads `settings.watchClaude` and `settings.watchCodex` once, at launch. Flipping either toggle in the menu does nothing until the app restarts. Hook events are also accepted whatever the toggles say.
- **The fix.**
  - Split the method into `setClaudeWatching(_ on: Bool)` and `setCodexWatching(_ on: Bool)`. Each starts or stops the watchers: set them to nil and call `stop()` on the actors.
  - Call them from `didSet` on the settings. Settings is `@Observable`, so either wire it through a callback like `onLayoutChanged`, or observe it from `IslandModel`.
  - When a kind is turned off, retire every session of that kind: `reducer.dismiss(id:)` for ids starting with `claude:` or `codex:`.
  - In `handle(_:)`, drop hook events whose `kind` is disabled.
- The demo guard in `startWatchers` (`guard demo == nil`) must keep working.
- **Done when:** turning Watch Claude off makes the Claude circles retract within about 0.5s, and turning it back on brings live sessions back without a relaunch.

### 9. Test "Pop, then tuck back" mode
This mode is built but has never been run live.
- **Where the code is.**
  - `IslandModel.shouldTuck`, and the tuck and peek branches in `rebuild()`.
  - `setPointer`: the peek zone is the notch rect grown by one circle diameter.
  - The setting is `settings.visibility`, with a delay of `settings.tuckAfter` (default 5s).
- **What to check.**
  - With the mode on, a working circle slides back into the notch after about 5 seconds.
  - A question, error, or plan circle never tucks away.
  - A new status makes the circle emerge again.
  - Hovering over the notch pulls every tucked circle back out, and moving the pointer away tucks them again.
  - A tucked circle takes no clicks: `interactiveRects` and `hitTest` already skip bubbles that are retracting.
- **Things to watch for.**
  - In `tick()`, a tucked bubble stays in the `retracting` list forever. Only bubbles whose session is retiring get dropped, but confirm nothing leaks as sessions end.
  - `AnimationMode` should drop to `.paused` once every circle is tucked. Each tucked bubble has `isRetracting == true`, and `currentAnimationMode()` returns `.emerging` for any retracting bubble, so this is probably wrong. Treat "tucked and settled" (retracting for longer than `retractDuration` without retiring) as still. Otherwise a tucked island runs at 60fps for as long as it stays tucked. **This is the likely real bug.**
- It is worth pulling the tuck/peek decision into a small pure function and unit-testing it. The app target has no test target today, so either move the function into `IslandCore` or add an `AgentIslandTests` target.

### 10. Re-run the tests after the latest changes
These changes landed after the last full `swift test` run:
- the name-and-path cache in `PetCatalog`, and the removal of the header cache in `AsarReader`
- `NotchGeometry`: the window now hugs the island, with its own `panelFrame` and `compactHeight`
- the canvas renderer
- `AnimationMode`

To do:
- Run `swift test` and fix any failures.
- Add a test that calling `PetCatalog.builtInPetIDs()` twice gives the same result, and skip it when `ChatGPT.app` is not installed, the same way `SpriteTests` does.
- Check `swift build -c release`.
- Re-render the image sheets and look over `emerge.png`, `statuses.png`, `efforts.png`, and `card.png`.

---

## Needs a person (an agent can't do these)
1. **Look at it on the real screen.** Check that the circles line up with the physical notch, the liquid pull-out on emerge and retract, the hover card, and click to open. A human has to look, since agent sessions can't capture the screen.
2. **Answer the first-run hook dialog.** The `askedAboutHooks` default was reset, so the dialog shows on the next normal launch. So far the installer has only been tested on temporary files, never on the real `~/.claude/settings.json`.
   - Afterwards, check it with `grep agent-island-hook ~/.claude/settings.json`.
   - Then start a new Claude Code session, trigger a permission prompt, and confirm the circle turns amber.
3. **Run a live Codex thread** in ChatGPT.app with effort set to ultra. Confirm the pet circle appears with the aurora, that an approval request turns it amber, and that `task_complete` turns it green.
   - **Risk:** approval requests may not be written to rollout files at all. If they aren't, installing the Codex hooks from the menu is the fix.
4. **Click through the deep links.** Clicking a Claude circle should open `claude://code/continue?session=<uuid>` (the UUID format was confirmed in Claude.app's URL handler). A Codex circle should open `codex://threads/<id>`. A terminal session should bring its terminal app to the front.

## Optional, later
- **Lower CPU.** Move the rotating comets and aurora to Core Animation layers, so the render server animates them and the app's CPU cost while agents work drops close to zero.
- **More than one display.** Test screen changes. `PanelController.updateGeometry()` handles `didChangeScreenParametersNotification`, but that path has not been tried.
- **Git.** The folder is not a git repo. Run `git init`, then add a `.gitignore` for `.build/` and `build/`.

## Hard-won lessons
- **TimelineView schedule.** A TimelineView keeps the schedule it had when its surrounding body last ran. That is why the frame rate is a stored, observed `animationMode` on the model rather than something computed in the view.
- **Menu bar re-renders.** The `MenuBarExtra` body re-runs on every change to the model. Never do I/O in it. It once re-parsed the 4MB asar index on every render and pushed CPU to about 30%.
- **Header caching.** Don't cache the parsed asar header: it takes more than 100MB of memory. Cache the answers you looked up instead, as `PetCatalog.Cache` does.
- **Swift 6 concurrency.** A `deinit` on a `@MainActor` class can't touch that class's isolated state, and SwiftUI views that conform to `Equatable` need `@MainActor Equatable`.
