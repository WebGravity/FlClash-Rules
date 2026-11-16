"""Offline behavioral checks using synthetic proxies and credentials only."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "openclash_custom_overwrite.sh"


def node(name):
    return {"name": name, "type": "socks5", "server": "192.0.2.2", "port": 1080}


def fixture():
    return {
        "proxies": [node("Japan A"), node("US B"), node("剩余流量 1GB"),
                    node("距离重置 1天"), dict(node("nested"), **{"dialer-proxy": "Japan A"})],
        "proxy-groups": [{"name": "自动选择", "type": "url-test",
                          "proxies": ["Japan A", "US B"],
                          "url": "https://www.gstatic.com/generate_204", "interval": 300}],
        "rules": ["DOMAIN,ads.example.invalid,REJECT", "MATCH,DIRECT"],
        "dns": {"enable": True, "fake-ip-filter": ["+.example.invalid"]},
    }


def parse(path):
    result = subprocess.run(
        ["ruby", "-ryaml", "-rjson", "-e",
         "puts JSON.generate(YAML.load_file(ARGV[0]))", str(path)],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)


def group(config, name):
    return next(g for g in config["proxy-groups"] if g["name"] == name)


class OverwriteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="openclash-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.input = self.directory / "input.yaml"
        self.private = self.directory / "residential.yaml"
        self.log = self.directory / "overwrite.log"
        self.credentials = {"server": "192.0.2.1", "port": 1080,
                            "username": "dummy-user", "password": "dummy-password", "udp": True}
        self.private.write_text(json.dumps(self.credentials))
        self.private.chmod(0o600)
        self.env = dict(os.environ, RESIDENTIAL_CONFIG=str(self.private),
                        OVERWRITE_LOG=str(self.log), AIRPORT_AUTO_GROUP="")

    def run_script(self, config=None, success=True):
        if config is not None:
            self.input.write_text(json.dumps(config, ensure_ascii=False))
            self.input.chmod(0o600)
        before = self.input.read_bytes()
        result = subprocess.run(["sh", str(SCRIPT), str(self.input)],
                                env=self.env, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.input.stat().st_mode & 0o777, 0o600)
            return parse(self.input)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.input.read_bytes(), before)
        self.assertNotIn(self.credentials["password"], result.stderr + result.stdout + self.log.read_text())

    def test_chain_and_routing(self):
        config = self.run_script(fixture())
        auto = group(config, "住宅链路自动")
        self.assertEqual(len(auto["proxies"]), 2)
        self.assertEqual((auto["type"], auto["interval"], auto["tolerance"]), ("url-test", 300, 100))
        self.assertEqual(auto["expected-status"], "204")
        self.assertEqual(auto["empty-fallback"], "REJECT")
        self.assertEqual(group(config, "住宅IP")["proxies"], ["住宅链路自动"])
        chains = [p for p in config["proxies"] if p["name"] in auto["proxies"]]
        self.assertEqual({p["dialer-proxy"] for p in chains}, {"Japan A", "US B"})
        for chain in chains:
            self.assertEqual(chain["type"], "socks5")
            for key, value in self.credentials.items():
                self.assertEqual(chain[key], value)
        exchange = group(config, "交易所-台韩日澳英澳门")
        self.assertEqual(exchange["proxies"], ["Japan A"])
        self.assertEqual((exchange["interval"], exchange["tolerance"]), (600, 50))
        self.assertEqual(config["rules"][-1], "MATCH,住宅IP")
        for domain in ("chatgpt.com", "openai.com", "x.com", "twimg.com", "anthropic.com"):
            self.assertLess(config["rules"].index(f"DOMAIN-SUFFIX,{domain},住宅IP"),
                            config["rules"].index("GEOIP,CN,DIRECT"))
        self.assertIn("DOMAIN,ads.example.invalid,REJECT", config["rules"])
        self.assertIn("DOMAIN-SUFFIX,binance.com,交易所-台韩日澳英澳门", config["rules"])
        self.assertEqual(config["mode"], "rule")
        before = self.input.read_bytes()
        self.run_script()
        self.assertEqual(self.input.read_bytes(), before)

    def test_renamed_airport_and_include_all(self):
        config = self.run_script({"proxies": [node("新机场 東京"), node("新机场 巴黎")],
                                  "proxy-groups": [{"name": "主代理", "type": "select", "include-all": True}],
                                  "rules": []})
        self.assertEqual(len(group(config, "住宅链路自动")["proxies"]), 2)
        self.assertEqual(set(group(config, "机场自动选择")["proxies"]), {"新机场 東京", "新机场 巴黎"})
        self.assertIn("住宅链路｜", group(config, "主代理")["exclude-filter"])
        before = self.input.read_bytes()
        self.run_script()
        self.assertEqual(self.input.read_bytes(), before)

    def test_missing_private_file(self):
        self.private.unlink()
        self.run_script(fixture(), success=False)

    def test_invalid_private_config(self):
        for changes in ({"password": "CHANGE_ME"}, {"server": ""}, {"port": 0},
                        {"port": 65536}, {"port": 12.5}, {"udp": "true"}):
            with self.subTest(changes=changes):
                self.private.write_text(json.dumps(dict(self.credentials, **changes)))
                self.run_script(fixture(), success=False)
        self.private.write_text('password: "dummy-password\n')
        self.run_script(fixture(), success=False)

    def test_no_inline_candidates(self):
        self.run_script({"proxies": [], "proxy-groups": [], "rules": []}, success=False)

    def test_unknown_explicit_airport_group(self):
        self.env["AIRPORT_AUTO_GROUP"] = "missing-group"
        self.run_script(fixture(), success=False)

    @unittest.skipUnless(os.environ.get("MIHOMO_BIN"), "Set MIHOMO_BIN for offline core validation")
    def test_core_validation(self):
        config = self.run_script(fixture())
        config["rules"] = [r for r in config["rules"] if not r.startswith(("GEOIP,", "GEOSITE,"))]
        core_file = self.directory / "core.json"
        core_file.write_text(json.dumps(config, ensure_ascii=False))
        core_file.chmod(0o600)
        result = subprocess.run([os.environ["MIHOMO_BIN"], "-t", "-d", str(self.directory),
                                 "-f", str(core_file)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
