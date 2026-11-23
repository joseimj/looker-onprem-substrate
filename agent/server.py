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

"""Entrypoint for the Looker agent when it runs as an Agent Substrate actor.

On Vertex AI Agent Engine the managed runtime served the agent. On Substrate an
actor is just a container, so this file does that job. It:

  1. Serves the ADK API on port 80, the port Substrate's router sends traffic
     to by default, with a /readyz endpoint for the wakeup probe. ADK's
     developer UI, and the test, eval and debug endpoints that come with it,
     are served only when ADK_WEB_UI is set: the chat needs none of them.
  2. Points Python's TLS clients at the trust bundle Substrate projects into
     the actor. The egress gateway terminates HTTPS it is allowed to inspect
     and re-signs it with its own CA, so that CA has to be trusted.
  3. Optionally runs a loopback stand-in for the GCE metadata server. Substrate
     keeps cloud credentials out of the sandbox: the egress gateway swaps a
     placeholder Authorization header for a real token on the way out. Google
     client libraries only send that header if they believe they have a
     credential, so the stand-in hands them a placeholder token.
  4. Keeps running on SIGTERM. Substrate signals an actor before its worker pod
     goes away and expects it to stay alive until something suspends it. A
     process that has exited cannot be snapshotted.
  5. Keeps the ids of conversations out of the log. Nothing but its id stands
     between one chat user's conversation and another's.
"""

import http.server
import json
import logging
import os
import signal
import sys
import threading
import urllib.parse

LOG = logging.getLogger("looker-agent")

AGENTS_DIR = os.environ.get("AGENTS_DIR", "/app/agents")
PORT = int(os.environ.get("PORT", "80"))
SUBSTRATE_TRUST_BUNDLE = os.environ.get(
    "SUBSTRATE_TRUST_BUNDLE", "/run/ate/egress-trust-bundle/trust-bundle.pem")
EXTRA_CA_FILE = os.environ.get("EXTRA_CA_FILE", "/app/extra-ca.pem")
COMBINED_CA_FILE = os.environ.get(
    "COMBINED_CA_FILE", "/tmp/looker-agent-ca-bundle.pem")

# What the stand-in metadata server returns. It is not a secret and grants
# nothing: the egress gateway discards it and injects the real token.
PLACEHOLDER_TOKEN = "placeholder-replaced-by-the-substrate-egress-gateway"
_METADATA_PREFIX = "/computeMetadata/v1/"
_SERVICE_ACCOUNT = _METADATA_PREFIX + "instance/service-accounts/default/"
_CLOUD_PLATFORM_SCOPE = "https://www.googleapis.com/auth/cloud-platform"


def _is_true(value):
  return str(value).strip().lower() in ("1", "true", "yes", "on")


def _nonempty_file(path):
  return bool(path) and os.path.isfile(path) and os.path.getsize(path) > 0


def configure_trust(environ=os.environ):
  """Sets the CA bundle variables Python HTTP clients read.

  Returns the path that was configured, or None when nothing was changed.

  On Substrate the projected bundle already holds the gateway CA and the public
  roots. `requests` treats REQUESTS_CA_BUNDLE as a replacement for its trust
  store, not an addition, so a private CA (for example the one that signed an
  on-prem Looker certificate) has to be merged into one file.

  The merged file is built once, at start. If Substrate rotates its gateway CA,
  restart the actor from a fresh template to pick up the new one.
  """
  bundle = SUBSTRATE_TRUST_BUNDLE if _nonempty_file(SUBSTRATE_TRUST_BUNDLE) else None
  extra = EXTRA_CA_FILE if _nonempty_file(EXTRA_CA_FILE) else None

  if bundle and not extra:
    chosen = bundle
  elif extra:
    base = bundle
    if base is None:
      # Not on Substrate (a local run): start from the public roots.
      try:
        import certifi  # pylint: disable=import-outside-toplevel
        base = certifi.where()
      except ImportError:
        base = None
    with open(COMBINED_CA_FILE, "w", encoding="utf-8") as combined:
      for path in (base, extra):
        if path:
          with open(path, encoding="utf-8") as source:
            combined.write(source.read().rstrip("\n") + "\n")
    chosen = COMBINED_CA_FILE
  else:
    return None

  for name in ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE"):
    environ[name] = chosen
  LOG.info("TLS trust anchors: %s", chosen)
  return chosen


class _MetadataHandler(http.server.BaseHTTPRequestHandler):
  """Answers the few metadata paths google-auth asks for."""

  project_id = ""

  def log_message(self, format, *args):  # pylint: disable=redefined-builtin
    LOG.debug("metadata %s", format % args)

  def _reply(self, status, body, content_type):
    payload = body.encode("utf-8")
    self.send_response(status)
    # google-auth only accepts answers that carry this header.
    self.send_header("Metadata-Flavor", "Google")
    self.send_header("Content-Type", content_type)
    self.send_header("Content-Length", str(len(payload)))
    self.end_headers()
    self.wfile.write(payload)

  def _text(self, body):
    self._reply(200, body, "application/text")

  def _json(self, value):
    self._reply(200, json.dumps(value), "application/json")

  def _handle(self):
    # The token request is a GET today and may become a POST. Drain any body.
    length = int(self.headers.get("Content-Length", "0") or 0)
    if length:
      self.rfile.read(length)
    path = urllib.parse.urlsplit(self.path).path
    if path == "/":
      self._text("computeMetadata/\n")
    elif path == _SERVICE_ACCOUNT + "token":
      self._json({
          "access_token": PLACEHOLDER_TOKEN,
          "expires_in": 3600,
          "token_type": "Bearer",
      })
    elif path in (_SERVICE_ACCOUNT, _SERVICE_ACCOUNT.rstrip("/")):
      self._json({
          "aliases": ["default"],
          "email": "default",
          "scopes": [_CLOUD_PLATFORM_SCOPE],
      })
    elif path == _SERVICE_ACCOUNT + "email":
      self._text("default")
    elif path == _SERVICE_ACCOUNT + "scopes":
      self._text(_CLOUD_PLATFORM_SCOPE + "\n")
    elif path == _METADATA_PREFIX + "project/project-id" and self.project_id:
      self._text(self.project_id)
    elif path == _METADATA_PREFIX + "universe/universe-domain":
      self._text("googleapis.com")
    else:
      self._reply(404, "not found\n", "text/plain")

  do_GET = do_POST = _handle  # pylint: disable=invalid-name


def start_fake_metadata_server(environ=os.environ):
  """Starts the loopback metadata stand-in when FAKE_GCE_METADATA is set.

  google-auth reads GCE_METADATA_HOST and GCE_METADATA_IP when it is imported,
  so both must already be in the environment and name this server. They are
  set in the ActorTemplate. Returns the server, or None when disabled.
  """
  if not _is_true(environ.get("FAKE_GCE_METADATA", "")):
    return None
  address = environ.get("GCE_METADATA_HOST", "")
  host, _, port = address.rpartition(":")
  if host not in ("127.0.0.1", "localhost") or not port.isdigit():
    raise ValueError(
        "FAKE_GCE_METADATA needs GCE_METADATA_HOST=127.0.0.1:<port>, got %r" % address)
  if environ.get("GCE_METADATA_IP") != address:
    raise ValueError("GCE_METADATA_IP must equal GCE_METADATA_HOST (%r)" % address)

  handler = type("MetadataHandler", (_MetadataHandler,), {
      "project_id": environ.get("GOOGLE_CLOUD_PROJECT", ""),
  })
  server = http.server.ThreadingHTTPServer(("127.0.0.1", int(port)), handler)
  server.daemon_threads = True
  threading.Thread(target=server.serve_forever, name="fake-metadata", daemon=True).start()
  LOG.info("stand-in metadata server on %s (placeholder token only)", address)
  return server


def build_app():
  """Builds the ADK FastAPI app and adds the readiness endpoint."""
  # Imported here so the helpers above can be used and tested without ADK.
  from google.adk.cli.fast_api import get_fast_api_app  # pylint: disable=import-outside-toplevel
  from starlette.responses import PlainTextResponse  # pylint: disable=import-outside-toplevel
  from starlette.routing import Route  # pylint: disable=import-outside-toplevel

  # With web=True ADK serves its developer server: the UI, and endpoints to
  # run tests and evals and to read traces. With web=False it serves what
  # ADK's own source calls the production-safe endpoints only. Off unless
  # someone asks for it.
  app = get_fast_api_app(
      agents_dir=AGENTS_DIR,
      web=_is_true(os.environ.get("ADK_WEB_UI", "false")),
  )

  async def readyz(_request):
    return PlainTextResponse("ok\n")

  # First in the list so no catch-all route of the web UI can shadow it.
  app.router.routes.insert(0, Route("/readyz", readyz, methods=["GET"]))
  return app


def serve(app):
  """Runs uvicorn and owns signal handling.

  uvicorn installs its own SIGTERM handler, which exits, when it runs on the
  main thread. Running it on a worker thread leaves the signals to this
  function.
  """
  import uvicorn  # pylint: disable=import-outside-toplevel

  # No access log. It would hold the path of every request, and the path of a
  # request for a rendered image holds the user id, the id of the conversation
  # and the file name: all it takes to fetch that image.
  server = uvicorn.Server(uvicorn.Config(
      app, host="0.0.0.0", port=PORT, log_level="info", access_log=False))
  ignore_sigterm = _is_true(os.environ.get("IGNORE_SIGTERM", ""))

  def on_sigterm(_signum, _frame):
    if ignore_sigterm:
      LOG.warning(
          "SIGTERM received: the worker is going away. Staying up so the actor "
          "can be suspended (kubectl ate suspend actor ... --mode=sync).")
      return
    server.should_exit = True

  def on_sigint(_signum, _frame):
    server.should_exit = True

  signal.signal(signal.SIGTERM, on_sigterm)
  signal.signal(signal.SIGINT, on_sigint)

  thread = threading.Thread(target=server.run, name="uvicorn", daemon=True)
  thread.start()
  # A bare join() would block signal delivery until the thread ends.
  while thread.is_alive():
    thread.join(timeout=0.5)


def configure_logging():
  """Logs to stdout at INFO, and ADK's own messages from WARNING up.

  At INFO, ADK writes the id of every conversation it creates ("New session
  created: ..."). All its loggers are children of "google_adk".
  """
  logging.basicConfig(
      level=logging.INFO, stream=sys.stdout,
      format="%(asctime)s %(levelname)s %(name)s %(message)s")
  logging.getLogger("google_adk").setLevel(logging.WARNING)


def main():
  configure_logging()
  configure_trust()
  start_fake_metadata_server()
  serve(build_app())
  return 0


if __name__ == "__main__":
  sys.exit(main())
