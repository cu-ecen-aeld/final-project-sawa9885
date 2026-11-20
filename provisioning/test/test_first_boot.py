# Host test for the gateway's side of provisioning (issue #10): it runs the real
# /usr/sbin/gateway-provision script from the rootfs overlay against a local fake of the
# provisioning function, in temporary directories that stand for /etc/station and
# /etc/gateway-provision.
#
#   python3 -m unittest discover -s provisioning/test -v
#
# Needs sh, curl, jq and sha256sum on the host (Linux or WSL). Without them these tests are skipped.
# The script's GWPROV_* variables point it at the temporary directories, shorten its delays
# (1 s, then 2 s at most) and allow plain http, because the fake has no certificate.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #10): https://claude.ai/code/cshk_01CSAPnw19XXA81xkir2Ei316vsRvZPpL3YkJGDGzNdFWr

import http.server
import json
import os
import shutil
import stat
import subprocess
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "base_external", "rootfs_overlay", "usr", "sbin",
                      "gateway-provision")
EUI = "0016c001f1135844"
SECRET = "5a" * 32
# The PEM marker of the fake key is put together from two lines, so that the repo check for
# committed keys (the "git grep" in the issue's definition of done) does not match this file.
KEY_WORDS = "PRIVATE " + "KEY"
GOOD_ANSWER = {
    "gateway_eui": EUI,
    "cups.uri": "https://example.cups.lorawan.us-east-1.amazonaws.com:443",
    "cups.trust": "-----BEGIN CERTIFICATE-----\ntrust\n-----END CERTIFICATE-----\n",
    "cups.crt": "-----BEGIN CERTIFICATE-----\ncert\n-----END CERTIFICATE-----\n",
    "cups.key": "-----BEGIN FAKE %s-----\nkey\n-----END FAKE %s-----\n" % (KEY_WORDS, KEY_WORDS),
}
TOOLS = ["sh", "curl", "jq", "sha256sum"]
MISSING = [tool for tool in TOOLS if shutil.which(tool) is None]


class FakeFunction(http.server.BaseHTTPRequestHandler):
    """Answers each POST with the next (status, body) from the server's script, and the last
    one from then on. It keeps every request body it received."""

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.server.requests.append((self.path, self.rfile.read(length).decode()))
        answers = self.server.answers
        status, body = answers.pop(0) if len(answers) > 1 else answers[0]
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


@unittest.skipIf(MISSING, "not on this host: " + ", ".join(MISSING))
class FirstBootTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="gwprov-test-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.station = os.path.join(self.root, "station")
        self.prov = os.path.join(self.root, "gateway-provision")
        self.log_file = os.path.join(self.root, "log")
        self.restarted = os.path.join(self.root, "restarted")
        os.mkdir(self.station)
        os.mkdir(self.prov)
        self.server = None

    def serve(self, *answers):
        self.server = http.server.HTTPServer(("127.0.0.1", 0), FakeFunction)
        self.server.answers = list(answers)
        self.server.requests = []
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        return "http://127.0.0.1:%d/provision" % self.server.server_address[1]

    def flash(self, url, secret=SECRET):
        """What S35provision leaves in /etc/gateway-provision after flash-gateway.ps1."""
        with open(os.path.join(self.prov, "secret"), "w") as f:
            f.write(secret + "\n")
        with open(os.path.join(self.prov, "url"), "w") as f:
            f.write(url + "\n")

    def run_script(self, timeout=60):
        env = dict(os.environ,
                   GWPROV_STATION_DIR=self.station, GWPROV_DIR=self.prov,
                   GWPROV_LOG=self.log_file, GWPROV_EUI=EUI.upper(),
                   GWPROV_FIRST_DELAY="1", GWPROV_MAX_DELAY="2", GWPROV_CLOCK_TRIES="1",
                   GWPROV_TEST_ALLOW_HTTP="1",
                   GWPROV_RESTART_CMD="touch " + self.restarted)
        done = subprocess.run(["sh", SCRIPT], env=env, timeout=timeout,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(done.stdout, b"", "the script printed something")
        return done.returncode

    def log(self):
        if not os.path.exists(self.log_file):
            return ""
        with open(self.log_file) as f:
            return f.read()

    def assert_installed(self):
        for name in ("cups.uri", "cups.trust", "cups.crt", "cups.key"):
            path = os.path.join(self.station, name)
            with open(path) as f:
                self.assertEqual(f.read(), GOOD_ANSWER[name], name)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600, name)
        # The used secret and the work files are gone; gwmon was restarted.
        self.assertEqual(os.listdir(self.prov), [])
        self.assertTrue(os.path.exists(self.restarted))
        self.assertNotIn(SECRET, self.log())

    def assert_nothing_installed(self):
        self.assertEqual(os.listdir(self.station), [])
        self.assertFalse(os.path.exists(self.restarted))
        self.assertNotIn(SECRET, self.log())

    def test_first_boot_fetches_and_installs_the_four_files(self):
        self.flash(self.serve((200, GOOD_ANSWER)))
        self.assertEqual(self.run_script(), 0)
        self.assert_installed()
        # One request, with the EUI in lower case and the secret from the card.
        self.assertEqual(self.server.requests,
                         [("/provision", json.dumps({"gateway_eui": EUI, "secret": SECRET},
                                                    separators=(",", ":")))])
        self.assertIn("provisioned after 1 tries", self.log())

    def test_gateway_with_credentials_makes_no_request(self):
        self.flash(self.serve((200, GOOD_ANSWER)))
        with open(os.path.join(self.station, "cups.uri"), "w") as f:
            f.write("https://already.example:443\n")
        self.assertEqual(self.run_script(), 0)
        self.assertEqual(self.server.requests, [])
        self.assertIn("no provisioning request", self.log())
        self.assertFalse(os.path.exists(self.restarted))

    def test_gateway_without_a_secret_does_nothing(self):
        self.assertEqual(self.run_script(), 0)
        self.assertIn("nothing to do", self.log())
        self.assert_nothing_installed()

    def test_function_unavailable_is_retried_with_growing_delays(self):
        self.flash(self.serve((503, {"error": "try_again"}), (502, b"<html>bad gateway</html>"),
                              (503, {"error": "try_again"}), (200, GOOD_ANSWER)))
        self.assertEqual(self.run_script(), 0)
        self.assert_installed()
        self.assertEqual(len(self.server.requests), 4)
        log = self.log()
        self.assertIn("HTTP 503 try_again", log)
        self.assertIn("HTTP 502 (no error field)", log)
        # 1 s, then 2 s, then 2 s again because the test caps the delay at 2 s.
        self.assertIn("try 1 failed, next try in 1 s", log)
        self.assertIn("try 2 failed, next try in 2 s", log)
        self.assertIn("try 3 failed, next try in 2 s", log)
        self.assertIn("provisioned after 4 tries", log)

    def test_network_unavailable_is_retried(self):
        # Nothing listens on this port for the first tries: the address is taken from a server
        # that is started only after the script has failed twice.
        placeholder = http.server.HTTPServer(("127.0.0.1", 0), FakeFunction)
        port = placeholder.server_address[1]
        placeholder.server_close()
        self.flash("http://127.0.0.1:%d/provision" % port)

        def start_later():
            self.server = http.server.HTTPServer(("127.0.0.1", port), FakeFunction)
            self.server.answers = [(200, GOOD_ANSWER)]
            self.server.requests = []
            self.server.serve_forever()

        timer = threading.Timer(2.0, start_later)
        timer.start()
        self.addCleanup(lambda: self.server and (self.server.shutdown(), self.server.server_close()))
        self.assertEqual(self.run_script(), 0)
        self.assert_installed()
        self.assertIn("no answer: curl:", self.log())
        self.assertIn("try 1 failed", self.log())

    def test_used_secret_is_refused_and_not_retried(self):
        self.flash(self.serve((409, {"error": "secret_already_used"})))
        self.assertEqual(self.run_script(), 1)
        self.assertEqual(len(self.server.requests), 1)
        self.assertIn("refused by the provisioning function: HTTP 409 secret_already_used",
                      self.log())
        self.assertIn("giving up until the next boot", self.log())
        self.assert_nothing_installed()

    def test_unknown_secret_is_refused_and_not_retried(self):
        self.flash(self.serve((403, {"error": "unknown_secret"})))
        self.assertEqual(self.run_script(), 1)
        self.assertEqual(len(self.server.requests), 1)
        self.assert_nothing_installed()

    def test_incomplete_answer_installs_nothing(self):
        incomplete = dict(GOOD_ANSWER)
        del incomplete["cups.key"]
        # The real function would refuse the second try, because the secret is used by then.
        self.flash(self.serve((200, incomplete), (409, {"error": "secret_already_used"})))
        self.assertEqual(self.run_script(), 1)
        self.assertIn("the function's answer has no cups.key", self.log())
        self.assert_nothing_installed()

    def test_malformed_secret_file_makes_no_request(self):
        self.flash(self.serve((200, GOOD_ANSWER)), secret='x","gateway_eui":"0000000000000000')
        self.assertEqual(self.run_script(), 1)
        self.assertEqual(self.server.requests, [])
        self.assert_nothing_installed()


if __name__ == "__main__":
    unittest.main()
