#!/usr/bin/env python3
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Local test for server.py. Standard library only; ADK is not needed.

Covers the pieces that are specific to running on Agent Substrate:
  * which CA bundle Python clients are pointed at,
  * the stand-in metadata server, driven with the requests google-auth makes
    (see google/auth/compute_engine/_metadata.py), and
  * signal handling, with a stub in place of uvicorn.

Run:  python3 test_server.py
"""

import contextlib
import io
import json
import logging
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
import types
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import server  # pylint: disable=wrong-import-position


def free_port():
  with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    return probe.getsockname()[1]


class ConfigureTrustTest(unittest.TestCase):

  def setUp(self):
    self.tmp = tempfile.TemporaryDirectory()
    self.addCleanup(self.tmp.cleanup)
    self.bundle = os.path.join(self.tmp.name, "trust-bundle.pem")
    self.extra = os.path.join(self.tmp.name, "extra-ca.pem")
    self.combined = os.path.join(self.tmp.name, "combined.pem")
    self.saved = (server.SUBSTRATE_TRUST_BUNDLE, server.EXTRA_CA_FILE, server.COMBINED_CA_FILE)
    server.SUBSTRATE_TRUST_BUNDLE = self.bundle
    server.EXTRA_CA_FILE = self.extra
    server.COMBINED_CA_FILE = self.combined
    self.addCleanup(self._restore)

  def _restore(self):
    server.SUBSTRATE_TRUST_BUNDLE, server.EXTRA_CA_FILE, server.COMBINED_CA_FILE = self.saved

  def _write(self, path, text):
    with open(path, "w", encoding="utf-8") as out:
      out.write(text)

  def test_substrate_bundle_alone_is_used_directly(self):
    self._write(self.bundle, "GATEWAY-AND-PUBLIC-ROOTS\n")
    environ = {}
    self.assertEqual(server.configure_trust(environ), self.bundle)
    self.assertEqual(environ, {
        "SSL_CERT_FILE": self.bundle,
        "REQUESTS_CA_BUNDLE": self.bundle,
        "CURL_CA_BUNDLE": self.bundle,
    })
    self.assertFalse(os.path.exists(self.combined))

  def test_private_ca_is_merged_with_the_substrate_bundle(self):
    self._write(self.bundle, "GATEWAY-AND-PUBLIC-ROOTS")  # no trailing newline on purpose
    self._write(self.extra, "PRIVATE-LOOKER-CA\n")
    environ = {}
    self.assertEqual(server.configure_trust(environ), self.combined)
    with open(self.combined, encoding="utf-8") as merged:
      self.assertEqual(merged.read(), "GATEWAY-AND-PUBLIC-ROOTS\nPRIVATE-LOOKER-CA\n")
    self.assertEqual(environ["REQUESTS_CA_BUNDLE"], self.combined)

  def test_nothing_is_changed_without_any_bundle(self):
    environ = {"SSL_CERT_FILE": "/already/set"}
    self.assertIsNone(server.configure_trust(environ))
    self.assertEqual(environ, {"SSL_CERT_FILE": "/already/set"})

  def test_empty_private_ca_file_is_ignored(self):
    self._write(self.bundle, "ROOTS\n")
    self._write(self.extra, "")
    self.assertEqual(server.configure_trust({}), self.bundle)


class FakeMetadataServerTest(unittest.TestCase):

  def setUp(self):
    self.port = free_port()
    self.address = "127.0.0.1:%d" % self.port
    self.server = server.start_fake_metadata_server({
        "FAKE_GCE_METADATA": "1",
        "GCE_METADATA_HOST": self.address,
        "GCE_METADATA_IP": self.address,
        "GOOGLE_CLOUD_PROJECT": "my-project",
    })
    self.addCleanup(self.server.server_close)
    self.addCleanup(self.server.shutdown)

  def get(self, path, method="GET", body=None):
    request = urllib.request.Request(
        "http://%s%s" % (self.address, path), method=method, data=body,
        headers={"Metadata-Flavor": "Google"})
    with urllib.request.urlopen(request, timeout=5) as response:
      return response.status, dict(response.headers), response.read().decode()

  def test_ping_is_recognised_as_a_metadata_server(self):
    # google-auth ping(): GET http://<GCE_METADATA_IP>, expects 200 and this header.
    status, headers, _ = self.get("/")
    self.assertEqual(status, 200)
    self.assertEqual(headers["Metadata-Flavor"], "Google")

  def test_token_is_the_placeholder_and_parses_like_a_real_one(self):
    # google-auth get_service_account_token(): needs JSON with these two keys.
    status, headers, body = self.get(
        "/computeMetadata/v1/instance/service-accounts/default/token"
        "?scopes=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcloud-platform")
    self.assertEqual(status, 200)
    self.assertEqual(headers["Content-Type"], "application/json")
    token = json.loads(body)
    self.assertEqual(token["access_token"], server.PLACEHOLDER_TOKEN)
    self.assertGreater(token["expires_in"], 0)

  def test_token_request_may_be_a_post(self):
    status, _, body = self.get(
        "/computeMetadata/v1/instance/service-accounts/default/token",
        method="POST", body=b'{"certificate_chain": "x"}')
    self.assertEqual(status, 200)
    self.assertEqual(json.loads(body)["access_token"], server.PLACEHOLDER_TOKEN)

  def test_service_account_info_is_json(self):
    # google-auth get_service_account_info(): GET .../default/?recursive=true
    status, headers, body = self.get(
        "/computeMetadata/v1/instance/service-accounts/default/?recursive=true")
    self.assertEqual(status, 200)
    self.assertEqual(headers["Content-Type"], "application/json")
    info = json.loads(body)
    self.assertEqual(info["email"], "default")
    self.assertIn("https://www.googleapis.com/auth/cloud-platform", info["scopes"])

  def test_project_and_universe(self):
    _, headers, body = self.get("/computeMetadata/v1/project/project-id")
    self.assertEqual(body, "my-project")
    self.assertIn("Content-Type", headers)  # google-auth indexes this header on every 200
    _, _, body = self.get("/computeMetadata/v1/universe/universe-domain")
    self.assertEqual(body, "googleapis.com")

  def test_unknown_paths_are_not_found(self):
    with self.assertRaises(urllib.error.HTTPError) as caught:
      self.get("/computeMetadata/v1/instance/service-accounts/default/identity?audience=x")
    self.assertEqual(caught.exception.code, 404)

  def test_it_only_listens_on_loopback(self):
    self.assertEqual(self.server.server_address[0], "127.0.0.1")


class FakeMetadataConfigTest(unittest.TestCase):

  def test_disabled_by_default(self):
    self.assertIsNone(server.start_fake_metadata_server({}))

  def test_refuses_a_non_loopback_address(self):
    with self.assertRaises(ValueError):
      server.start_fake_metadata_server({
          "FAKE_GCE_METADATA": "true",
          "GCE_METADATA_HOST": "0.0.0.0:8087",
          "GCE_METADATA_IP": "0.0.0.0:8087",
      })

  def test_refuses_mismatched_ping_address(self):
    with self.assertRaises(ValueError):
      server.start_fake_metadata_server({
          "FAKE_GCE_METADATA": "true",
          "GCE_METADATA_HOST": "127.0.0.1:8087",
          "GCE_METADATA_IP": "169.254.169.254",
      })


STUB_UVICORN = textwrap.dedent('''
    import json, time
    class Config:
      def __init__(self, app, **settings):
        print("CONFIG " + json.dumps(settings, sort_keys=True), flush=True)
    class Server:
      def __init__(self, config):
        self.should_exit = False
      def run(self):
        print("READY", flush=True)
        while not self.should_exit:
          time.sleep(0.02)
        print("STOPPED", flush=True)
''')


class SignalHandlingTest(unittest.TestCase):

  def start(self, ignore_sigterm):
    tmp = tempfile.TemporaryDirectory()
    self.addCleanup(tmp.cleanup)
    with open(os.path.join(tmp.name, "uvicorn.py"), "w", encoding="utf-8") as stub:
      stub.write(STUB_UVICORN)
    environment = dict(os.environ, PYTHONPATH=tmp.name + os.pathsep + HERE)
    environment.pop("IGNORE_SIGTERM", None)
    if ignore_sigterm:
      environment["IGNORE_SIGTERM"] = "1"
    process = subprocess.Popen(
        [sys.executable, "-c", "import server; server.serve(object())"],
        env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    self.addCleanup(process.stdout.close)
    self.addCleanup(process.kill)
    config_line = process.stdout.readline().strip()
    self.assertTrue(config_line.startswith("CONFIG "), config_line)
    self.uvicorn_settings = json.loads(config_line[len("CONFIG "):])
    self.assertEqual(process.stdout.readline().strip(), "READY")
    return process

  def test_sigterm_does_not_stop_an_actor(self):
    process = self.start(ignore_sigterm=True)
    process.send_signal(signal.SIGTERM)
    time.sleep(1.0)
    self.assertIsNone(process.poll(), "process exited on SIGTERM although IGNORE_SIGTERM=1")
    # It can still be stopped deliberately.
    process.send_signal(signal.SIGINT)
    self.assertEqual(process.wait(timeout=5), 0)

  def test_sigterm_stops_the_process_outside_substrate(self):
    process = self.start(ignore_sigterm=False)
    process.send_signal(signal.SIGTERM)
    self.assertEqual(process.wait(timeout=5), 0)

  def test_requests_are_not_written_to_the_log(self):
    """The path of a request holds the ids that keep conversations apart."""
    process = self.start(ignore_sigterm=False)
    self.assertEqual(self.uvicorn_settings, {
        "host": "0.0.0.0", "port": server.PORT, "log_level": "info", "access_log": False})
    process.send_signal(signal.SIGINT)
    self.assertEqual(process.wait(timeout=5), 0)


class LoggingTest(unittest.TestCase):

  def setUp(self):
    root = logging.getLogger()
    adk = logging.getLogger("google_adk")
    saved = (root.level, list(root.handlers), adk.level)

    def restore():
      for handler in list(root.handlers):
        if handler not in saved[1]:
          root.removeHandler(handler)
          handler.close()
      for handler in saved[1]:
        if handler not in root.handlers:
          root.addHandler(handler)
      root.setLevel(saved[0])
      adk.setLevel(saved[2])

    self.addCleanup(restore)
    for handler in list(root.handlers):
      root.removeHandler(handler)

  def test_adk_does_not_log_the_ids_of_conversations(self):
    stream = io.StringIO()
    with contextlib.redirect_stdout(stream):
      # The handler it installs writes to what is stdout at this moment.
      server.configure_logging()
    # What ADK's API server does when a conversation starts (api_server.py),
    # through a logger named the way ADK names its loggers.
    adk = logging.getLogger("google_adk.google.adk.cli.api_server")
    adk.info("New session created: %s", "0b6f2a54-58f0-4c8e-9a46-0c1d2e3f4a5b")
    adk.warning("a warning from ADK")
    # The agent's own messages still appear at INFO.
    server.LOG.info("TLS trust anchors: %s", "/run/ate/egress-trust-bundle/trust-bundle.pem")
    logged = stream.getvalue()
    self.assertNotIn("0b6f2a54", logged)
    self.assertNotIn("New session created", logged)
    self.assertIn("a warning from ADK", logged)
    self.assertIn("TLS trust anchors", logged)


class ImageRecipeTest(unittest.TestCase):
  """The Dockerfile, read as text. No image is built here."""

  def setUp(self):
    with open(os.path.join(HERE, "Dockerfile"), encoding="utf-8") as recipe:
      self.text = recipe.read()
    # Instructions only: comments and blank lines left out, continuations joined.
    joined = re.sub(r"\\\n", " ", self.text)
    self.instructions = [line.strip() for line in joined.splitlines()
                         if line.strip() and not line.lstrip().startswith("#")]

  def test_the_base_image_can_be_named_by_digest(self):
    self.assertEqual(self.instructions[0], "ARG BASE_IMAGE=python:3.12-slim")
    self.assertEqual(self.instructions[1], "FROM ${BASE_IMAGE}")
    self.assertEqual(len([line for line in self.instructions if line.startswith("FROM ")]), 1)

  def test_the_agent_cannot_change_its_own_code(self):
    # It used to be handed all of /app.
    self.assertNotIn("chown", " ".join(self.instructions))
    user = self.instructions.index("USER 10001:10001")
    self.assertTrue(self.instructions[user - 1].startswith("RUN useradd --uid 10001"))
    self.assertIn("chmod -R a+rX,go-w /app", self.instructions[user - 1])
    # Nothing is copied or run after the switch to that user except the start.
    self.assertEqual(self.instructions[user + 1:], ["EXPOSE 80", 'ENTRYPOINT ["python", "/app/server.py"]'])

  def lock_condition(self):
    (install,) = [line for line in self.instructions if "pip install" in line]
    found = re.match(r"RUN if (grep [^;]+); then\s+(pip install --require-hashes -r /app/requirements\.lock);"
                     r"\s+else\s+(pip install -r /app/requirements\.txt);\s+fi\s+&& pip freeze", install)
    self.assertIsNotNone(found, install)
    self.assertIn("COPY requirements.txt requirements.lock /app/", self.instructions)
    return found.group(1)

  def test_a_filled_lock_file_is_installed_with_hashes_and_the_shipped_one_is_not(self):
    condition = self.lock_condition()
    self.assertTrue(condition.endswith(" /app/requirements.lock"))

    def names_packages(path):
      # The Dockerfile's own test, run on a file here.
      command = condition.replace("/app/requirements.lock", "'%s'" % path)
      return subprocess.run(["sh", "-c", command], check=False).returncode == 0

    self.assertFalse(names_packages(os.path.join(HERE, "requirements.lock")),
                     "requirements.lock as shipped must hold comments only")
    with tempfile.TemporaryDirectory() as directory:
      samples = {
          "comments.lock": "# a comment\n\n   # another\n",
          "empty.lock": "",
          "filled.lock": "# made by pip-compile\ngoogle-adk==2.15.0 \\\n    --hash=sha256:" + "0" * 64 + "\n",
      }
      results = {}
      for name, content in samples.items():
        path = os.path.join(directory, name)
        with open(path, "w", encoding="utf-8") as sample:
          sample.write(content)
        results[name] = names_packages(path)
    self.assertEqual(results, {"comments.lock": False, "empty.lock": False, "filled.lock": True})


class FakeModules:
  """Stand-ins for the ADK and Starlette modules build_app() imports."""

  def __init__(self):
    self.calls = []
    self.saved = {}

  def install(self):
    def get_fast_api_app(**settings):
      self.calls.append(settings)
      return types.SimpleNamespace(router=types.SimpleNamespace(routes=["a route of ADK"]))

    modules = {
        "google": types.ModuleType("google"),
        "google.adk": types.ModuleType("google.adk"),
        "google.adk.cli": types.ModuleType("google.adk.cli"),
        "google.adk.cli.fast_api": types.ModuleType("google.adk.cli.fast_api"),
        "starlette": types.ModuleType("starlette"),
        "starlette.responses": types.ModuleType("starlette.responses"),
        "starlette.routing": types.ModuleType("starlette.routing"),
    }
    modules["google.adk.cli.fast_api"].get_fast_api_app = get_fast_api_app
    modules["starlette.responses"].PlainTextResponse = lambda text: text
    modules["starlette.routing"].Route = lambda path, endpoint, methods: (path, tuple(methods))
    for name, module in modules.items():
      self.saved[name] = sys.modules.get(name)
      sys.modules[name] = module

  def remove(self):
    for name, module in self.saved.items():
      if module is None:
        sys.modules.pop(name, None)
      else:
        sys.modules[name] = module


class BuildAppTest(unittest.TestCase):

  def setUp(self):
    self.fakes = FakeModules()
    self.fakes.install()
    self.addCleanup(self.fakes.remove)
    saved = os.environ.get("ADK_WEB_UI")

    def restore():
      if saved is None:
        os.environ.pop("ADK_WEB_UI", None)
      else:
        os.environ["ADK_WEB_UI"] = saved

    self.addCleanup(restore)

  def build(self, setting):
    os.environ.pop("ADK_WEB_UI", None)
    if setting is not None:
      os.environ["ADK_WEB_UI"] = setting
    app = server.build_app()
    return app, self.fakes.calls[-1]

  def test_the_developer_server_is_off_unless_asked_for(self):
    for setting in (None, "", "false", "0", "no", "off", "anything else"):
      _, settings = self.build(setting)
      self.assertEqual(settings, {"agents_dir": server.AGENTS_DIR, "web": False}, setting)
    for setting in ("true", "1", "TRUE", " yes "):
      _, settings = self.build(setting)
      self.assertIs(settings["web"], True, setting)

  def test_the_readiness_endpoint_comes_first(self):
    app, _ = self.build(None)
    self.assertEqual(app.router.routes, [("/readyz", ("GET",)), "a route of ADK"])


if __name__ == "__main__":
  unittest.main(verbosity=2)
