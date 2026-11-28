#!/usr/bin/env python3
"""Close a container terminal the way the app does, and report whether the guest shell survives.

usage: terminal_hangup.py DOCKER CONTAINER TOKEN SHELL_SCRIPT CLEANUP_SCRIPT
DOCKER_HOST comes from the environment. Prints one line: "<state>" where state is
  no-record      the shell never wrote its pid file
  not-running    the shell was not alive before the client died
  ended-early    the shell died with the client alone, so the fix has nothing to prove
  survived-cleanup  the shell outlived the killed client and the cleanup exec did not end it within 10 s
  ok             the shell outlived the killed client, then the cleanup exec ended it within 10 s
"""
import os, pty, signal, subprocess, sys, threading, time

docker, name, token, shell_script, cleanup_script = sys.argv[1:6]


def dexec(*cmd):
    return subprocess.run([docker, "exec", name, *cmd], capture_output=True, text=True, timeout=30)


pid, fd = pty.fork()
if pid == 0:
    os.execv(docker, [docker, "exec", "-it", name, "sh", "-c", shell_script, "sh", token])


def drain():
    # Read the terminal as the app's view does. On macOS a process that exits with unread pty output blocks in its
    # tty close, even after SIGKILL, so without this os.waitpid below never returns.
    try:
        while os.read(fd, 65536):
            pass
    except OSError:
        pass


threading.Thread(target=drain, daemon=True).start()

guest = None
for _ in range(80):
    r = dexec("sh", "-c", "cat /tmp/.noodle-term-$1", "sh", token)
    if r.returncode == 0 and r.stdout.strip().isdigit():
        guest = r.stdout.strip()
        break
    time.sleep(0.5)
if guest is None:
    print("no-record"); sys.exit(0)


def alive():
    return dexec("sh", "-c", "kill -0 $1 2>/dev/null && ! grep -q '^State:.*Z' /proc/$1/status 2>/dev/null", "sh", guest).returncode == 0


def top_has():
    out = subprocess.run([docker, "top", name, "-eo", "pid,args"], capture_output=True, text=True, timeout=30).stdout
    return any(line.split(None, 1)[:1] == [guest] for line in out.splitlines()[1:])


if not alive():
    print("not-running"); sys.exit(0)
os.kill(pid, signal.SIGKILL)  # the window closing: the local client dies, the guest shell is not told
os.waitpid(pid, 0)
time.sleep(2)
if not alive():
    print("ended-early"); sys.exit(0)  # the fix assumes killing the client alone leaves the shell behind
dexec("sh", "-c", cleanup_script, "sh", token)
deadline = time.time() + 10
while time.time() < deadline and (alive() or top_has()):
    time.sleep(0.3)
print("ok" if not alive() and not top_has() else "survived-cleanup")
