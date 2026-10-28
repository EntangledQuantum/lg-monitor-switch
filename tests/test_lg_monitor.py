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
