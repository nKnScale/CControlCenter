#!/usr/bin/env python3
"""Find this checkout's running dashboard home without contacting its database."""
import argparse
import os
import re
import subprocess
from pathlib import Path


def _procfs_candidates():
    """(argv, cwd, env) per process, read from Linux procfs."""
    for proc in Path('/proc').iterdir():
        if not proc.name.isdecimal():
            continue
        try:
            argv = [os.fsdecode(a) for a in proc.joinpath('cmdline').read_bytes().split(b'\0')]
            env = {os.fsdecode(k): os.fsdecode(v) for k, v in
                   (item.split(b'=', 1) for item in
                    proc.joinpath('environ').read_bytes().split(b'\0') if b'=' in item)}
            yield argv, proc.joinpath('cwd').resolve(), env
        except (FileNotFoundError, ProcessLookupError, PermissionError, ValueError):
            continue


def _ps_candidates():
    """The same triple on macOS/BSD, which has no procfs.

    Three separate queries because no single BSD command reports all of argv,
    cwd and the environment: `ps -o command=` gives argv, `lsof -d cwd` gives
    the working directory, and `ps eww` appends the environment. Only processes
    whose command mentions server.py are interrogated, so the expensive lsof
    call runs a handful of times rather than once per pid. A value containing a
    space is truncated by the env scan, which is acceptable here because the only
    variables read are HOME and AGENTMUX_HOME.
    """
    try:
        listing = subprocess.run(['ps', '-axww', '-o', 'pid=,command='],
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return
    for line in listing.splitlines():
        pid, _, command = line.strip().partition(' ')
        if not pid.isdecimal() or 'server.py' not in command:
            continue
        try:
            cwd_out = subprocess.run(['lsof', '-a', '-p', pid, '-d', 'cwd', '-Fn'],
                                     stdin=subprocess.DEVNULL, capture_output=True, text=True).stdout
            cwd = next((l[1:] for l in cwd_out.splitlines() if l.startswith('n')), None)
            if not cwd:
                continue
            env_out = subprocess.run(['ps', 'eww', '-p', pid, '-o', 'command='],
                                     stdin=subprocess.DEVNULL, capture_output=True, text=True).stdout
            env = {}
            for token in env_out.split():
                if re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', token):
                    key, _, value = token.partition('=')
                    env.setdefault(key, value)
            yield command.split(), Path(cwd).resolve(), env
        except OSError:
            continue


def server_home():
    script = Path(__file__).resolve().with_name('server.py')
    found = []
    candidates = _procfs_candidates() if Path('/proc').is_dir() else _ps_candidates()
    for argv, cwd, env in candidates:
        try:
            # The interpreter's argv[0] basename is 'python3' on Linux but
            # 'Python' inside a macOS framework build, so match case-insensitively.
            if len(argv) < 2 or not Path(argv[0]).name.lower().startswith('python'):
                continue
            candidate = Path(argv[1])
            if candidate.name != 'server.py':
                continue
            if (cwd / candidate).resolve() != script:
                continue
            home = env.get('AGENTMUX_HOME') or env.get('HOME', str(Path.home()))
            if not env.get('AGENTMUX_HOME'):
                home = str(Path(home) / '.agentmux')
            found.append(str((cwd / home).resolve()))
        except (FileNotFoundError, ProcessLookupError, OSError):
            continue
    # Resource probes can briefly fork before exec, retaining the server cmdline.
    # Duplicate processes with the same home are unambiguous; different homes are not.
    homes = set(found)
    if len(homes) > 1:
        raise RuntimeError(f'multiple dashboard homes; cannot safely restore: {sorted(homes)}')
    return next(iter(homes)) if homes else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fallback')
    parser.add_argument('--expect')
    args = parser.parse_args()
    try:
        home = server_home()
        if args.expect:
            if home != str(Path(args.expect).resolve()):
                raise RuntimeError('running dashboard is not using the requested home')
        elif home or args.fallback:
            print(home or str(Path(args.fallback).resolve()))
        else:
            raise RuntimeError('no dashboard process found')
    except (OSError, RuntimeError) as error:
        parser.exit(1, f'dashboard isolation: {error}\n')


if __name__ == '__main__':
    main()
