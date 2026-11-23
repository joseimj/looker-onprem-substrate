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

"""Local test for gateway.py. Standard library plus the `openssl` CLI only.

It stands in for atenet-router with a small HTTPS server that *requires* a
client certificate, starts the real gateway as a subprocess, and checks what
the gateway sends upstream and what it returns to the caller.

Run:  python3 test_gateway.py
"""

import base64
import contextlib
import hashlib
import http.client
import http.server
import json
import logging
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gateway  # pylint: disable=wrong-import-position

SERVER_NAME = "atenet-router.ate-system.svc"
TARGET_ACTOR = "looker-agent/looker-agent"
# Shaped like the requests the Looker extension sends.
SESSIONS_PATH = "/apps/looker_app/users/looker-42/sessions"
SESSION = "3f6c9a1e-0b7d-4c55-9d3e-1a2b3c4d5e6f"
ARTIFACT_PATH = SESSIONS_PATH + "/" + SESSION + "/artifacts/dashboard_12.png"
# Made-up credentials for the gateway that the tests start. Nothing real.
# The gateway refuses passwords shorter than 16 characters.
USER, PASSWORD = "agent", "s3cret-pass-of-the-administrator"
CHAT_USER, CHAT_PASSWORD = "looker-chat", "chat-pass-kept-in-looker"
LOOKER_ORIGIN = "https://looker.example.com"
MAX_JOB_WAIT = 2.0
MAX_RUNNING_JOBS = 3
MAX_CHAT_RUNNING_JOBS = 2
HEAD_TIMEOUT = 2.0
MAX_JOB_RESPONSE_BYTES = 65536
MAX_REQUEST_BYTES = 2 * 1024 * 1024
MAX_CHAT_REQUEST_BYTES = 4096
# Room for two answers of the largest size, not for three.
MAX_STORED_JOB_BYTES = 2 * MAX_JOB_RESPONSE_BYTES
TOKEN_TTL = 600


def run_body(text, **changes):
  """The body of a chat's POST /run, as the Looker extension sends it."""
  request = {
      "appName": "looker_app", "userId": "looker-42", "sessionId": SESSION,
      "newMessage": {"role": "user", "parts": [{"text": text}]}, "streaming": False,
  }
  request.update(changes)
  return json.dumps(request).encode()


def basic(user, password):
  return "Basic " + base64.b64encode(("%s:%s" % (user, password)).encode()).decode()


# Answers of an agent that says two things about where its answer ends, or
# nothing that can be used. Written to the socket as they are.
FORGED = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 6\r\n\r\nFORGED"
FRAMING = {
    "two-lengths": (b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n"
                    b"Content-Length: 44\r\n\r\nhello" + FORGED),
    "length-that-is-no-number": (b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                                 b"Content-Length: 5x\r\n\r\nhello" + FORGED),
    "length-and-chunks": (b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                          b"Transfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n"
                          b"5\r\nhello\r\n%x\r\n" % len(FORGED) + FORGED + b"\r\n0\r\n\r\n"),
    "another-coding": (b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                       b"Transfer-Encoding: gzip, chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"),
    "interim-status": (b"HTTP/1.1 103 Early Hints\r\nLink: </x>; rel=preload\r\n\r\n"
                       b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"),
    "line-that-is-no-header": (b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX Y: z\r\n"
                               b"Content-Length: 5\r\n\r\nhello" + FORGED),
    "folded-line": (b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-Folded: a\r\n b\r\n"
                    b"Content-Length: 5\r\n\r\nhello"),
}
SEVERAL_PARTS = b"--x\r\nContent-Type: text/plain\r\n\r\none\r\n--x--\r\n"
# JSON that a parser reads without trouble and would not write the same way.
ODD_JSON = b'{"b" :1.0,  "a":"\\u00e9", "list":[1,2 ,3]}'
# Nested deeper than Python's JSON reader goes.
DEEP_JSON = b"[" * 30000 + b"]" * 30000


def start_router(directory):
  """Starts the stand-in for atenet-router on a free port.

  It serves HTTPS with the certificate in `directory` and admits only clients
  that present one of the same CA, as the router does.
  """
  context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
  context.load_cert_chain(
      os.path.join(directory, "server.pem"), os.path.join(directory, "server.key"))
  context.load_verify_locations(os.path.join(directory, "ca.pem"))
  context.verify_mode = ssl.CERT_REQUIRED
  router = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeRouterHandler)
  router.daemon_threads = True
  router.socket = context.wrap_socket(router.socket, server_side=True)
  threading.Thread(target=router.serve_forever, daemon=True).start()
  return router


def gateway_environment(directory, router_port, settings):
  """The environment of a gateway that talks to the stand-in router.

  `directory` holds ca.pem and credential-bundle.pem. A setting that is None
  is left out, also when the environment of the tests has it.
  """
  environment = dict(
      os.environ, ROUTER_HOST="127.0.0.1", ROUTER_PORT=str(router_port),
      ROUTER_SERVER_NAME=SERVER_NAME, ROUTER_CA_FILE=os.path.join(directory, "ca.pem"),
      CLIENT_CRED_BUNDLE=os.path.join(directory, "credential-bundle.pem"),
      TARGET_ACTOR=TARGET_ACTOR, LISTEN_HOST="127.0.0.1")
  environment.update(settings)
  return {name: value for name, value in environment.items() if value is not None}


class GatewayProcess:
  """The real gateway as a subprocess, on free ports, with the settings given."""

  def __init__(self, directory, router_port, **settings):
    self.port = free_port()
    self.health_port = free_port()
    settings = dict(
        {"LISTEN_PORT": str(self.port), "HEALTH_PORT": str(self.health_port)}, **settings)
    # The gateway's log goes to a file, not to a pipe. Nothing here reads a
    # pipe, and once a pipe is full a gateway that cannot write its log stops
    # answering: the tests would hang instead of failing.
    self._log = tempfile.NamedTemporaryFile(
        prefix="gateway-", suffix=".log", dir=directory, delete=False)
    self.process = subprocess.Popen(
        [sys.executable, os.path.join(HERE, "gateway.py")],
        env=gateway_environment(directory, router_port, settings),
        stdout=self._log, stderr=subprocess.STDOUT)
    deadline = time.time() + 10
    while time.time() < deadline and self.process.poll() is None:
      try:
        # It is up once it takes connections. Not a request: the port may speak TLS.
        socket.create_connection(("127.0.0.1", self.port), timeout=1).close()
        return
      except OSError:
        time.sleep(0.05)
    self.stop()
    raise RuntimeError("gateway did not start; the end of its log:\n" + self.log()[-4000:])

  def log(self):
    with open(self._log.name, "rb") as log:
      return log.read().decode("utf-8", "replace")

  def stop(self):
    self.process.terminate()
    try:
      self.process.wait(timeout=5)
    except subprocess.TimeoutExpired:
      self.process.kill()
      self.process.wait(timeout=5)
    self._log.close()


def gateway_exit(directory, router_port, **settings):
  """Starts a gateway that is expected to give up, and returns (exit code, log)."""
  settings = dict({"LISTEN_PORT": str(free_port()), "HEALTH_PORT": "0"}, **settings)
  done = subprocess.run(
      [sys.executable, os.path.join(HERE, "gateway.py")],
      env=gateway_environment(directory, router_port, settings),
      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20, check=False)
  return done.returncode, done.stdout.decode("utf-8", "replace")


def read_until_closed(sock, timeout=5.0):
  """Everything the other side sends until it ends the connection, and whether it did."""
  sock.settimeout(timeout)
  received = b""
  while True:
    try:
      chunk = sock.recv(65536)
    except socket.timeout:
      return received, False
    except ConnectionError:
      return received, True
    if not chunk:
      return received, True
    received += chunk


def _run(*args, cwd):
  subprocess.run(args, cwd=cwd, check=True, capture_output=True)


def _make_key_and_csr(directory, name):
  _run("openssl", "req", "-newkey", "ec", "-pkeyopt",
       "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", name + ".key",
       "-out", name + ".csr", "-subj", "/CN=" + name, cwd=directory)


def _sign(directory, name, extensions):
  ext_path = os.path.join(directory, name + ".ext")
  with open(ext_path, "w", encoding="utf-8") as ext_file:
    ext_file.write(extensions)
  _run("openssl", "x509", "-req", "-in", name + ".csr", "-CA", "ca.pem",
       "-CAkey", "ca.key", "-CAcreateserial", "-out", name + ".pem", "-days",
       "2", "-extfile", ext_path, cwd=directory)


def make_ca(directory):
  _run("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
       "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "ca.key", "-out",
       "ca.pem", "-subj", "/CN=test-ca", "-days", "2", "-addext",
       "basicConstraints=critical,CA:TRUE", "-addext",
       "keyUsage=critical,keyCertSign,cRLSign", cwd=directory)


def make_server_cert(directory):
  _make_key_and_csr(directory, "server")
  _sign(directory, "server",
        "subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n" % SERVER_NAME)


def make_client_bundle(directory, name, spiffe_id):
  """Writes <name>-bundle.pem holding the certificate and its key, like a podCertificate bundle."""
  _make_key_and_csr(directory, name)
  _sign(directory, name,
        "subjectAltName=URI:%s\nextendedKeyUsage=clientAuth\n" % spiffe_id)
  bundle = os.path.join(directory, name + "-bundle.pem")
  with open(bundle, "w", encoding="utf-8") as out:
    for part in (name + ".pem", name + ".key"):
      with open(os.path.join(directory, part), encoding="utf-8") as source:
        out.write(source.read())
  return bundle


class FakeRouterHandler(http.server.BaseHTTPRequestHandler):
  protocol_version = "HTTP/1.1"

  def log_message(self, format, *args):  # pylint: disable=redefined-builtin
    pass

  def _peer_uris(self):
    certificate = self.connection.getpeercert() or {}
    return [value for kind, value in certificate.get("subjectAltName", ()) if kind == "URI"]

  def _send(self, status, content_type, payload, extra_headers=None):
    self.send_response(status)
    self.send_header("Content-Type", content_type)
    self.send_header("Content-Length", str(len(payload)))
    for name, value in (extra_headers or {}).items():
      self.send_header(name, value)
    self.end_headers()
    if self.command != "HEAD":
      self.wfile.write(payload)

  def _handle(self):
    length = int(self.headers.get("Content-Length", "0"))
    body = self.rfile.read(length) if length else b""
    split = urllib.parse.urlsplit(self.path)
    query = urllib.parse.parse_qs(split.query)
    if self.path == "/sse":
      self.send_response(200)
      self.send_header("Content-Type", "text/event-stream")
      self.send_header("Transfer-Encoding", "chunked")
      self.end_headers()
      for index in range(3):
        event = ("data: event-%d\n\n" % index).encode()
        self.wfile.write(b"%x\r\n%s\r\n" % (len(event), event))
        self.wfile.flush()
        time.sleep(0.4)
      self.wfile.write(b"0\r\n\r\n")
      return
    if self.path == "/nocontent":
      self.send_response(204)
      self.end_headers()
      return
    if self.path == "/close-delimited":
      self.send_response(200)
      self.send_header("Content-Type", "text/plain")
      self.send_header("Connection", "close")
      self.end_headers()
      self.wfile.write(b"until-close")
      self.close_connection = True
      return
    if split.path.startswith("/status/"):
      self._send(int(split.path.rsplit("/", 1)[1]), "application/json",
                 json.dumps({"detail": "Session not found"}).encode())
      return
    if split.path == "/big":
      self._send(200, "text/plain", b"x" * int(query["size"][0]))
      return
    if split.path == "/not-json":
      self._send(200, "application/json", b"{broken")
      return
    if split.path == "/broken":
      # Announces more than it sends, then hangs up.
      self.send_response(200)
      self.send_header("Content-Type", "application/json")
      self.send_header("Content-Length", "1000")
      self.end_headers()
      self.wfile.write(b'{"partial":')
      self.wfile.flush()
      self.close_connection = True
      return
    if split.path == "/slow":
      time.sleep(float(query["seconds"][0]))
    if split.path == "/trickle":
      # A byte every 0.3 s: never silent for long, and not finished for a while.
      self.send_response(200)
      self.send_header("Content-Type", "text/plain")
      self.send_header("Transfer-Encoding", "chunked")
      self.end_headers()
      until = time.monotonic() + float(query["seconds"][0])
      try:
        while time.monotonic() < until:
          self.wfile.write(b"1\r\n.\r\n")
          self.wfile.flush()
          time.sleep(0.3)
        self.wfile.write(b"0\r\n\r\n")
      except OSError:
        pass  # the gateway hung up
      self.close_connection = True
      return
    if split.path.startswith("/framing/"):
      self.wfile.write(FRAMING[split.path[len("/framing/"):]])
      self.wfile.flush()
      self.close_connection = True
      return
    if split.path == "/several-parts":
      self._send(200, "multipart/mixed; boundary=x", SEVERAL_PARTS)
      return
    if split.path == "/odd-json":
      self._send(200, "application/json", ODD_JSON)
      return
    if split.path == "/deep-json":
      self._send(200, "application/json", DEEP_JSON)
      return
    if split.path == "/nan-json":
      self._send(200, "application/json", b'{"value": NaN}')
      return
    if split.path == "/run" and body.startswith(b"{"):
      # The one agent path a chat may start a job for. What it writes to the
      # agent says how this stand-in behaves: "sleep 1.5" takes that long.
      try:
        text = json.loads(body)["newMessage"]["parts"][0]["text"]
      except (ValueError, KeyError, IndexError, TypeError):
        text = ""
      if text.startswith("sleep "):
        time.sleep(float(text.split()[1]))
    payload = json.dumps({
        "method": self.command,
        "path": self.path,
        "headers": [[name, value] for name, value in self.headers.items()],
        "body_length": len(body),
        "body_sha256": hashlib.sha256(body).hexdigest(),
        "body_text": body.decode("utf-8", "replace") if len(body) <= 16384 else None,
        "peer_uris": self._peer_uris(),
    }).encode()
    self._send(200, "application/json", payload, {
        "X-Upstream": "fake-router",
        # An agent that tries to open itself to every site. The gateway decides.
        "Access-Control-Allow-Origin": "*",
        # And one that tries to leave something with the caller's browser, and
        # to speak where the gateway speaks.
        "Set-Cookie": "sid=from-the-agent; Path=/",
        "Cache-Control": "public, max-age=3600",
        "X-Content-Type-Options": "from-the-agent",
    })

  do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_PATCH = do_OPTIONS = _handle  # pylint: disable=invalid-name


def free_port():
  with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    return probe.getsockname()[1]


class GatewayTest(unittest.TestCase):

  @classmethod
  def setUpClass(cls):
    cls.tmp = tempfile.TemporaryDirectory()
    directory = cls.tmp.name
    make_ca(directory)
    make_server_cert(directory)
    cls.first_id = "spiffe://cluster.local/ns/looker-agent/sa/looker-agent-gateway"
    first_bundle = make_client_bundle(directory, "client", cls.first_id)
    # The gateway reads this path; the rotation test overwrites it in place.
    cls.live_bundle = os.path.join(directory, "credential-bundle.pem")
    with open(first_bundle, encoding="utf-8") as source, open(
        cls.live_bundle, "w", encoding="utf-8") as out:
      out.write(source.read())
    cls.ca = os.path.join(directory, "ca.pem")

    cls.router = start_router(directory)
    cls.router_port = cls.router.server_address[1]
    cls.process = GatewayProcess(
        directory, cls.router_port,
        BASIC_AUTH_USER=USER, BASIC_AUTH_PASSWORD=PASSWORD,
        CHAT_AUTH_USER=CHAT_USER, CHAT_AUTH_PASSWORD=CHAT_PASSWORD,
        UPSTREAM_TIMEOUT_SECONDS="10",
        CORS_ALLOWED_ORIGINS=LOOKER_ORIGIN + "/",
        HEAD_TIMEOUT_SECONDS=str(HEAD_TIMEOUT),
        MAX_JOB_WAIT_SECONDS=str(MAX_JOB_WAIT),
        MAX_RUNNING_JOBS=str(MAX_RUNNING_JOBS),
        MAX_CHAT_RUNNING_JOBS=str(MAX_CHAT_RUNNING_JOBS),
        MAX_JOB_RESPONSE_BYTES=str(MAX_JOB_RESPONSE_BYTES),
        MAX_REQUEST_BYTES=str(MAX_REQUEST_BYTES),
        MAX_CHAT_REQUEST_BYTES=str(MAX_CHAT_REQUEST_BYTES),
        MAX_STORED_JOB_BYTES=str(MAX_STORED_JOB_BYTES),
        TOKEN_TTL_SECONDS=str(TOKEN_TTL))
    cls.gateway_port = cls.process.port

  @classmethod
  def tearDownClass(cls):
    cls.process.stop()
    cls.router.shutdown()
    cls.router.server_close()
    cls.tmp.cleanup()

  def auth_header(self, user=USER, password=PASSWORD):
    token = base64.b64encode(("%s:%s" % (user, password)).encode()).decode()
    return {"Authorization": "Basic " + token}

  def request(self, method, path, headers=None, body=None, authenticated=True):
    all_headers = dict(self.auth_header()) if authenticated else {}
    all_headers.update(headers or {})
    connection = http.client.HTTPConnection("127.0.0.1", self.gateway_port, timeout=15)
    connection.request(method, path, body=body, headers=all_headers)
    response = connection.getresponse()
    data = response.read()
    connection.close()
    return response, data

  def upstream_headers(self, echoed):
    return {name.lower(): value for name, value in echoed["headers"]}

  # --- helpers for the job API ----------------------------------------------
  @staticmethod
  def _json(data):
    try:
      return json.loads(data)
    except ValueError:
      return None

  def start_job(self, agent_path, body=b"{}", headers=None, **kwargs):
    all_headers = {"Content-Type": "application/json"}
    all_headers.update(headers or {})
    response, data = self.request(
        "POST", "/_gateway/jobs" + agent_path, body=body, headers=all_headers, **kwargs)
    return response, self._json(data)

  def poll_job(self, job_id, wait=None, **kwargs):
    path = "/_gateway/jobs/" + job_id
    if wait is not None:
      path += "?wait=%s" % wait
    response, data = self.request("GET", path, **kwargs)
    return response, self._json(data)

  def finished_job(self, job_id, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
      response, view = self.poll_job(job_id, wait=MAX_JOB_WAIT)
      self.assertEqual(response.status, 200)
      if view["status"] != "running":
        return view
    self.fail("job did not finish")

  def bearer_token(self, credential=None):
    response, data = self.request(
        "POST", "/_gateway/token", headers=credential or self.auth_header(),
        authenticated=False)
    self.assertEqual(response.status, 200)
    return json.loads(data)

  def chat_header(self):
    return self.auth_header(CHAT_USER, CHAT_PASSWORD)

  def confined_callers(self):
    """The chat credential, and tokens bought with either credential."""
    return {
        "chat credential": self.chat_header(),
        "token bought by the chat credential": {
            "Authorization": "Bearer " + self.bearer_token(self.chat_header())["access_token"]},
        "token bought by the administrator": {
            "Authorization": "Bearer " + self.bearer_token()["access_token"]},
    }

  # --- forwarding -------------------------------------------------------------
  def test_healthz_needs_no_credentials(self):
    response, data = self.request("GET", "/healthz", authenticated=False)
    self.assertEqual(response.status, 200)
    self.assertEqual(data, b"ok\n")

  def test_missing_or_wrong_credentials_are_refused(self):
    response, _ = self.request("GET", "/list-apps", authenticated=False)
    self.assertEqual(response.status, 401)
    self.assertIn("Basic", response.getheader("WWW-Authenticate"))
    response, _ = self.request(
        "GET", "/list-apps", headers=self.auth_header(password="wrong"), authenticated=False)
    self.assertEqual(response.status, 401)
    response, _ = self.request(
        "GET", "/list-apps", headers={"Authorization": "Bearer abc"}, authenticated=False)
    self.assertEqual(response.status, 401)

  def test_request_reaches_router_with_client_certificate_and_routing_header(self):
    response, data = self.request("GET", "/list-apps?x=1")
    self.assertEqual(response.status, 200)
    self.assertEqual(response.getheader("X-Upstream"), "fake-router")
    echoed = json.loads(data)
    self.assertEqual(echoed["path"], "/list-apps?x=1")
    headers = self.upstream_headers(echoed)
    self.assertEqual(headers["ate-target-actor"], TARGET_ACTOR)
    # The router saw the gateway's own identity.
    self.assertEqual(echoed["peer_uris"], [self.first_id])
    self.assertIn("x-forwarded-for", headers)

  def test_gateway_credential_is_not_forwarded_to_the_actor(self):
    _, data = self.request("GET", "/echo")
    self.assertNotIn("authorization", self.upstream_headers(json.loads(data)))

  def test_caller_cannot_choose_the_actor(self):
    _, data = self.request("GET", "/echo", headers={"ate-target-actor": "other/actor"})
    echoed = json.loads(data)
    values = [value for name, value in echoed["headers"] if name.lower() == "ate-target-actor"]
    self.assertEqual(values, [TARGET_ACTOR])

  def test_post_body_is_relayed_intact(self):
    body = os.urandom(1024 * 1024)
    response, data = self.request(
        "POST", "/run", body=body, headers={"Content-Type": "application/octet-stream"})
    self.assertEqual(response.status, 200)
    echoed = json.loads(data)
    self.assertEqual(echoed["method"], "POST")
    self.assertEqual(echoed["body_length"], len(body))
    self.assertEqual(echoed["body_sha256"], hashlib.sha256(body).hexdigest())

  def test_streamed_response_arrives_incrementally(self):
    connection = http.client.HTTPConnection("127.0.0.1", self.gateway_port, timeout=15)
    connection.request("GET", "/sse", headers=self.auth_header())
    response = connection.getresponse()
    self.assertEqual(response.status, 200)
    self.assertEqual(response.getheader("Content-Type"), "text/event-stream")
    arrivals, received = [], b""
    while True:
      chunk = response.read1(65536)
      if not chunk:
        break
      arrivals.append(time.monotonic())
      received += chunk
    connection.close()
    self.assertEqual(received, b"data: event-0\n\ndata: event-1\n\ndata: event-2\n\n")
    # The upstream spaces events 0.4s apart. If the gateway buffered the whole
    # response, every chunk would arrive at the same instant.
    self.assertGreaterEqual(len(arrivals), 3)
    self.assertGreater(arrivals[-1] - arrivals[0], 0.5)

  def test_no_content_and_head_have_no_body(self):
    response, data = self.request("GET", "/nocontent")
    self.assertEqual((response.status, data), (204, b""))
    response, data = self.request("HEAD", "/echo")
    self.assertEqual((response.status, data), (200, b""))

  def test_close_delimited_upstream_body_is_relayed(self):
    response, data = self.request("GET", "/close-delimited")
    self.assertEqual((response.status, data), (200, b"until-close"))

  def test_unsupported_requests_are_rejected_before_forwarding(self):
    response, _ = self.request(
        "GET", "/run_live", headers={"Connection": "Upgrade", "Upgrade": "websocket"})
    self.assertEqual(response.status, 501)

  def raw_request(self, head, payload=b""):
    """Sends bytes as they are; http.client would tidy them up."""
    connection = http.client.HTTPConnection("127.0.0.1", self.gateway_port, timeout=15)
    connection.connect()
    lines = [head, "Host: gateway.test", "Authorization: " + self.auth_header()["Authorization"]]
    connection.sock.sendall(("\r\n".join(lines)).encode("latin-1") + payload)
    # Nothing more will be sent. A gateway that waits for the rest of a body
    # that never comes sees the end of the stream instead of hanging.
    connection.sock.shutdown(socket.SHUT_WR)
    response = http.client.HTTPResponse(connection.sock, method=head.split(" ", 1)[0])
    response.begin()
    data = response.read()
    response.close()
    connection.close()
    return response, data

  def test_chunked_request_body_is_put_together_and_forwarded_with_a_length(self):
    parts = [b"{\"appName\":", b" \"looker_app\", \"padding\": \"", b"x" * 70000, b"\"}"]
    chunked = b"".join(b"%x;note=ignored\r\n%s\r\n" % (len(part), part) for part in parts)
    chunked += b"0\r\nX-Trailer: dropped\r\n\r\n"
    whole = b"".join(parts)
    for path in ("/run", "/_gateway/jobs/run"):
      response, data = self.raw_request(
          "POST %s HTTP/1.1\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked" % path,
          b"\r\n\r\n" + chunked)
      if path == "/run":
        self.assertEqual(response.status, 200)
        echoed = json.loads(data)
      else:
        self.assertEqual(response.status, 202)
        echoed = self.finished_job(json.loads(data)["id"])["json"]
      self.assertEqual(echoed["body_length"], len(whole), path)
      self.assertEqual(echoed["body_sha256"], hashlib.sha256(whole).hexdigest(), path)
      headers = self.upstream_headers(echoed)
      # The agent gets one plain body: a length, no chunking, no trailer.
      self.assertEqual(headers["content-length"], str(len(whole)))
      self.assertNotIn("transfer-encoding", headers)
      self.assertNotIn("x-trailer", headers)

  def test_request_bodies_that_cannot_be_delimited_safely_are_refused(self):
    head = "POST /run HTTP/1.1\r\nTransfer-Encoding: %s"
    cases = {
        # Two statements about where the body ends.
        "chunked and a length": (head % "chunked" + "\r\nContent-Length: 5", b"\r\n\r\n5\r\nhello\r\n0\r\n\r\n"),
        "another coding": (head % "gzip, chunked", b"\r\n\r\n5\r\nhello\r\n0\r\n\r\n"),
        "size is not hex": (head % "chunked", b"\r\n\r\nfive\r\nhello\r\n0\r\n\r\n"),
        "size with a sign": (head % "chunked", b"\r\n\r\n+5\r\nhello\r\n0\r\n\r\n"),
        "size with a prefix": (head % "chunked", b"\r\n\r\n0x5\r\nhello\r\n0\r\n\r\n"),
        "chunk longer than announced": (head % "chunked", b"\r\n\r\n2\r\nhello\r\n0\r\n\r\n"),
        # Everything after it is well-formed, so only the check of these two
        # bytes can notice.
        "chunk not followed by a line end": (head % "chunked", b"\r\n\r\n5\r\nhelloXX0\r\n\r\n"),
        "no last chunk": (head % "chunked", b"\r\n\r\n5\r\nhello\r\n"),
        # A length has to be plain digits, and there has to be exactly one.
        "length with a sign": ("POST /run HTTP/1.1\r\nContent-Length: +5", b"\r\n\r\nhello"),
        "length with an underscore": ("POST /run HTTP/1.1\r\nContent-Length: 1_0", b"\r\n\r\nhellohello"),
        "length in hex": ("POST /run HTTP/1.1\r\nContent-Length: 0x5", b"\r\n\r\nhello"),
        "negative length": ("POST /run HTTP/1.1\r\nContent-Length: -1", b"\r\n\r\n"),
        "the same length twice": (
            "POST /run HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5", b"\r\n\r\nhello"),
        "chunked twice": (
            "POST /run HTTP/1.1\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked",
            b"\r\n\r\n5\r\nhello\r\n0\r\n\r\n"),
    }
    for name, (request_head, payload) in cases.items():
      with self.subTest(name=name):
        response, data = self.raw_request(request_head, payload)
        self.assertEqual(response.status, 400)
        self.assertNotIn(b"peer_uris", data)
    # More than the gateway accepts: refused as soon as the sizes add up to
    # it, without reading the rest.
    too_much = b"%x\r\n" % (MAX_REQUEST_BYTES + 1)
    response, data = self.raw_request(head % "chunked", b"\r\n\r\n" + too_much)
    self.assertEqual(response.status, 413)
    self.assertNotIn(b"peer_uris", data)

  def exchange_until_closed(self, raw):
    """Sends bytes and returns all the gateway sends until it closes the connection."""
    with socket.create_connection(("127.0.0.1", self.gateway_port), timeout=5) as sock:
      sock.sendall(raw)
      received = b""
      while True:
        try:
          chunk = sock.recv(65536)
        except socket.timeout:
          self.fail("the gateway left the connection open; it sent %r" % received[:400])
        if not chunk:
          return received
        received += chunk

  def test_an_answer_given_before_the_body_is_read_ends_the_connection(self):
    """Unread body bytes would otherwise be taken for the caller's next request.

    Each case sends a request the gateway answers without reading the body,
    with a second, valid request as that body. Exactly one answer may come
    back, and the second request must never reach the agent.
    """
    admin = self.auth_header()["Authorization"]
    chat = self.chat_header()["Authorization"]
    hidden = ("GET /echo HTTP/1.1\r\nHost: x\r\nAuthorization: %s\r\n\r\n" % admin).encode()
    length = "Content-Length: %d" % len(hidden)
    cases = {
        "no credentials": (401, ["POST /run HTTP/1.1", length]),
        # "wrong:wrong" in base64.
        "wrong password": (401, ["POST /run HTTP/1.1", "Authorization: Basic d3Jvbmc6d3Jvbmc=", length]),
        "no credentials, body in chunks": (401, ["POST /run HTTP/1.1", "Transfer-Encoding: chunked"]),
        "chat credential on a path it may not use": (
            403, ["POST /list-apps HTTP/1.1", "Authorization: " + chat, length]),
        "protocol upgrade": (
            501, ["POST /run_live HTTP/1.1", "Authorization: " + admin, "Connection: Upgrade",
                  "Upgrade: websocket", length]),
        "health check with a body": (200, ["POST /healthz HTTP/1.1", length]),
        "preflight with a body": (
            204, ["OPTIONS /run HTTP/1.1", "Origin: " + LOOKER_ORIGIN,
                  "Access-Control-Request-Method: POST", length]),
        "refused preflight with a body": (
            403, ["OPTIONS /run HTTP/1.1", "Origin: https://evil.example.com",
                  "Access-Control-Request-Method: POST", length]),
        "body too large for the chat credential": (
            413, ["POST /_gateway/jobs/run HTTP/1.1", "Authorization: " + chat,
                  "Content-Type: application/json",
                  "Content-Length: %d" % (MAX_CHAT_REQUEST_BYTES + 1)]),
        # One reader takes the first length, another the second.
        "two different lengths": (
            400, ["POST /run HTTP/1.1", "Authorization: " + admin, "Content-Length: 0", length]),
        # Malformed although both say "no body". What follows is then a
        # request of its own by any reading, but after a head like this the
        # gateway does not go on with the connection.
        "the same zero length twice": (
            401, ["POST /run HTTP/1.1", "Content-Length: 0", "Content-Length: 0"]),
    }
    for name, (status, lines) in cases.items():
      with self.subTest(name=name):
        head = "\r\n".join(lines + ["Host: gateway.test", "", ""]).encode()
        received = self.exchange_until_closed(head + hidden)
        answers = re.findall(rb"(?m)^HTTP/1\.[01] (\d{3}) ", received)
        self.assertEqual(answers, [b"%d" % status], received[:400])
        self.assertIn(b"\r\nconnection: close\r\n", received.lower())
        self.assertNotIn(b"peer_uris", received)

  def test_a_refusal_does_not_wait_for_the_body(self):
    """A caller who may not send a body cannot make the gateway wait for one."""
    chat = self.chat_header()["Authorization"]
    cases = {
        "no credentials": (401, ["POST /run HTTP/1.1"]),
        "chat credential on a path it may not use": (
            403, ["POST /list-apps HTTP/1.1", "Authorization: " + chat]),
    }
    for name, (status, lines) in cases.items():
      with self.subTest(name=name):
        head = "\r\n".join(lines + ["Host: gateway.test", "Content-Length: 1000000", "", ""]).encode()
        started = time.monotonic()
        received = self.exchange_until_closed(head)  # the body is never sent
        self.assertTrue(received.startswith(b"HTTP/1.1 %d " % status), received[:200])
        self.assertLess(time.monotonic() - started, 3)

  def test_a_connection_is_kept_once_the_body_has_been_read(self):
    """The other half of the rule above: no needless reconnecting."""
    connection = http.client.HTTPConnection("127.0.0.1", self.gateway_port, timeout=15)
    headers = dict(self.auth_header(), **{"Content-Type": "application/json"})
    for method, path, body in (("POST", "/run", b'{"x": 1}'), ("GET", "/echo", None),
                               ("POST", "/_gateway/jobs/run", b"{}"),
                               ("GET", "/_gateway/jobs/no-such-job", None)):
      connection.request(method, path, body=body, headers=headers)
      response = connection.getresponse()
      response.read()
      self.assertNotEqual((response.getheader("Connection") or "").lower(), "close", (method, path))
      # http.client drops its socket when the server ends the connection.
      self.assertIsNotNone(connection.sock, (method, path))
    connection.close()

  def test_chat_credential_and_tokens_get_a_small_request_limit(self):
    big = run_body("x" * MAX_CHAT_REQUEST_BYTES)
    fits = run_body("x" * (MAX_CHAT_REQUEST_BYTES - 300))
    self.assertLess(len(fits), MAX_CHAT_REQUEST_BYTES)
    self.assertLess(len(big), MAX_REQUEST_BYTES)
    for who, credential in self.confined_callers().items():
      with self.subTest(who=who):
        response, _ = self.start_job("/run", body=big, headers=credential, authenticated=False)
        self.assertEqual(response.status, 413)
        response, view = self.start_job("/run", body=fits, headers=credential, authenticated=False)
        self.assertEqual(response.status, 202)
        self.assertEqual(self.finished_job(view["id"])["json"]["body_length"], len(fits))
        # The same limit when the body comes in chunks. (http.client sends
        # an iterable body chunked.)
        as_json = dict(credential, **{"Content-Type": "application/json"})
        response, _ = self.request(
            "POST", "/_gateway/jobs/run", headers=as_json,
            body=iter([big[:3000], big[3000:]]), authenticated=False)
        self.assertEqual(response.status, 413)
        response, data = self.request(
            "POST", "/_gateway/jobs/run", headers=as_json,
            body=iter([fits[:3000], fits[3000:]]), authenticated=False)
        self.assertEqual(response.status, 202)
        self.assertEqual(self.finished_job(json.loads(data)["id"])["json"]["body_length"], len(fits))
    # The administrator keeps the larger limit.
    response, view = self.start_job("/run", body=big)
    self.assertEqual(response.status, 202)
    self.assertEqual(self.finished_job(view["id"])["json"]["body_length"], len(big))

  def test_router_refuses_a_client_without_a_certificate(self):
    """A check on the fake itself: this is the wall the gateway gets callers past."""
    context = ssl.create_default_context(cafile=self.ca)
    with self.assertRaises((ssl.SSLError, ConnectionError, http.client.RemoteDisconnected)):
      connection = http.client.HTTPSConnection("127.0.0.1", self.router_port, context=context, timeout=5)
      connection._tunnel_host = None  # pylint: disable=protected-access
      connection.connect = lambda: _connect_with_name(connection, context)
      connection.request("GET", "/echo")
      connection.getresponse().read()

  # --- background jobs --------------------------------------------------------
  def test_job_answers_at_once_and_the_result_is_collected_later(self):
    body = json.dumps({"appName": "looker_app", "padding": "x" * 5000}).encode()
    started = time.monotonic()
    response, view = self.start_job("/slow?seconds=1.2", body=body)
    self.assertEqual(response.status, 202)
    self.assertLess(time.monotonic() - started, 0.8, "starting a job must not wait for the agent")
    self.assertEqual(view["status"], "running")
    job_id = view["id"]
    self.assertGreaterEqual(len(job_id), 32)

    response, view = self.poll_job(job_id)
    self.assertEqual((response.status, view), (200, {"id": job_id, "status": "running"}))

    view = self.finished_job(job_id)
    self.assertEqual(view["status"], "done")
    self.assertEqual(view["http_status"], 200)
    echoed = view["json"]
    # The agent got the POST the caller described, through the router.
    self.assertEqual(echoed["method"], "POST")
    self.assertEqual(echoed["path"], "/slow?seconds=1.2")
    self.assertEqual(echoed["body_sha256"], hashlib.sha256(body).hexdigest())
    self.assertEqual(echoed["peer_uris"], [self.first_id])
    headers = self.upstream_headers(echoed)
    self.assertEqual(headers["ate-target-actor"], TARGET_ACTOR)
    self.assertEqual(headers["content-type"], "application/json")
    self.assertNotIn("authorization", headers)

    # The answer stays available: a caller whose poll got lost can ask again.
    response, again = self.poll_job(job_id)
    self.assertEqual((response.status, again), (200, view))

  def test_waiting_poll_returns_as_soon_as_the_job_finishes(self):
    _, view = self.start_job("/slow?seconds=0.6")
    started = time.monotonic()
    response, view = self.poll_job(view["id"], wait=MAX_JOB_WAIT)
    elapsed = time.monotonic() - started
    self.assertEqual((response.status, view["status"]), (200, "done"))
    self.assertGreater(elapsed, 0.3)
    self.assertLess(elapsed, MAX_JOB_WAIT - 0.5)

  def test_wait_is_capped(self):
    _, view = self.start_job("/slow?seconds=4")
    job_id = view["id"]
    started = time.monotonic()
    response, view = self.poll_job(job_id, wait=600)
    elapsed = time.monotonic() - started
    self.assertEqual((response.status, view["status"]), (200, "running"))
    self.assertGreater(elapsed, MAX_JOB_WAIT - 0.3)
    self.assertLess(elapsed, MAX_JOB_WAIT + 1.5)
    self.assertEqual(self.finished_job(job_id)["status"], "done")
    for bad in ("soon", "nan", "inf"):
      response, _ = self.poll_job(job_id, wait=bad)
      self.assertEqual(response.status, 400, bad)

  def test_job_reports_an_http_error_from_the_agent_as_its_answer(self):
    _, view = self.start_job("/status/404")
    view = self.finished_job(view["id"])
    self.assertEqual((view["status"], view["http_status"]), ("done", 404))
    self.assertEqual(view["json"], {"detail": "Session not found"})

  def test_job_body_that_is_not_json_is_returned_as_text(self):
    _, view = self.start_job("/big?size=100")
    view = self.finished_job(view["id"])
    self.assertEqual(view["text"], "x" * 100)
    self.assertNotIn("json", view)
    _, view = self.start_job("/not-json")
    view = self.finished_job(view["id"])
    self.assertEqual(view["text"], "{broken")
    self.assertNotIn("json", view)

  def test_job_with_an_oversized_or_broken_answer_fails_cleanly(self):
    _, view = self.start_job("/big?size=%d" % (MAX_JOB_RESPONSE_BYTES + 1))
    view = self.finished_job(view["id"])
    self.assertEqual(view["status"], "failed")
    self.assertIn("MAX_JOB_RESPONSE_BYTES", view["error"])
    _, view = self.start_job("/big?size=%d" % MAX_JOB_RESPONSE_BYTES)
    self.assertEqual(self.finished_job(view["id"])["status"], "done")
    _, view = self.start_job("/broken")
    view = self.finished_job(view["id"])
    self.assertEqual(view["status"], "failed")
    self.assertIn("broke", view["error"])

  def test_kept_answers_are_limited_in_total_size(self):
    """At the running gateway, not only in the store on its own."""
    size = MAX_JOB_RESPONSE_BYTES - 5000  # two of these fit, three do not
    self.assertLessEqual(2 * size, MAX_STORED_JOB_BYTES)
    self.assertGreater(3 * size, MAX_STORED_JOB_BYTES)

    def finished(path):
      _, view = self.start_job(path)
      self.assertEqual(self.finished_job(view["id"])["status"], "done")
      return view["id"]

    first = finished("/big?size=%d" % size)
    second = finished("/big?size=%d" % size)
    response, view = self.poll_job(first)
    self.assertEqual((response.status, len(view["text"])), (200, size))
    third = finished("/big?size=%d" % size)
    # No room for three: the one that finished longest ago is forgotten.
    response, _ = self.poll_job(first)
    self.assertEqual(response.status, 404)
    for job_id in (second, third):
      response, view = self.poll_job(job_id)
      self.assertEqual((response.status, len(view["text"])), (200, size))

  def test_jobs_need_credentials(self):
    response, _ = self.start_job("/echo", authenticated=False)
    self.assertEqual(response.status, 401)
    _, view = self.start_job("/echo")
    response, _ = self.poll_job(view["id"], authenticated=False)
    self.assertEqual(response.status, 401)

  def test_unknown_job_and_bad_job_requests(self):
    response, view = self.poll_job("no-such-job")
    self.assertEqual(response.status, 404)
    self.assertIn("error", view)
    # A job must name an agent path, and cannot point back at the gateway.
    for path in ("/", "/_gateway/token", "/_gateway"):
      response, view = self.start_job(path)
      self.assertEqual(response.status, 400, path)
    response, _ = self.request("DELETE", "/_gateway/jobs/whatever")
    self.assertEqual(response.status, 405)
    response, _ = self.request("GET", "/_gateway/nothing-here")
    self.assertEqual(response.status, 404)

  def test_gateway_paths_are_never_forwarded(self):
    """A path under /_gateway/ must not reach the agent, known or not."""
    for method, path in (("GET", "/_gateway/nothing-here"), ("GET", "/_gateway"),
                         ("POST", "/_gateway/token")):
      response, data = self.request(method, path)
      self.assertIsNone(response.getheader("X-Upstream"), path)
      self.assertNotIn(b"peer_uris", data)

  def test_running_jobs_are_limited(self):
    views = [self.start_job("/slow?seconds=1.5")[1] for _ in range(MAX_RUNNING_JOBS)]
    response, view = self.start_job("/slow?seconds=1.5")
    self.assertEqual(response.status, 429)
    self.assertIn("error", view)
    self.assertTrue(response.getheader("Retry-After"))
    for started in views:
      self.assertEqual(self.finished_job(started["id"])["status"], "done")
    # Room again once they have finished.
    response, view = self.start_job("/echo")
    self.assertEqual(response.status, 202)
    self.finished_job(view["id"])

  # --- bearer tokens ----------------------------------------------------------
  def test_token_replaces_the_password_and_is_not_forwarded(self):
    granted = self.bearer_token()
    self.assertEqual(granted["token_type"], "Bearer")
    self.assertEqual(granted["expires_in"], TOKEN_TTL)
    self.assertNotIn(PASSWORD, granted["access_token"])
    bearer = {"Authorization": "Bearer " + granted["access_token"]}
    response, data = self.request("GET", ARTIFACT_PATH, headers=bearer, authenticated=False)
    self.assertEqual(response.status, 200)
    echoed = json.loads(data)
    self.assertEqual(echoed["path"], ARTIFACT_PATH)
    self.assertNotIn("authorization", self.upstream_headers(echoed))
    # It works for the job API too.
    response, view = self.start_job("/run", body=run_body("hello"), headers=bearer, authenticated=False)
    self.assertEqual(response.status, 202)
    response, view = self.poll_job(view["id"], wait=MAX_JOB_WAIT, headers=bearer, authenticated=False)
    self.assertEqual((response.status, view["status"]), (200, "done"))
    self.assertNotIn("authorization", self.upstream_headers(view["json"]))

  def test_token_endpoint_requires_the_password(self):
    response, _ = self.request("POST", "/_gateway/token", authenticated=False)
    self.assertEqual(response.status, 401)
    response, _ = self.request(
        "POST", "/_gateway/token", headers=self.auth_header(password="wrong"),
        authenticated=False)
    self.assertEqual(response.status, 401)
    # A token cannot be used to get another token.
    bearer = {"Authorization": "Bearer " + self.bearer_token()["access_token"]}
    response, _ = self.request("POST", "/_gateway/token", headers=bearer, authenticated=False)
    self.assertEqual(response.status, 401)
    response, _ = self.request("GET", "/_gateway/token")
    self.assertEqual(response.status, 405)

  def test_altered_tokens_are_refused(self):
    token = self.bearer_token()["access_token"]
    version, expires, nonce, signature = token.split(".")
    later = ".".join([version, str(int(expires) + 3600), nonce, signature])
    flipped = token[:-1] + ("A" if token[-1] != "A" else "B")
    response, _ = self.request(
        "GET", ARTIFACT_PATH, headers={"Authorization": "Bearer " + token}, authenticated=False)
    self.assertEqual(response.status, 200)
    for forged in (later, flipped, token + "x", "v1.9999999999.abc.def", "garbage", ""):
      response, _ = self.request(
          "GET", ARTIFACT_PATH, headers={"Authorization": "Bearer " + forged}, authenticated=False)
      self.assertEqual(response.status, 401, forged)

  # --- the chat credential ----------------------------------------------------
  def test_chat_credential_and_tokens_can_do_what_a_chat_needs(self):
    for who, credential in self.confined_callers().items():
      with self.subTest(who=who):
        response, view = self.start_job(
            "/apps/looker_app/users/looker-42/sessions", headers=credential, authenticated=False)
        self.assertEqual(response.status, 202)
        response, view = self.poll_job(
            view["id"], wait=MAX_JOB_WAIT, headers=credential, authenticated=False)
        self.assertEqual((response.status, view["status"]), (200, "done"))
        self.assertEqual(view["json"]["path"], "/apps/looker_app/users/looker-42/sessions")

        response, view = self.start_job(
            "/run", body=run_body("hello"), headers=credential, authenticated=False)
        self.assertEqual(response.status, 202)
        response, view = self.poll_job(view["id"], headers=credential, authenticated=False)
        self.assertEqual(response.status, 200)

        for path in (ARTIFACT_PATH, ARTIFACT_PATH + "?version=2",
                     ARTIFACT_PATH.replace("dashboard_12.png", "charts/dashboard_thelook::q1.png") + "?version=3"):
          response, data = self.request("GET", path, headers=credential, authenticated=False)
          self.assertEqual(response.status, 200, path)
          echoed = json.loads(data)
          self.assertEqual(echoed["path"], path)
          self.assertNotIn("authorization", self.upstream_headers(echoed))

  def test_chat_credential_and_tokens_cannot_reach_the_developer_api(self):
    session = "/apps/looker_app/users/looker-42/sessions"
    refused = [
        # ADK's developer API and UI.
        ("GET", "/list-apps"), ("GET", "/dev-ui/"), ("GET", "/"), ("GET", "/version"),
        ("GET", "/dev/apps/looker_app/debug/trace/session/s1"),
        ("POST", "/dev/apps/looker_app/tests/run"),
        ("GET", "/apps/looker_app/app-info"),
        # Other people's sessions: listing, reading, changing, deleting.
        ("GET", session), ("GET", session + "/s1"), ("DELETE", session + "/s1"),
        ("PATCH", session + "/s1"), ("POST", session + "/s1/rewind"),
        ("GET", session + "/s1/artifacts"), ("POST", session + "/s1/artifacts"),
        ("DELETE", ARTIFACT_PATH), ("HEAD", ARTIFACT_PATH), ("POST", ARTIFACT_PATH),
        # The agent directly, without a job.
        ("POST", "/run"), ("POST", "/run_sse"), ("POST", session),
        # Jobs for anything but a turn or a new session.
        ("POST", "/_gateway/jobs/run_sse"), ("POST", "/_gateway/jobs/list-apps"),
        ("POST", "/_gateway/jobs/apps/looker_app/users/looker-42/sessions/chosen-id"),
        ("POST", "/_gateway/jobs/dev/apps/looker_app/tests/run"),
        ("POST", "/_gateway/jobs/run?x=1"), ("DELETE", "/_gateway/jobs/some-id"),
        # An allowed path with something extra.
        ("GET", ARTIFACT_PATH + "?version=1&detailed=true"), ("GET", ARTIFACT_PATH + "?x=1"),
        # Paths another reader might resolve to something else.
        ("GET", ARTIFACT_PATH + "/../../../../../../../list-apps"),
        ("GET", session + "/s1/artifacts/../../../../../../list-apps"),
        ("GET", session + "/s1/artifacts/%2e%2e/%2e%2e/%2e%2e/%2e%2e/%2e%2e/%2e%2e/list-apps"),
        ("GET", session + "/s1/artifacts/%2E%2E%2F%2E%2E%2Flist-apps"),
        ("GET", session + "/s1/artifacts/%252e%252e/%252e%252e/list-apps"),
        ("GET", session + "/s1/artifacts/..%5C..%5Clist-apps"),
        ("GET", session + "/s1/artifacts/a//b"), ("GET", session + "/s1/artifacts/./a"),
        ("POST", "/_gateway/jobs/apps/looker_app/users/../sessions"),
        ("POST", "/_gateway/jobs/./run"),
    ]
    for who, credential in self.confined_callers().items():
      for method, path in refused:
        with self.subTest(who=who, method=method, path=path):
          response, data = self.request(
              method, path, headers=dict(credential, **{"Content-Type": "application/json"}),
              body=b"{}" if method in ("POST", "PATCH") else None, authenticated=False)
          self.assertEqual(response.status, 403)
          # Refused by the gateway itself: the agent never saw it.
          self.assertIsNone(response.getheader("X-Upstream"))
          self.assertNotIn(b"peer_uris", data)
    # Current Python versions fold leading slashes into one before the gateway
    # sees the path; older ones do not, and then the gateway refuses it. Either
    # is fine. What matters: the path that was checked is the path forwarded.
    response, data = self.request(
        "GET", "//apps/looker_app/users/u/sessions/s1/artifacts/a", headers=self.chat_header(),
        authenticated=False)
    self.assertIn(response.status, (200, 403))
    if response.status == 200:
      self.assertEqual(json.loads(data)["path"], "/apps/looker_app/users/u/sessions/s1/artifacts/a")
    response, data = self.request(
        "GET", "//list-apps", headers=self.chat_header(), authenticated=False)
    self.assertEqual(response.status, 403)
    # The administrator is not confined: the same requests go through.
    for method, path in (("GET", "/list-apps"), ("GET", session), ("DELETE", session + "/s1")):
      response, _ = self.request(method, path)
      self.assertEqual(response.getheader("X-Upstream"), "fake-router", (method, path))

  def test_request_targets_that_are_not_plain_paths_are_refused(self):
    """For the administrator too: such a target must never be passed on."""
    for who, credential in (("administrator", self.auth_header()), ("chat", self.chat_header())):
      for target in ("http://other.example/list-apps", "/caf\xe9", "*", "list-apps"):
        with self.subTest(who=who, target=target):
          connection = http.client.HTTPConnection("127.0.0.1", self.gateway_port, timeout=15)
          request = "GET %s HTTP/1.1\r\nHost: x\r\nAuthorization: %s\r\n\r\n" % (
              target, credential["Authorization"])
          connection.connect()
          connection.sock.sendall(request.encode("latin-1"))
          response = http.client.HTTPResponse(connection.sock, method="GET")
          response.begin()
          data = response.read()
          response.close()
          connection.close()
          self.assertEqual(response.status, 400)
          self.assertNotIn(b"peer_uris", data)

  # --- cross-origin callers ---------------------------------------------------
  def test_preflight_from_the_allowed_origin_is_answered_without_credentials(self):
    response, data = self.request(
        "OPTIONS", "/_gateway/jobs/run", authenticated=False,
        headers={"Origin": LOOKER_ORIGIN, "Access-Control-Request-Method": "POST",
                 "Access-Control-Request-Headers": "authorization,content-type"})
    self.assertEqual((response.status, data), (204, b""))
    self.assertEqual(response.getheader("Access-Control-Allow-Origin"), LOOKER_ORIGIN)
    self.assertIn("POST", response.getheader("Access-Control-Allow-Methods"))
    allowed = response.getheader("Access-Control-Allow-Headers").lower()
    self.assertIn("authorization", allowed)
    self.assertIn("content-type", allowed)
    self.assertIn("Origin", response.getheader("Vary"))

  def test_preflight_from_another_origin_is_refused(self):
    for origin in ("https://evil.example.com", "null", LOOKER_ORIGIN + ".evil.example.com"):
      response, _ = self.request(
          "OPTIONS", "/_gateway/jobs/run", authenticated=False,
          headers={"Origin": origin, "Access-Control-Request-Method": "POST"})
      self.assertEqual(response.status, 403, origin)
      self.assertIsNone(response.getheader("Access-Control-Allow-Origin"), origin)

  def test_only_the_allowed_origin_may_read_answers(self):
    for path in ("/echo", "/_gateway/jobs/no-such-job"):
      response, _ = self.request("GET", path, headers={"Origin": LOOKER_ORIGIN})
      # Exactly one value, the gateway's. The fake agent answers /echo with
      # "Access-Control-Allow-Origin: *"; that must not get through.
      self.assertEqual(response.headers.get_all("Access-Control-Allow-Origin"), [LOOKER_ORIGIN], path)
      for headers in ({"Origin": "https://evil.example.com"}, {}):
        response, _ = self.request("GET", path, headers=headers)
        self.assertIsNone(response.getheader("Access-Control-Allow-Origin"), (path, headers))
    # A refusal is readable by the allowed origin too, so the page can tell
    # "wrong password" from "network error".
    response, _ = self.request(
        "GET", "/echo", headers={"Origin": LOOKER_ORIGIN}, authenticated=False)
    self.assertEqual(response.status, 401)
    self.assertEqual(response.getheader("Access-Control-Allow-Origin"), LOOKER_ORIGIN)

  # --- request heads ------------------------------------------------------------
  def test_a_head_that_can_be_read_in_two_ways_is_refused(self):
    """One line the header parser does not take hides every header after it.

    The gateway would not see the Content-Length, would take the request for
    one without a body, and would read the body as the caller's next request.
    Each case hides a valid request that way. It must never reach the agent.
    """
    admin = self.auth_header()["Authorization"]
    hidden = ("GET /echo HTTP/1.1\r\nHost: x\r\nAuthorization: %s\r\n\r\n" % admin).encode()
    length = b"Content-Length: %d\r\n" % len(hidden)
    cases = {
        "a space before the colon": b"Content-Length : %d\r\n" % len(hidden),
        "a space inside a name": b"X Y: z\r\n" + length,
        "a line without a colon": b"garbage\r\n" + length,
        "a line that ends in CR CR LF": b"X-A: b\r\r\n" + length,
        "a line that ends in LF alone": b"X-A: b\n" + length,
        "a line that is folded": b"X-A: b\r\n c\r\n" + length,
        "a name that is not a token": b"X(A): b\r\n" + length,
        "a control character in a value": b"X-A: b\x0bc\r\n" + length,
        "a second Host": b"Host: other.test\r\n" + length,
    }
    for name, lines in cases.items():
      with self.subTest(name=name):
        received = self.exchange_until_closed(
            b"POST /run HTTP/1.1\r\nHost: gateway.test\r\n" + lines + b"\r\n" + hidden)
        self.assertEqual(re.findall(rb"HTTP/1\.[01] (\d{3}) ", received), [b"400"], received[:300])
        self.assertIn(b"\r\nconnection: close\r\n", received.lower())
        self.assertNotIn(b"peer_uris", received)

  def test_a_head_that_is_merely_unusual_is_served(self):
    # A body in several parts: the header parser notes things about such a
    # type that say nothing about the head.
    parts = b"--x\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--x--\r\n"
    response, data = self.request(
        "POST", "/upload", headers={"Content-Type": "multipart/form-data; boundary=x"}, body=parts)
    self.assertEqual((response.status, json.loads(data)["body_length"]), (200, len(parts)))
    # Bytes beyond ASCII in a value, 0x85 among them, which some readers of
    # text take for a line end: one header, as sent, and no body behind it.
    response, data = self.raw_request(
        "GET /echo HTTP/1.1\r\nX-Name: caf\xe9\x85Content-Length: 5", b"\r\n\r\n")
    self.assertEqual(response.status, 200)
    echoed = json.loads(data)
    self.assertEqual(echoed["body_length"], 0)
    self.assertEqual(self.upstream_headers(echoed)["x-name"], "caf\xe9\x85Content-Length: 5")
    self.assertNotIn("content-length", self.upstream_headers(echoed))

  def test_a_request_head_has_a_largest_size(self):
    # More than the gateway takes, with and without the empty line that ends a head.
    for end in (b"", b"\r\n\r\n"):
      with socket.create_connection(("127.0.0.1", self.gateway_port)) as sock:
        sock.sendall(b"GET /echo HTTP/1.1\r\nHost: x\r\nX-Pad: " + b"a" * 40000 + end)
        received, closed = read_until_closed(sock)
      self.assertTrue(received.startswith(b"HTTP/1.1 431 "), received[:100])
      self.assertTrue(closed)
      self.assertNotIn(b"peer_uris", received)
    # Just under the limit is served.
    response, _ = self.request("GET", "/echo", headers={"X-Pad": "a" * 32000})
    self.assertEqual(response.status, 200)

  def test_a_request_head_has_to_arrive_in_time_however_it_trickles(self):
    """A byte now and then keeps a timeout on single reads from ever striking."""
    with socket.create_connection(("127.0.0.1", self.gateway_port), timeout=10) as sock:
      started = time.monotonic()
      sock.sendall(b"GET /echo HTTP/1.1\r\n")
      sock.settimeout(0.2)
      received = b""
      while time.monotonic() - started < HEAD_TIMEOUT + 4:
        try:
          sock.sendall(b"X")
          chunk = sock.recv(4096)
        except socket.timeout:
          continue
        except OSError:
          break
        if not chunk:
          break
        received += chunk
      elapsed = time.monotonic() - started
    self.assertTrue(received.startswith(b"HTTP/1.1 408 "), received[:100])
    self.assertGreater(elapsed, HEAD_TIMEOUT - 0.5)
    self.assertLess(elapsed, HEAD_TIMEOUT + 1.5)

  def test_a_connection_that_sends_nothing_is_ended(self):
    """One that never asks anything, and one that is kept after an answer."""
    with socket.create_connection(("127.0.0.1", self.gateway_port)) as silent, \
        socket.create_connection(("127.0.0.1", self.gateway_port)) as kept:
      started = time.monotonic()
      kept.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
      answered, closed = read_until_closed(kept, HEAD_TIMEOUT + 3)
      self.assertTrue(closed)
      self.assertEqual(re.findall(rb"HTTP/1\.1 (\d{3}) ", answered), [b"200"])
      self.assertNotIn(b"connection: close", answered.lower())
      self.assertEqual(read_until_closed(silent, HEAD_TIMEOUT + 3), (b"", True))
      elapsed = time.monotonic() - started
    self.assertGreater(elapsed, HEAD_TIMEOUT - 0.5)
    self.assertLess(elapsed, HEAD_TIMEOUT + 1.5)

  def test_lengths_are_read_strictly(self):
    """Digits and CR LF, nothing a stricter reader in front would take otherwise."""
    chunked = "POST /run HTTP/1.1\r\nTransfer-Encoding: chunked"
    refused = {
        "a no-break space before the length": (
            "POST /run HTTP/1.1\r\nContent-Length: \xa05", b"\r\n\r\nhello"),
        "a form feed after the length": (
            "POST /run HTTP/1.1\r\nContent-Length: 5\x0c", b"\r\n\r\nhello"),
        "control characters around the length": (
            "POST /run HTTP/1.1\r\nContent-Length: \x1f5\x85", b"\r\n\r\nhello"),
        "a chunk size line that ends in LF alone": (chunked, b"\r\n\r\n5\nhello\r\n0\r\n\r\n"),
        "spaces around a chunk size": (chunked, b"\r\n\r\n 5 \r\nhello\r\n0\r\n\r\n"),
        "a vertical tab before a chunk size": (chunked, b"\r\n\r\n\x0b5\r\nhello\r\n0\r\n\r\n"),
        "a last chunk that ends in LF alone": (chunked, b"\r\n\r\n5\r\nhello\r\n0\n\n"),
        "a trailer that is no header field": (
            chunked, b"\r\n\r\n5\r\nhello\r\n0\r\nnot a field\r\n\r\n"),
    }
    for name, (head, payload) in refused.items():
      with self.subTest(name=name):
        response, data = self.raw_request(head, payload)
        self.assertEqual(response.status, 400)
        self.assertNotIn(b"peer_uris", data)
    # Spaces and tabs around a length are part of the syntax.
    response, data = self.raw_request("POST /run HTTP/1.1\r\nContent-Length: \t5 ", b"\r\n\r\nhello")
    self.assertEqual((response.status, json.loads(data)["body_length"]), (200, 5))

  # --- requests from other web sites --------------------------------------------
  def test_requests_that_another_site_caused_are_not_carried_out(self):
    """A browser attaches the administrator's remembered credential to them.

    That the other site cannot read the answer does not undo what the request
    did, so the request itself is refused.
    """
    own = "http://127.0.0.1:%d" % self.gateway_port
    refused = {
        "another origin": {"Origin": "https://evil.example.com"},
        "an origin without a name": {"Origin": "null"},
        "this host on another port": {"Origin": "http://127.0.0.1:1"},
        "another site, by the browser's word": {
            "Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "no-cors"},
        "a site under the same domain": {"Sec-Fetch-Site": "same-site"},
    }
    requests = (("GET", "/echo", None), ("POST", "/run", b"{}"),
                ("POST", "/_gateway/jobs/echo", b"{}"), ("POST", "/_gateway/token", None))
    for name, headers in refused.items():
      for method, path, body in requests:
        with self.subTest(name=name, method=method, path=path):
          sent = dict(headers, **{"Content-Type": "application/json"})
          response, data = self.request(method, path, headers=sent, body=body)
          self.assertEqual(response.status, 403)
          self.assertIsNone(response.getheader("X-Upstream"))
          self.assertNotIn(b"peer_uris", data)
          self.assertNotIn(b"access_token", data)
          self.assertNotIn(b'"id"', data)
    accepted = {
        "no word about the origin: not a browser": {},
        "the gateway's own pages": {"Origin": own, "Sec-Fetch-Site": "same-origin"},
        "a link that a person followed": {
            "Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "navigate"},
        "a site on the allowlist": {"Origin": LOOKER_ORIGIN, "Sec-Fetch-Site": "cross-site"},
    }
    for name, headers in accepted.items():
      with self.subTest(name=name):
        response, _ = self.request("GET", "/echo", headers=headers)
        self.assertEqual(response.getheader("X-Upstream"), "fake-router")
    response, _ = self.request(
        "POST", "/run", headers={"Origin": own, "Sec-Fetch-Site": "same-origin"}, body=b"{}")
    self.assertEqual(response.status, 200)
    # A link that a person follows is let through. A form that another site sends is no link.
    response, _ = self.request(
        "POST", "/run", headers={"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "navigate"},
        body=b"{}")
    self.assertEqual(response.status, 403)

  def test_a_job_has_to_be_sent_as_json(self):
    """Were the type filled in for a caller that names none, a form on any page could post JSON."""
    callers = dict(self.confined_callers(), administrator=self.auth_header())
    for who, credential in callers.items():
      for content_type in (None, "text/plain", "application/x-www-form-urlencoded",
                           "multipart/form-data; boundary=x", "application/jsonx", "text/json"):
        with self.subTest(who=who, content_type=content_type):
          headers = dict(credential)
          if content_type:
            headers["Content-Type"] = content_type
          response, data = self.request(
              "POST", "/_gateway/jobs/run", headers=headers, body=run_body("hi"),
              authenticated=False)
          self.assertEqual(response.status, 415)
          self.assertNotIn(b'"id"', data)
      for content_type in ("application/json", "Application/JSON; charset=utf-8"):
        with self.subTest(who=who, content_type=content_type):
          headers = dict(credential, **{"Content-Type": content_type})
          response, data = self.request(
              "POST", "/_gateway/jobs/run", headers=headers, body=run_body("hi"),
              authenticated=False)
          self.assertEqual(response.status, 202)
          sent = self.upstream_headers(self.finished_job(json.loads(data)["id"])["json"])
          self.assertEqual(sent["content-type"], "application/json")

  # --- what is passed on, in both directions -------------------------------------
  EXTRA_HEADERS = {
      "Accept": "application/json", "Accept-Language": "de", "User-Agent": "tests/1.0",
      "ate-anything": "x", "ATE-Target-Actor": "other/actor", "X-Envoy-Original-Path": "/list-apps",
      "X-Forwarded-For": "203.0.113.66", "X-Forwarded-Host": "evil.example",
      "X-Forwarded-Proto": "https", "X-Forwarded-Client-Cert": "By=spiffe://x",
      "Forwarded": "for=203.0.113.66;host=evil.example;proto=https", "X-Real-IP": "203.0.113.66",
      "Cookie": "session=of-another-site", "X-HTTP-Method-Override": "DELETE",
      "If-None-Match": "*", "Referer": "https://looker.example.com/extensions/chat",
  }

  def test_of_a_chat_s_headers_only_a_short_list_is_passed_on(self):
    for who, credential in self.confined_callers().items():
      with self.subTest(who=who):
        headers = dict(self.EXTRA_HEADERS, Host="chosen-by-the-caller.example",
                       Origin=LOOKER_ORIGIN, **credential)
        response, data = self.request("GET", ARTIFACT_PATH, headers=headers, authenticated=False)
        self.assertEqual(response.status, 200)
        sent = sorted([name.lower(), value] for name, value in json.loads(data)["headers"])
        self.assertEqual(sent, sorted([
            ["host", SERVER_NAME], ["accept", "application/json"], ["accept-language", "de"],
            ["user-agent", "tests/1.0"], ["ate-target-actor", TARGET_ACTOR],
            ["x-forwarded-for", "127.0.0.1"], ["x-forwarded-proto", "http"]]))
        # A job takes even less along.
        response, view = self.start_job(
            "/run", body=run_body("hi"), headers=headers, authenticated=False)
        self.assertEqual(response.status, 202)
        sent = sorted(
            [name.lower(), value] for name, value in self.finished_job(view["id"])["json"]["headers"])
        self.assertEqual(sent, sorted([
            ["host", SERVER_NAME], ["content-type", "application/json"],
            ["accept", "application/json"], ["ate-target-actor", TARGET_ACTOR],
            ["x-forwarded-for", "127.0.0.1"], ["x-forwarded-proto", "http"],
            ["content-length", str(len(run_body("hi")))]]))

  def test_the_administrator_s_headers_go_on_without_what_the_gateway_says_itself(self):
    headers = dict(self.EXTRA_HEADERS, Host="localhost:8080")
    response, data = self.request("GET", "/echo", headers=headers)
    self.assertEqual(response.status, 200)
    sent = {}
    for name, value in json.loads(data)["headers"]:
      sent.setdefault(name.lower(), []).append(value)
    # As sent: ADK's developer UI compares the Host with the browser's Origin.
    self.assertEqual(sent["host"], ["localhost:8080"])
    given = {name.lower(): value for name, value in self.EXTRA_HEADERS.items()}
    for name in ("accept", "accept-language", "user-agent", "referer", "if-none-match",
                 "x-http-method-override"):
      self.assertEqual(sent[name], [given[name]], name)
    # Said by the gateway, once, whatever the caller said.
    self.assertEqual(sent["ate-target-actor"], [TARGET_ACTOR])
    self.assertEqual(sent["x-forwarded-for"], ["127.0.0.1"])
    self.assertEqual(sent["x-forwarded-proto"], ["http"])
    for name in ("authorization", "cookie", "forwarded", "x-real-ip", "ate-anything",
                 "x-envoy-original-path", "x-forwarded-host", "x-forwarded-client-cert"):
      self.assertNotIn(name, sent)

  def test_the_agent_leaves_nothing_with_a_chat_s_browser(self):
    for who, credential in self.confined_callers().items():
      with self.subTest(who=who):
        response, _ = self.request("GET", ARTIFACT_PATH, headers=credential, authenticated=False)
        self.assertEqual(response.status, 200)
        self.assertIsNone(response.getheader("Set-Cookie"))
        self.assertEqual(response.headers.get_all("Cache-Control"), ["no-store"])
    # The administrator's developer UI is the agent's own pages.
    response, _ = self.request("GET", "/echo")
    self.assertEqual(response.getheader("Set-Cookie"), "sid=from-the-agent; Path=/")
    self.assertEqual(response.headers.get_all("Cache-Control"), ["public, max-age=3600"])

  def test_every_answer_carries_the_headers_that_guard_a_browser(self):
    chat = self.chat_header()
    own = {
        "no credential": self.request("GET", "/list-apps", authenticated=False),
        "refused to the chat": self.request("GET", "/list-apps", headers=chat, authenticated=False),
        "a token": self.request("POST", "/_gateway/token"),
        "a job": self.request("GET", "/_gateway/jobs/no-such-job"),
        "health": self.request("GET", "/healthz", authenticated=False),
        "a request line that is none": self.raw_request("GET", b"\r\n\r\n"),
    }
    for name, (response, _) in own.items():
      with self.subTest(name=name):
        self.assertEqual(response.headers.get_all("X-Content-Type-Options"), ["nosniff"])
        self.assertEqual(response.headers.get_all("Referrer-Policy"), ["no-referrer"])
        self.assertEqual(response.headers.get_all("Cache-Control"), ["no-store"])
        self.assertEqual(
            response.headers.get_all("Content-Security-Policy"), ["frame-ancestors 'none'"])
        # Only over TLS, which this gateway does not serve.
        self.assertIsNone(response.getheader("Strict-Transport-Security"))
    # The agent's answers too, and what the agent says in their place is dropped.
    for credential in (self.auth_header(), chat):
      path = "/echo" if credential is not chat else ARTIFACT_PATH
      response, _ = self.request("GET", path, headers=credential, authenticated=False)
      self.assertEqual(response.getheader("X-Upstream"), "fake-router")
      self.assertEqual(response.headers.get_all("X-Content-Type-Options"), ["nosniff"])
      self.assertEqual(response.headers.get_all("Referrer-Policy"), ["no-referrer"])
    # With an allowlist of sites, every answer says that it depends on the site.
    for headers in ({}, {"Origin": LOOKER_ORIGIN}):
      for path in ("/echo", "/_gateway/jobs/no-such-job", "/healthz"):
        response, _ = self.request("GET", path, headers=headers)
        self.assertIn("Origin", response.getheader("Vary") or "", (headers, path))

  def test_an_answer_that_is_not_put_together_properly_is_not_passed_on(self):
    """The agent is untrusted code: its answer must end where every reader agrees it ends."""
    admin = self.auth_header()["Authorization"]
    for case in sorted(FRAMING):
      with self.subTest(case=case):
        received = self.exchange_until_closed((
            "GET /framing/%s HTTP/1.1\r\nHost: x\r\nConnection: close\r\nAuthorization: %s\r\n\r\n"
            % (case, admin)).encode())
        self.assertEqual(re.findall(rb"HTTP/1\.[01] (\d{3}) ", received), [b"502"], received[:300])
        self.assertNotIn(b"FORGED", received)
        self.assertNotIn(b"hello", received)
        # The same answer to a job: the job fails, nothing of it is kept.
        _, view = self.start_job("/framing/" + case)
        view = self.finished_job(view["id"])
        self.assertEqual(view["status"], "failed")
        self.assertNotIn("FORGED", json.dumps(view))
    # An answer in several parts is in order: what the header parser notes
    # about such a type says nothing about where the answer ends.
    response, data = self.request("GET", "/several-parts")
    self.assertEqual((response.status, data), (200, SEVERAL_PARTS))

  def test_an_answer_that_stops_short_ends_the_connection(self):
    """The caller was told a length. Only the end of the connection can say it was not reached."""
    admin = self.auth_header()["Authorization"]
    started = time.monotonic()
    received = self.exchange_until_closed(
        ("GET /broken HTTP/1.1\r\nHost: x\r\nAuthorization: %s\r\n\r\n" % admin).encode())
    self.assertIn(b"\r\nContent-Length: 1000\r\n", received)
    self.assertTrue(received.endswith(b'{"partial":'), received[-100:])
    # At once, not when the connection has been idle for long enough.
    self.assertLess(time.monotonic() - started, HEAD_TIMEOUT - 0.5)

  # --- the chat's share of the gateway --------------------------------------------
  def test_a_chat_s_run_request_reaches_the_agent_written_anew(self):
    as_sent = ('{ "new_message": {"parts": [{"text": "caf\\u00e9"}], "role": "user"},\n'
               '  "session_id": "%s", "user_id": "looker-42", "app_name": "looker_app" }' % SESSION)
    for who, credential in self.confined_callers().items():
      with self.subTest(who=who):
        response, view = self.start_job(
            "/run", body=as_sent.encode(), headers=credential, authenticated=False)
        self.assertEqual(response.status, 202)
        echoed = self.finished_job(view["id"])["json"]
        self.assertEqual(echoed["body_text"], run_body("caf\u00e9").decode())
    # The administrator's body is passed on as it is.
    response, view = self.start_job("/run", body=as_sent.encode())
    self.assertEqual(self.finished_job(view["id"])["json"]["body_text"], as_sent)

  def test_what_a_chat_may_not_say_is_refused_by_the_body(self):
    credential_as_looker_fills_it_in = basic(CHAT_USER, CHAT_PASSWORD)[len("Basic "):]
    bodies = {
        "another app": run_body("hi", appName="other_app"),
        "state for the session": run_body("hi", stateDelta={"x": 1}),
        "streaming": run_body("hi", streaming=True),
        "a field twice": b'{"appName": "other_app", ' + run_body("hi")[1:],
        "not JSON": b"hello",
        "the chat's password": run_body("my password is " + CHAT_PASSWORD),
        "the chat's credential": run_body("Basic " + credential_as_looker_fills_it_in),
        "the chat's password, spelled with an escape": run_body(
            "x " + CHAT_PASSWORD).replace(b"chat-pass", b"\\u0063hat-pass"),
    }
    for who, credential in self.confined_callers().items():
      for name, body in bodies.items():
        with self.subTest(who=who, name=name):
          response, answer = self.start_job(
              "/run", body=body, headers=credential, authenticated=False)
          self.assertEqual(response.status, 400)
          self.assertNotIn("id", answer)
          self.assertNotIn(CHAT_PASSWORD, json.dumps(answer))
      # A new conversation takes no settings from a chat.
      for body in (b'{"state": {"x": 1}}', b'{"sessionId": "chosen-by-the-caller"}', b"[]", b" {}"):
        with self.subTest(who=who, body=body):
          response, _ = self.start_job(SESSIONS_PATH, body=body, headers=credential, authenticated=False)
          self.assertEqual(response.status, 400)
      for body in (b"", b"{}"):
        response, view = self.start_job(SESSIONS_PATH, body=body, headers=credential, authenticated=False)
        self.assertEqual(response.status, 202, body)
        self.finished_job(view["id"])
      # The other requests have no body, and the credential goes nowhere else either.
      with self.subTest(who=who):
        response, _ = self.request(
            "GET", ARTIFACT_PATH, headers=credential, body=b"x", authenticated=False)
        self.assertEqual(response.status, 400)
        response, data = self.request(
            "GET", ARTIFACT_PATH, headers=dict(credential, **{"User-Agent": "x " + CHAT_PASSWORD}),
            authenticated=False)
        self.assertEqual(response.status, 400)
        self.assertNotIn(b"peer_uris", data)
    response, _ = self.request(
        "POST", "/_gateway/token", headers=self.chat_header(), body=b"{}", authenticated=False)
    self.assertEqual(response.status, 400)
    # The administrator is not confined.
    response, view = self.start_job("/run", body=run_body(CHAT_PASSWORD, stateDelta={"x": 1}))
    self.assertEqual(response.status, 202)
    self.finished_job(view["id"])

  def test_the_chat_cannot_take_every_place_among_the_running_jobs(self):
    chat = self.chat_header()
    token = {"Authorization": "Bearer " + self.bearer_token(chat)["access_token"]}
    slow = run_body("sleep 1.5")
    started = []
    for credential in (chat, token)[:MAX_CHAT_RUNNING_JOBS]:
      response, view = self.start_job("/run", body=slow, headers=credential, authenticated=False)
      self.assertEqual(response.status, 202)
      started.append(view["id"])
    for credential in (chat, token):
      response, view = self.start_job("/run", body=slow, headers=credential, authenticated=False)
      self.assertEqual(response.status, 429)
      self.assertTrue(response.getheader("Retry-After"))
    # The place that is left is the administrator's.
    response, view = self.start_job("/slow?seconds=0.1")
    self.assertEqual(response.status, 202)
    for job_id in started + [view["id"]]:
      self.assertEqual(self.finished_job(job_id)["status"], "done")

  def test_a_job_of_the_administrator_is_not_for_the_chat(self):
    _, view = self.start_job("/echo")
    admin_job = view["id"]
    self.finished_job(admin_job)
    _, view = self.start_job("/run", body=run_body("hi"), headers=self.chat_header(), authenticated=False)
    chat_job = view["id"]
    self.finished_job(chat_job)
    for who, credential in self.confined_callers().items():
      with self.subTest(who=who):
        response, answer = self.poll_job(admin_job, headers=credential, authenticated=False)
        # The same as for a job that there is not.
        self.assertEqual((response.status, answer), (404, {"error": "unknown or expired job"}))
        response, unknown = self.poll_job(
            "no-such-job-0123456789", headers=credential, authenticated=False)
        self.assertEqual((response.status, unknown), (404, answer))
        response, answer = self.poll_job(chat_job, headers=credential, authenticated=False)
        self.assertEqual((response.status, answer["status"]), (200, "done"))
    # The administrator reads every job.
    for job_id in (admin_job, chat_job):
      response, answer = self.poll_job(job_id)
      self.assertEqual((response.status, answer["status"]), (200, "done"))

  def test_an_answer_is_kept_as_the_agent_wrote_it(self):
    """It is built once. Read and written again for every poll, it would come out in Python's words."""
    _, view = self.start_job("/odd-json")
    self.finished_job(view["id"])
    for _ in range(2):
      response, data = self.request("GET", "/_gateway/jobs/" + view["id"])
      self.assertEqual(response.status, 200)
      self.assertTrue(data.endswith(b', "json": ' + ODD_JSON + b"}"), data)
      self.assertEqual(json.loads(data)["json"], json.loads(ODD_JSON))
    # What Python reads as JSON and the standard does not is passed on as text.
    _, view = self.start_job("/nan-json")
    view = self.finished_job(view["id"])
    self.assertEqual((view["status"], view.get("text")), ("done", '{"value": NaN}'))
    self.assertNotIn("json", view)

  def test_an_answer_nested_deeper_than_can_be_read_is_text(self):
    with self.assertRaises(RecursionError):
      json.loads(DEEP_JSON)
    _, view = self.start_job("/deep-json")
    view = self.finished_job(view["id"])
    self.assertEqual((view["status"], view["http_status"]), ("done", 200))
    self.assertEqual(view.get("text"), DEEP_JSON.decode())
    self.assertNotIn("json", view)

  # --- the log -----------------------------------------------------------------
  def test_the_log_holds_no_whole_ids_and_nothing_a_caller_can_shape(self):
    chat = self.chat_header()
    _, view = self.start_job("/run", body=run_body("hi"), headers=chat, authenticated=False)
    job_id = view["id"]
    self.poll_job(job_id, wait=MAX_JOB_WAIT, headers=chat, authenticated=False)
    self.request("GET", ARTIFACT_PATH, headers=chat, authenticated=False)
    # Request lines with control characters, and one without a version: no credential needed.
    for line in (b"GET /\x1b[2J\x1b[31mforged\x1b[0m HTTP/1.1",
                 b"GET /x\r2026-01-01 00:00:00,000 INFO forged HTTP/1.1",
                 b"GET /caf\xe9\x00 HTTP/1.1", b"GET /no-version"):
      self.exchange_until_closed(line + b"\r\nHost: x\r\nConnection: close\r\n\r\n")
    log = self.process.log()
    self.assertIn(job_id[:8], log)
    self.assertNotIn(job_id, log)
    self.assertIn(SESSION[:8] + "...", log)
    self.assertNotIn(SESSION, log)
    self.assertNotIn("looker-42", log)
    self.assertNotIn("dashboard_12.png", log)
    self.assertIn("\\x1b[2J", log)
    for character in ("\x1b", "\r", "\x00", "\xe9"):
      self.assertNotIn(character, log)
    # Every line is one record: no line of a caller's making, no traceback.
    for line in log.splitlines():
      self.assertRegex(line, r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d,\d{3} (INFO|WARNING|ERROR) ")

  def test_refused_credentials_are_reported_and_cannot_fill_the_log(self):
    def reports():
      return [line for line in self.process.log().splitlines()
              if "credential that was not accepted" in line]

    time.sleep(1.1)  # past the second in which an earlier test may have been refused
    before = len(reports())
    wrong = [self.auth_header(password="wrong-guess-%d" % number) for number in range(28)]
    wrong.append({"Authorization": "Bearer v1.9999999999.made.up"})
    wrong.append({"Authorization": "Negotiate abc"})
    for headers in wrong:
      response, _ = self.request("GET", "/list-apps", headers=headers, authenticated=False)
      self.assertEqual(response.status, 401)
    # Asking without a credential is how a browser starts: nothing to report.
    self.request("GET", "/list-apps", authenticated=False)
    time.sleep(1.1)
    self.request("GET", "/list-apps", headers=wrong[0], authenticated=False)
    new = reports()[before:]
    # One line when the first is refused and one a second later for the rest:
    # a few lines for 31 refusals, and none of the refusals left out.
    self.assertIn(len(new), (2, 3, 4), new)
    for line in new:
      self.assertRegex(line, r" WARNING \d+ request\(s\) .* from 127\.0\.0\.1$")
    self.assertGreaterEqual(
        sum(int(re.search(r"WARNING (\d+) ", line).group(1)) for line in new), 31)
    log = self.process.log()
    self.assertNotIn("wrong-guess", log)
    self.assertNotIn(wrong[0]["Authorization"].split()[1], log)
    # The right password still works at once: nobody is locked out.
    response, _ = self.request("GET", "/list-apps")
    self.assertEqual(response.status, 200)

  # --- these change the fixture: keep them last ------------------------------
  def test_zz_rotated_client_certificate_is_picked_up(self):
    rotated_id = "spiffe://cluster.local/ns/looker-agent/sa/rotated"
    rotated = make_client_bundle(self.tmp.name, "client2", rotated_id)
    with open(rotated, encoding="utf-8") as source:
      content = source.read()
    with open(self.live_bundle, "w", encoding="utf-8") as out:
      out.write(content)
    future = time.time() + 5
    os.utime(self.live_bundle, (future, future))
    _, data = self.request("GET", "/echo")
    self.assertEqual(json.loads(data)["peer_uris"], [rotated_id])

  def test_zzz_unreachable_router_gives_bad_gateway(self):
    self.router.shutdown()
    self.router.server_close()
    response, data = self.request("GET", "/echo")
    self.assertEqual(response.status, 502)
    self.assertNotIn(b"Traceback", data)
    # A job is still accepted; its failure is what the caller collects.
    response, view = self.start_job("/run")
    self.assertEqual(response.status, 202)
    view = self.finished_job(view["id"])
    self.assertEqual(view["status"], "failed")
    self.assertIn("could not reach the agent", view["error"])


class FakeClock:

  def __init__(self, now=1000.0):
    self.now = now

  def __call__(self):
    return self.now


class TokenSignerTest(unittest.TestCase):

  def test_token_expires(self):
    clock = FakeClock()
    signer = gateway.TokenSigner(900, clock=clock)
    token, ttl = signer.issue()
    self.assertEqual(ttl, 900)
    self.assertTrue(signer.valid(token))
    clock.now += 899
    self.assertTrue(signer.valid(token))
    clock.now += 2
    self.assertFalse(signer.valid(token))

  def test_tokens_are_unique_and_bound_to_the_key(self):
    signer = gateway.TokenSigner(900)
    first, _ = signer.issue()
    second, _ = signer.issue()
    self.assertNotEqual(first, second)
    # Another process (or this one after a restart) has another key.
    self.assertFalse(gateway.TokenSigner(900).valid(first))
    self.assertFalse(signer.valid(None))
    self.assertFalse(signer.valid("v1.99999999999.nonce"))
    self.assertFalse(signer.valid("caf\u00e9.x.y.z"))


class JobStoreTest(unittest.TestCase):

  def test_finished_jobs_expire_but_running_jobs_do_not(self):
    clock = FakeClock()
    store = gateway.JobStore(ttl=60, max_running=10, max_stored=10, clock=clock)
    finished, running = store.create(), store.create()
    store.finish(finished, http_status=200, body=b"{}")
    clock.now += 59
    self.assertIs(store.get(finished.id), finished)
    clock.now += 2
    self.assertIsNone(store.get(finished.id))
    clock.now += 100000
    self.assertIs(store.get(running.id), running)

  def test_running_limit_counts_only_running_jobs(self):
    store = gateway.JobStore(ttl=60, max_running=2, max_stored=10, clock=FakeClock())
    first, second = store.create(), store.create()
    self.assertIsNone(store.create())
    store.finish(first, error="boom")
    self.assertIsNotNone(store.create())
    self.assertIsNone(store.create())
    self.assertEqual(
        json.loads(first.answer()), {"id": first.id, "status": "failed", "error": "boom"})
    self.assertEqual(json.loads(second.answer()), {"id": second.id, "status": "running"})

  def test_stored_limit_drops_the_oldest_finished_answers(self):
    store = gateway.JobStore(ttl=600, max_running=10, max_stored=3, clock=FakeClock())
    jobs = [store.create() for _ in range(3)]
    for job in jobs[:2]:
      store.finish(job, http_status=200, body=b"{}")
    newest = store.create()  # a fourth: over the limit
    self.assertIsNone(store.get(jobs[0].id))       # oldest finished is forgotten
    self.assertIsNotNone(store.get(jobs[1].id))
    self.assertIsNotNone(store.get(jobs[2].id))    # still running, never dropped
    self.assertIsNotNone(store.get(newest.id))


class ChatMayTest(unittest.TestCase):
  """The list itself, without a server: quick to read, quick to extend."""

  def test_the_whole_list(self):
    session = SESSIONS_PATH + "/" + SESSION
    allowed = [
        ("POST", "/_gateway/token"),
        ("POST", "/_gateway/jobs/run"),
        ("POST", "/_gateway/jobs" + SESSIONS_PATH),
        ("POST", "/_gateway/jobs/apps/looker_app/users/looker-unknown/sessions"),
        ("GET", "/_gateway/jobs/q8Zk3_-AbCdEf0123456789xyzXYZ"),
        ("GET", "/_gateway/jobs/q8Zk3_-AbCdEf0123456789xyzXYZ?wait=5"),
        ("GET", "/_gateway/jobs/q8Zk3_-AbCdEf0123456789xyzXYZ?wait=2.5"),
        ("GET", ARTIFACT_PATH),
        ("GET", ARTIFACT_PATH + "?version=0"),
        ("GET", session + "/artifacts/dashboard_thelook::business_pulse.png?version=3"),
        ("GET", session + "/artifacts/look_5.png/versions/0"),
        ("GET", session + "/artifacts/charts/q1.png/versions/7"),
    ]
    for method, target in allowed:
      self.assertTrue(gateway.chat_may(method, target), (method, target))
    refused = [
        ("GET", "/_gateway/token"), ("POST", "/_gateway/token?x=1"),
        ("POST", "/_gateway/jobs/"), ("POST", "/_gateway/jobs/run/"),
        ("POST", "/_gateway/jobs/run?wait=5"), ("POST", "/_gateway/jobs/RUN"),
        ("POST", "/_gateway/jobs/run_sse"),
        ("GET", "/_gateway/jobs/"), ("GET", "/_gateway/jobs/a/b"),
        ("GET", "/_gateway/jobs/id?wait=soon"), ("GET", "/_gateway/jobs/id?wait=5&x=1"),
        ("GET", "/_gateway/jobs/id%2fx"), ("DELETE", "/_gateway/jobs/id"),
        ("GET", "/_gateway"), ("GET", "/_gateway/"), ("GET", "/_gateway/other"),
        ("get", ARTIFACT_PATH), ("PUT", ARTIFACT_PATH), ("OPTIONS", ARTIFACT_PATH),
        ("HEAD", ARTIFACT_PATH), ("DELETE", ARTIFACT_PATH), ("POST", ARTIFACT_PATH),
        ("GET", ARTIFACT_PATH + "#x"), ("GET", ARTIFACT_PATH + "?version="),
        ("GET", ARTIFACT_PATH + "?version=1;x"), ("GET", ARTIFACT_PATH + "/"),
        ("GET", ARTIFACT_PATH + "?version=1&detailed=true"), ("GET", ARTIFACT_PATH + "?x=1"),
        ("GET", SESSIONS_PATH), ("GET", SESSIONS_PATH + "/"), ("GET", session),
        ("GET", session + "/artifacts"), ("GET", session + "/artifacts/"),
        ("GET", "/apps/looker_app/users/looker-42/artifacts/x"),
        ("GET", session + "/artifacts/a/b/c/d/e"),  # a name of five parts
        ("GET", session + "/artifacts/" + "x" * 129),
        ("GET", ARTIFACT_PATH[1:]), ("GET", "/" + ARTIFACT_PATH), ("GET", ""), ("GET", "?"),
        ("GET", "/list-apps"), ("GET", "/healthz/../list-apps"),
        # Another app; a user or a session that the extension would not name.
        ("GET", ARTIFACT_PATH.replace("looker_app", "other_app")),
        ("POST", "/_gateway/jobs/apps/other_app/users/looker-42/sessions"),
        ("POST", "/_gateway/jobs/apps/looker_app/users/admin/sessions"),
        ("POST", "/_gateway/jobs/apps/looker_app/users/looker-42x/sessions"),
        ("POST", "/_gateway/jobs/apps/looker_app/users/looker-/sessions"),
        ("POST", "/_gateway/jobs" + session),  # a session with an id of the caller's choosing
        ("GET", ARTIFACT_PATH.replace("looker-42", "someone")),
        ("GET", ARTIFACT_PATH.replace(SESSION, "s1")),
        ("GET", ARTIFACT_PATH.replace(SESSION, "s" * 129)),
    ]
    for method, target in refused:
      self.assertFalse(gateway.chat_may(method, target), (method, target))

  def test_segments_that_could_be_read_two_ways(self):
    prefix = SESSIONS_PATH + "/" + SESSION + "/artifacts/"
    self.assertTrue(gateway.chat_may("GET", prefix + "a.b..c/d.png"))
    # Nothing that is an escape, a separator or a sign with a meaning of its
    # own to some reader of paths can be part of a name.
    for name in ("..", ".", "../x", "x/..", "x/./y", "x//y", "%2e%2e", "%2E.", ".%2e/x",
                 "x%2fy", "x%2Fy", "x%5cy", "x\\y", "%252e%252e", "%25252e%25252E", "%252fx",
                 "a b", "a\tb", "a\x7fb", "100%25.png", "q1%20%232.png", "x%3fy", "x%23y",
                 "x%00", "x%0d%0ay", "x\n", "x\ny", "x;y", "..;/x", "x/..;/y", "caf\xe9",
                 "a+b", "a@b", "a,b", "a=b", "a&b", "~x", "x*", "'x'", "(x)", "x!"):
      self.assertFalse(gateway.chat_may("GET", prefix + name), name)

  def test_the_app_is_the_one_the_gateway_serves(self):
    other = ARTIFACT_PATH.replace("looker_app", "sales_app")
    self.assertTrue(gateway.chat_may("GET", other, "sales_app"))
    self.assertFalse(gateway.chat_may("GET", ARTIFACT_PATH, "sales_app"))
    self.assertTrue(gateway.chat_may(
        "POST", "/_gateway/jobs/apps/sales_app/users/looker-7/sessions", "sales_app"))
    self.assertFalse(gateway.chat_may("POST", "/_gateway/jobs" + SESSIONS_PATH, "sales_app"))

  def test_a_run_request_is_checked_and_written_anew(self):
    body, text = gateway.chat_run_request(run_body("How many orders?"), "looker_app")
    self.assertEqual(text, "How many orders?")
    self.assertEqual(body, run_body("How many orders?"))
    # The other spelling ADK takes, in another order, without "streaming": the
    # agent is sent the same as above.
    other_spelling = json.dumps({
        "new_message": {"parts": [{"text": "How many orders?"}], "role": "user"},
        "session_id": SESSION, "user_id": "looker-42", "app_name": "looker_app"}, indent=2)
    body, _ = gateway.chat_run_request(other_spelling.encode(), "looker_app")
    self.assertEqual(body, run_body("How many orders?"))
    # What a person may type comes through unchanged.
    typed = "caf\u00e9 \U0001f600 \"quoted\" \\ <b> line one\nline two\t"
    body, text = gateway.chat_run_request(run_body(typed), "looker_app")
    self.assertEqual(text, typed)
    self.assertEqual(json.loads(body)["newMessage"]["parts"][0]["text"], typed)
    gateway.chat_run_request(run_body("x" * gateway.MAX_CHAT_TEXT), "looker_app")
    gateway.chat_run_request(run_body(""), "looker_app")
    gateway.chat_run_request(run_body("hi", userId="looker-unknown"), "looker_app")
    gateway.chat_run_request(run_body("hi", appName="sales_app"), "sales_app")

  def test_run_requests_a_chat_may_not_send(self):
    def message(**changes):
      return dict({"role": "user", "parts": [{"text": "hi"}]}, **changes)

    without_app = json.loads(run_body("hi"))
    del without_app["appName"]
    refused = {
        "not JSON": b"appName=looker_app",
        "not UTF-8": b'{"appName": "\xff"}',
        "not an object": b'["looker_app"]',
        "nested deeper than can be read": DEEP_JSON,
        "a number that is not JSON": run_body("hi").replace(b"false", b"NaN"),
        "another app": run_body("hi", appName="other_app"),
        "no app": json.dumps(without_app).encode(),
        "a user the extension would not name": run_body("hi", userId="admin"),
        "a user id that is not text": run_body("hi", userId=42),
        "a session id that is too short": run_body("hi", sessionId="s1"),
        "a session id with a slash": run_body("hi", sessionId=SESSION + "/x"),
        "state for the session": run_body("hi", stateDelta={"x": 1}),
        "an invocation to resume": run_body("hi", invocationId="e-123"),
        "a field nobody knows": run_body("hi", extra=None),
        "streaming": run_body("hi", streaming=True),
        "streaming, as text": run_body("hi", streaming="false"),
        "both spellings of one field": run_body("hi", app_name="looker_app"),
        "a field twice": b'{"appName": "other_app", ' + run_body("hi")[1:],
        "a field twice, further in": run_body("hi").replace(
            b'{"text": "hi"}', b'{"text": "hi", "text": "other"}'),
        "a message from the model": run_body("hi", newMessage=message(role="model")),
        "a message with one field more": run_body("hi", newMessage=message(extra=1)),
        "two parts": run_body("hi", newMessage=message(parts=[{"text": "a"}, {"text": "b"}])),
        "no part": run_body("hi", newMessage=message(parts=[])),
        "a part that is a file": run_body("hi", newMessage=message(
            parts=[{"inlineData": {"mimeType": "text/plain", "data": "aGk="}}])),
        "a part with more than text": run_body("hi", newMessage=message(
            parts=[{"text": "a", "thought": True}])),
        "text that is not text": run_body("hi", newMessage=message(parts=[{"text": 5}])),
        "a message that is text": run_body("hi", newMessage="hi"),
        "one character too many": run_body("x" * (gateway.MAX_CHAT_TEXT + 1)),
    }
    for name, body in refused.items():
      with self.assertRaises(ValueError, msg=name):
        gateway.chat_run_request(body, "looker_app")

  def test_total_size_is_limited_and_the_answers_finished_longest_ago_go_first(self):
    store = gateway.JobStore(
        ttl=600, max_running=10, max_stored=10, max_stored_bytes=100, clock=FakeClock())
    slow, first, second, running = (store.create() for _ in range(4))
    store.finish(first, http_status=200, body=b"a" * 60)
    self.assertIsNotNone(store.get(first.id))
    store.finish(second, http_status=200, body=b"b" * 30)
    self.assertIsNotNone(store.get(first.id))      # 90 bytes: both fit
    # The job that was created first finishes last. Its answer is the newest,
    # and nobody has collected it yet: it must not be the one that goes.
    store.finish(slow, http_status=200, body=b"c" * 60)
    self.assertIsNone(store.get(first.id))         # finished longest ago
    self.assertIsNotNone(store.get(second.id))     # 30 + 60 fit
    self.assertIsNotNone(store.get(slow.id))
    self.assertIsNotNone(store.get(running.id))    # running jobs are never dropped
    # An answer that needs all the room pushes out every older one.
    store.finish(running, http_status=200, body=b"d" * 100)
    self.assertIsNone(store.get(second.id))
    self.assertIsNone(store.get(slow.id))
    self.assertEqual(store.get(running.id).body, b"d" * 100)

  def test_count_limit_also_spares_the_newest_answer(self):
    store = gateway.JobStore(ttl=600, max_running=10, max_stored=2, clock=FakeClock())
    slow, fast = store.create(), store.create()
    store.finish(fast, http_status=200, body=b"{}")
    store.finish(slow, http_status=200, body=b"{}")   # created first, finished last
    store.create()                                    # a third: over the limit
    self.assertIsNone(store.get(fast.id))
    self.assertIsNotNone(store.get(slow.id))


class ServerSettingsTest(unittest.TestCase):
  """The server hands each setting to the part that enforces it.

  The store and the signer are tested on their own above. This is about the
  step in between: a limit that is configured but never passed on is no limit.
  """

  def test_job_and_token_settings_are_in_force_in_the_server(self):
    config = gateway.Config({
        "TARGET_ACTOR": TARGET_ACTOR, "LISTEN_HOST": "127.0.0.1", "LISTEN_PORT": "0",
        "ALLOW_UNAUTHENTICATED": "true", "MAX_CHAT_RUNNING_JOBS": "2",
        "MAX_RUNNING_JOBS": "2", "MAX_STORED_JOBS": "2", "MAX_JOB_RESPONSE_BYTES": "10",
        "MAX_STORED_JOB_BYTES": "15", "JOB_TTL_SECONDS": "1.0", "TOKEN_TTL_SECONDS": "123"})
    config.validate()
    server = gateway.GatewayServer(config)
    try:
      jobs = server.jobs
      # MAX_RUNNING_JOBS
      first, second = jobs.create(), jobs.create()
      self.assertIsNone(jobs.create())
      # MAX_STORED_JOB_BYTES: 10 + 10 is more than 15.
      jobs.finish(first, http_status=200, body=b"x" * 10)
      jobs.finish(second, http_status=200, body=b"y" * 10)
      self.assertIsNone(jobs.get(first.id))
      self.assertIsNotNone(jobs.get(second.id))
      # MAX_STORED_JOBS: with two more, the finished one has to go.
      third, fourth = jobs.create(), jobs.create()
      self.assertIsNone(jobs.get(second.id))
      # JOB_TTL_SECONDS
      jobs.finish(third, http_status=200, body=b"z")
      self.assertIsNotNone(jobs.get(third.id))
      time.sleep(1.3)
      self.assertIsNone(jobs.get(third.id))
      self.assertIsNotNone(jobs.get(fourth.id))  # still running: kept
      # TOKEN_TTL_SECONDS
      token, lifetime = server.tokens.issue()
      self.assertEqual(lifetime, 123)
      self.assertTrue(server.tokens.valid(token))
    finally:
      server.server_close()


class ConfigTest(unittest.TestCase):

  NO_CREDENTIAL = {"TARGET_ACTOR": TARGET_ACTOR}
  BASE = dict(NO_CREDENTIAL, BASIC_AUTH_USER=USER, BASIC_AUTH_PASSWORD=PASSWORD)

  def test_chat_credential_needs_an_administrator_and_must_differ(self):
    admin = self.BASE
    config = gateway.Config(dict(admin, CHAT_AUTH_USER="chat", CHAT_AUTH_PASSWORD=CHAT_PASSWORD))
    config.validate()
    self.assertTrue(config.chat_auth_enabled)
    self.assertFalse(gateway.Config(admin).chat_auth_enabled)
    for bad in (
        dict(admin, CHAT_AUTH_USER="chat"),
        dict(admin, CHAT_AUTH_PASSWORD=CHAT_PASSWORD),
        dict(self.NO_CREDENTIAL, CHAT_AUTH_USER="chat", CHAT_AUTH_PASSWORD=CHAT_PASSWORD),
        dict(admin, CHAT_AUTH_USER=USER, CHAT_AUTH_PASSWORD=PASSWORD),
    ):
      with self.assertRaises(ValueError, msg=bad):
        gateway.Config(bad).validate()
    # Same user name with another password is two different credentials.
    gateway.Config(dict(admin, CHAT_AUTH_USER=USER, CHAT_AUTH_PASSWORD=CHAT_PASSWORD)).validate()

  def test_cors_origins_are_normalized_and_checked(self):
    config = gateway.Config(dict(
        self.BASE, CORS_ALLOWED_ORIGINS=" https://Looker.Example.com/ , http://localhost:8080"))
    config.validate()
    self.assertEqual(
        config.cors_allowed_origins,
        frozenset({"https://looker.example.com", "http://localhost:8080"}))
    for bad in ("*", "looker.example.com", "https://looker.example.com/path", "ftp://x"):
      with self.assertRaises(ValueError, msg=bad):
        gateway.Config(dict(self.BASE, CORS_ALLOWED_ORIGINS=bad)).validate()

  def test_a_gateway_without_a_credential_has_to_be_meant(self):
    with self.assertRaises(ValueError):
      gateway.Config(dict(self.NO_CREDENTIAL)).validate()
    config = gateway.Config(dict(self.NO_CREDENTIAL, ALLOW_UNAUTHENTICATED="true"))
    config.validate()
    self.assertFalse(config.auth_enabled)
    for bad in (
        dict(self.NO_CREDENTIAL, ALLOW_UNAUTHENTICATED="false"),
        dict(self.NO_CREDENTIAL, ALLOW_UNAUTHENTICATED="yes"),
        # A credential and the permission to do without: one of them is a mistake.
        dict(self.BASE, ALLOW_UNAUTHENTICATED="true"),
    ):
      with self.assertRaises(ValueError, msg=bad):
        gateway.Config(bad).validate()

  def test_passwords_have_a_least_length(self):
    short = dict(self.NO_CREDENTIAL, BASIC_AUTH_USER=USER, BASIC_AUTH_PASSWORD="15-characters-x")
    with self.assertRaises(ValueError) as refusal:
      gateway.Config(short).validate()
    self.assertNotIn("15-characters-x", str(refusal.exception))
    gateway.Config(dict(short, BASIC_AUTH_PASSWORD="16-characters-xx")).validate()
    with self.assertRaises(ValueError):
      gateway.Config(dict(self.BASE, CHAT_AUTH_USER="chat", CHAT_AUTH_PASSWORD="short")).validate()
    # The length is a setting, in both directions.
    gateway.Config(dict(short, MIN_PASSWORD_LENGTH="15")).validate()
    with self.assertRaises(ValueError):
      gateway.Config(dict(self.BASE, MIN_PASSWORD_LENGTH="64")).validate()

  def test_credentials_can_come_from_files(self):
    with tempfile.TemporaryDirectory() as directory:
      def stored(name, content):
        path = os.path.join(directory, name)
        with open(path, "w", encoding="utf-8", newline="") as out:
          out.write(content)
        return path

      settings = dict(
          self.NO_CREDENTIAL,
          BASIC_AUTH_USER_FILE=stored("user", USER + "\n"),
          BASIC_AUTH_PASSWORD_FILE=stored("password", PASSWORD + "\r\n"),
          CHAT_AUTH_USER_FILE=stored("chat-user", CHAT_USER),
          CHAT_AUTH_PASSWORD_FILE=stored("chat-password", " " + CHAT_PASSWORD + " \n"))
      config = gateway.Config(settings)
      config.validate()
      self.assertEqual((config.basic_auth_user, config.basic_auth_password), (USER, PASSWORD))
      # Only the line end goes: a space can be part of a password.
      self.assertEqual(
          (config.chat_auth_user, config.chat_auth_password), (CHAT_USER, " " + CHAT_PASSWORD + " "))
      for bad in (
          dict(settings, BASIC_AUTH_PASSWORD=PASSWORD),  # one value in both forms
          dict(settings, BASIC_AUTH_PASSWORD_FILE=os.path.join(directory, "missing")),
          dict(settings, BASIC_AUTH_PASSWORD_FILE=directory),
          dict(settings, BASIC_AUTH_PASSWORD_FILE=stored("empty", "\n")),
          dict(settings, BASIC_AUTH_PASSWORD_FILE=stored("short", "short\n")),
      ):
        with self.assertRaises(ValueError, msg=bad):
          gateway.Config(bad).validate()

  def test_the_other_settings_are_checked(self):
    gateway.Config(dict(self.BASE, MAX_RUNNING_JOBS="4", MAX_CHAT_RUNNING_JOBS="4")).validate()
    for settings in (
        {"MAX_RUNNING_JOBS": "4", "MAX_CHAT_RUNNING_JOBS": "5"},  # more than there are
        {"MAX_RUNNING_JOBS": "8"},  # fewer than the chat's 24 by default
        {"MAX_CHAT_RUNNING_JOBS": "0"}, {"MAX_CONNECTIONS": "0"}, {"MAX_CONNECTIONS": "many"},
        {"MAX_HEAD_BYTES": "0"}, {"HEAD_TIMEOUT_SECONDS": "0"}, {"HEAD_TIMEOUT_SECONDS": "nan"},
        {"JOB_DEADLINE_SECONDS": "-1"}, {"JOB_DEADLINE_SECONDS": "inf"},
        {"UPSTREAM_TIMEOUT_SECONDS": "0"}, {"JOB_TTL_SECONDS": "nan"},
        {"TLS_CERT_FILE": "/tmp/cert.pem"}, {"TLS_KEY_FILE": "/tmp/key.pem"},
        {"HEALTH_PORT": "8080"},  # the main listener's
        {"HEALTH_PORT": "70000"}, {"HEALTH_PORT": "-1"},
        {"ADK_APP_NAME": "looker app"}, {"ADK_APP_NAME": "../x"}, {"ADK_APP_NAME": ""},
        {"MIN_PASSWORD_LENGTH": "0"},
    ):
      with self.assertRaises(ValueError, msg=settings):
        gateway.Config(dict(self.BASE, **settings)).validate()
    defaults = gateway.Config(self.BASE)
    self.assertEqual(
        (defaults.max_connections, defaults.head_timeout, defaults.max_head_bytes),
        (256, 30, 32768))
    self.assertEqual(
        (defaults.max_running_jobs, defaults.max_chat_running_jobs, defaults.job_deadline),
        (32, 24, 600))
    self.assertEqual(
        (defaults.health_port, defaults.min_password_length, defaults.adk_app_name),
        (8081, 16, "looker_app"))
    self.assertFalse(defaults.tls_enabled)
    self.assertFalse(defaults.allow_unauthenticated)

  def test_limits_must_be_positive(self):
    for name in ("TOKEN_TTL_SECONDS", "JOB_TTL_SECONDS", "MAX_RUNNING_JOBS",
                 "MAX_STORED_JOBS", "MAX_JOB_RESPONSE_BYTES", "MAX_STORED_JOB_BYTES",
                 "MAX_REQUEST_BYTES", "MAX_CHAT_REQUEST_BYTES"):
      with self.assertRaises(ValueError, msg=name):
        gateway.Config(dict(self.BASE, **{name: "0"})).validate()
    gateway.Config(dict(self.BASE)).validate()

  def test_one_answer_must_fit_into_the_room_for_all_answers(self):
    with self.assertRaises(ValueError):
      gateway.Config(dict(
          self.BASE, MAX_JOB_RESPONSE_BYTES="2000", MAX_STORED_JOB_BYTES="1999")).validate()
    gateway.Config(dict(
        self.BASE, MAX_JOB_RESPONSE_BYTES="2000", MAX_STORED_JOB_BYTES="2000")).validate()
    # The defaults leave room for several answers of the largest size.
    defaults = gateway.Config(dict(self.BASE))
    self.assertGreaterEqual(defaults.max_stored_job_bytes, 4 * defaults.max_job_response_bytes)
    self.assertLess(defaults.max_chat_request_bytes, defaults.max_request_bytes)


def ask(port, method, path, headers=None, body=None, tls=None, timeout=15):
  """One request to a gateway on this machine. Returns (response, body)."""
  if tls is None:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
  else:
    connection = http.client.HTTPSConnection("127.0.0.1", port, timeout=timeout, context=tls)
  try:
    connection.request(method, path, body=body, headers=headers or {})
    response = connection.getresponse()
    return response, response.read()
  finally:
    connection.close()


class OtherSettingsTest(unittest.TestCase):
  """Gateways with other settings than the one above, started for one test each."""

  CREDENTIALS = ("BASIC_AUTH_USER", "BASIC_AUTH_PASSWORD", "CHAT_AUTH_USER", "CHAT_AUTH_PASSWORD")
  ADMIN = {"Authorization": basic(USER, PASSWORD), "Content-Type": "application/json"}
  CHAT = {"Authorization": basic(CHAT_USER, CHAT_PASSWORD), "Content-Type": "application/json"}

  @classmethod
  def setUpClass(cls):
    cls.tmp = tempfile.TemporaryDirectory()
    directory = cls.tmp.name
    make_ca(directory)
    make_server_cert(directory)
    bundle = make_client_bundle(
        directory, "client", "spiffe://cluster.local/ns/looker-agent-gateway/sa/looker-agent-gateway")
    os.replace(bundle, os.path.join(directory, "credential-bundle.pem"))
    cls.router = start_router(directory)

  @classmethod
  def tearDownClass(cls):
    cls.router.shutdown()
    cls.router.server_close()
    cls.tmp.cleanup()

  @contextlib.contextmanager
  def gateway(self, **settings):
    """A gateway with the two credentials of the tests, and the settings given on top."""
    with_credentials = {
        "BASIC_AUTH_USER": USER, "BASIC_AUTH_PASSWORD": PASSWORD,
        "CHAT_AUTH_USER": CHAT_USER, "CHAT_AUTH_PASSWORD": CHAT_PASSWORD,
        "HEAD_TIMEOUT_SECONDS": "2"}
    with_credentials.update(settings)
    process = GatewayProcess(self.tmp.name, self.router.server_address[1], **with_credentials)
    try:
      yield process
    finally:
      process.stop()

  def finished_job(self, process, job_id, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
      response, data = ask(process.port, "GET", "/_gateway/jobs/%s?wait=2" % job_id, self.ADMIN)
      self.assertEqual(response.status, 200)
      view = json.loads(data)
      if view["status"] != "running":
        return view
    self.fail("job did not finish")

  # --- connections ----------------------------------------------------------
  def test_connections_beyond_the_limit_are_turned_away_at_once(self):
    with self.gateway(MAX_CONNECTIONS="4") as process:
      held = [socket.create_connection(("127.0.0.1", process.port)) for _ in range(4)]
      try:
        time.sleep(0.3)  # until the four have their places
        started = time.monotonic()
        with socket.create_connection(("127.0.0.1", process.port)) as fifth:
          received, closed = read_until_closed(fifth)
        self.assertTrue(received.startswith(b"HTTP/1.1 503 "), received[:100])
        self.assertIn(b"\r\nRetry-After: ", received)
        self.assertTrue(closed)
        self.assertLess(time.monotonic() - started, 1)
        # The kubelet's question has a door of its own.
        response, data = ask(process.health_port, "GET", "/healthz")
        self.assertEqual((response.status, data), (200, b"ok\n"))
      finally:
        for sock in held:
          sock.close()
      # With the four gone there is room again.
      deadline = time.monotonic() + 3
      while True:
        with socket.create_connection(("127.0.0.1", process.port)) as sock:
          sock.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
          received, _ = read_until_closed(sock)
        if received.startswith(b"HTTP/1.1 200 ") or time.monotonic() > deadline:
          break
        time.sleep(0.05)
      self.assertTrue(received.startswith(b"HTTP/1.1 200 "), received[:100])

  def test_callers_that_arrive_together_do_not_wait_in_front_of_the_door(self):
    """With http.server's backlog of 5, the sixth of them waits a second for the kernel."""
    with self.gateway() as process:
      started = time.monotonic()
      together = [socket.create_connection(("127.0.0.1", process.port)) for _ in range(100)]
      elapsed = time.monotonic() - started
      for sock in together:
        sock.close()
    self.assertLess(elapsed, 0.9)

  def test_the_health_port_answers_one_question(self):
    with self.gateway() as process:
      response, data = ask(process.health_port, "GET", "/healthz")
      self.assertEqual((response.status, data), (200, b"ok\n"))
      self.assertEqual(response.getheader("Cache-Control"), "no-store")
      response, data = ask(process.health_port, "HEAD", "/healthz")
      self.assertEqual((response.status, data), (200, b""))
      # Nothing else, with the best of credentials.
      for method, path in (("GET", "/list-apps"), ("GET", "/echo"), ("POST", "/healthz"),
                           ("GET", "/healthz?x=1"), ("POST", "/_gateway/token")):
        response, data = ask(process.health_port, method, path, self.ADMIN)
        self.assertEqual(response.status, 404, (method, path))
        self.assertNotIn(b"peer_uris", data)
        self.assertNotIn(b"access_token", data)
      # Callers that connect and say nothing do not keep the kubelet out:
      # the oldest of them make room.
      silent = [socket.create_connection(("127.0.0.1", process.health_port)) for _ in range(40)]
      try:
        response, data = ask(process.health_port, "GET", "/healthz", timeout=2)
        self.assertEqual((response.status, data), (200, b"ok\n"))
      finally:
        for sock in silent:
          sock.close()
      # More head than a probe has: no answer.
      with socket.create_connection(("127.0.0.1", process.health_port)) as sock:
        sock.sendall(b"GET /healthz HTTP/1.1\r\nX-Pad: " + b"a" * 5000)
        self.assertEqual(read_until_closed(sock), (b"", True))

  def test_without_a_health_port_the_main_one_still_answers(self):
    with self.gateway(HEALTH_PORT="0") as process:
      response, data = ask(process.port, "GET", "/healthz")
      self.assertEqual((response.status, data), (200, b"ok\n"))
      self.assertNotIn("as well", process.log())

  # --- jobs -------------------------------------------------------------------
  def test_a_job_has_a_time_limit_in_all(self):
    """An agent that sends a byte now and then stays within every limit on single reads."""
    with self.gateway(JOB_DEADLINE_SECONDS="1.5", UPSTREAM_TIMEOUT_SECONDS="10",
                      MAX_RUNNING_JOBS="1", MAX_CHAT_RUNNING_JOBS="1") as process:
      started = time.monotonic()
      response, data = ask(process.port, "POST", "/_gateway/jobs/trickle?seconds=8", self.ADMIN, b"{}")
      self.assertEqual(response.status, 202)
      view = self.finished_job(process, json.loads(data)["id"])
      self.assertEqual(view["status"], "failed")
      self.assertIn("JOB_DEADLINE_SECONDS", view["error"])
      self.assertLess(time.monotonic() - started, 4.5)
      # Its place, the only one, is free again.
      response, data = ask(process.port, "POST", "/_gateway/jobs/echo", self.ADMIN, b"{}")
      self.assertEqual(response.status, 202)
      self.assertEqual(self.finished_job(process, json.loads(data)["id"])["status"], "done")

  # --- credentials ----------------------------------------------------------------
  def test_credentials_from_files_are_not_in_the_environment(self):
    files = {}
    for name, value in zip(self.CREDENTIALS, (USER, PASSWORD, CHAT_USER, CHAT_PASSWORD)):
      files[name + "_FILE"] = os.path.join(self.tmp.name, name.lower())
      with open(files[name + "_FILE"], "w", encoding="utf-8") as out:
        out.write(value + "\n")
    with self.gateway(**dict(dict.fromkeys(self.CREDENTIALS), **files)) as process:
      response, _ = ask(process.port, "GET", "/echo", self.ADMIN)
      self.assertEqual(response.status, 200)
      response, _ = ask(process.port, "GET", "/list-apps", self.CHAT)
      self.assertEqual(response.status, 403)
      response, _ = ask(process.port, "GET", ARTIFACT_PATH, self.CHAT)
      self.assertEqual(response.status, 200)
      response, _ = ask(process.port, "GET", "/echo", {"Authorization": basic(USER, PASSWORD + "x")})
      self.assertEqual(response.status, 401)
      environ = "/proc/%d/environ" % process.process.pid
      if os.path.exists(environ):
        with open(environ, "rb") as environment:
          held = environment.read()
        self.assertNotIn(PASSWORD.encode(), held)
        self.assertNotIn(CHAT_PASSWORD.encode(), held)

  def test_a_gateway_that_is_not_set_up_safely_does_not_start(self):
    directory, router_port = self.tmp.name, self.router.server_address[1]
    nothing = dict.fromkeys(self.CREDENTIALS + ("ALLOW_UNAUTHENTICATED",))
    admin = dict(nothing, BASIC_AUTH_USER=USER, BASIC_AUTH_PASSWORD=PASSWORD)
    cases = {
        "no credential": (nothing, "ALLOW_UNAUTHENTICATED"),
        "a password within reach of guessing": (
            dict(nothing, BASIC_AUTH_USER=USER, BASIC_AUTH_PASSWORD="too-short"),
            "MIN_PASSWORD_LENGTH"),
        "a certificate that is not there": (
            dict(admin, TLS_CERT_FILE=os.path.join(directory, "missing.pem"),
                 TLS_KEY_FILE=os.path.join(directory, "missing.key")), "missing.pem"),
        "a certificate file that holds none": (
            dict(admin, TLS_CERT_FILE=os.path.join(directory, "server.key"),
                 TLS_KEY_FILE=os.path.join(directory, "server.key")), "PEM"),
    }
    for name, (settings, said) in cases.items():
      with self.subTest(name=name):
        code, log = gateway_exit(directory, router_port, **settings)
        self.assertEqual(code, 2, log)
        self.assertIn("configuration error", log)
        self.assertIn(said, log)
        self.assertNotIn("too-short", log)
        self.assertNotIn("Traceback", log)

  def test_a_gateway_that_is_open_on_purpose_passes_no_credential_on(self):
    with self.gateway(ALLOW_UNAUTHENTICATED="true", **dict.fromkeys(self.CREDENTIALS)) as process:
      response, data = ask(
          process.port, "GET", "/echo", {"Authorization": "Bearer meant-for-somebody-else"})
      self.assertEqual(response.status, 200)
      self.assertNotIn(
          "authorization", [name.lower() for name, _ in json.loads(data)["headers"]])
      self.assertIn(" WARNING ALLOW_UNAUTHENTICATED=true", process.log())

  # --- TLS towards callers -----------------------------------------------------------
  def serving_certificate(self, name):
    """A certificate for the gateway's own listener, from the CA of the tests."""
    _make_key_and_csr(self.tmp.name, name)
    _sign(self.tmp.name, name, "subjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n")
    return os.path.join(self.tmp.name, name + ".pem"), os.path.join(self.tmp.name, name + ".key")

  def presented_certificate(self, port, trusting):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as plain:
      with trusting.wrap_socket(plain, server_hostname="127.0.0.1") as secured:
        self.assertIn(secured.version(), ("TLSv1.2", "TLSv1.3"))
        return secured.getpeercert(binary_form=True)

  @staticmethod
  def as_der(certificate_file):
    with open(certificate_file, encoding="ascii") as pem:
      return ssl.PEM_cert_to_DER_cert(pem.read())

  def test_with_a_certificate_the_gateway_serves_tls(self):
    directory = self.tmp.name
    first_cert, first_key = self.serving_certificate("gateway-first")
    live_cert, live_key = os.path.join(directory, "tls.crt"), os.path.join(directory, "tls.key")
    shutil.copy(first_cert, live_cert)
    shutil.copy(first_key, live_key)
    self.assertEqual(
        gateway.serving_context(live_cert, live_key).minimum_version, ssl.TLSVersion.TLSv1_2)
    trusting = ssl.create_default_context(cafile=os.path.join(directory, "ca.pem"))
    with self.gateway(TLS_CERT_FILE=live_cert, TLS_KEY_FILE=live_key, MAX_CONNECTIONS="3") as process:
      response, data = ask(process.port, "GET", "/echo", self.ADMIN, tls=trusting)
      self.assertEqual(response.status, 200)
      self.assertEqual(response.getheader("Strict-Transport-Security"), "max-age=31536000")
      # The agent is told how the caller came.
      sent = {name.lower(): value for name, value in json.loads(data)["headers"]}
      self.assertEqual(sent["x-forwarded-proto"], "https")
      # There is no answer in the clear on this port ...
      with socket.create_connection(("127.0.0.1", process.port)) as plain:
        plain.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
        received, closed = read_until_closed(plain)
      self.assertTrue(closed)
      self.assertNotIn(b"HTTP/1.1 200", received)
      self.assertNotIn(b"ok\n", received)
      # ... and the kubelet's port stays plain.
      response, data = ask(process.health_port, "GET", "/healthz")
      self.assertEqual((response.status, data), (200, b"ok\n"))

      # A caller that does not get on with the handshake holds up nobody else.
      started = time.monotonic()
      early = [socket.create_connection(("127.0.0.1", process.port)) for _ in range(2)]
      try:
        response, _ = ask(process.port, "GET", "/healthz", tls=trusting)
        self.assertEqual(response.status, 200)
        self.assertLess(time.monotonic() - started, 1.5)
      finally:
        for sock in early:
          sock.close()
      # Wait until those threads finish unwinding before taking all three places.
      time.sleep(0.2)
      started = time.monotonic()
      stalled = [socket.create_connection(("127.0.0.1", process.port)) for _ in range(3)]
      try:
        # Three places, all taken now (none turned away). To the next caller there
        # is nothing to say before a handshake, and the handshake is the work to
        # be spared.
        time.sleep(0.2)
        with socket.create_connection(("127.0.0.1", process.port)) as fourth:
          self.assertEqual(read_until_closed(fourth, 1), (b"", True))
        # The handshake has as long as a request head, and no longer.
        for sock in stalled:
          self.assertEqual(read_until_closed(sock, 4), (b"", True))
        self.assertLess(time.monotonic() - started, 4)
      finally:
        for sock in stalled:
          sock.close()
      time.sleep(0.1)

      # A new certificate is taken up without a restart.
      self.assertEqual(self.presented_certificate(process.port, trusting), self.as_der(first_cert))
      second_cert, second_key = self.serving_certificate("gateway-second")
      later = time.time() + 5
      for source, live in ((second_key, live_key), (second_cert, live_cert)):
        shutil.copy(source, live)
        os.utime(live, (later, later))
      self.assertEqual(self.presented_certificate(process.port, trusting), self.as_der(second_cert))
      # A file that cannot be read for the moment leaves the one in use.
      with open(live_cert, "w", encoding="ascii") as half_written:
        half_written.write("-----BEGIN CERTIFICATE-----\n")
      os.utime(live_cert, (later + 5, later + 5))
      self.assertEqual(self.presented_certificate(process.port, trusting), self.as_der(second_cert))

  # --- a process that can start no thread ---------------------------------------
  def test_a_job_whose_thread_cannot_be_started_does_not_keep_its_place(self):
    config = gateway.Config({
        "TARGET_ACTOR": TARGET_ACTOR, "LISTEN_HOST": "127.0.0.1", "LISTEN_PORT": "0",
        "ALLOW_UNAUTHENTICATED": "true", "MAX_RUNNING_JOBS": "1", "MAX_CHAT_RUNNING_JOBS": "1",
        "ROUTER_HOST": "127.0.0.1", "ROUTER_PORT": str(self.router.server_address[1]),
        "ROUTER_CA_FILE": os.path.join(self.tmp.name, "ca.pem"),
        "CLIENT_CRED_BUNDLE": os.path.join(self.tmp.name, "credential-bundle.pem")})
    config.validate()
    server = gateway.GatewayServer(config)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    start = threading.Thread.start

    def no_thread_for_a_job(thread):
      if thread.name.startswith("job-"):
        raise RuntimeError("can't start new thread")
      start(thread)

    port = server.server_address[1]
    as_json = {"Content-Type": "application/json"}
    try:
      with self.assertLogs("gateway", level="INFO"):
        with unittest.mock.patch.object(threading.Thread, "start", no_thread_for_a_job):
          for _ in range(3):
            response, data = ask(port, "POST", "/_gateway/jobs/echo", as_json, b"{}")
            self.assertEqual(response.status, 503)
            self.assertTrue(response.getheader("Retry-After"))
            self.assertNotIn(b'"id"', data)
        # With threads to be had again, the one place there is turns out free.
        response, data = ask(port, "POST", "/_gateway/jobs/echo", as_json, b"{}")
        self.assertEqual(response.status, 202)
        job_id = json.loads(data)["id"]
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
          response, data = ask(port, "GET", "/_gateway/jobs/%s?wait=2" % job_id)
          if json.loads(data)["status"] != "running":
            break
        self.assertEqual(json.loads(data)["status"], "done")
    finally:
      server.shutdown()
      server.server_close()


class JobShareTest(unittest.TestCase):

  def test_the_chat_has_a_share_of_the_running_jobs_and_no_more(self):
    store = gateway.JobStore(
        ttl=60, max_running=3, max_stored=10, max_chat_running=2, clock=FakeClock())
    first, second = store.create(confined=True), store.create(confined=True)
    self.assertTrue(first.confined and second.confined)
    self.assertIsNone(store.create(confined=True))
    mine = store.create()  # the administrator's
    self.assertFalse(mine.confined)
    self.assertIsNone(store.create())  # all three are taken
    store.finish(first, error="boom")
    self.assertIsNotNone(store.create(confined=True))
    # The administrator may use all the places; a share is a limit, not a reserve for the chat.
    store = gateway.JobStore(
        ttl=60, max_running=3, max_stored=10, max_chat_running=2, clock=FakeClock())
    self.assertTrue(all(store.create() for _ in range(3)))
    self.assertIsNone(store.create(confined=True))


class AnswerTest(unittest.TestCase):

  def test_an_answer_is_one_json_document_whatever_the_agent_sent(self):
    def rendered(content_type, data):
      document = gateway.render_answer("job-1", 200, content_type, data)
      view = json.loads(document.decode("utf-8"))
      self.assertEqual(
          (view.pop("id"), view.pop("status"), view.pop("http_status"), view.pop("content_type")),
          ("job-1", "done", 200, content_type))
      return view

    self.assertEqual(rendered("application/json", b'{"a": [1, 2]}'), {"json": {"a": [1, 2]}})
    self.assertEqual(rendered("application/json; charset=utf-8", b" 5 "), {"json": 5})
    self.assertEqual(rendered("text/plain", b'plain "text"\n'), {"text": 'plain "text"\n'})
    self.assertEqual(rendered("text/plain", b'{"a": 1}'), {"text": '{"a": 1}'})
    self.assertEqual(rendered("image/png", b"\x89PNG\xff"), {"text": "\ufffdPNG\ufffd"})
    # Called JSON, and is not JSON by the standard: passed on as text.
    for data in (b"{broken", b'{"a": NaN}', b"\xef\xbb\xbf{}", b"", b'{"a": "\x01"}', DEEP_JSON):
      self.assertEqual(rendered("application/json", data), {"text": data.decode("utf-8")}, data[:20])
    # Bytes that are not UTF-8, inside a JSON string.
    self.assertEqual(rendered("application/json", b'{"a": "\xff"}'), {"json": {"a": "\ufffd"}})


class LogTest(unittest.TestCase):

  def test_ids_in_paths_are_cut_short(self):
    session = SESSIONS_PATH + "/" + SESSION
    for target, logged in {
        "/_gateway/jobs/UE-CJEZgu_rRSyHM5z2sWGN3A6ILQC2Q?wait=5": "/_gateway/jobs/UE-CJEZg...?wait=5",
        "/_gateway/jobs/run": "/_gateway/jobs/run",
        "/_gateway/jobs" + SESSIONS_PATH: "/_gateway/jobs/apps/looker_app/users/looker-4.../sessions",
        ARTIFACT_PATH + "?version=2":
            "/apps/looker_app/users/looker-4.../sessions/3f6c9a1e.../artifacts/dashboar...?version=2",
        session + "/artifacts/charts/q1.png/versions/3":
            "/apps/looker_app/users/looker-4.../sessions/3f6c9a1e.../artifacts/charts/q...",
        "DELETE " + session + " HTTP/1.1":
            "DELETE /apps/looker_app/users/looker-4.../sessions/3f6c9a1e... HTTP/1.1",
        "/apps/looker_app/users/u1/sessions/s1": "/apps/looker_app/users/u1/sessions/s1",
        "/list-apps?x=1": "/list-apps?x=1",
    }.items():
      self.assertEqual(gateway.logged_path(target), logged)

  def test_what_is_logged_is_one_line_of_printable_ascii(self):
    self.assertEqual(
        gateway.printable("a\x1b[2J\r\n\x00\x7f caf\xe9 \u20ac \U0001f600 ~"),
        "a\\x1b[2J\\x0d\\x0a\\x00\\x7f caf\\xe9 \\u20ac \\U0001f600 ~")
    formatter = gateway.LineFormatter("%(levelname)s %(message)s")
    record = logging.LogRecord(
        "gateway", logging.INFO, __file__, 1, "%s asked for %s", ("10.0.0.1", "/x\r\nforged\x1b[0m"), None)
    self.assertEqual(formatter.format(record), "INFO 10.0.0.1 asked for /x\\x0d\\x0aforged\\x1b[0m")
    # A traceback: its frames are the program's own lines, and what the
    # exception says, which may be a caller's words, is one line.
    try:
      raise ValueError("header value\r\nforged line")
    except ValueError:
      record = logging.LogRecord("gateway", logging.ERROR, __file__, 1, "failed", (), sys.exc_info())
    lines = formatter.format(record).split("\n")
    self.assertEqual(lines[0], "ERROR failed")
    self.assertTrue(lines[1].startswith("  File "), lines[1])
    self.assertEqual(lines[-1], "ValueError: header value\\x0d\\x0aforged line")

  def test_refused_credentials_are_one_line_a_second(self):
    clock = FakeClock()
    refusals = gateway.RefusalLog(interval=1.0, clock=clock)
    with self.assertLogs("gateway", level="WARNING") as logged:
      refusals.note("10.0.0.1")
      for _ in range(50):
        refusals.note("10.0.0.2")
      clock.now += 1.0
      refusals.note("10.0.0.3")
    self.assertEqual([record.getMessage() for record in logged.records], [
        "1 request(s) with a credential that was not accepted, the latest from 10.0.0.1",
        "51 request(s) with a credential that was not accepted, the latest from 10.0.0.3"])


class TokenStateTest(unittest.TestCase):

  def test_a_token_whose_time_is_up_is_told_from_one_that_was_never_issued(self):
    clock = FakeClock()
    signer = gateway.TokenSigner(900, clock=clock)
    token, _ = signer.issue()
    self.assertEqual(signer.state(token), "valid")
    clock.now += 901
    self.assertEqual(signer.state(token), "expired")
    self.assertFalse(signer.valid(token))
    for other in (token + "x", "v1.9999999999.made.up", "", None,
                  gateway.TokenSigner(900, clock=clock).issue()[0]):
      self.assertEqual(signer.state(other), "unknown")


def _connect_with_name(connection, context):
  http.client.HTTPConnection.connect(connection)
  connection.sock = context.wrap_socket(connection.sock, server_hostname=SERVER_NAME)


if __name__ == "__main__":
  unittest.main(verbosity=2)
