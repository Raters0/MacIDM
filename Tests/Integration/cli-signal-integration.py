#!/usr/bin/env python3
"""Run with the optimized macidm executable, using only owned child processes."""
import http.server
import importlib.util
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("signal_fixture", ROOT / "Tests/Support/signal-http-fixture.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
binary = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".build/release/macidm").resolve()
assert binary.is_file(), "Build the optimized CLI first: swift build -c release --product macidm"
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), fixture.SignalHTTPFixture)
threading.Thread(target=server.serve_forever, daemon=True).start()


def wait_for(predicate, seconds=8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.02)
    raise AssertionError("Timed out waiting for the controlled CLI state")


try:
    with tempfile.TemporaryDirectory(prefix="macidm-signal-tests-") as temp:
        for name, sig, second in [("interrupt", signal.SIGINT, False), ("terminate", signal.SIGTERM, False), ("force", signal.SIGINT, True)]:
            directory = Path(temp) / name
            directory.mkdir()
            state = directory / "state"
            state.mkdir()
            log = (directory / "output.log").open("wb")
            endpoint = "stalled" if second else "slow"
            process = subprocess.Popen([
                str(binary), "add", f"http://127.0.0.1:{server.server_port}/{endpoint}",
                "--output", str(directory / "download.bin"), "--parallel", "1", "--foreground", "--json", "--state-dir", str(state),
            ], stdout=log, stderr=log)

            def record():
                for path in state.glob("*.json"):
                    try:
                        data = json.loads(path.read_text())
                        if isinstance(data, dict) and data.get("workerPID") == process.pid:
                            return data
                    except (OSError, ValueError):
                        pass
                return {}

            try:
                wait_for(lambda: record().get("status") == "running")
                if second:
                    assert fixture.SignalHTTPFixture.stalled_probe.wait(5)
                else:
                    wait_for(lambda: record().get("receivedBytes", 0) > 0)
                process.send_signal(sig)
                if second:
                    wait_for(lambda: record().get("desiredAction") == "pause")
                    assert process.poll() is None, "First signal must still be pending for second-signal coverage"
                    process.send_signal(signal.SIGTERM)
                    assert process.wait(timeout=5) == 130
                else:
                    assert process.wait(timeout=8) == 8
                    records = [json.loads(p.read_text()) for p in state.glob("*.json")]
                    paused = next(r for r in records if r.get("status") == "paused")
                    assert paused.get("workerPID") is None
                    assert paused["desiredAction"] == "pause"
                print(f"PASS optimized CLI {name}")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                log.close()
finally:
    server.shutdown()
    server.server_close()
