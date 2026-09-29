#!/usr/bin/env bash
# Offline: `send` must actually SUBMIT a long message to a TUI that assembles pastes slowly.
#   bash <(tr -d '\r' < dashboard/test_send_paste.sh)
#
# Why this exists. codex turns a large burst of text into a "[Pasted Content N chars]"
# placeholder, and an Enter that arrives while it is still assembling does nothing. The
# old confirm loop looked twice, 0.4s apart, and quit at the first look that showed no
# placeholder - which is exactly what a paste STILL BEING ASSEMBLED looks like. A 4506-char
# post sat unsent on tm-037-worker2 on 2026-09-29. The fake tmux below models that: the
# placeholder appears only after an assembly delay, and Enters before then are swallowed.
set -euo pipefail
python3 - <<'PY'
import os, pathlib, subprocess, tempfile, time
repo = pathlib.Path.cwd()
with tempfile.TemporaryDirectory(prefix='agentmux-send-') as td:
    root = pathlib.Path(td)
    harness = root / 'agentmux.sh'
    harness.write_text((repo / 'agentmux.sh').read_text())
    state = root / 'state'; state.mkdir()
    bindir = root / 'bin'; bindir.mkdir()
    (bindir / 'tmux').write_text(r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
args = sys.argv[3:]                      # drop "-L agentmux"
st = pathlib.Path(os.environ['FAKE_STATE']) / 'pane.json'
s = json.loads(st.read_text()) if st.exists() else {'pasted_at': None, 'submitted': False, 'enters': 0, 'scrollback': ''}
assembly = float(os.environ.get('FAKE_ASSEMBLY', '0'))
now = time.time()
def save(): st.write_text(json.dumps(s))
cmd = args[0] if args else ''
if cmd == 'has-session':
    sys.exit(0)
elif cmd in ('list-panes', 'display-message'):
    print('%1')
elif cmd == 'send-keys':
    keys = args[args.index('--') + 1:] if '--' in args else [a for a in args[1:] if not a.startswith('-') and a != '%1']
    if '-l' in args:
        s['pasted_at'] = now; s['submitted'] = False; s['text'] = keys[-1] if keys else ''
    elif keys and keys[-1] == 'Enter':
        s['enters'] += 1
        swallow = int(os.environ.get('FAKE_SWALLOW', '0'))
        # an Enter while the paste is still assembling is swallowed, and so are the
        # first FAKE_SWALLOW Enters after it (a composer that drops the keypress)
        if s['pasted_at'] is not None and now - s['pasted_at'] >= assembly:
            s['late'] = s.get('late', 0) + 1
            if s['late'] > swallow:
                s['submitted'] = True
    save()
elif cmd == 'capture-pane':
    lines = [s.get('scrollback', '')]
    if s['pasted_at'] is not None and not s['submitted'] and now - s['pasted_at'] < assembly:
        lines.append('› ' + s.get('text', '')[:60])          # still arriving
    elif s['pasted_at'] is not None and not s['submitted'] and os.environ.get('FAKE_SHOW_TAIL'):
        lines.append('  ' + s.get('text', '')[-60:])         # a wrapped composer shows the END
    elif s['pasted_at'] is not None and not s['submitted'] and os.environ.get('FAKE_NO_PLACEHOLDER'):
        lines.append('› ' + s.get('text', '')[:60])          # typed in full, sitting there
    elif s['pasted_at'] is not None and not s['submitted']:
        lines.append('› [Pasted Content 4506 chars]')
    else:
        lines.append('› Ask Codex to do anything')
    lines.append('  GPT · ~/repo')
    print('\n'.join(lines))
''')
    (bindir / 'tmux').chmod(0o755)
    env = dict(os.environ, AGENTMUX_HOME=str(root / 'home'), AGENTMUX_NO_COURIER='1',
               FAKE_STATE=str(state), PATH=str(bindir) + ':' + os.environ['PATH'],
               AGENTMUX_SEND_CONFIRM_INTERVAL='0.2')
    (root / 'home').mkdir()
    counter = 0
    def check(label):
        global counter
        counter += 1; print('ok', counter, label, flush=True)
    def pane():
        import json
        state_now = json.loads((state / 'pane.json').read_text())
        state_now.pop('text', None)          # keep failure output readable
        return state_now
    def reset(scrollback=''):
        import json
        (state / 'pane.json').write_text(json.dumps(
            {'pasted_at': None, 'submitted': False, 'enters': 0, 'scrollback': scrollback}))
    def send(text, **extra):
        return subprocess.run(['bash', str(harness), 'send', 'worker', text],
                              env=dict(env, **extra), text=True, capture_output=True, timeout=30)

    long = 'OMEN brief for TM-054: ' + 'x' * 4480
    # 1. the regression: assembly (1.2s) outlasts the old loop's first look (~0.65s)
    reset(); r = send(long, FAKE_ASSEMBLY='1.2')
    assert r.returncode == 0, r.stderr
    assert pane()['submitted'], ('long paste left unsent', pane())
    assert pane()['enters'] <= 4, pane()
    check('a slowly assembled long paste is still submitted')

    # 2. a fast TUI: submitted by the first Enter, no extra presses
    reset(); r = send(long, FAKE_ASSEMBLY='0')
    assert r.returncode == 0 and pane()['submitted'] and pane()['enters'] == 1, pane()
    check('an instant paste gets exactly one Enter')

    # 3. a placeholder left in SCROLLBACK does not trigger phantom Enters
    reset(scrollback='\n'.join(['› [Pasted Content 999 chars]'] + ['history line'] * 12))
    r = send(long, FAKE_ASSEMBLY='0')
    assert r.returncode == 0 and pane()['submitted'] and pane()['enters'] == 1, pane()
    check('an old placeholder in scrollback is ignored')

    # 4. bounded: a composer that never submits gets at most 1 + 3 Enters, then send returns
    reset(); r = send(long, FAKE_ASSEMBLY='999')
    assert r.returncode == 0, r.stderr
    assert pane()['enters'] <= 4, pane()
    check('a composer that never submits is not pressed forever')

    # 5. THE COURIER FAULT (2026-09-29, tm-037-worker2): the text is fully in the composer,
    #    no placeholder, and the first Enter was dropped. The loop read "text still visible"
    #    as "still assembling" and waited out its budget without pressing Enter again.
    reset(); r = send(long, FAKE_ASSEMBLY='0', FAKE_NO_PLACEHOLDER='1', FAKE_SWALLOW='1')
    assert r.returncode == 0, r.stderr
    assert pane()['submitted'], ('typed-but-unsubmitted message left in the composer', pane())
    assert pane()['enters'] <= 4, pane()
    check('a composer that dropped the Enter is pressed again')

    # 6. short text: one Enter, no confirm loop
    reset(); t0 = time.time(); r = send('short message', FAKE_ASSEMBLY='0')
    assert r.returncode == 0 and pane()['enters'] == 1 and time.time() - t0 < 5, pane()
    check('short text is sent once, without polling')
    # 7. CODEX, SHORT TEXT: the 512-char gate skipped the confirm loop, and a short pointer
    #    message to tm-037-worker2 sat unsent twice on 2026-09-29 because codex dropped
    #    the Enter. A codex agent is confirmed at any length.
    rundir = root / 'home' / 'run'; rundir.mkdir(parents=True, exist_ok=True)
    (rundir / 'worker.cli').write_text('codex\n')
    reset(); r = send('read ~/.agentmux/dispatch/brief.md and do it',
                      FAKE_ASSEMBLY='0', FAKE_NO_PLACEHOLDER='1', FAKE_SWALLOW='1')
    assert r.returncode == 0, r.stderr
    assert pane()['submitted'], ('short message to codex left unsent', pane())
    assert pane()['enters'] <= 4, pane()
    check('a short message to codex is confirmed too')
    (rundir / 'worker.cli').unlink()
    # 8. THE rev-041 FAULT: a long brief wraps, the composer's bottom lines show only its
    #    END, the lead check never matched, so "not visible" read as "submitted".
    reset(); r = send(long + ' then run.py verdict 94864d/1.', FAKE_ASSEMBLY='0',
                      FAKE_SHOW_TAIL='1', FAKE_SWALLOW='1')
    assert r.returncode == 0, r.stderr
    assert pane()['submitted'], ('wrapped long message left unsent', pane())
    assert pane()['enters'] <= 4, pane()
    check('a wrapped message showing only its tail is still confirmed')
    print(f'passed {counter}, failed 0')
PY
