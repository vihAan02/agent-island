#!/bin/bash
# Walks a fake Claude session and a fake Codex thread through every status, and the
# Claude one through /compact and a /review, through the real hook helper, so the
# socket, the decoding, and the reducer run together.
#
#   scripts/simulate.sh [seconds per step]      (default 3)
#
# Start the app first:  ./scripts/bundle.sh && open build/AgentIsland.app
# Or check it headlessly:
#   build/AgentIsland.app/Contents/MacOS/AgentIsland --probe 45 &
#   sleep 2 && scripts/simulate.sh 2
#
# AGENT_ISLAND_HOOK=/path   use a different agent-island-hook binary
# AGENT_ISLAND_SOCKET=/path talk to a different socket (the helper reads this too)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
hook="${AGENT_ISLAND_HOOK:-$root/build/AgentIsland.app/Contents/MacOS/agent-island-hook}"
socket="${AGENT_ISLAND_SOCKET:-$HOME/Library/Application Support/AgentIsland/island.sock}"
step="${1:-3}"

if [[ ! -x "$hook" ]]; then
    echo "No hook helper at $hook. Build it with ./scripts/bundle.sh first." >&2
    exit 1
fi
if [[ ! -S "$socket" ]]; then
    echo "Nothing is listening at $socket. Is Agent Island running?" >&2
    exit 1
fi

run="$(date +%s)"
claude_id="sim-claude-$run"
codex_id="sim-codex-$run"

# send <agent> <json>
send() {
    # A Claude Code shell sets CLAUDE_EFFORT, and the helper forwards it. It would
    # stand in for the effort these payloads carry, so keep it out.
    printf '%s' "$2" | env -u CLAUDE_EFFORT "$hook" "$1"
}

# claude <event> [extra json fields] -- effort max, like a real Claude Code hook.
claude() {
    send claude "{\"hook_event_name\":\"$1\",\"session_id\":\"$claude_id\",\"cwd\":\"$root\",\"permission_mode\":\"default\",\"effort\":{\"level\":\"max\"}${2:+,$2}}"
}

# codex <event> [extra json fields] -- effort ultra, so the aurora shows.
codex() {
    send codex "{\"hook_event_name\":\"$1\",\"session_id\":\"$codex_id\",\"cwd\":\"$root\",\"effort\":{\"level\":\"ultra\"}${2:+,$2}}"
}

# say <agent> <status> <what>
say() {
    printf '%s  %-6s → %-9s %s\n' "$(date +%T)" "$1" "$2" "$3"
}

pause() { sleep "$(echo "$step * ${1:-1}" | bc)"; }

claude_walk() {
    say claude working "UserPromptSubmit, effort max"
    claude UserPromptSubmit '"prompt":"Fix the flaky test"'
    pause

    say claude question "PermissionRequest for Bash"
    claude PermissionRequest '"tool_name":"Bash","tool_input":{"command":"npm test -- --runInBand"}'
    pause

    say claude working "PostToolUse, approved"
    claude PostToolUse '"tool_name":"Bash","tool_input":{"command":"npm test -- --runInBand"}'
    pause

    say claude plan "PreToolUse for ExitPlanMode"
    claude PreToolUse '"tool_name":"ExitPlanMode","tool_input":{"plan":"1. Pin the clock\n2. Retry once"}'
    pause

    say claude error "PostToolUseFailure: a red flash, then working"
    claude PostToolUseFailure '"tool_name":"Edit","tool_input":{"file_path":"src/clock.ts"},"error":"old_string not found","is_interrupt":false'
    # The flash lasts 2.5s and the app checks every 0.5s; leave room to see it end.
    sleep 3.2
    pause

    say claude error "StopFailure"
    claude StopFailure '"error":"API Error: 529 overloaded"'
    pause

    say claude working "UserPromptSubmit"
    claude UserPromptSubmit '"prompt":"Try again"'
    pause 0.6

    say claude complete "Stop"
    claude Stop '"stop_hook_active":false'
    pause 1.5

    say claude spinner "PreCompact: /compact typed at the idle prompt"
    claude PreCompact '"trigger":"manual","custom_instructions":null'
    pause 1.5

    say claude complete "PostCompact"
    claude PostCompact '"trigger":"manual","compact_summary":"The user asked for a fix."'
    pause

    say claude spinner "UserPromptExpansion + UserPromptSubmit: /review"
    claude UserPromptExpansion '"expansion_type":"slash_command","command_name":"review","command_args":"","command_source":"builtin","prompt":"/review"'
    claude UserPromptSubmit '"prompt":"/review"'
    pause

    say claude question "PermissionRequest inside /review: the question shows"
    claude PermissionRequest '"tool_name":"Bash","tool_input":{"command":"git diff main"}'
    pause

    say claude spinner "PostToolUse: back to the spinner"
    claude PostToolUse '"tool_name":"Bash","tool_input":{"command":"git diff main"}'
    pause

    say claude complete "Stop: /review is done"
    claude Stop '"stop_hook_active":false'
    pause 1.5

    say claude gone "SessionEnd: the circle slides back in"
    claude SessionEnd '"reason":"prompt_input_exit"'
}

codex_walk() {
    sleep 0.8
    say codex working "UserPromptSubmit, effort ultra"
    codex UserPromptSubmit '"prompt":"Port the parser to Rust"'
    pause 2

    say codex question "PermissionRequest for shell"
    codex PermissionRequest '"tool_name":"shell","tool_input":{"command":"cargo test"}'
    pause 1.5

    say codex working "PostToolUse, approved"
    codex PostToolUse '"tool_name":"shell","tool_input":{"command":"cargo test"}'
    pause 2.5

    say codex complete "Stop"
    codex Stop
    pause 2.5

    say codex gone "SessionEnd: the circle slides back in"
    codex SessionEnd
}

echo "Simulating $claude_id and $codex_id, ${step}s per step"
claude_walk &
codex_walk &
wait
echo "Done."
