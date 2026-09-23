# Agent Island

A native macOS app that shows every active **Claude Code** session and **Codex** thread as a small circle beside the MacBook notch. By default the circles line up to the left of the notch. When an agent starts working, a circle slides out of the notch like liquid pulling off the bezel. The circle shows Claude's mascot Clawd or the Codex pet at work, with a ring that lights up when the agent needs you. When the session ends, the circle slides back in.

| Status | Ring | Mascot |
|---|---|---|
| working | brand color (Claude coral, Codex blue) plus the effort light; purple at ultra effort | Clawd looks around; the pet types on its laptop |
| question: a permission prompt, AskUserQuestion, an approval, or request_user_input | amber, breathing slowly | Clawd raises its arms with a "?"; the pet waits |
| plan: plan mode, or a plan ready for review | violet | Clawd scans slowly; the pet reviews |
| error: StopFailure, a stream error, or a failed tool call | red. A failed tool call only flashes. | Clawd shakes; the pet plays its failed animation |
| complete | green sweep, then dims | Clawd jumps; the pet jumps, then idles |

**Effort** shows as light orbiting the ring while the agent works:
- **low to xhigh:** one to three comets, going faster and brighter at each tier.
- **max:** a shimmer all the way round.
- **ultracode** (Claude) and **ultra** (Codex): the ring turns purple, with a purple aurora sweeping round it, a breathing bloom, and sparks.

Hovering over a circle makes it swell slightly; nothing else happens until you click.
- **Click a circle** and it pours down into a card. The card shows the repo and branch, the chat title, and what the agent is doing right now: its last tool call, such as `Edit(IslandModel.swift)` or `Run(npm test)`.
- The card also shows a quick diff of the session's folder (`+128 −14 3 files`) and the agent's mode:
  - For Claude: Default, Accept edits, Auto, Plan, or Bypass.
  - For Codex: Read only, Auto, Full access, or Plan.
- The diff counts uncommitted changes against the last commit, including new files. Git runs with the repository's hooks, fsmonitor, and diff drivers disabled, and never takes the index lock.
- **Click the card** to open that chat.
- **Click the circle again**, or anywhere else, to close the card without leaving what you are doing.

**Drag a circle** to move it to the other side of the notch, or to reorder it:
- The other circles slide aside to make room while you drag.
- A circle crossing the notch fuses with it like liquid.
- When you let go, the circle is thrown with the speed you gave it. It overshoots its place a little, swings back, and settles, the way the Dynamic Island moves.
- A side holds four circles. A circle dropped on a full side springs back to where it came from.

New circles land next to the notch on the left and push the others outward. When the left side is full, new circles go to the right. You can change the starting side in the window's Island page.

## Install

Requires macOS 26 or later and Swift 6.2 or later (Xcode 26+).

```bash
./scripts/bundle.sh release      # builds build/AgentIsland.app
mv build/AgentIsland.app /Applications/   # optional
open /Applications/AgentIsland.app
```

## Using it

Agent Island keeps to the menu bar. Its window stays hidden until you ask for it:
- **Open it** by launching the app from Finder, Spotlight, or Launchpad, even while it is already running. You can also use **Open Agent Island…** (⌘O) in the menu bar menu.
- **Close it** with ⌘W or the close button. The island keeps running beside the notch.
- **While the window is open**, the app has a Dock icon and shows in ⌘-Tab. Both go away again when you close it.
- A launch at login does not open the window.

The window has three pages:
- **Agents** lists every live session: its mascot and status ring, repo and branch, what it is doing, and its effort level.
  - Double-click a row or press **Open** to jump to the chat.
  - **×** hides a circle until that agent has something new.
- **Island** holds the settings:
  - **Watch Claude Code** and **Watch Codex** turn each agent on or off. The change is immediate: switching an agent off sends its circles back into the notch.
  - **New circles appear** on the left of the notch (the default) or the right.
  - **Circles** has two modes:
    - **Stay out while working** is the default.
    - **Pop, then tuck back:** a circle hides in the notch a few seconds after its news (adjustable). Questions, plans, and errors stay out until they're handled. Point at the notch to bring every circle back out.
  - **Codex Pet** picks the pet from a grid of previews.
- **Hooks** shows whether each agent's hooks are installed and whether they point at this copy of the app. It has buttons to add, repair, or remove them, and shows any error.

The first launch opens on **Hooks**, so you can decide there whether Agent Island may edit `~/.claude/settings.json`. The menu bar menu keeps quick versions of the toggles and the hook buttons.

## Hooks

The app finds sessions without hooks, but hooks make it precise. Without hooks, a permission prompt looks the same as a long-running tool.

- **Claude Code.** **Add Hooks** on the window's Hooks page, *Add Claude Hooks* in the menu, or `AgentIsland --install-hooks` adds entries to `~/.claude/settings.json`.
  - Each entry runs `agent-island-hook claude` with `async: true`, so it never blocks a turn and never prints anything that could affect a permission decision.
  - The events covered are SessionStart, UserPromptSubmit, PreToolUse (for AskUserQuestion and ExitPlanMode only), PostToolUse, PostToolUseFailure, PermissionRequest, PermissionDenied, Notification, Stop, StopFailure, and SessionEnd.
  - The original file is backed up to `settings.json.agent-island.bak` before anything changes. Installing twice changes nothing.
  - To remove them, use **Remove Hooks** or `AgentIsland --uninstall-hooks`. This removes only Agent Island's entries.
- **Codex.** Opt in from the Hooks page or the menu, which writes `~/.codex/hooks/hooks.json`. Codex may ask you to trust the new hooks the first time. Codex works without hooks because its rollout files already report every status. Hooks can still catch approval requests that aren't written to rollouts.

> **The hook command is an absolute path into the app bundle.** If you move or rename `AgentIsland.app`, the Hooks page says the hooks point at another copy of the app. Press **Repair** to point them here. Until then every hook silently runs a binary that is no longer there.

The helper sends each hook's input to the app over a Unix socket at `~/Library/Application Support/AgentIsland/island.sock`. It gives up after 300ms and always exits 0, so a closed app never slows an agent down.

## What gets detected

- **Claude Code**, both the Code tab in Claude.app and the terminal CLI:
  - Sessions come from the registry in `~/.claude/sessions/`, which gives each chat's title, folder, and busy/idle status.
  - The effort level and ultracode come from each session's launch arguments, and from its transcript as they change turn by turn.
  - Headless runs that never register show up once their hooks fire.
- **Codex**, both ChatGPT.app's Codex and the CLI: threads come from the rollout files in `~/.codex/sessions/`, and titles come from Codex's own thread database, opened read-only.
- **Not detected:** plain claude.ai or ChatGPT conversations. Nothing on disk reveals them.
- **Subagents** count toward the session that started them. They don't get a circle of their own.
- A circle appears on a session's first prompt, not just because the session is open.
- A finished session keeps its dimmed circle for 10 minutes, then leaves. A session that says nothing for an hour is dropped.

## Mascot art

None of the art is copied into this repository.
- **Clawd** is redrawn from the block characters the Claude Code CLI uses to draw it.
- **Codex pets** are read at runtime from the installed ChatGPT.app (its `app.asar`), or from your own hatched pets in `~/.codex/pets/`. The extracted sheets are cached in `~/Library/Caches/AgentIsland`.
- Without ChatGPT.app, Codex circles fall back to a plain placeholder.

## Developer flags

Run these on the binary inside the bundle: `build/AgentIsland.app/Contents/MacOS/AgentIsland <flag>`.

| Flag | What it does |
|---|---|
| `--demo` | Fake sessions that cycle through every status and effort level |
| `--render <dir>` | Draws the island, and each page of the window, into PNG files offscreen, then exits |
| `--render-icon <dir>.iconset` | Writes the app icon at every size (used by `bundle.sh`) |
| `--probe [seconds]` | Prints the notch geometry and what the watchers find, then exits (default 6 seconds) |
| `--diagnose` | Logs rebuild and render rates per second to stderr |
| `--install-hooks` / `--uninstall-hooks` | Adds or removes the Claude hooks, then exits |

Only one copy of the app runs at a time. Quit the menu bar copy before running these flags.

```bash
swift build && swift test
./scripts/simulate.sh            # with the app running: walks a fake Claude
                                 # session and Codex thread through every status
```

`simulate.sh` pipes hook payloads through the real helper binary. To check the result without looking at the screen, run `AgentIsland --probe 45 &` first; the probe prints each status change. You can override any preference for one run from the command line, for example `--probe 30 -visibility popThenTuck -tuckAfter 3`.

The code is split into three parts:
- `IslandCore` has no UI and holds the event reducer, watchers, parsers, and sprite decoding. All tests live here.
- `AgentIsland` is the app: the island panel, the main window, the model, and the drawing. The app icon is drawn in code too (`Views/AppIcon.swift`).
- `agent-island-hook` is the hook helper. It uses Darwin only, with no Foundation, so it starts fast.

## Known limits

- The circles sit in the menu bar strip and cover some menu items: up to 4 circles per side, next to the notch. On the left that means the frontmost app's own menus. Drag circles to the right, or set new ones to appear there, if they get in the way. Only the circles take clicks, so menu items between them still work.
- A circle's side lasts as long as its session. A new session starts on the preferred side again.
- Only one display is supported: the notch screen, or the main screen when there is no notch. Screen changes are handled but haven't been tested much.
- CPU is about 0.1% when nothing is happening and about 3.5–4% while an agent works, in a release build.
- Codex approval requests may not appear in rollout files. If a Codex circle never turns amber, add the Codex hooks.
- Clicking a terminal session brings its terminal app forward but can't pick the exact tab.
