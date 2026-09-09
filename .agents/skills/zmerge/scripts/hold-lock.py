#!/usr/bin/env python3
"""Hold an exclusive flock until the parent shell exits.

argv[1] = lock file, argv[2] = status file (written after the flock attempt).
Exit 2 if the lock is already held. Status is "ok", "busy", or "fail".
"""
import errno
import fcntl
import os
import sys
import time


def write_status(path: str, text: str) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="ascii") as fh:
        fh.write(text)
    os.replace(tmp, path)


def main() -> int:
    if len(sys.argv) != 3:
        return 1
    lock_path, status_path = sys.argv[1], sys.argv[2]
    watch_pid = os.getppid()
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        if exc.errno in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
            write_status(status_path, "busy")
            return 2
        write_status(status_path, "fail")
        return 1
    write_status(status_path, "ok")
    while True:
        try:
            os.kill(watch_pid, 0)
        except OSError:
            break
        time.sleep(0.15)
    return 0


if __name__ == "__main__":
    sys.exit(main())
