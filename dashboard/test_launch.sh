#!/usr/bin/env bash
# Offline spawn integration tests: isolated state, fake tmux/providers, no model calls.
set -euo pipefail
python3 - <<'PY'
import json, os, pathlib, subprocess, tempfile, concurrent.futures
repo = pathlib.Path.cwd()
with tempfile.TemporaryDirectory(prefix='agentmux-launch-') as td:
    root = pathlib.Path(td)
    harness = root / 'agentmux.sh'
    harness.write_text((repo / 'agentmux.sh').read_text())
    bindir = root / 'bin'; bindir.mkdir()
    state = root / 'state'; state.mkdir()
    src = root / 'claude-source'; src.mkdir()
    (src / 'settings.json').write_text(json.dumps({'hooks': {'bad': True}, 'statusLine': {},
        'permissions': {'defaultMode': 'bypassPermissions', 'allow': ['Bash', 'Write'],
                        'additionalDirectories': ['/']}}))
    (src / 'CLAUDE.md').write_text('shared instructions')
    (src / 'history.jsonl').write_text('private history')
    tmux = bindir / 'tmux'
    tmux.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[3:]
root = pathlib.Path(os.environ['FAKE_STATE'])
cmd = args[0]
def target():
    return args[args.index('-t')+1].lstrip('=')
if cmd == 'has-session':
    sys.exit(0 if (root / target()).exists() else 1)
elif cmd == 'new-session':
    name = args[args.index('-s')+1]
    (root / name).write_text(args[-1])
elif cmd == 'list-panes':
    print('%1')
elif cmd == 'display-message':
    print('0')
''')
    tmux.chmod(0o755)
    for name, body in [('sleep', 'exit 0'), ('claude', 'echo "--restricted --strict-mcp-config"')]:
        path = bindir / name; path.write_text('#!/bin/sh\n' + body + '\n'); path.chmod(0o755)
    env = dict(os.environ, AGENTMUX_HOME=str(root / 'home'), AGENTMUX_NO_COURIER='1',
               CLAUDE_CONFIG_DIR=str(src), FAKE_STATE=str(state), PATH=str(bindir)+':'+os.environ['PATH'])
    env.pop('AGENTMUX_NO_BYPASS', None)
    counter = 0
    def run(name, *args, extra=None, success=True, error=None):
        result = subprocess.run(['bash', str(harness), 'spawn', name, '--cwd', str(root), *args],
            env=dict(env, **(extra or {})), text=True, capture_output=True, timeout=15)
        assert (result.returncode == 0) == success, (args, result.returncode, result.stdout, result.stderr)
        if error: assert error in result.stderr, result.stderr
        if not success: assert not (state / name).exists(), 'failed spawn created a session'
        return result
    def check(label):
        global counter
        counter += 1; print('ok', counter, label, flush=True)
    for flag in ('--agentdef', '--posture', '--persona-file', '--tools', '--deny-tools', '--team', '--role', '--task'):
        run('missing', flag, success=False, error='needs a value')
    run('unknown', '--postuer', 'read-only', success=False, error='unknown option')
    for flag, value in [('--agentdef', '../escape'), ('--agentdef', 'x\nforged'),
        ('--posture', 'yolo'), ('--team', 'TM-1\rforged'), ('--role', 'admin'), ('--team', 'TM-'+'1'*509),
        ('--tools', 'Read,$(touch pwned)'), ('--deny-tools', 'Read,,Write')]:
        run('bad', flag, value, success=False, error='invalid')
    check('missing, unknown, and malformed flags fail before tmux')
    for cli in ('codex', 'claude'):
        for posture in ('unrestricted', 'workspace-write', 'read-only'):
            name = cli + '-' + posture
            run(name, '--cli', cli, '--posture', posture)
            command = (state / name).read_text()
            assert (root / 'home/run' / (name+'.posture')).read_text() == posture+'\n'
            assert (root / 'home/run' / (name+'.perms')).read_text() == ('UNRESTRICTED\n' if posture == 'unrestricted' else 'sandboxed\n')
            if cli == 'codex':
                assert ('--dangerously-bypass-approvals-and-sandbox' if posture == 'unrestricted'
                    else '--sandbox '+posture+' --ask-for-approval never') in command
            else:
                cfg = json.loads((root / 'home/claude-config' / name / 'settings.json').read_text())
                assert cfg['permissions']['defaultMode'] == {'unrestricted':'bypassPermissions',
                    'workspace-write':'acceptEdits', 'read-only':'default'}[posture]
                assert 'hooks' not in cfg and not cfg['permissions']['allow']
                assert not (root / 'home/claude-config' / name / 'history.jsonl').exists()
                if posture != 'unrestricted':
                    assert '--restricted' in command and '--strict-mcp-config' in command
                    assert 'Bash' in cfg['permissions']['deny'] and 'Agent' in cfg['permissions']['deny']
                if posture == 'read-only':
                    assert {'Write','Edit'}.issubset(cfg['permissions']['deny'])
                    assert "--tools 'Read,Grep,Glob'" in command
    check('Codex/Claude posture matrix, denies, isolated settings and permission sidecars')
    for cli in ('codex', 'claude'):
        result = run(cli+'-clamp', '--cli', cli, '--posture', 'unrestricted', extra={'AGENTMUX_NO_BYPASS':'1'})
        assert 'clamps unrestricted to workspace-write' in result.stderr
        run(cli+'-ro-brake', '--cli', cli, '--posture', 'read-only', extra={'AGENTMUX_NO_BYPASS':'1'})
        assert (root / 'home/run' / (cli+'-ro-brake.posture')).read_text() == 'read-only\n'
    check('machine ceiling logs clamp and preserves read-only')
    run('grok-unrestricted', '--cli', 'grok')
    for posture in ('read-only', 'workspace-write'):
        run('grok-'+posture, '--cli', 'grok', '--posture', posture, success=False, error='cannot enforce')
    run('grok-clamp', '--cli', 'grok', extra={'AGENTMUX_NO_BYPASS':'1'}, success=False, error='cannot enforce')
    run('shell-posture', '--cli', 'shell', '--posture', 'read-only', success=False, error='cannot enforce')
    check('unverified Grok/custom postures fail closed, including machine clamp')
    persona = root / 'persona secret.txt'; persona.write_text('PRIVATE PERSONA $(touch SHOULD_NOT_EXIST)\nsecond line\n')
    run('metadata', '--agentdef', 'reviewer', '--posture', 'unrestricted', '--team', 'TM-042',
        '--role', 'reviewer', '--persona-file', str(persona), '--tools', 'Read,Grep', '--deny-tools', 'Write')
    for field, expected in [('agentdef','reviewer'), ('posture','unrestricted'), ('team','TM-042'), ('role','reviewer')]:
        raw = (root / 'home/run' / ('metadata.'+field)).read_bytes()
        assert raw == expected.encode()+b'\n' and len(raw) <= 512
        assert all(32 <= c < 127 for c in raw[:-1])
    copied = root / 'home/run/metadata.persona'
    assert copied.stat().st_mode & 0o777 == 0o600
    assert copied.read_text().startswith(persona.read_text()) and '[degraded:' in copied.read_text()
    assert 'PRIVATE PERSONA' not in (state / 'metadata').read_text()
    assert not (root / 'SHOULD_NOT_EXIST').exists()
    check('four bounded one-line sidecars; private persona copy; degraded tool prose; no command interpolation')
    run('unsafe-tools', '--cli', 'claude', '--posture', 'read-only', '--tools', 'Bash', success=False, error='cannot be enabled')
    run('allow-tools', '--cli', 'claude', '--posture', 'read-only', '--tools', 'Read', '--deny-tools', 'Grep')
    assert "--tools 'Read'" in (state / 'allow-tools').read_text()
    assert 'Grep' in json.loads((root/'home/claude-config/allow-tools/settings.json').read_text())['permissions']['deny']
    check('Claude named tool restrictions cannot reopen bounded tools')
    stale = root / 'home/claude-config/stale'; stale.mkdir(); (stale/'settings.json').write_text('{}')
    with concurrent.futures.ThreadPoolExecutor() as pool:
        futures = [pool.submit(run, 'parallel-'+posture, '--cli', 'claude', '--posture', posture)
                   for posture in ('read-only', 'unrestricted')]
        for future in futures: future.result()
    assert not stale.exists()
    for posture in ('read-only', 'unrestricted'):
        assert (root / 'home/claude-config' / ('parallel-'+posture) / 'settings.json').exists()
    check('concurrent different-posture spawns retain separate configs; GC prunes only dead agents')
    # Corrupt the actual published file between generation and readback. The
    # prove-it gate must catch this, rather than checking the intended object.
    mv = bindir / 'mv'
    mv.write_text('''#!/bin/bash
/bin/mv "$@" || exit
last="${@: -1}"
case "$last" in */settings.json) printf '%s\\n' '{"permissions":{"defaultMode":"default","deny":[]}}' > "$last" ;; esac
'''); mv.chmod(0o755)
    run('corrupt', '--cli', 'claude', '--posture', 'read-only', success=False, error='could not prove')
    mv.unlink()
    (src/'settings.json').write_text('{invalid')
    run('broken-source', '--cli', 'claude', '--posture', 'unrestricted', success=False, error='could not prove')
    check('published-settings corruption and broken source fail the spawn without permissive fallback')

    # A new agent must open at a prompt: onboarding done, theme set, its cwd trusted -
    # and nothing else copied out of the operator's ~/.claude.json.
    (src/'settings.json').write_text('{}')
    operator_home = root / 'operator-home'; operator_home.mkdir()
    (operator_home / '.claude.json').write_text(json.dumps({
        'hasCompletedOnboarding': True, 'theme': 'light', 'lastOnboardingVersion': '9.9.9',
        'oauthAccount': {'emailAddress': 'operator@example.com'}, 'userID': 'operator-id',
        'mcpServers': {'secret': {'command': 'x'}}}))
    run('seeded', '--cli', 'claude', '--posture', 'read-only', extra={'HOME': str(operator_home)})
    seeded = json.loads((root/'home'/'claude-config'/'seeded'/'.claude.json').read_text())
    assert seeded['hasCompletedOnboarding'] is True and seeded['theme'] == 'light', seeded
    assert seeded['projects'][os.path.realpath(root)]['hasTrustDialogAccepted'] is True, seeded
    for leaked in ('oauthAccount', 'userID', 'mcpServers'):
        assert leaked not in seeded, leaked
    assert oct((root/'home'/'claude-config'/'seeded'/'.claude.json').stat().st_mode & 0o777) == '0o600'
    # no operator theme -> a fixed default, still past the picker
    (operator_home / '.claude.json').write_text(json.dumps({'hasCompletedOnboarding': True}))
    run('defaulted', '--cli', 'claude', '--posture', 'read-only', extra={'HOME': str(operator_home)})
    assert json.loads((root/'home'/'claude-config'/'defaulted'/'.claude.json').read_text())['theme'] == 'dark'
    # a .claude.json inside the source config dir is never linked into the mirror,
    # so seeding can never write through to the operator's file
    (src/'.claude.json').write_text(json.dumps({'oauthAccount': {'emailAddress': 'operator@example.com'}}))
    run('unlinked', '--cli', 'claude', '--posture', 'read-only', extra={'HOME': str(operator_home)})
    agent_state = root/'home'/'claude-config'/'unlinked'/'.claude.json'
    assert not agent_state.is_symlink() and 'oauthAccount' not in json.loads(agent_state.read_text())
    assert json.loads((src/'.claude.json').read_text()) == {'oauthAccount': {'emailAddress': 'operator@example.com'}}
    (src/'.claude.json').unlink()
    check('claude agents start past onboarding and trust, copy no operator identity, never link operator state')

    codex = bindir / 'codex'; codex.write_text('#!/bin/sh\nexit 0\n'); codex.chmod(0o755)
    run('codexlaunch', '--cli', 'codex', '--posture', 'read-only')
    launch = (state/'codexlaunch').read_text()
    assert 'check_for_update_on_startup=false' in launch, launch
    assert os.path.realpath(root) in launch and 'trust_level' in launch, launch
    check('codex agents skip the update prompt and trust only their own cwd, per launch')
    print(f'passed {counter}, failed 0')
PY
