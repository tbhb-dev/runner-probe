#!/usr/bin/env python3
"""Probe the Landlock ABI: landlock_create_ruleset(NULL, 0, VERSION flag).

Usage: landlock.py OUT_DIR. Exits non-zero when Landlock is unavailable.
"""
import ctypes
import os
import platform
import subprocess
import sys

out_dir = sys.argv[1]
# Syscall 444 is landlock_create_ruleset on x86_64 and aarch64 (unified table).
SYS_LANDLOCK_CREATE_RULESET = 444
LANDLOCK_CREATE_RULESET_VERSION = 1

libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long
ret = libc.syscall(
    ctypes.c_long(SYS_LANDLOCK_CREATE_RULESET),
    ctypes.c_void_p(None),
    ctypes.c_size_t(0),
    ctypes.c_uint(LANDLOCK_CREATE_RULESET_VERSION),
)
err = ctypes.get_errno() if ret < 0 else 0
try:
    lsm = open("/sys/kernel/security/lsm", encoding="utf-8").read().strip()
except OSError:
    lsm = "unreadable"

record = os.path.join(os.path.dirname(os.path.abspath(__file__)), "record.py")
subprocess.run(
    [
        sys.executable, record, out_dir, "landlock",
        f"machine={platform.machine()}",
        f"abi={ret if ret >= 0 else -1}",
        f"errno={err}",
        f"errno_name={os.strerror(err) if err else ''}",
        f"lsm_list={lsm}",
    ],
    check=True,
)
sys.exit(0 if ret >= 1 else 1)
