# Agent Island

A native macOS app that shows every active **Claude Code** session and **Codex** thread as a small circle beside the MacBook notch. By default the circles line up to the left of the notch. When an agent starts working, a circle slides out of the notch like liquid pulling off the bezel. The circle shows Claude's mascot Clawd or the Codex pet at work, with a ring that lights up when the agent needs you. When the session ends, the circle slides back in.

| Status | Ring | Mascot |
|---|---|---|
| working | brand color (Claude coral, Codex blue) plus the effort light; purple at ultra effort | Clawd looks around; the pet types on its laptop |
| question: a permission prompt, AskUserQuestion, an approval, or request_user_input | amber, breathing slowly | Clawd raises its arms with a "?"; the pet waits |
| plan: plan mode, or a plan ready for review | violet | Clawd scans slowly; the pet reviews |
| error: StopFailure, a stream error, or a failed tool call | red. A failed tool call only flashes. | Clawd shakes; the pet plays its failed animation |
| complete | green sweep, then dims | Clawd jumps; the pet jumps, then idles |
| running a slash command: `/compact`, or any command you type | white, blinking | the circle turns into a white spinner |

**Slash commands.** While Claude runs a command you typed, the whole circle becomes a white spinner: eight spokes lit one after another inside a blinking ring.
- `/compact` spins until compacting is done, then lands green. Claude compacting on its own when the context fills up spins too, then goes back to work.
- A command that expands into a prompt, such as `/review` or your own commands and skills, spins for its whole turn.
- A question, a ready plan, or an error still shows over the spinner, since those need you. The spinner comes back once you answer.
- The card says what the command is doing, for example "Compacting conversation…" or "/review · Bash(git diff main)".

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
- **Click the card**, or **Open ↗**, to open that chat: the exact chat in the Claude app, or the thread in Codex.
- **Click the circle again**, or anywhere else, to close the card without leaving what you are doing.

**The drop-down.** The chevron at the bottom right of the card drops it down to show more. A card whose agent is waiting on you opens this way on its own, and its chevron carries an amber dot.
- **Answer Claude's questions.** When Claude asks with AskUserQuestion, the card shows the questions and their options. A single question is answered as soon as you click an option. With several questions, or several answers allowed, pick them and press **Send answers**. You can also type your own answer in the field.
- **Review a plan.** When Claude finishes a plan, the card shows it. **Approve** lets Claude go ahead in the mode it planned from. **Approve, auto-accept edits** switches to accept-edits as it goes. To ask for changes, type them in the field and press Return; Claude stays in plan mode.
  - Claude's own dialog stays up the whole time. Whichever you answer first wins, and the other one goes away.
- **See what it did.** A timeline shows what you asked, what the agent said, each tool it ran, and anything that failed, newest at the bottom. It works for Codex threads too.
- **Send the next message.** Type in the field and press Return.
  - **A chat in the Claude app:** Agent Island opens that chat, pastes the message into its own message box, and presses Return, so it goes as your own message, exactly as if you had typed it there. If Claude is busy, Claude queues it the way it does anything typed mid-turn. The Island page can make Return only paste, to send from Claude yourself.
    - Pasting takes Accessibility permission (Island page, or the prompt macOS shows the first time). Without it, the chat opens and the message waits on your clipboard for a ⌘V.
    - Keys are only pressed while Claude is in front with a text box focused in the lower half of its window. If Claude's box already has something typed in it, the message is pasted but not sent.
  - **A terminal session:** once the turn has ended, the message reaches Claude through a hook, marked as coming from Agent Island. While Claude is still working it waits for the turn to end; the × takes it back. Sessions that were already open when the hooks changed need a restart first, because Claude Code reads hooks when a session starts.
  - Codex threads show the timeline only; reply to them in the Codex app.

**Drag a circle** to move it to the other side of the notch, or to reorder it:
- The other circles slide aside to make room while you drag.
- A circle crossing the notch fuses with it like liquid.
- When you let go, the circle is thrown with the speed you gave it. It overshoots its place a little, swings back, and settles, the way the Dynamic Island moves.
- A side holds four circles. A circle dropped on a full side springs back to where it came from.

New circles land next to the notch on the left and push the others outward. When the left side is full, new circles go to the right. You can change the starting side in the window's Island page.

## Install

There is no prebuilt download yet. You build the app from the source on GitHub, which takes a minute or two.

**You need:**
- A Mac on macOS 26 or later. The circles sit beside the notch, so a MacBook with a notch is best.
- Xcode 26 or later, which brings Swift 6.2. Install it from the App Store and open it once to accept its license. The Command Line Tools alone (`xcode-select --install`) also work if they include Swift 6.2; check with `swift --version`.

**1. Get the code.** Either clone it with git:

```bash
git clone https://github.com/vihAan02/agent-island.git
```

Or, without git, open [github.com/vihAan02/agent-island](https://github.com/vihAan02/agent-island), click **Code → Download ZIP**, and double-click the ZIP to unpack it. The folder is called `agent-island-main`; use that name in the next step.

**2. Build the app.** In Terminal:

```bash
cd agent-island
./scripts/bundle.sh release
```

This builds `build/AgentIsland.app`. If Terminal says `permission denied`, run `chmod +x scripts/*.sh` and try again.

**3. Move it to Applications and open it:**

```bash
mv build/AgentIsland.app /Applications/
open /Applications/AgentIsland.app
```

Moving it is optional, but do it before you add hooks: the hooks point at wherever the app is when you add them.

**4. Set it up.** The first launch opens the window on the **Hooks** page. Press **Add Hooks** for Claude Code (and Codex, if you use it). Then start a Claude Code session, and its circle appears by the notch. See [Using it](#using-it) and [Hooks](#hooks) for the rest.

Because you built it yourself, macOS opens it without a Gatekeeper warning.

### Updating

```bash
cd agent-island
git pull
./scripts/bundle.sh release
rm -rf /Applications/AgentIsland.app && mv build/AgentIsland.app /Applications/
open /Applications/AgentIsland.app
```

If you downloaded the ZIP, download a fresh one instead of `git pull`. After updating, turn Agent Island off and on again under **System Settings → Privacy & Security → Accessibility** if you use sending from the card (see [Known limits](#known-limits)). Restart any open Claude Code sessions to pick up changed hooks.

### Uninstalling

1. Press **Remove Hooks** on the Hooks page (or run `/Applications/AgentIsland.app/Contents/MacOS/AgentIsland --uninstall-hooks`). This removes only Agent Island's entries from `~/.claude/settings.json`.
2. Quit Agent Island from its menu bar menu and delete `/Applications/AgentIsland.app`.
3. Optionally delete `~/Library/Application Support/AgentIsland` and `~/Library/Caches/AgentIsland`.

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
  - Almost every entry runs `agent-island-hook claude` with `async: true`, so it never blocks a turn and never prints anything that could affect a permission decision.
  - The events covered are SessionStart, UserPromptSubmit, UserPromptExpansion, PreToolUse (for AskUserQuestion and ExitPlanMode only), PostToolUse, PostToolUseFailure, PermissionRequest, PermissionDenied, Notification, Stop, StopFailure, SessionEnd, PreCompact, and PostCompact.
  - Two entries run `agent-island-hook claude --reply` and wait, so the card can answer:
    - **PermissionRequest for AskUserQuestion and ExitPlanMode.** Claude Code shows its own dialog at the same moment, and the first answer wins. The helper prints a decision only when you answer on the card.
    - **Stop**, with `asyncRewake`. It waits in the background after each turn, so it never holds a turn up. A message typed on the card makes it exit with status 2, which is what wakes the session.
  - A waiting hook gives up within 2 seconds unless the app says it will answer. The app lets go at once of a `Stop` from a session the Claude registry doesn't list, so a headless `claude -p` run never waits. A waiting hook lasts a day at most.
  - When a new version adds entries or changes how one runs, it updates hooks it installed before, at launch. Hooks you never added, or that run another copy of the app, are left alone.
  - The original file is backed up to `settings.json.agent-island.bak` before anything changes. Installing twice changes nothing.
  - To remove them, use **Remove Hooks** or `AgentIsland --uninstall-hooks`. This removes only Agent Island's entries.
- **Codex.** Opt in from the Hooks page or the menu, which writes `~/.codex/hooks/hooks.json`. Codex may ask you to trust the new hooks the first time. Codex works without hooks because its rollout files already report every status. Hooks can still catch approval requests that aren't written to rollouts.

> **The hook command is an absolute path into the app bundle.** If you move or rename `AgentIsland.app`, the Hooks page says the hooks point at another copy of the app. Press **Repair** to point them here. Until then every hook silently runs a binary that is no longer there.

The helper sends each hook's input to the app over a Unix socket at `~/Library/Application Support/AgentIsland/island.sock`. It gives up after 300ms if the app is closed, so a closed app never slows an agent down. Only the two waiting entries ever print anything or exit with a status other than 0.

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
                                 # session and Codex thread through every status,
                                 # and the Claude one through /compact and /review
./scripts/simulate.sh ask        # leaves a question, then a plan, waiting for you
                                 # to answer on the card, and prints what Claude
                                 # would have received
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
- The app is signed ad hoc, so macOS treats each rebuild as a new app: after `./scripts/bundle.sh`, turn Agent Island off and on again under Accessibility for pasting to keep working.
