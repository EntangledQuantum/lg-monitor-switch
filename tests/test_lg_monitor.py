# SPDX-License-Identifier: MIT
"""Unit tests for linux/lg-monitor. They never touch the monitor.

Run:  /usr/bin/python3 -m unittest discover -s tests -v
"""

import http.client
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_path = os.path.join(HERE, "..", "linux", "lg-monitor")
_loader = importlib.machinery.SourceFileLoader("lg_monitor", _path)
_spec = importlib.util.spec_from_loader("lg_monitor", _loader)
lg = importlib.util.module_from_spec(_spec)
_loader.exec_module(lg)


class PacketTests(unittest.TestCase):
    def test_verified_packets(self):
        # Bytes verified on a real 32GN650 (see docs/TEST_LOG.md).
        self.assertEqual(lg.lg_input_packet(0x91), [0x50, 0x84, 0x03, 0xF4, 0x00, 0x91, 0xDC])
        self.assertEqual(lg.lg_input_packet(0xD0), [0x50, 0x84, 0x03, 0xF4, 0x00, 0xD0, 0x9D])

    def test_checksum_is_xor_with_dest(self):
        for value in lg.INPUTS.values():
            pkt = lg.lg_input_packet(value)
            x = 0x6E
            for b in pkt:
                x ^= b
            self.assertEqual(x, 0)

    def test_unknown_value_refused(self):
        with self.assertRaises(lg.LgError):
            lg.lg_input_packet(0x14)

    def test_input_names(self):
        self.assertEqual(lg.normalize_input("DP"), "dp1")
        self.assertEqual(lg.normalize_input("HDMI-2"), "hdmi2")
        self.assertEqual(lg.normalize_input("hdmi"), "hdmi1")
        with self.assertRaises(lg.LgError):
            lg.normalize_input("vga")


class ParsingTests(unittest.TestCase):
    DETECT = """Display 1
   I2C bus:          /dev/i2c-6
   Monitor:          GSM:LG ULTRAGEAR:000AAAA00000

Invalid display
   I2C bus:          /dev/i2c-3
   Monitor:          GSM:LG ULTRAGEAR:OTHER

Display 2
   I2C bus:          /dev/i2c-9
   Monitor:          DEL:DELL U2720Q:ABC
"""

    def test_detect(self):
        self.assertEqual(lg.parse_detect(self.DETECT), 6)
        self.assertEqual(lg.parse_detect(self.DETECT, "DEL", "U2720"), 9)
        self.assertIsNone(lg.parse_detect(self.DETECT, "SAM", "X"))
        self.assertEqual(lg.parse_detect(self.DETECT.split("\n\n", 1)[1]), 3)

    def test_getvcp(self):
        vals = lg.parse_getvcp("VCP 10 C 94 100\nVCP 12 C 70 100\n")
        self.assertEqual(vals, {0x10: (94, 100), 0x12: (70, 100)})

    def test_levels(self):
        self.assertEqual(lg.check_level("42"), 42)
        self.assertEqual(lg.check_level(0), 0)
        for bad in ("-1", "101", "4.5", "abc", True, None, 1000):
            with self.assertRaises(lg.LgError):
                lg.check_level(bad)

    def test_only_brightness_and_contrast_writable(self):
        self.assertEqual(set(lg.WRITABLE_VCP), {0x10, 0x12})
        cfg = lg.new_config()
        for code in (0x14, 0x16, 0x18, 0x1A, 0x60, 0xF4):
            with self.assertRaises(lg.LgError):
                lg.set_vcp(cfg, code, 50)


class FakeBackend:
    def __init__(self):
        self.calls = []

    def status(self, cfg):
        self.calls.append(("status",))
        return {"brightness": 50, "contrast": 60}

    def set_vcp(self, cfg, code, value):
        self.calls.append(("set", code, value))
        return value

    def switch(self, cfg, name):
        self.calls.append(("switch", name))
        return "dp1" if name == "home" else lg.normalize_input(name)


class ListenerTests(unittest.TestCase):
    TOKEN = "test-token-0123456789abcdef"

    def setUp(self):
        self.backend = FakeBackend()
        token = self.TOKEN
        cfg = lg.new_config()

        class Handler(lg.ListenerHandler):
            backend = self.backend
            config_loader = staticmethod(lambda: cfg)
            token_loader = staticmethod(lambda: token)

            def log_message(self, *a):
                pass

        self.cfg = cfg
        self.srv = lg.make_server("127.0.0.1", 0, Handler)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def req(self, method, path, body=None, token=TOKEN, raw=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        data = raw if raw is not None else (json.dumps(body) if body is not None else None)
        conn.request(method, path, body=data, headers=headers)
        resp = conn.getresponse()
        out = json.loads(resp.read() or b"{}")
        conn.close()
        return resp.status, out

    def test_ping_and_status(self):
        self.assertEqual(self.req("GET", "/v1/ping")[0], 200)
        status, out = self.req("GET", "/v1/status")
        self.assertEqual((status, out["brightness"], out["contrast"]), (200, 50, 60))

    def test_auth_required(self):
        self.assertEqual(self.req("GET", "/v1/ping", token=None)[0], 401)
        self.assertEqual(self.req("GET", "/v1/ping", token="wrong")[0], 401)
        self.assertEqual(self.req("POST", "/v1/switch", {}, token="")[0], 401)
        self.assertEqual(self.backend.calls, [])

    def test_unknown_endpoints(self):
        self.assertEqual(self.req("GET", "/v1/vcp/14")[0], 404)
        self.assertEqual(self.req("POST", "/v1/color", {"value": 5})[0], 404)
        self.assertEqual(self.req("GET", "/v1/switch")[0], 404)

    def test_set_levels(self):
        self.assertEqual(self.req("POST", "/v1/brightness", {"value": 30}), (200, {"ok": True, "brightness": 30}))
        self.assertEqual(self.req("POST", "/v1/contrast", {"value": 100})[0], 200)
        self.assertEqual(self.backend.calls, [("set", 0x10, 30), ("set", 0x12, 100)])

    def test_bad_values(self):
        for body in ({"value": 101}, {"value": -1}, {"value": "50"}, {"value": 5.5},
                     {"value": True}, {}, {"value": None}):
            self.assertEqual(self.req("POST", "/v1/brightness", body)[0], 400, body)
        self.assertEqual(self.req("POST", "/v1/brightness", raw="not json")[0], 400)
        self.assertEqual(self.req("POST", "/v1/brightness", raw="[1,2]")[0], 400)
        self.assertEqual(self.req("POST", "/v1/brightness", raw='{"value": 1, "pad": "%s"}' % ("x" * 400))[0], 413)
        self.assertEqual(self.backend.calls, [])

    def test_switch(self):
        self.assertEqual(self.req("POST", "/v1/switch", {}), (200, {"ok": True, "input": "dp1"}))
        self.assertEqual(self.req("POST", "/v1/switch", {"input": "hdmi2"})[0], 200)
        self.assertEqual(self.req("POST", "/v1/switch", {"input": "vga"})[0], 400)
        self.assertEqual(self.req("POST", "/v1/switch", {"input": 17})[0], 400)
        self.assertEqual(self.backend.calls, [("switch", "home"), ("switch", "hdmi2")])

    def test_client_policy(self):
        self.assertTrue(lg.client_allowed("192.168.1.10", "private"))
        self.assertTrue(lg.client_allowed("10.0.0.5", "private"))
        self.assertTrue(lg.client_allowed("127.0.0.1", "private"))
        self.assertTrue(lg.client_allowed("::ffff:192.168.1.2", "private"))
        self.assertFalse(lg.client_allowed("8.8.8.8", "private"))
        self.assertTrue(lg.client_allowed("8.8.8.8", "any"))


class AutoSwitcherTests(unittest.TestCase):
    MAP = {"linux-pc": "dp1", "win-pc": "hdmi2"}

    @staticmethod
    def line(a, b):
        return '[2026-10-29T10:00:00] INFO: switch from "%s" to "%s" at 1919,500' % (a, b)

    def test_switch_after_delay(self):
        sw = lg.AutoSwitcher(self.MAP, delay=5, cooldown=2, current="dp1")
        self.assertEqual(sw.on_line(self.line("linux-pc", "win-pc"), 100.0), ("schedule", "win-pc"))
        self.assertIsNone(sw.due(104.9))
        self.assertEqual(sw.due(105.0), "hdmi2")
        sw.mark_switched("hdmi2", 105.0)
        self.assertIsNone(sw.due(106.0))
        sw.on_line(self.line("win-pc", "linux-pc"), 200.0)
        self.assertEqual(sw.due(205.0), "dp1")

    def test_cancel_when_cursor_returns(self):
        sw = lg.AutoSwitcher(self.MAP, delay=5, current="dp1")
        sw.on_line(self.line("linux-pc", "win-pc"), 100.0)
        self.assertEqual(sw.on_line(self.line("win-pc", "linux-pc"), 102.0), ("cancel", "linux-pc"))
        self.assertIsNone(sw.due(110.0))

    def test_bouncing_restarts_delay(self):
        sw = lg.AutoSwitcher(self.MAP, delay=5, current="dp1")
        sw.on_line(self.line("linux-pc", "win-pc"), 100.0)
        sw.on_line(self.line("win-pc", "linux-pc"), 101.0)
        sw.on_line(self.line("linux-pc", "win-pc"), 103.0)
        self.assertIsNone(sw.due(107.0))
        self.assertEqual(sw.due(108.0), "hdmi2")

    def test_cooldown(self):
        sw = lg.AutoSwitcher(self.MAP, delay=0, cooldown=2, current="dp1")
        sw.on_line(self.line("linux-pc", "win-pc"), 100.0)
        sw.mark_switched(sw.due(100.0), 100.0)
        sw.on_line(self.line("win-pc", "linux-pc"), 100.5)
        self.assertIsNone(sw.due(100.5))
        self.assertIsNone(sw.due(101.9))
        self.assertEqual(sw.due(102.0), "dp1")

    def test_unmapped_and_noise(self):
        sw = lg.AutoSwitcher({"win-pc": "hdmi2"}, delay=1, current="dp1")
        self.assertIsNone(sw.on_line("INFO: client \"win-pc\" has connected", 1.0))
        self.assertEqual(sw.on_line(self.line("win-pc", "laptop"), 1.0), ("ignore", "laptop"))
        self.assertIsNone(sw.due(10.0))

    def test_already_on_target(self):
        sw = lg.AutoSwitcher(self.MAP, delay=1, current="hdmi2")
        self.assertEqual(sw.on_line(self.line("linux-pc", "win-pc"), 1.0), ("cancel", "win-pc"))
        self.assertIsNone(sw.due(5.0))

    def test_manual_switch_sync(self):
        sw = lg.AutoSwitcher(self.MAP, delay=5, current="dp1")
        sw.on_line(self.line("linux-pc", "win-pc"), 100.0)
        sw.sync_current("hdmi2")  # user pressed the Switch button meanwhile
        self.assertIsNone(sw.due(106.0))

    def test_jump_lines(self):
        sw = lg.AutoSwitcher(self.MAP, delay=0, current="hdmi2")
        sw.on_line('NOTE: jump from "win-pc" to "linux-pc" at 10,10', 1.0)
        self.assertEqual(sw.due(1.0), "dp1")


class DeskflowFileTests(unittest.TestCase):
    def test_follower_and_server_conf(self):
        with tempfile.TemporaryDirectory() as d:
            log = os.path.join(d, "deskflow.log")
            f = lg.FileFollower(log)
            self.assertEqual(f.lines(first=True), [])
            with open(log, "w") as fh:
                fh.write("old line\n")
            self.assertEqual(f.lines(), ["old line"])
            with open(log, "a") as fh:
                fh.write('switch from "a" to "b" at 1,1\npartial')
            self.assertEqual(f.lines(), ['switch from "a" to "b" at 1,1'])
            with open(log, "a") as fh:
                fh.write(" done\n")
            self.assertEqual(f.lines(), ["partial done"])
            with open(log, "w") as fh:  # truncation / rotation
                fh.write("fresh\n")
            self.assertEqual(f.lines(), ["fresh"])
            f.close()

            conf = os.path.join(d, "deskflow-server.conf")
            with open(conf, "w") as fh:
                fh.write("section: screens\n\tlinux:\n\twin:\nend\nsection: links\n\tlinux:\n"
                         "\t\tright = win\nend\n")
            self.assertEqual(lg.parse_server_conf_screens(conf), ["linux", "win", "linux", "win"])


if __name__ == "__main__":
    unittest.main()


# ---------------------------------------------------------------------------
# Deskflow detection and the watcher (v1.0.1). Everything runs in a temporary
# fake HOME; switches go to a recording fake, never to the monitor.
# ---------------------------------------------------------------------------

FP = ".var/app/org.deskflow.deskflow"


def write(path, text, bump=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)
    if bump is not None:  # make mtime changes visible even within one clock tick
        st = os.stat(path)
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + bump * 1_000_000_000))


def append(path, text):
    with open(path, "a") as fh:
        fh.write(text)


def deskflow_conf(log_file=None, to_file=True, level="INFO", local="linux-pc"):
    return ("[core]\ncomputerName=%s\n\n[computer_win]\nname=windows-pc\n\n[log]\nfile=%s\nlevel=%s\n"
            "toFile=%s\n" % (local, log_file or "", level, "true" if to_file else "false"))


def sw_line(a, b):
    return '[2026-10-29T10:00:00] INFO: switch from "%s" to "%s" at 10,10\n' % (a, b)


class DeskflowDetectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name
        self.cfg = lg.new_config()
        self.fpconf = os.path.join(self.home, FP, "config/Deskflow/Deskflow.conf")
        self.fplog = os.path.join(self.home, FP, "data/deskflow.log")

    def tearDown(self):
        self.tmp.cleanup()

    def report(self, running="flatpak"):
        info = lg.deskflow_info(self.home, running=running)
        return info, lg.deskflow_log_report(self.cfg, info, self.home)

    def test_flatpak_ok(self):
        write(self.fpconf, deskflow_conf(self.fplog))
        write(self.fplog, "x\n")
        info, rep = self.report()
        self.assertEqual(info["screens"], ["linux-pc", "windows-pc"])
        self.assertEqual((rep["state"], rep["path"], rep["usable"]), ("ok", self.fplog, True))

    def test_flatpak_outside_sandbox_without_fallback(self):
        write(self.fpconf, deskflow_conf(os.path.join(self.home, "deskflow.log")))
        write(os.path.join(self.home, "deskflow.log"), "stale host file\n")  # not written by the Flatpak
        _, rep = self.report()
        self.assertEqual((rep["state"], rep["path"]), ("outside_sandbox", None))
        self.assertIn(self.fplog, rep["message"])
        self.assertEqual(rep["recommended"], self.fplog)

    def test_flatpak_outside_sandbox_falls_back_to_recent_log(self):
        write(self.fpconf, deskflow_conf(os.path.join(self.home, "deskflow.log")))
        old = os.path.join(self.home, FP, "cache/old.log")
        write(old, "old\n", bump=-100)
        write(self.fplog, "newer\n")
        _, rep = self.report()
        self.assertEqual((rep["state"], rep["path"]), ("outside_sandbox", self.fplog))
        self.assertIn("Meanwhile following", rep["message"])

    def test_log_to_file_off(self):
        write(self.fpconf, deskflow_conf(self.fplog, to_file=False))
        _, rep = self.report()
        self.assertEqual((rep["state"], rep["path"]), ("off", None))
        self.assertIn("'Log to file' is off", rep["message"])

    def test_not_created_yet(self):
        write(self.fpconf, deskflow_conf(self.fplog))
        _, rep = self.report()
        self.assertEqual((rep["state"], rep["path"], rep["usable"]), ("not_created", self.fplog, False))

    def test_quiet_log_level_warning(self):
        write(self.fpconf, deskflow_conf(self.fplog, level="WARNING"))
        _, rep = self.report()
        self.assertIn("log level is Warning", rep["message"])

    def test_manual_path_missing_falls_back(self):
        write(self.fpconf, deskflow_conf(self.fplog))
        write(self.fplog, "x\n")
        self.cfg.set("deskflow", "log_file", os.path.join(self.home, "nope.log"))
        _, rep = self.report()
        self.assertEqual((rep["state"], rep["path"]), ("manual_missing", self.fplog))
        self.cfg.set("deskflow", "log_file", "")  # empty means automatic
        self.assertEqual(self.report()[1]["state"], "ok")

    def test_native_install(self):
        conf = os.path.join(self.home, ".config/Deskflow/Deskflow.conf")
        log = os.path.join(self.home, "deskflow.log")
        write(conf, deskflow_conf(log))
        write(log, "x\n")
        info, rep = self.report(running="native")
        self.assertEqual((info["kind"], info["config"]), ("native", conf))
        self.assertEqual((rep["state"], rep["path"]), ("ok", log))
        self.assertEqual(rep["recommended"], log)

    def test_both_configs_prefer_running_kind(self):
        native = os.path.join(self.home, ".config/Deskflow/Deskflow.conf")
        write(native, deskflow_conf(os.path.join(self.home, "deskflow.log")), bump=50)
        write(self.fpconf, deskflow_conf(self.fplog))
        self.assertEqual(lg.deskflow_info(self.home, running="flatpak")["config"], self.fpconf)
        self.assertEqual(lg.deskflow_info(self.home, running="native")["config"], native)

    def test_appimage_detected(self):
        write(os.path.join(self.home, "Applications/Deskflow-1.27.0-x86_64.AppImage"), "")
        self.assertIn("appimage", [k for k, _ in lg.deskflow_installs(self.home)])

    def test_effective_mapping_defaults(self):
        write(self.fpconf, deskflow_conf(self.fplog))
        info = lg.deskflow_info(self.home, running="flatpak")
        self.assertEqual(lg.effective_mapping(self.cfg, info), {"linux-pc": "dp1", "windows-pc": "hdmi2"})
        self.cfg.set("deskflow.screens", "windows-pc", "none")
        self.cfg.set("deskflow.screens", "laptop", "hdmi1")
        self.assertEqual(lg.effective_mapping(self.cfg, info), {"linux-pc": "dp1", "laptop": "hdmi1"})

    def test_rotation_by_rename(self):
        f = lg.FileFollower(self.fplog)
        write(self.fplog, "")
        f.lines(first=True)
        append(self.fplog, "a\nb")
        self.assertEqual(f.lines(), ["a"])
        append(self.fplog, "\n")
        os.rename(self.fplog, self.fplog + ".1")
        write(self.fplog, "c\n")
        self.assertEqual(f.lines(), ["b", "c"])
        f.close()


class WatcherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name
        self.cfgpath = os.path.join(self.home, "lgcfg/config.ini")
        self.fpconf = os.path.join(self.home, FP, "config/Deskflow/Deskflow.conf")
        self.fplog = os.path.join(self.home, FP, "data/deskflow.log")
        self.journal = os.path.join(self.home, "fake-journal")
        write(self.journal, "")
        write(self.cfgpath, "[deskflow]\ndelay = 0\ncooldown = 0\n")
        self.switched, self.logs = [], []
        self.now = [1000.0]
        self.w = None

    def tearDown(self):
        if self.w:
            self.w.close()
        self.tmp.cleanup()

    def start(self):
        self.w = lg.DeskflowWatcher(
            switch_fn=lambda cfg, t: self.switched.append(t), log=self.logs.append,
            config_path=self.cfgpath, home=self.home, state_file=os.path.join(self.home, "watch.json"),
            journal_cmd=["tail", "-n0", "-F", self.journal], state_reader=lambda: None,
            clock=lambda: self.now[0], info_fn=lambda: lg.deskflow_info(self.home, running="flatpak"))
        self.w.step(0)
        return self.w

    def steps(self, n=3, timeout=0.05):
        for _ in range(n):
            self.w.step(timeout)

    def test_file_appears_after_startup(self):
        write(self.fpconf, deskflow_conf(self.fplog))
        w = self.start()
        self.assertEqual(w.source, ("file", self.fplog))
        self.assertIsNotNone(w.next_retry)          # not usable yet -> retrying
        write(self.fplog, "Deskflow server started\n" + sw_line("linux-pc", "windows-pc"))
        self.steps()
        self.assertEqual(self.switched, ["hdmi2"])
        self.now[0] += 10                            # retry interval passes
        self.steps(1)
        self.assertIsNone(w.next_retry)              # found -> retrying stops

    def test_no_redetection_while_working(self):
        write(self.fpconf, deskflow_conf(self.fplog))
        write(self.fplog, "x\n")
        w = self.start()
        self.assertIsNone(w.next_retry)
        for _ in range(5):
            self.now[0] += 60
            w.step(0)
        self.assertEqual(w.detections, 1)
        with open(os.path.join(self.home, "watch.json")) as fh:
            self.assertEqual(json.load(fh)["source"], "file")

    def test_deskflow_log_path_changes_while_running(self):
        other = os.path.join(self.home, FP, "data/other.log")
        write(self.fplog, "")
        write(other, "")
        write(self.fpconf, deskflow_conf(self.fplog))
        w = self.start()
        self.assertEqual(w.source, ("file", self.fplog))
        write(self.fpconf, deskflow_conf(other), bump=5)   # user changes Deskflow's log path
        w.step(0)
        self.assertEqual(w.source, ("file", other))
        self.assertTrue(any("settings changed" in m for m in self.logs))
        append(self.fplog, sw_line("linux-pc", "windows-pc"))   # old file: ignored now
        self.steps()
        self.assertEqual(self.switched, [])
        append(other, sw_line("linux-pc", "windows-pc"))
        self.steps()
        self.assertEqual(self.switched, ["hdmi2"])

    def test_journal_to_file_transition(self):
        write(self.cfgpath, "[deskflow]\ndelay = 0\ncooldown = 0\n[deskflow.screens]\nwindows-pc = hdmi2\n"
                            "linux-pc = dp1\n")
        w = self.start()                              # no Deskflow config at all -> journal fallback
        self.assertEqual(w.source, ("journal", None))
        self.assertIsNotNone(w.next_retry)
        import time as _t
        _t.sleep(0.3)                                 # let the fake journal (tail -F) start
        append(self.journal, "unrelated\n" + sw_line("linux-pc", "windows-pc"))
        for _ in range(30):
            w.step(0.1)
            if self.switched:
                break
        self.assertEqual(self.switched, ["hdmi2"])    # journal lines work
        write(self.fpconf, deskflow_conf(self.fplog))  # Deskflow configured later
        write(self.fplog, "")
        w.step(0)
        self.assertEqual(w.source, ("file", self.fplog))
        self.assertIsNone(w.next_retry)
        append(self.fplog, sw_line("windows-pc", "linux-pc"))
        self.steps()
        self.assertEqual(self.switched, ["hdmi2", "dp1"])

    def test_outside_sandbox_then_fixed(self):
        write(self.fpconf, deskflow_conf(os.path.join(self.home, "deskflow.log")))
        w = self.start()
        self.assertEqual(w.report["state"], "outside_sandbox")
        self.assertEqual(w.source, ("journal", None))
        write(self.fpconf, deskflow_conf(self.fplog), bump=5)   # user fixes the path in Deskflow
        w.step(0)
        self.assertEqual((w.report["state"], w.source), ("not_created", ("file", self.fplog)))
        write(self.fplog, sw_line("windows-pc", "linux-pc"))
        self.steps()
        self.assertEqual(self.switched, [])            # already on dp1 (home input)
        append(self.fplog, sw_line("linux-pc", "windows-pc") + sw_line("windows-pc", "linux-pc"))
        self.steps()
        self.assertEqual(self.switched, [])            # came back before the delay -> nothing
        append(self.fplog, sw_line("linux-pc", "windows-pc"))
        self.steps()
        self.assertEqual(self.switched, ["hdmi2"])

    def test_lg_config_change_applies_without_restart(self):
        write(self.fpconf, deskflow_conf(self.fplog))
        write(self.fplog, "")
        w = self.start()
        write(self.cfgpath, "[deskflow]\ndelay = 0\ncooldown = 0\n[deskflow.screens]\nwindows-pc = hdmi1\n",
              bump=5)
        w.step(0)
        self.assertEqual(w.sw.mapping["windows-pc"], "hdmi1")
        append(self.fplog, sw_line("linux-pc", "windows-pc"))
        self.steps()
        self.assertEqual(self.switched, ["hdmi1"])

    def test_failed_switch_is_not_remembered(self):
        write(self.fpconf, deskflow_conf(self.fplog))
        write(self.fplog, "")
        w = self.start()

        def boom(cfg, t):
            raise lg.LgError("i2c error")
        w.switch_fn = boom
        append(self.fplog, sw_line("linux-pc", "windows-pc"))
        self.steps()
        self.assertEqual(w.sw.current, "dp1")
        w.switch_fn = lambda cfg, t: self.switched.append(t)
        append(self.fplog, sw_line("windows-pc", "linux-pc") + sw_line("linux-pc", "windows-pc"))
        self.steps()
        self.assertEqual(self.switched, ["hdmi2"])
