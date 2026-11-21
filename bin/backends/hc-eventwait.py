#!/usr/bin/env python3
"""Project a bounded, home-filtered hc events stream for the transition policy."""

import json
import os
import selectors
import signal
import subprocess
import sys
import time


def clean(value):
    return str(value or "").replace("\t", " ").replace("\r", " ").replace("\n", " ")


def main(argv):
    if len(argv) < 7:
        return 2
    binary, session, socket_path, duration, home = argv[1:6]
    try:
        duration = float(duration)
    except ValueError:
        return 2
    if not 0 < duration < float("inf"):
        return 2
    wanted = set(argv[6:])
    env = os.environ.copy()
    for name in ("HC_TERMINAL_ID", "HC_TERMINAL_SOCKET", "HC_SCOPE", "HC_SOCKET"):
        env.pop(name, None)
    env["HC_SESSION"] = session
    if socket_path:
        env["HC_SOCKET"] = socket_path
    try:
        proc = subprocess.Popen(
            [binary, "events", "--json", "--label", "firstmate.home=" + home],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env,
        )
    except OSError:
        return 2

    def stop(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + duration
    buffer = b""
    subscribed = False
    known = set()

    def emit(address, status):
        if address not in wanted or not isinstance(status, dict):
            return
        state = status.get("state")
        if isinstance(state, str):
            print("\t".join((clean(address), clean(state), clean(status.get("app")))), flush=True)

    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return 0 if subscribed else 2
            if not selector.select(remaining):
                return 0 if subscribed else 2
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                return 2
            buffer += chunk
            if len(buffer) > 16 * 1024 * 1024:
                return 2
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    msg = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    return 2
                if not isinstance(msg, dict):
                    return 2
                if not subscribed:
                    terminals = msg.get("terminals")
                    if not isinstance(msg.get("seq"), int) or not isinstance(terminals, list):
                        return 2
                    print("@subscribed", flush=True)
                    subscribed = True
                    for terminal in terminals:
                        if not isinstance(terminal, dict) or not isinstance(terminal.get("labels"), dict):
                            return 2
                        address = terminal.get("address")
                        if (address in wanted and terminal.get("state") == "live"
                                and terminal["labels"].get("firstmate.home") == home
                                and terminal["labels"].get("firstmate.task")):
                            known.add(address)
                            emit(address, terminal.get("status"))
                    continue
                method = msg.get("method")
                if method == "missed":
                    return 2
                if method == "heartbeat":
                    continue
                if method != "event" or not isinstance(msg.get("params"), dict):
                    return 2
                event = msg["params"]
                address = event.get("terminal")
                data = event.get("data")
                if address not in wanted:
                    continue
                kind = event.get("type")
                if not isinstance(data, dict):
                    return 2
                if kind in ("created", "restarted", "labels"):
                    labels = data.get("labels")
                    if isinstance(labels, dict) and labels.get("firstmate.home") == home and labels.get("firstmate.task"):
                        known.add(address)
                    else:
                        known.discard(address)
                    if kind in ("created", "restarted") and address in known:
                        emit(address, data.get("status"))
                if kind in ("finished", "removed", "lost"):
                    known.discard(address)
                if kind == "status" and address in known:
                    if "status" not in data:
                        return 2
                    emit(address, data.get("status"))
    except (KeyboardInterrupt, BrokenPipeError, OSError):
        return 2
    finally:
        selector.close()
        proc.terminate() if proc.poll() is None else None
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
