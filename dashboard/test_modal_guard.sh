#!/usr/bin/env bash
# Verify the `send` modal guard against real captured pane text.
#   bash <(tr -d '\r' < dashboard/test_modal_guard.sh)
#
# No tmux, no CLI, no network: agentmux.sh's modal_text takes the text directly, so
# every sample below is a literal capture rather than a live agent.
#
# WHY THIS SUITE EXISTS. `send` types text and then presses Enter. If the pane is
# showing a selection dialog, that Enter actuates whatever is highlighted instead of
# talking to the agent. It has gone wrong twice, both times destructively:
#
#   2026-09-20  a codex "Update available / Press enter to continue" prompt took the
#               Enter, chose "Update now", and npm install killed the pane mid-session
#   2026-09-22  a claude "No, exit / Yes, I accept" consent dialog took the Enter,
#               chose the DEFAULT of "No, exit", and the agent exited
#
# The second one is why the false-negative half matters more than the false-positive
# half: a missed modal destroys an agent, while an over-eager guard merely asks the
# operator to use `key`. Both are checked, because a guard that fires on an ordinary
# prompt would make `send` useless and get switched off.
set -u
[ -f agentmux.sh ] || { echo 'run this from the agentmux repo root' >&2; exit 2; }

GUARD="$(mktemp)"
trap 'rm -f "$GUARD"' EXIT
tr -d '\r' < agentmux.sh > "$GUARD"
# Pull in just the function; the script's dispatch runs on source otherwise.
eval "$(sed -n '/^modal_text() {/,/^}/p' "$GUARD")"
eval "$(sed -n '/^modal_answer() {/,/^}/p' "$GUARD")"
eval "$(sed -n '/^modal_decision() {/,/^}/p' "$GUARD")"

# shellcheck source=/dev/null
. dashboard/testlib.sh          # ok/bad/check/check_rc/rc_is/count_msgs, one copy

modal() {   # modal <label> <text...>  - MUST be detected
  if modal_text "$2"; then
    printf '  ok    %-56s detected\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL  %-56s MISSED - send would actuate this\n' "$1"; fail=$((fail + 1))
  fi
}

normal() {  # normal <label> <text...> - must NOT be detected
  if modal_text "$2"; then
    printf '  FAIL  %-56s false positive - send would refuse\n' "$1"; fail=$((fail + 1))
  else
    printf '  ok    %-56s not a modal\n' "$1"; pass=$((pass + 1))
  fi
}

echo '--- the two that actually cost an agent ---'
modal 'codex update prompt (2026-09-20)' '  Update available
  1. Update now (runs npm install)
  Press enter to continue'
modal 'claude bypass consent (2026-09-22)' '  By proceeding, you accept all responsibility.
  ❯ No, exit
    Yes, I accept
  Enter to confirm · Esc to cancel'

echo '--- the two that slipped through when gemini was added (2026-09-23) ---'
# Both are literal captures of the last eight non-blank lines, which is the slice
# modal_prompt actually inspects. Neither contains a question or a selector
# marker - the dialog's own controls are above the window - which is exactly why
# `send` typed into them and advanced the dialog.
modal 'claude theme picker' '   7. Light mode (ANSI colors only)
  1  function greet() {
  2 -  console.log("Hello, World!");
  2 +  console.log("Hello, Claude!");
  3  }
  Syntax theme: Monokai Extended (ctrl+t to disable)'
modal 'gemini terms screen' '│   (Use Enter to select)
│   Terms of Services and Privacy Notice for Gemini CLI
│   https://geminicli.com/docs/resources/tos-privacy/'
modal 'gemini radio confirm'    '│  Do you want to continue?
│  ● 1. Yes
│    2. No
│  Enter to select · ↑/↓ to navigate · Esc to cancel'

echo '--- claude startup dialogs ---'
modal 'folder trust'            '  Do you trust the files in this folder?
  ❯ No, exit
    Yes, I trust this folder'
modal 'workspace safety check'  '  Quick safety check: Is this a project you created or one you trust?
  ❯ No, exit
    Yes, I accept'
modal 'opus effort recommendation' ' We recommend Opus 5 at medium effort
   ❯ Switch Opus 5 to medium effort
     Keep high'
modal 'bare confirm footer'     '  Enter to confirm · Esc to cancel'

echo '--- codex / grok dialogs ---'
modal 'codex directory trust'   '  Do you trust the contents of this directory?
  › 1. Yes, continue
    2. No, quit'
modal 'numbered selection'      '  ❯ 1. Claude account with subscription
    2. Anthropic Console account'
modal 'y/n inline'              '  Overwrite the file? [y/n]'
modal 'parenthesised y/n'       '  Continue (y/N)'

# The new alternatives are TUI chrome, not prose. Prove they do not fire on an
# agent that merely writes about the same subjects.
normal 'prose about a theme'    '  I updated the syntax theme handling in style.css
  and the chip colours now follow the token set.'
normal 'prose about terms'      '  The terms of service link in the footer is stale;
  I replaced it with the current URL.'
normal 'prose about a selector'  '  The picker needs Enter to choose an entry, so the
  courier has to use key rather than send.'
modal 'press any key'           '  Press any key to continue'
modal 'select an option'        '  Select an option to continue'
modal 'login menu'              '  ❯ Sign in with your account'

echo '--- ordinary panes: the guard must stay quiet ---'
normal 'claude idle prompt'     '❯
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents'
normal 'claude placeholder'     '❯ Try "how does <filepath> work?"
  ⏵⏵ auto mode on (shift+tab to cycle)'
normal 'codex idle prompt'      '› Ask Codex to do anything

  gpt-6-astra default · /mnt/c/Dev/agentmux'
normal 'grok idle prompt'       '  │ ❯                                   │
  Grok 4.7 (high) · always-approve'
normal 'bash prompt'            'nick@MEP31337:/tmp$'
normal 'a finished answer'      '❯ What is 6 times 7? Reply with only the number.
● 42
✻ Cogitated for 2s · done 2:40 PM'
normal 'prose mentioning exit'  '● The function will exit when the last agent is killed.'
normal 'shell output'           'total 20
drwxr-xr-x 2 nick nick 4096 Sep 22 09:38 .'
normal 'a diff'                 '+  if not logged in:
-      continue'

echo '--- unblock: what may be answered, and what may NOT ---'
# `send` refusing is only half an answer: nothing ANSWERS, so a pane parked on a
# first-run dialog waits for a human. `unblock` closes that - but only for prompts it
# can positively identify, and only with the option that declines or keeps the current
# state. The defaults here are hostile, which is the whole reason there is no generic
# "press Enter": codex preselects "Update now (runs npm install -g)" and claude
# preselects "No, exit", which kills the agent.

answers() {   # answers <label> <expected-keys> <text>
  local got
  if got="$(modal_answer "$3")"; then
    if [ "${got%%|*}" = "$2" ]; then
      printf '  ok    %-56s answers %s\n' "$1" "$2"; pass=$((pass + 1))
    else
      printf '  FAIL  %-56s pressed %s, wanted %s\n' "$1" "${got%%|*}" "$2"; fail=$((fail + 1))
    fi
  else
    printf '  FAIL  %-56s no answer offered\n' "$1"; fail=$((fail + 1))
  fi
}

leaves() {    # leaves <label> <text>  - must be left for a person
  if modal_answer "$2" >/dev/null; then
    printf '  FAIL  %-56s ANSWERED - this is a decision\n' "$1"; fail=$((fail + 1))
  else
    printf '  ok    %-56s left for a person\n' "$1"; pass=$((pass + 1))
  fi
}

names() {     # names <label> <needle> <text> - the refusal says WHAT the decision is
  local why
  if why="$(modal_decision "$3")" && printf '%s' "$why" | grep -qiF -- "$2"; then
    printf '  ok    %-56s named: %s\n' "$1" "$why"; pass=$((pass + 1))
  else
    printf '  FAIL  %-56s not named (%s)\n' "$1" "${why:-no classification}"; fail=$((fail + 1))
  fi
}

answers 'the codex update nag is a nuisance, not a decision' 2 '  Update available
  1. Update now (runs npm install)
  Press enter to continue'

# EVERY ONE OF THESE MUST BE LEFT ALONE. A harness that clicks through a trust
# dialog, a consent dialog or an account chooser has removed the point of the guard.
leaves 'folder trust'            '  Do you trust the files in this folder?
  ❯ No, exit
    Yes, I trust this folder'
leaves 'claude bypass consent'   '  By proceeding, you accept all responsibility.
  ❯ No, exit
    Yes, I accept'
leaves 'codex directory trust'   '  Do you trust the contents of this directory?
  › 1. Yes, continue
    2. No, quit'
leaves 'account chooser'         '  ❯ 1. Claude account with subscription
    2. Anthropic Console account'
leaves 'a destructive y/n'       '  Overwrite the file? [y/n]'
leaves 'an unrecognised prompt'  '  Frobnicate the widget? [a/b/c]'

names 'trust is named as a trust decision' 'trust' '  Do you trust the files in this folder?
  ❯ No, exit'
names 'consent is named, and so is its lethal default' 'No, exit' \
  '  By proceeding, you accept all responsibility.
  ❯ No, exit
    Yes, I accept'
names 'an account chooser is named' 'account' '  ❯ 1. Claude account with subscription
    2. Anthropic Console account'

echo '--- standing consent: the operator decides once, per kind ---'
# The decisions above stay decisions. What an operator may do is make one ONCE, for a
# kind they always answer the same way, and have it recorded. Pinned here: which
# prompts are consent-able, that nothing is answered without a grant, and that a bad
# grant file answers nothing at all.
eval "$(sed -n '/^file_mode() {/,/}$/p' "$GUARD" | head -1)"
eval "$(sed -n '/^consent_kind() {/,/^}/p' "$GUARD")"
eval "$(sed -n '/^consent_keys() {/,/^}/p' "$GUARD")"
eval "$(sed -n '/^consent_granted() {/,/^}/p' "$GUARD")"
eval "$(sed -n '/^consent_answer() {/,/^}/p' "$GUARD")"
CONSENT_KINDS="$(sed -n 's/^CONSENT_KINDS="\(.*\)"$/\1/p' "$GUARD")"
CTMP="$(mktemp -d)"; trap 'rm -f "$GUARD"; rm -rf "$CTMP"' EXIT
CONSENT_FILE_DEFAULT="$CTMP/none.json"
BYPASS='  WARNING: Claude Code running in Bypass Permissions mode
  By proceeding, you accept all responsibility for actions taken while running in Bypass Permissions mode.
  ❯ No, exit
    Yes, I accept
  Enter to confirm · Esc to cancel'
CTRUST='  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings.
› 1. Trust and continue
  2. Back to Agent Command Center
  enter continue · esc back'
GTRUST='                                          Do you trust the contents of this directory?
                                       /Users/someone/dayJob/omen-integration-mock
                                    Grok Build may run or modify contents in this directory,
                                                     posing security risks.
                                                 Yes, proceed                 y
                                                 No, quit                     n'
grant_file() {  # grant_file <path> <mode> <kind...>
  local path="$1" mode="$2"; shift 2
  python3 - "$path" "$@" <<'PY'
import json, sys
json.dump({'grants': {k: {'by': 'test', 'at': 'now'} for k in sys.argv[2:]}}, open(sys.argv[1], 'w'))
PY
  chmod "$mode" "$path"
}
consent_is() {  # consent_is <label> <expected-keys|NONE> <text> <file>
  local got
  if got="$(consent_answer "$3" "$4")"; then got="${got%%|*}"; else got=NONE; fi
  if [ "$got" = "$2" ]; then printf '  ok    %-56s %s\n' "$1" "$2"; pass=$((pass + 1))
  else printf '  FAIL  %-56s got %s, wanted %s\n' "$1" "$got" "$2"; fail=$((fail + 1)); fi
}
[ "$(consent_kind "$BYPASS")" = claude-bypass ] && { printf '  ok    %-56s\n' 'claude bypass warning is a consent kind'; pass=$((pass + 1)); } \
  || { printf '  FAIL  claude bypass warning not recognised\n'; fail=$((fail + 1)); }
[ "$(consent_kind "$CTRUST")" = codex-folder-trust ] && { printf '  ok    %-56s\n' 'codex folder trust is a consent kind'; pass=$((pass + 1)); } \
  || { printf '  FAIL  codex folder trust not recognised\n'; fail=$((fail + 1)); }
if consent_kind '  ❯ 1. Claude account with subscription
    2. Anthropic Console account' >/dev/null || consent_kind '  Overwrite the file? [y/n]' >/dev/null; then
  printf '  FAIL  an account chooser or y/n became consent-able\n'; fail=$((fail + 1))
else printf '  ok    %-56s\n' 'account choice and y/n are never consent-able'; pass=$((pass + 1)); fi

consent_is 'no grant file: bypass is left for a person'     NONE         "$BYPASS" "$CTMP/none.json"
grant_file "$CTMP/ok.json" 600 claude-bypass
consent_is 'granted: bypass moves off "No, exit", confirms'  'Down Enter' "$BYPASS" "$CTMP/ok.json"
consent_is 'granting bypass does not grant folder trust'     NONE         "$CTRUST" "$CTMP/ok.json"
grant_file "$CTMP/both.json" 600 claude-bypass codex-folder-trust
consent_is 'granted: codex trust presses 1'                  1            "$CTRUST" "$CTMP/both.json"
consent_is 'grok trust is not granted by the codex grant'    NONE         "$GTRUST" "$CTMP/both.json"
grant_file "$CTMP/grok.json" 600 grok-folder-trust
consent_is 'granted: grok trust presses y'                   y            "$GTRUST" "$CTMP/grok.json"
grant_file "$CTMP/loose.json" 644 claude-bypass
consent_is 'a group/world-readable grant file is ignored'    NONE         "$BYPASS" "$CTMP/loose.json"
ln -s "$CTMP/ok.json" "$CTMP/link.json"
consent_is 'a symlinked grant file is ignored'               NONE         "$BYPASS" "$CTMP/link.json"
printf '{not json' > "$CTMP/bad.json"; chmod 600 "$CTMP/bad.json"
consent_is 'an unparseable grant file is ignored'            NONE         "$BYPASS" "$CTMP/bad.json"
consent_is 'the built-in guard is unchanged by consent'      NONE         '  Do you trust the files in this folder?
  ❯ No, exit
    Yes, I trust this folder' "$CTMP/both.json"

# Only a person at a terminal grants: refused in a pane, refused with no TTY.
out="$(AGENTMUX_HOME="$CTMP/h" AGENTMUX_AGENT=someone bash "$GUARD" consent grant claude-bypass </dev/null 2>&1)"
case "$out" in *"inside an agent pane"*) printf '  ok    %-56s\n' 'grant refused inside an agent pane'; pass=$((pass + 1)) ;;
  *) printf '  FAIL  grant inside a pane was not refused: %s\n' "$out"; fail=$((fail + 1)) ;; esac
out="$(env -u AGENTMUX_AGENT AGENTMUX_HOME="$CTMP/h" bash "$GUARD" consent grant claude-bypass </dev/null 2>&1)"
case "$out" in *"interactive terminal"*) printf '  ok    %-56s\n' 'grant refused without a terminal'; pass=$((pass + 1)) ;;
  *) printf '  FAIL  grant without a TTY was not refused: %s\n' "$out"; fail=$((fail + 1)) ;; esac
[ ! -e "$CTMP/h/consent.json" ] && { printf '  ok    %-56s\n' 'a refused grant writes nothing'; pass=$((pass + 1)); } \
  || { printf '  FAIL  a refused grant wrote consent.json\n'; fail=$((fail + 1)); }

finish
[ "$fail" -eq 0 ] || exit 1
