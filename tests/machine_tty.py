#!/usr/bin/env python3
"""Drive `noodle machine shell` through a real pty and report what the guest saw.

usage: machine_tty.py window NOODLE NAME      prints "rows cols" the guest sees after the window was set to 31x101
       machine_tty.py resize NOODLE NAME      resizes the window while the shell runs; prints the new size
       machine_tty.py signal NOODLE NAME      sends SIGTERM to the client; the guest traps it and exits 7
"""
import fcntl, os, pty, select, signal, struct, sys, termios, time

mode, noodle, name = sys.argv[1:4]
scripts = {
    "window": ["sh", "-c", "test -t 0 && stty size"],
    "resize": ["sh", "-c", "echo ready; sleep 2; stty size"],
    "signal": ["sh", "-c", "trap 'exit 7' TERM; echo ready; while :; do sleep 0.2; done"],
}
pid, fd = pty.fork()
if pid == 0:
    os.execv(noodle, [noodle, "machine", "shell", name, "--"] + scripts[mode])


def set_size(rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


set_size(31, 101)
buf = b""
deadline = time.time() + 60
acted = False
status = None
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try:
            data = os.read(fd, 4096)
        except OSError:
            data = b""
        if not data:
            break
        buf += data
    if not acted and b"ready" in buf:
        acted = True
        if mode == "resize":
            set_size(40, 120)
            os.kill(pid, signal.SIGWINCH)
        elif mode == "signal":
            os.kill(pid, signal.SIGTERM)
_, st = os.waitpid(pid, 0)
code = os.waitstatus_to_exitcode(st)
text = buf.decode(errors="replace").replace("\r", "").replace("ready\n", "").strip()
print(text)
print("exit", code)
