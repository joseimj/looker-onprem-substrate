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

"""Reverse proxy that fronts one Agent Substrate actor.

Why this exists
---------------
Browsers and ordinary API clients cannot talk to Substrate's ingress router
(atenet-router) directly:

  * the router only serves TLS and only admits clients that present a pod
    certificate whose SPIFFE ID is on its allowlist, and
  * it picks the actor from the `ate-target-actor: <atespace>/<actor>` request
    header, which a browser cannot set.

This gateway does both on the caller's behalf. It runs as an ordinary pod whose
ServiceAccount is on the router's allowlist, authenticates the caller itself,
and forwards the request to the router over mutual TLS with the routing header
taken from its own configuration -- never from the caller.

It is deliberately small and uses only the Python standard library, so it can
run on a stock `python:3-slim` image with this file mounted from a ConfigMap.
It is meant for an internal endpoint. For production traffic put your standard
reverse proxy or policy enforcement point in this position instead.

Not supported: WebSocket upgrades. Streaming responses (server-sent events) are
relayed as they arrive. A request body is read in full before it is passed
on, whether it comes with a Content-Length or chunked.

Who may call
------------
Every caller has to prove who it is, with HTTP Basic or with a bearer token
bought with it. A gateway without a credential does not start, unless
ALLOW_UNAUTHENTICATED=true says that this is meant. Refused credentials are
reported in the log, at most one line a second. Nothing slows a caller that
guesses: every chat user arrives from Looker's one address, so a lockout would
let any of them stop the chat for all. The defence is the length of the
passwords (MIN_PASSWORD_LENGTH).

Two credentials, two reaches
----------------------------
The agent's HTTP server is ADK's API server. Next to "run the agent" it offers
a developer API: list and delete anyone's sessions, read traces, run evals,
the developer UI. Whoever holds the administrator's password can use all of
it.

A chat front end is used by many people, and each of them can make it send
any request it likes (it runs in their browser). So the chat gets a second,
weaker credential:

  BASIC_AUTH_USER / BASIC_AUTH_PASSWORD   the administrator: everything.
  CHAT_AUTH_USER / CHAT_AUTH_PASSWORD     the chat: only the requests below.

A bearer token is always confined like the chat credential, whichever
credential bought it: a token is made to be handed to a browser.

What a confined caller may send, and nothing else (chat_may, chat_run_request):

  POST /_gateway/jobs/apps/<app>/users/<user>/sessions
      A new conversation. No body, or "{}".
  POST /_gateway/jobs/run
      One turn: {"appName", "userId", "sessionId", "newMessage": {"role":
      "user", "parts": [{"text": ...}]}} and optionally "streaming": false.
      The agent is sent a body put together again from these fields, not the
      caller's bytes.
  GET /_gateway/jobs/<id>[?wait=<seconds>]
      A job that a confined caller started.
  GET /apps/<app>/users/<user>/sessions/<session>/artifacts/<name>[?version=<n>]
      An artifact (a rendered image) of a conversation.
  POST /_gateway/token
      With the Basic credential only.

<app> is ADK_APP_NAME, <user> is "looker-" and a number, <session> and <name>
are plain letters, digits and a few signs. The gateway cannot tell one chat
user from another: a conversation is protected from other users only by its
session id, which is random and which nothing on this list reveals. A request
that carries the chat credential anywhere in what is passed on is refused:
Looker fills its secret in wherever a caller puts the placeholder, and an
answer that repeats the request would hand it to the browser.

Paths the gateway answers itself
--------------------------------
Everything under /_gateway/ is for callers that cannot keep one HTTP request
open for a whole agent turn, or that must not hold the password. The Looker
extension in looker-extension/ is such a caller: its requests travel through
Looker's proxies, which return whole responses only and may cut a slow one.

  POST /_gateway/jobs/<agent path>      (Content-Type: application/json)
      Sends the POST to the agent in the background and answers at once with
      202 {"id": ..., "status": "running"}. The gateway, not the caller, holds
      the connection to the agent, so a caller that goes away does not abort
      the agent's work.
  GET /_gateway/jobs/<id>[?wait=<seconds>]
      The job's state. Once it has finished, the agent's status and body.
      `wait` holds the answer back until the job finishes or the time is up.
      The administrator can read every job, a confined caller only those that
      confined callers started.
  POST /_gateway/token
      Trades the Basic credential for a short-lived bearer token, so that a
      browser never needs the password itself. A token cannot be taken back;
      it ends with its lifetime or with the gateway.
  GET /healthz
      "ok", without a credential. Also served on a port of its own
      (HEALTH_PORT) that the limits of the main one cannot starve.

Jobs and tokens live in this process. Keep the gateway at one replica: a
second one would not know the first one's jobs. A restart loses running jobs
and invalidates tokens; callers see a 404 or a 401 and start over.

Requests from other web sites
-----------------------------
A browser attaches a remembered Basic credential to requests that any page
makes to the gateway. A request that another site caused is therefore refused,
before the credential is looked at, unless that site is listed in
CORS_ALLOWED_ORIGINS. Listed sites may also read the answers.

Limits
------
Each has a setting below. Connections at once; time and size of a request
head, and the idle time of a kept connection; size of a request body; jobs
running at once, with a share kept for the administrator; time one job may
take; number, size and age of the answers kept for collection.

What is passed on
-----------------
To the router and the agent: the request line; for the administrator the
headers, without the credential, cookies, and anything that speaks about
routing or forwarding (the gateway states those itself); for a confined caller
only Accept, Accept-Language, Content-Type and User-Agent. From the agent: an
answer whose framing is in order; for a confined caller without cookies.

TLS
---
To the router: always, with the pod certificate, verifying the router's name
against the given CA only. Towards callers: when TLS_CERT_FILE and
TLS_KEY_FILE are set. Both sets of files are read again when they change.

Settings (environment)
----------------------
  TARGET_ACTOR                  <atespace>/<actor>. Required.
  ROUTER_HOST, ROUTER_PORT      atenet-router.ate-system.svc, 443
  ROUTER_SERVER_NAME            name on the router's certificate
  ROUTER_CA_FILE                /run/router-client/router-ca.pem
  CLIENT_CRED_BUNDLE            /run/router-client/credential-bundle.pem
  LISTEN_HOST, LISTEN_PORT      0.0.0.0, 8080
  HEALTH_PORT                   8081; 0 for none
  TLS_CERT_FILE, TLS_KEY_FILE   unset: plain HTTP
  BASIC_AUTH_USER, BASIC_AUTH_PASSWORD, CHAT_AUTH_USER, CHAT_AUTH_PASSWORD
                                each also as <NAME>_FILE, a file that holds it
  ALLOW_UNAUTHENTICATED         unset; "true" to run without a credential
  MIN_PASSWORD_LENGTH           16
  ADK_APP_NAME                  looker_app
  CORS_ALLOWED_ORIGINS          none; comma-separated https://host[:port]
  TOKEN_TTL_SECONDS             900
  MAX_CONNECTIONS               256
  HEAD_TIMEOUT_SECONDS          30
  MAX_HEAD_BYTES                32768
  MAX_REQUEST_BYTES             64 MiB (administrator)
  MAX_CHAT_REQUEST_BYTES        1 MiB (confined callers)
  UPSTREAM_TIMEOUT_SECONDS      600, for each step of talking to the router
  MAX_RUNNING_JOBS              32
  MAX_CHAT_RUNNING_JOBS         24 of them for confined callers
  JOB_DEADLINE_SECONDS          600
  MAX_JOB_RESPONSE_BYTES        8 MiB
  MAX_STORED_JOBS               512
  MAX_STORED_JOB_BYTES          64 MiB
  JOB_TTL_SECONDS               900
  MAX_JOB_WAIT_SECONDS          25
"""

import base64
import email.errors
import hashlib
import hmac
import http.client
import http.server
import io
import json
import logging
import math
import os
import re
import secrets
import selectors
import signal
import socket
import ssl
import sys
import threading
import time
import traceback
import urllib.parse

LOG = logging.getLogger("gateway")

# Headers that describe one hop and must not be forwarded (RFC 9110 section 7.6.1).
HOP_BY_HOP = frozenset({
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "proxy-connection", "te", "trailer", "trailers", "transfer-encoding",
    "upgrade",
})
ROUTING_HEADER = "ate-target-actor"

# Request headers that are never passed on, whoever sends them. The credential
# was for this gateway, and the actor is untrusted code. The rest speak about
# routing or about who is calling, which the router and the agent must hear
# from the gateway alone: ADK, for one, takes a request without forwarding
# headers for a local one and compares a browser's Origin with them.
NEVER_FORWARDED = frozenset({
    ROUTING_HEADER, "authorization", "content-length", "cookie", "forwarded",
    "host", "x-real-ip",
})
NEVER_FORWARDED_PREFIXES = ("ate-", "x-envoy-", "x-forwarded-")
# All that is passed on of the headers of a caller confined to chat.
CONFINED_REQUEST_HEADERS = frozenset({
    "accept", "accept-language", "content-type", "user-agent"})
# Response headers the gateway states itself; the agent's are not passed on.
OWN_RESPONSE_HEADERS = frozenset({
    "content-length", "referrer-policy", "strict-transport-security",
    "x-content-type-options",
})
# Not passed on to a confined caller: a browser would keep them for the
# gateway's site, and the agent has no business there.
CONFINED_RESPONSE_DROPS = frozenset({"cache-control", "expires", "pragma", "set-cookie"})

METHODS = frozenset({"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"})
GATEWAY_ROOT = "/_gateway"
JOBS_PREFIX = GATEWAY_ROOT + "/jobs/"
TOKEN_PATH = GATEWAY_ROOT + "/token"
RUN_JOB_PATH = JOBS_PREFIX + "run"
HEALTH_PATH = "/healthz"
CORS_ALLOW_METHODS = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
CORS_ALLOW_HEADERS = "authorization, content-type"

_DECIMAL = re.compile(r"[0-9]+")
_TOKEN = re.compile(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+")

# What a caller confined to chat may name. The user id is what the Looker
# extension makes of a Looker user; the session id is ADK's (a UUID).
_USER = r"looker-(?:unknown|[0-9]{1,18})"
_SESSION = r"[A-Za-z0-9_-]{8,128}"
_NAME_PART = r"[A-Za-z0-9_.:-]{1,128}"
_USER_ID = re.compile(_USER)
_SESSION_ID = re.compile(_SESSION)
_CHAT_SESSIONS = re.compile(r"/apps/([^/]+)/users/%s/sessions" % _USER)
_CHAT_ARTIFACT = re.compile(
    r"/apps/([^/]+)/users/%s/sessions/%s/artifacts/(%s(?:/%s){0,3})" % (
        _USER, _SESSION, _NAME_PART, _NAME_PART))
_CHAT_ARTIFACT_QUERY = re.compile(r"(version=[0-9]{1,18})?")
_CHAT_JOB = re.compile(JOBS_PREFIX + r"[A-Za-z0-9_-]{1,128}")
_CHAT_JOB_QUERY = re.compile(r"(wait=[0-9]{1,6}(\.[0-9]{1,6})?)?")
MAX_CHAT_TEXT = 16000
# The two spellings ADK accepts for each field of a run request.
_RUN_FIELDS = {
    "app": ("appName", "app_name"),
    "user": ("userId", "user_id"),
    "session": ("sessionId", "session_id"),
    "message": ("newMessage", "new_message"),
}


def chat_may(method, target, app_name="looker_app"):
  """Whether a caller confined to chat may send this request line.

  `target` is the request target as received ("/path?query"). The list is
  short on purpose (see the module docstring), and every name on it is spelled
  from letters, digits and a few signs: no "%", no ";", no "..". A path that
  could mean one thing here and another to the router or to the agent's web
  framework cannot be written with them.
  """
  path, _, query = target.partition("?")
  if method == "POST":
    if query:
      return False
    if path in (TOKEN_PATH, RUN_JOB_PATH):
      return True
    if path.startswith(JOBS_PREFIX):
      sessions = _CHAT_SESSIONS.fullmatch(path[len(JOBS_PREFIX) - 1:])
      return bool(sessions) and sessions.group(1) == app_name
    return False
  if method == "GET":
    if _CHAT_JOB.fullmatch(path):
      return bool(_CHAT_JOB_QUERY.fullmatch(query))
    artifact = _CHAT_ARTIFACT.fullmatch(path)
    if (artifact and artifact.group(1) == app_name
        and not any(part in (".", "..") for part in artifact.group(2).split("/"))):
      return bool(_CHAT_ARTIFACT_QUERY.fullmatch(query))
  return False


def _unique_fields(pairs):
  """json.loads hook: a JSON object as a dict, refused when a name repeats."""
  fields = dict(pairs)
  if len(fields) != len(pairs):
    # Which of the two values counts depends on who reads the object.
    raise ValueError("a field is given twice")
  return fields


def _no_constant(name):
  """json.loads hook: NaN and Infinity are not JSON."""
  raise ValueError("%s is not JSON" % name)


def _message_text(message):
  """The text of {"role": "user", "parts": [{"text": ...}]}; None for anything else."""
  if (not isinstance(message, dict) or set(message) != {"role", "parts"}
      or message["role"] != "user"):
    return None
  parts = message["parts"]
  if not isinstance(parts, list) or len(parts) != 1:
    return None
  part = parts[0]
  if not isinstance(part, dict) or set(part) != {"text"} or not isinstance(part["text"], str):
    return None
  return part["text"]


def chat_run_request(body, app_name):
  """Checks the body of a chat's POST /run.

  Returns (the body to send to the agent, the text of the message), or raises
  ValueError saying what is wrong. The body returned is written anew from the
  fields that were checked, so the agent reads nothing that was not.
  """
  try:
    request = json.loads(
        body.decode("utf-8"), object_pairs_hook=_unique_fields, parse_constant=_no_constant)
  except RecursionError:
    raise ValueError("the body is nested too deeply") from None
  except UnicodeDecodeError:
    raise ValueError("the body is not UTF-8") from None
  except json.JSONDecodeError:
    raise ValueError("the body is not JSON") from None
  if not isinstance(request, dict):
    raise ValueError("the body is not a JSON object")
  fields = {}
  for field, spellings in _RUN_FIELDS.items():
    given = [request.pop(name) for name in spellings if name in request]
    if len(given) != 1:
      raise ValueError("%s has to be given, once" % spellings[0])
    fields[field] = given[0]
  streaming = request.pop("streaming", False)
  if request:
    raise ValueError("a run request from a chat holds appName, userId, sessionId, "
                     "newMessage and streaming only")
  if fields["app"] != app_name:
    raise ValueError("appName is not the app this gateway serves")
  for field, pattern in (("user", _USER_ID), ("session", _SESSION_ID)):
    if not isinstance(fields[field], str) or not pattern.fullmatch(fields[field]):
      raise ValueError("%s is not one a chat may name" % _RUN_FIELDS[field][0])
  text = _message_text(fields["message"])
  if text is None:
    raise ValueError('newMessage has to be {"role": "user", "parts": [{"text": "..."}]}')
  if len(text) > MAX_CHAT_TEXT:
    raise ValueError("the message is longer than %d characters" % MAX_CHAT_TEXT)
  if streaming is not False:
    raise ValueError("streaming has to be false")
  rebuilt = {
      "appName": fields["app"], "userId": fields["user"], "sessionId": fields["session"],
      "newMessage": {"role": "user", "parts": [{"text": text}]}, "streaming": False,
  }
  return json.dumps(rebuilt).encode("ascii"), text


class Config:
  """Settings, all from the environment."""

  def __init__(self, env=os.environ):
    self._env = env
    self.router_host = env.get("ROUTER_HOST", "atenet-router.ate-system.svc")
    self.router_port = self._number("ROUTER_PORT", 443)
    # The name on the router's serving certificate. Kept separate from
    # ROUTER_HOST so the gateway can dial an IP and still verify the name.
    self.router_server_name = env.get(
        "ROUTER_SERVER_NAME", "atenet-router.ate-system.svc")
    self.router_ca_file = env.get(
        "ROUTER_CA_FILE", "/run/router-client/router-ca.pem")
    self.client_cred_bundle = env.get(
        "CLIENT_CRED_BUNDLE", "/run/router-client/credential-bundle.pem")
    self.target_actor = env.get("TARGET_ACTOR", "")
    self.listen_host = env.get("LISTEN_HOST", "0.0.0.0")
    self.listen_port = self._number("LISTEN_PORT", 8080)
    # A second, plain listener that answers /healthz only. 0: none.
    self.health_port = self._number("HEALTH_PORT", 8081)
    # With both, the main listener serves HTTPS.
    self.tls_cert_file = env.get("TLS_CERT_FILE", "")
    self.tls_key_file = env.get("TLS_KEY_FILE", "")
    self.basic_auth_user = self._value_or_file("BASIC_AUTH_USER")
    self.basic_auth_password = self._value_or_file("BASIC_AUTH_PASSWORD")
    # The weaker credential, for a chat front end. See the module docstring.
    self.chat_auth_user = self._value_or_file("CHAT_AUTH_USER")
    self.chat_auth_password = self._value_or_file("CHAT_AUTH_PASSWORD")
    self.allow_unauthenticated = self._switch("ALLOW_UNAUTHENTICATED")
    self.min_password_length = self._number("MIN_PASSWORD_LENGTH", 16)
    # The one ADK app that confined callers may address.
    self.adk_app_name = env.get("ADK_APP_NAME", "looker_app")
    self.upstream_timeout = self._number("UPSTREAM_TIMEOUT_SECONDS", 600, float)
    self.max_connections = self._number("MAX_CONNECTIONS", 256)
    # For a request head to arrive in full, and for a kept connection to
    # bring the next one.
    self.head_timeout = self._number("HEAD_TIMEOUT_SECONDS", 30, float)
    self.max_head_bytes = self._number("MAX_HEAD_BYTES", 32768)
    self.max_request_bytes = self._number("MAX_REQUEST_BYTES", 64 * 1024 * 1024)
    # The same limit for the chat credential and for tokens. A chat turn is a
    # line of text, and every chat user can send requests with this credential.
    self.max_chat_request_bytes = self._number("MAX_CHAT_REQUEST_BYTES", 1024 * 1024)
    # Browser origins (scheme://host[:port]) allowed to call from another site.
    self.cors_allowed_origins = frozenset(
        origin.strip().rstrip("/").lower()
        for origin in env.get("CORS_ALLOWED_ORIGINS", "").split(",")
        if origin.strip())
    self.token_ttl = self._number("TOKEN_TTL_SECONDS", 900)
    # How long a finished job's answer is kept for collection.
    self.job_ttl = self._number("JOB_TTL_SECONDS", 900, float)
    self.max_running_jobs = self._number("MAX_RUNNING_JOBS", 32)
    # How many of them confined callers may hold. The rest stay free for the
    # administrator, whatever the chat's users do.
    self.max_chat_running_jobs = self._number("MAX_CHAT_RUNNING_JOBS", 24)
    # From the start of a job to the end of the agent's answer.
    self.job_deadline = self._number("JOB_DEADLINE_SECONDS", 600, float)
    self.max_stored_jobs = self._number("MAX_STORED_JOBS", 512)
    # The largest answer of one job, and how much all kept answers may hold
    # together. When there is no room, the answers finished longest ago go.
    self.max_job_response_bytes = self._number("MAX_JOB_RESPONSE_BYTES", 8 * 1024 * 1024)
    self.max_stored_job_bytes = self._number("MAX_STORED_JOB_BYTES", 64 * 1024 * 1024)
    # Upper bound for ?wait= on a job. Keep it under the shortest timeout of
    # any proxy between the caller and this gateway.
    self.max_job_wait = self._number("MAX_JOB_WAIT_SECONDS", 25, float)

  def _number(self, name, default, kind=int):
    text = self._env.get(name, "")
    if not text:
      return default
    try:
      return kind(text)
    except ValueError:
      raise ValueError("%s must be a number, got %r" % (name, text)) from None

  def _switch(self, name):
    text = self._env.get(name, "").strip().lower()
    if text not in ("", "true", "false"):
      raise ValueError("%s must be 'true' or 'false'" % name)
    return text == "true"

  def _value_or_file(self, name):
    """A setting given as NAME, or as NAME_FILE: a file that holds it.

    The file keeps a password out of the process environment. It is read once,
    here; a line end after the value is not part of it.
    """
    value = self._env.get(name, "")
    path = self._env.get(name + "_FILE", "")
    if not path:
      return value
    if value:
      raise ValueError("set %s or %s_FILE, not both" % (name, name))
    try:
      with open(path, encoding="utf-8") as source:
        return source.read().rstrip("\r\n")
    except (OSError, UnicodeDecodeError) as error:
      raise ValueError("%s_FILE: cannot read %s: %s" % (
          name, path, error.__class__.__name__)) from None

  @property
  def auth_enabled(self):
    return bool(self.basic_auth_user and self.basic_auth_password)

  @property
  def chat_auth_enabled(self):
    return bool(self.chat_auth_user and self.chat_auth_password)

  @property
  def tls_enabled(self):
    return bool(self.tls_cert_file and self.tls_key_file)

  def carries_chat_credential(self, data):
    """Whether these bytes hold the chat's password, or its Basic credential."""
    if not self.chat_auth_enabled:
      return False
    pair = ("%s:%s" % (self.chat_auth_user, self.chat_auth_password)).encode("utf-8")
    return (self.chat_auth_password.encode("utf-8") in data
            or base64.b64encode(pair) in data or base64.urlsafe_b64encode(pair) in data)

  def validate(self):
    parts = self.target_actor.split("/")
    if len(parts) != 2 or not all(parts):
      raise ValueError(
          "TARGET_ACTOR must be '<atespace>/<actor>', got %r" % self.target_actor)
    if bool(self.basic_auth_user) != bool(self.basic_auth_password):
      raise ValueError(
          "set both BASIC_AUTH_USER and BASIC_AUTH_PASSWORD, or neither")
    if bool(self.chat_auth_user) != bool(self.chat_auth_password):
      raise ValueError(
          "set both CHAT_AUTH_USER and CHAT_AUTH_PASSWORD, or neither")
    if self.chat_auth_enabled and not self.auth_enabled:
      # Without an administrator password everybody is admitted to everything,
      # and a "restricted" credential would restrict nobody.
      raise ValueError(
          "CHAT_AUTH_USER needs BASIC_AUTH_USER and BASIC_AUTH_PASSWORD as well")
    if not self.auth_enabled and not self.allow_unauthenticated:
      # A gateway whose credential went missing must not turn into an open one.
      raise ValueError(
          "BASIC_AUTH_USER and BASIC_AUTH_PASSWORD are not set. To run without "
          "authentication on purpose, set ALLOW_UNAUTHENTICATED=true")
    if self.auth_enabled and self.allow_unauthenticated:
      raise ValueError(
          "ALLOW_UNAUTHENTICATED=true contradicts BASIC_AUTH_USER: set one of them")
    if self.chat_auth_enabled and (
        self.chat_auth_user == self.basic_auth_user
        and self.chat_auth_password == self.basic_auth_password):
      raise ValueError(
          "the chat credential must differ from the administrator credential")
    for name, password in (("BASIC_AUTH_PASSWORD", self.basic_auth_password),
                           ("CHAT_AUTH_PASSWORD", self.chat_auth_password)):
      # Nothing slows a caller that guesses (see the module docstring), so a
      # password has to be out of reach of guessing.
      if password and len(password) < self.min_password_length:
        raise ValueError("%s is shorter than MIN_PASSWORD_LENGTH (%d characters)" % (
            name, self.min_password_length))
    if bool(self.tls_cert_file) != bool(self.tls_key_file):
      raise ValueError("set both TLS_CERT_FILE and TLS_KEY_FILE, or neither")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,63}", self.adk_app_name):
      raise ValueError("ADK_APP_NAME must be a Python identifier, got %r" % self.adk_app_name)
    for origin in self.cors_allowed_origins:
      split = urllib.parse.urlsplit(origin)
      if (split.scheme not in ("http", "https") or not split.netloc
          or split.path or split.query or split.fragment):
        raise ValueError(
            "CORS_ALLOWED_ORIGINS entries must look like https://host[:port], "
            "got %r" % origin)
    for name in ("token_ttl", "job_ttl", "max_running_jobs", "max_chat_running_jobs",
                 "max_stored_jobs", "max_job_response_bytes", "max_stored_job_bytes",
                 "max_request_bytes", "max_chat_request_bytes", "max_connections",
                 "max_head_bytes", "min_password_length"):
      # "not greater" instead of "less or equal": NaN is neither.
      if not getattr(self, name) > 0:
        raise ValueError("%s must be greater than zero" % name.upper())
    for name, setting in (("upstream_timeout", "UPSTREAM_TIMEOUT_SECONDS"),
                          ("head_timeout", "HEAD_TIMEOUT_SECONDS"),
                          ("job_deadline", "JOB_DEADLINE_SECONDS")):
      if not 0 < getattr(self, name) < math.inf:
        raise ValueError("%s must be a number of seconds greater than zero" % setting)
    if self.max_chat_running_jobs > self.max_running_jobs:
      raise ValueError("MAX_CHAT_RUNNING_JOBS must not be greater than MAX_RUNNING_JOBS")
    if self.max_stored_job_bytes < self.max_job_response_bytes:
      # Otherwise an answer could be too big to keep until it is collected.
      raise ValueError(
          "MAX_STORED_JOB_BYTES must not be smaller than MAX_JOB_RESPONSE_BYTES")
    if not self.max_job_wait >= 0:
      raise ValueError("MAX_JOB_WAIT_SECONDS must not be negative")
    if not 0 <= self.health_port <= 65535 or (
        self.health_port and self.health_port == self.listen_port):
      raise ValueError("HEALTH_PORT must be a port other than LISTEN_PORT, or 0 for none")


_ESCAPES = {code: "\\x%02x" % code for code in list(range(0x20)) + [0x7f]}


def printable(text):
  """The text with everything but printable ASCII written as an escape.

  Request lines, header values and error texts come from callers and from the
  agent. Written to the log as they are, a line end in one would forge a log
  entry and an escape sequence would act on the terminal of whoever reads it.
  """
  return text.translate(_ESCAPES).encode("ascii", "backslashreplace").decode("ascii")

# The id of a job, and the user, session and artifact of a conversation, as
# far as they are written to the log: their first eight characters. A job id
# and a session id are all that protects an answer or a conversation from the
# other users of the chat, and more people read logs than hold credentials.
_LONG_ID = re.compile(r"(/(?:_gateway/jobs|users|sessions)/[^/?#\s]{8})[^/?#\s]+")
_LONG_ARTIFACT = re.compile(r"(/artifacts/[^?#\s]{8})[^?#\s]+")


def logged_path(target):
  """A request target, or a whole request line, as it is written to the log."""
  return _LONG_ARTIFACT.sub(r"\1...", _LONG_ID.sub(r"\1...", target))


class LineFormatter(logging.Formatter):
  """Writes each record as one line of printable ASCII.

  A traceback follows on lines of its own: its frames are this program's
  text, and what the exception says is escaped like any message.
  """

  def formatMessage(self, record):
    record.message = printable(record.message)
    return super().formatMessage(record)

  def formatException(self, ei):
    kind, error, trace = ei
    return "".join(traceback.format_tb(trace)) + "%s: %s" % (
        kind.__name__, printable(str(error)))


class RefusalLog:
  """Reports credentials that were not accepted.

  At most one line in `interval` seconds, with the number refused since the
  line before, so that a caller who guesses cannot fill the log. The line
  names the address the latest one came from and never the credential.
  """

  def __init__(self, interval=1.0, clock=time.monotonic):
    self._interval = interval
    self._clock = clock
    self._lock = threading.Lock()
    self._count = 0
    self._last_line = -math.inf

  def note(self, address):
    with self._lock:
      self._count += 1
      now = self._clock()
      if now - self._last_line < self._interval:
        return
      count, self._count, self._last_line = self._count, 0, now
    LOG.warning(
        "%d request(s) with a credential that was not accepted, the latest from %s",
        count, address)


class TlsContextCache:
  """Builds a TLS context from files and rebuilds it when the files change.

  The pod certificate is short-lived and the kubelet rewrites the projected
  file in place, so a context built once at startup would stop working at the
  first rotation. The same goes for a serving certificate from a Secret.

  `build` gets the file names. With `keep_last_good`, files that cannot be
  read for the moment (half written, say) leave the context in use as it was.
  """

  def __init__(self, paths, build, what, keep_last_good=False):
    self._paths = paths
    self._build = build
    self._what = what
    self._keep_last_good = keep_last_good
    self._lock = threading.Lock()
    self._stamp = None
    self._context = None
    self._complained = -math.inf

  def _current_stamp(self):
    return tuple(
        (os.stat(path).st_mtime_ns, os.stat(path).st_size) for path in self._paths)

  def get(self):
    with self._lock:
      try:
        stamp = self._current_stamp()
        if self._context is None or stamp != self._stamp:
          context = self._build(*self._paths)
          if self._context is not None:
            LOG.info("%s changed; TLS context rebuilt", self._what)
          self._context, self._stamp = context, stamp
      except OSError as error:  # ssl.SSLError is one
        if self._context is None or not self._keep_last_good:
          raise
        if time.monotonic() - self._complained > 60:
          self._complained = time.monotonic()
          LOG.error("%s cannot be read, the one in use stays: %r", self._what, error)
      return self._context


def router_client_context(ca_file, cred_bundle):
  """TLS towards the router: verify it against the given CA only, present the pod certificate."""
  context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=ca_file)
  # The bundle holds the certificate chain and the private key together.
  context.load_cert_chain(cred_bundle)
  context.minimum_version = ssl.TLSVersion.TLSv1_2
  return context


def serving_context(cert_file, key_file):
  """TLS towards callers."""
  context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
  context.minimum_version = ssl.TLSVersion.TLSv1_2
  context.load_cert_chain(cert_file, key_file)
  context.set_alpn_protocols(["http/1.1"])
  return context


class RouterConnection(http.client.HTTPSConnection):
  """HTTPS connection that verifies a fixed server name, whatever host is dialed."""

  def __init__(self, host, port, *, server_name, context, timeout):
    super().__init__(host, port, context=context, timeout=timeout)
    self._router_context = context
    self._router_server_name = server_name

  def connect(self):
    http.client.HTTPConnection.connect(self)
    self.sock = self._router_context.wrap_socket(
        self.sock, server_hostname=self._router_server_name)


class UpstreamError(Exception):
  """The agent could not be reached through the router."""


def router_connection(server, timeout=None):
  """A connection to atenet-router, not yet opened. The caller closes it."""
  config = server.config
  try:
    return RouterConnection(
        config.router_host, config.router_port,
        server_name=config.router_server_name, context=server.router_tls.get(),
        timeout=timeout or config.upstream_timeout)
  except OSError as error:
    raise UpstreamError(repr(error)) from error


def send_upstream(server, upstream, method, path, headers, body, client_ip):
  """Sends one request to atenet-router and returns the response.

  `headers` is an iterable of (name, value) pairs. What the router and the
  agent are told about routing and about the caller is added here, from the
  gateway's own knowledge, and must not be among them.
  """
  config = server.config
  try:
    upstream.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
    for name, value in headers:
      upstream.putheader(name, value)
    # The routing header comes from configuration only. A caller must never be
    # able to steer the request to another actor.
    upstream.putheader(ROUTING_HEADER, config.target_actor)
    # Always present: ADK takes a request without it for one from its own machine.
    upstream.putheader("X-Forwarded-For", client_ip)
    upstream.putheader("X-Forwarded-Proto", "https" if server.serving_tls else "http")
    if body or method in ("POST", "PUT", "PATCH"):
      upstream.putheader("Content-Length", str(len(body)))
    upstream.endheaders(body if body else None)
    return upstream.getresponse()
  except (OSError, http.client.HTTPException) as error:
    raise UpstreamError(repr(error)) from error


# What email.parser, which http.client uses as well, notes when it did not
# read a line of a header block as a header field. (It notes other things
# too, about bodies in several parts for one, which mean nothing here.)
_HEADER_DEFECTS = (
    email.errors.FirstHeaderLineIsContinuationDefect, email.errors.InvalidHeaderDefect,
    email.errors.MisplacedEnvelopeHeaderDefect, email.errors.MissingHeaderBodySeparatorDefect)


def framing_problem(response):
  """What is wrong with the way an answer from the router is put together, or None.

  The actor is untrusted code. An answer whose end can be read in two ways,
  passed on as it is, would let it place a second answer of its own choosing
  on a caller's connection.
  """
  if 100 <= response.status < 200:
    return "an interim status as the final one"
  head = response.msg
  if head.get_payload() or any(isinstance(defect, _HEADER_DEFECTS) for defect in head.defects):
    return "a header block with lines that are not header fields"
  if any(_CONTROL_CHARACTER.search(value) for value in head.values()):
    return "a folded header line, or control characters in a header"
  lengths = head.get_all("Content-Length") or []
  encodings = head.get_all("Transfer-Encoding") or []
  if encodings and (lengths or len(encodings) > 1
                    or encodings[0].strip(" \t").lower() != "chunked"):
    return "a Transfer-Encoding that is not just chunked, or one next to a Content-Length"
  if len(lengths) > 1 or (lengths and not _DECIMAL.fullmatch(lengths[0].strip(" \t"))):
    return "a Content-Length that is not one number"
  return None


def _check_basic_auth(header_value, user, password):
  """Returns True when header_value is a Basic credential for user/password."""
  if not header_value:
    return False
  scheme, _, encoded = header_value.partition(" ")
  if scheme.lower() != "basic":
    return False
  try:
    decoded = base64.b64decode(encoded.strip(), validate=True)
  except (ValueError, TypeError):
    return False
  given_user, sep, given_password = decoded.partition(b":")
  if not sep:
    return False
  # Compare both halves in constant time, and do not short-circuit.
  user_ok = hmac.compare_digest(given_user, user.encode("utf-8"))
  password_ok = hmac.compare_digest(given_password, password.encode("utf-8"))
  return user_ok and password_ok


class HeadTooLarge(Exception):
  """A request head is longer than MAX_HEAD_BYTES."""


class ClientStream:
  """What a caller sends on one connection, read against the clock.

  http.server reads through a buffered file, and each of its reads may wait
  for the whole socket timeout: a caller that sends one byte now and then is
  never timed out. Here every read is told the moment by which it has to be
  complete, and a head has a largest size.
  """

  _HEAD_END = re.compile(rb"\n\r?\n")

  def __init__(self, sock, write_timeout):
    self._sock = sock
    self._write_timeout = write_timeout
    self._pending = bytearray()  # received, not handed out yet

  @property
  def pending(self):
    return len(self._pending)

  def _receive(self, deadline):
    """Waits for more bytes. False when the caller has ended the connection."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
      raise TimeoutError("the caller took too long")
    self._sock.settimeout(remaining)
    try:
      chunk = self._sock.recv(65536)
    finally:
      self._sock.settimeout(self._write_timeout)
    self._pending += chunk
    return bool(chunk)

  def read_head(self, limit, deadline):
    """Returns a request head, through the empty line that ends it.

    b"" when the caller ended the connection instead. Raises HeadTooLarge, or
    TimeoutError at the deadline.
    """
    while True:
      end = self._HEAD_END.search(self._pending)
      size = end.end() if end else None
      for empty_line in (b"\r\n", b"\n"):
        if self._pending.startswith(empty_line):
          size = len(empty_line)
      if size is None and len(self._pending) <= limit:
        if not self._receive(deadline):
          return b""
        continue
      if size is None or size > limit:
        raise HeadTooLarge()
      return self.read(size, deadline)

  def read(self, size, deadline):
    """Returns `size` bytes, or fewer when the caller ends the connection first."""
    while len(self._pending) < size and self._receive(deadline):
      pass
    with memoryview(self._pending) as view:
      data = bytes(view[:size])
    del self._pending[:size]
    return data

  def readline(self, limit, deadline):
    """Returns a line with its line end, or the first `limit` bytes of a longer one."""
    while True:
      end = self._pending.find(b"\n", 0, limit)
      if end >= 0:
        return self.read(end + 1, deadline)
      if len(self._pending) >= limit or not self._receive(deadline):
        return self.read(limit, deadline)


_BARE_LINE_END = re.compile(rb"(?<!\r)\n|\r(?!\n)")
# A header field as RFC 9110 has it: a token, a colon, and a value without
# control characters. Not a folded line, which starts with a space.
_HEADER_LINE = re.compile(rb"([!#$%&'*+.^_`|~0-9A-Za-z-]+):[\t\x20-\x7e\x80-\xff]*")
_CONTROL_CHARACTER = re.compile(r"[\x00-\x08\x0a-\x1f\x7f]")


def head_problem(head, version, headers):
  """What is wrong with a request head that http.server took, or None.

  http.server parses the header block with email.parser, which stops at the
  first line that is not a header field and takes the rest for a message
  body. The headers after such a line would be invisible here, Content-Length
  among them, and the body of the request would be read as the next request.
  A proxy in front that reads the same bytes differently is how one caller's
  request gets answered to another. So a head that can be read in two ways is
  refused: other line ends than CR LF, a line that is not a header field
  (folded lines among them, RFC 9112 section 5.2), a second Host. And the
  parser must have found the very header fields that are there.
  """
  if _BARE_LINE_END.search(head):
    return "a line that does not end in CR LF"
  if version == "HTTP/0.9":
    return "a request line without an HTTP version"
  names = []
  for line in head.split(b"\r\n")[1:-2]:  # without the request line and the end
    field = _HEADER_LINE.fullmatch(line)
    if not field:
      return "a line that is not a header field"
    names.append(field.group(1).decode("ascii"))
  if names != headers.keys():
    return "header fields that can be read in two ways"
  if len(headers.get_all("Host") or []) > 1:
    return "more than one Host"
  return None


_CHUNK_LINE = re.compile(rb"([0-9a-fA-F]{1,8})(;[^\r\n]*)?\r\n")
_TRAILER_LINE = re.compile(rb"[!#$%&'*+.^_`|~0-9A-Za-z-]+:[^\r\n]*\r\n")


def read_chunked(stream, limit, deadline):
  """Reads a chunked body (RFC 9112 section 7.1) of at most `limit` bytes.

  Returns (body, None), or (None, what is wrong with it). Chunk extensions and
  trailers are read and dropped. The body is forwarded with a Content-Length,
  so nothing of the chunking reaches the agent. The syntax is taken strictly:
  a size is hex digits and nothing else, a line ends in CR LF.
  """
  body = bytearray()
  while True:
    size_line = _CHUNK_LINE.fullmatch(stream.readline(1024, deadline))
    if not size_line:
      return None, "malformed chunk"
    size = int(size_line.group(1), 16)
    if size == 0:
      break
    if len(body) + size > limit:
      return None, "too large"
    chunk = stream.read(size + 2, deadline)
    if len(chunk) != size + 2 or not chunk.endswith(b"\r\n"):
      return None, "malformed chunk"
    body += chunk[:size]
  # Trailer fields, up to the empty line that ends the message.
  for _ in range(64):
    line = stream.readline(8192, deadline)
    if line == b"\r\n":
      return bytes(body), None
    if not _TRAILER_LINE.fullmatch(line):
      break
  return None, "malformed trailer"


class TokenSigner:
  """Issues and checks short-lived bearer tokens.

  A token is "v1.<expiry>.<nonce>.<signature>". The signing key is made up at
  start and never leaves this process, so tokens stop working when the gateway
  restarts and no other process can mint one.
  """

  def __init__(self, ttl, key=None, clock=time.time):
    self._ttl = ttl
    self._key = key or secrets.token_bytes(32)
    self._clock = clock

  def _sign(self, payload):
    digest = hmac.new(self._key, payload.encode("utf-8"), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")

  def issue(self):
    """Returns (token, seconds until it expires)."""
    payload = "v1.%d.%s" % (int(self._clock()) + self._ttl, secrets.token_urlsafe(9))
    return payload + "." + self._sign(payload), self._ttl

  def state(self, token):
    """ "valid", "expired" (one of ours whose time is up) or "unknown"."""
    payload, sep, signature = (token or "").rpartition(".")
    if not sep:
      return "unknown"
    # Check the signature before looking at anything it protects.
    if not hmac.compare_digest(
        signature.encode("utf-8"), self._sign(payload).encode("utf-8")):
      return "unknown"
    fields = payload.split(".")
    if len(fields) != 3 or fields[0] != "v1":
      return "unknown"
    try:
      expires = int(fields[1])
    except ValueError:
      return "unknown"
    return "valid" if self._clock() < expires else "expired"

  def valid(self, token):
    return self.state(token) == "valid"


def _json_bytes(value):
  return json.dumps(value).encode("ascii")


def _nothing(_value):
  """json.loads hook: keep nothing of what was read."""


def _is_json(text):
  """Whether the text is one JSON value by the standard (RFC 8259).

  Judged without keeping what it holds, which for a large answer would take
  many times its size in memory.
  """
  try:
    json.loads(text, object_pairs_hook=_nothing, parse_float=_nothing,
               parse_int=_nothing, parse_constant=_no_constant)
  except (ValueError, RecursionError):
    return False
  return True


# One answer at a time: checking a large one still takes some memory.
_RENDERING = threading.Lock()


def render_answer(job_id, http_status, content_type, data):
  """The JSON document a caller is sent for a finished job.

  {"id", "status": "done", "http_status", "content_type"} and the agent's
  answer, as "json" when it is JSON and as "text" otherwise. Built once, when
  the job finishes: built for every poll, a few polls of a large answer at
  the same time would take more memory than the gateway has. An answer that
  is JSON goes in as the agent wrote it.
  """
  try:
    text, as_received = data.decode("utf-8"), True
  except UnicodeDecodeError:
    text, as_received = data.decode("utf-8", "replace"), False
  with _RENDERING:
    if "json" in content_type.lower() and _is_json(text):
      name, value = b"json", data if as_received else text.encode("utf-8")
    else:
      name, value = b"text", json.dumps(text, ensure_ascii=False).encode("utf-8")
  head = _json_bytes({"id": job_id, "status": "done", "http_status": http_status,
                      "content_type": content_type})
  return head[:-1] + b', "' + name + b'": ' + value + b"}"


class Job:
  """One request to the agent that runs without its caller waiting."""

  def __init__(self, job_id, created, confined=False):
    self.id = job_id
    self.created = created
    # Started with the chat credential or a token. Such a caller may collect
    # only jobs of this kind; the administrator's are not for the chat.
    self.confined = confined
    self.finished_at = None
    self.finished_order = None  # 1 for the first job that finished, 2, ...
    self.status = "running"
    self.http_status = None
    self.body = b""  # the answer, as a caller is sent it, once there is one
    self.done = threading.Event()

  def answer(self):
    """The JSON document a caller is sent about the job, ready to send."""
    if not self.done.is_set():
      return _json_bytes({"id": self.id, "status": "running"})
    return self.body


class JobStore:
  """Jobs in memory: limited in number, in total size and in age.

  Running jobs are never dropped. When finished answers have to go, the ones
  that finished longest ago go first, so the answer a caller is about to
  collect is the last to be forgotten.
  """

  def __init__(self, ttl, max_running, max_stored, max_stored_bytes=None,
               max_chat_running=None, clock=time.monotonic):
    self._ttl = ttl
    self._max_running = max_running
    self._max_chat_running = max_chat_running  # None: no share of its own
    self._max_stored = max_stored
    self._max_stored_bytes = max_stored_bytes  # None: no limit on total size
    self._clock = clock
    self._lock = threading.Lock()
    self._jobs = {}
    self._finished_count = 0

  def create(self, confined=False):
    """Returns a new running job, or None when too many are running."""
    with self._lock:
      self._purge_locked()
      running = [job for job in self._jobs.values() if job.finished_at is None]
      if len(running) >= self._max_running:
        return None
      if (confined and self._max_chat_running is not None
          and sum(1 for job in running if job.confined) >= self._max_chat_running):
        return None
      # The id is the only thing a caller needs to read the answer: unguessable.
      job = Job(secrets.token_urlsafe(24), self._clock(), confined)
      self._jobs[job.id] = job
      self._purge_locked()  # make room: running jobs are never dropped
      return job

  def get(self, job_id):
    with self._lock:
      self._purge_locked()
      return self._jobs.get(job_id)

  def finish(self, job, *, http_status=None, body=b"", error=""):
    """Ends a job: with the answer as a caller is sent it, or with what went wrong."""
    with self._lock:
      job.http_status = http_status
      job.status = "failed" if error else "done"
      job.body = _json_bytes(
          {"id": job.id, "status": "failed", "error": error}) if error else body
      job.finished_at = self._clock()
      self._finished_count += 1
      job.finished_order = self._finished_count
      self._purge_locked()
    job.done.set()

  def _purge_locked(self):
    now = self._clock()
    for job_id in [
        job_id for job_id, job in self._jobs.items()
        if job.finished_at is not None and now - job.finished_at > self._ttl]:
      del self._jobs[job_id]
    # Still too many, or too much: forget the answers finished longest ago.
    finished = sorted(
        (job for job in self._jobs.values() if job.finished_at is not None),
        key=lambda job: job.finished_order)
    excess = len(self._jobs) - self._max_stored
    stored_bytes = sum(len(job.body) for job in finished)
    for job in finished:
      too_many = excess > 0
      too_much = (self._max_stored_bytes is not None
                  and stored_bytes > self._max_stored_bytes)
      if not (too_many or too_much):
        break
      del self._jobs[job.id]
      excess -= 1
      stored_bytes -= len(job.body)


class Deadline:
  """Ends a connection to the router at a point in time, whatever it is doing.

  A timeout on the socket limits each read, not all of them together: an
  agent that sends a byte every few minutes would keep a job, and its place
  among the running ones, for ever.
  """

  def __init__(self, seconds, connection):
    self.passed = False
    self._connection = connection
    self._over = threading.Event()
    self._timer = threading.Timer(seconds, self._end)
    self._timer.daemon = True
    self._timer.start()

  def _end(self):
    self.passed = True
    # Again and again until the job's thread has noticed: at this moment the
    # connection may still be being set up and have no socket to shut.
    while not self._over.is_set():
      sock = self._connection.sock
      if sock is not None:
        try:
          sock.shutdown(socket.SHUT_RDWR)
        except OSError:
          pass
      self._over.wait(1.0)

  def cancel(self):
    self._timer.cancel()
    self._over.set()


def fetch_answer(server, job, upstream, path, headers, body, client_ip):
  """POSTs a job's request to the agent.

  Returns (None, the agent's status, the document for the caller) or (what
  went wrong in words for the caller, None, None).
  """
  config = server.config
  try:
    response = send_upstream(server, upstream, "POST", path, headers, body, client_ip)
  except UpstreamError as error:
    LOG.error("job %s: upstream error for POST %s: %s", job.id[:8], logged_path(path), error)
    return "could not reach the agent through the Substrate router", None, None
  problem = framing_problem(response)
  if problem:
    LOG.error("job %s: the answer to POST %s has %s", job.id[:8], logged_path(path), problem)
    return "the agent's answer was not put together properly", None, None
  try:
    limit = config.max_job_response_bytes
    data = response.read(limit + 1)
  except (OSError, http.client.HTTPException) as error:
    LOG.error("job %s: read error for POST %s: %r", job.id[:8], logged_path(path), error)
    return "the connection to the agent broke before it finished answering", None, None
  if len(data) > limit:
    return ("the agent's answer is larger than the gateway keeps "
            "(MAX_JOB_RESPONSE_BYTES)"), None, None
  # read(n) returns what it got when the connection ends early; it does not
  # complain. Half an answer must not be handed on as a whole one.
  declared = response.getheader("Content-Length")
  if declared is not None and len(data) != int(declared):
    LOG.error("job %s: POST %s answered %d of %s bytes", job.id[:8], logged_path(path),
              len(data), declared.strip())
    return "the connection to the agent broke before it finished answering", None, None
  answer = render_answer(
      job.id, response.status, response.getheader("Content-Type") or "", data)
  if len(answer) > config.max_stored_job_bytes:
    return ("the agent's answer is larger than the gateway keeps "
            "(MAX_STORED_JOB_BYTES)"), None, None
  return None, response.status, answer


def run_job(server, job, path, headers, body, client_ip):
  """Thread body: POSTs to the agent and stores what comes back."""
  config = server.config
  started = time.monotonic()
  outcome = "error"
  upstream = deadline = None
  try:
    try:
      upstream = router_connection(
          server, timeout=min(config.upstream_timeout, config.job_deadline))
    except UpstreamError as error:
      LOG.error("job %s: upstream error for POST %s: %s", job.id[:8], logged_path(path), error)
      server.jobs.finish(
          job, error="could not reach the agent through the Substrate router")
      return
    deadline = Deadline(config.job_deadline, upstream)
    error, status, answer = fetch_answer(server, job, upstream, path, headers, body, client_ip)
    if deadline.passed:
      error = ("the agent did not answer within the time one request may take "
               "(JOB_DEADLINE_SECONDS)")
    if error:
      server.jobs.finish(job, error=error)
    else:
      outcome = str(status)
      server.jobs.finish(job, http_status=status, body=answer)
  except Exception:  # pylint: disable=broad-exception-caught
    # Whatever happens, the caller polling this job must get an answer.
    LOG.exception("job %s: unexpected error", job.id[:8])
    if not job.done.is_set():
      server.jobs.finish(job, error="the gateway failed while handling this request")
  finally:
    if deadline is not None:
      deadline.cancel()
    if upstream is not None:
      upstream.close()
    LOG.info("job %s POST %s -> %s in %.3fs", job.id[:8], logged_path(path), outcome,
             time.monotonic() - started)


class GatewayHandler(http.server.BaseHTTPRequestHandler):
  """Checks each request and forwards it to atenet-router."""

  protocol_version = "HTTP/1.1"
  server_version = "looker-agent-gateway"
  sys_version = ""
  # How long one write to the caller may take, and how long a request body
  # may take to arrive in full. Longer than the upstream timeout so a slow
  # agent answer is not cut from this side first.
  timeout = 660
  # An answer is written as a head and a body. Without this the second piece
  # of every answer on a kept connection waits some 40 ms for the caller's
  # acknowledgement of the first.
  disable_nagle_algorithm = True

  # The request's Origin when it is on the allowlist, else None. Set per request.
  _cors_origin = None

  def setup(self):
    super().setup()
    self.stream = ClientStream(self.connection, self.timeout)
    self._idle_since = time.monotonic()

  def handle_one_request(self):
    """Reads one request head within its limits, and answers the request.

    http.server's own version reads the head from the socket line by line,
    with no limit on the time or the size of all lines together.
    """
    config = self.server.config
    # For an answer that has to be given before there is a request to speak of.
    self.command = self.path = self.requestline = self.request_version = ""
    try:
      try:
        head = self.stream.read_head(
            config.max_head_bytes, self._idle_since + config.head_timeout)
      except HeadTooLarge:
        self.send_error(http.HTTPStatus.REQUEST_HEADER_FIELDS_TOO_LARGE)
        return
      except TimeoutError:
        self.close_connection = True
        if self.stream.pending:  # part of a head; an idle connection just ends
          self.send_error(http.HTTPStatus.REQUEST_TIMEOUT)
        return
      if not head:
        self.close_connection = True
        return
      request_line, _, header_block = head.partition(b"\n")
      self.raw_requestline = request_line + b"\n"
      # parse_request reads the header block from rfile. It gets the bytes
      # that were read above, not the socket.
      socket_file, self.rfile = self.rfile, io.BytesIO(header_block)
      try:
        parsed = self.parse_request()
      finally:
        self.rfile = socket_file
      if not parsed:
        return  # the refusal has been sent
      problem = head_problem(head, self.request_version, self.headers)
      if problem:
        # Nothing after such a head can be trusted, least of all where it ends.
        self.close_connection = True
        self._send_simple(400, "malformed request head: " + problem)
      elif self.command not in METHODS:
        self.send_error(
            http.HTTPStatus.NOT_IMPLEMENTED, "Unsupported method (%r)" % self.command)
      else:
        self._handle()
      self.wfile.flush()
      self._idle_since = time.monotonic()
    except TimeoutError as error:
      # A read or a write took too long. Discard this connection.
      LOG.info("%s request timed out: %r", self.address_string(), error)
      self.close_connection = True

  def log_message(self, format, *args):  # pylint: disable=redefined-builtin
    LOG.info("%s %s", self.address_string(), (format % args)[:500])

  def log_request(self, code="-", size="-"):
    """One line for each answer of the gateway's own."""
    if self.command:
      request = "%s %s %s" % (self.command, logged_path(self.path), self.request_version)
    else:
      request = logged_path(self.requestline[:200])
    LOG.info('%s "%s" %s', self.address_string(), request, getattr(code, "value", code))

  def send_response_only(self, code, message=None):
    """Starts every answer, the gateway's own and the agent's."""
    super().send_response_only(code, message)
    if code >= 200:  # not after "100 Continue"
      self.send_header("X-Content-Type-Options", "nosniff")
      self.send_header("Referrer-Policy", "no-referrer")
      if self.server.serving_tls:
        self.send_header("Strict-Transport-Security", "max-age=31536000")

  def send_response(self, code, message=None):
    """Starts an answer of the gateway's own; the agent's go by send_response_only."""
    super().send_response(code, message)
    self.send_header("Cache-Control", "no-store")
    self.send_header("Content-Security-Policy", "frame-ancestors 'none'")

  def _cors_headers(self):
    if not self.server.config.cors_allowed_origins:
      return {}
    # Vary on every answer, so that no cache hands the answer for one site to another.
    headers = {"Vary": "Origin"}
    if self._cors_origin is not None:
      headers["Access-Control-Allow-Origin"] = self._cors_origin
    return headers

  def _send_body(self, status, content_type, body, extra_headers=None):
    self.send_response(status)
    self.send_header("Content-Type", content_type)
    self.send_header("Content-Length", str(len(body)))
    for name, value in self._cors_headers().items():
      self.send_header(name, value)
    for name, value in (extra_headers or {}).items():
      self.send_header(name, value)
    if self.close_connection:
      self.send_header("Connection", "close")
    self.end_headers()
    if self.command != "HEAD":
      self.wfile.write(body)

  def _send_simple(self, status, message, extra_headers=None):
    self._send_body(
        status, "text/plain; charset=utf-8", (message + "\n").encode("utf-8"),
        extra_headers)

  def _send_json(self, status, payload, extra_headers=None):
    self._send_body(status, "application/json", _json_bytes(payload), extra_headers)

  def _authenticate(self):
    """Returns who the caller is, or None when it did not prove anything.

      "open"   the gateway runs without a password and admits everyone
      "admin"  the administrator credential: may do everything
      "chat"   the chat credential: only what chat_may() allows
      "token"  a bearer token: confined like "chat"
    """
    config = self.server.config
    if not config.auth_enabled:
      return "open"
    given = self.headers.get_all("Authorization") or []
    if not given:
      return None
    if len(given) == 1:
      scheme, _, rest = given[0].partition(" ")
      scheme = scheme.lower()
      if scheme == "basic":
        if _check_basic_auth(given[0], config.basic_auth_user, config.basic_auth_password):
          return "admin"
        if config.chat_auth_enabled and _check_basic_auth(
            given[0], config.chat_auth_user, config.chat_auth_password):
          return "chat"
      elif scheme == "bearer":
        state = self.server.tokens.state(rest.strip())
        if state == "valid":
          return "token"
        if state == "expired":
          return None  # nothing to report: the chat buys the next one
    self.server.refused_credentials.note(self.client_address[0])
    return None

  def _from_another_site(self, origin):
    """True for a browser request that another web site caused."""
    site = (self.headers.get("Sec-Fetch-Site") or "").lower()
    if site in ("cross-site", "same-site"):
      # A person who follows a link to the developer UI is not an attack.
      return not (self.command == "GET"
                  and (self.headers.get("Sec-Fetch-Mode") or "").lower() == "navigate")
    if not origin:
      return False  # not a browser, or a browser on the gateway's own pages
    host = (self.headers.get("Host") or "").lower()
    return origin == "null" or urllib.parse.urlsplit(origin).netloc != host

  def _sends_json(self):
    media_type = (self.headers.get("Content-Type") or "").split(";", 1)[0]
    return media_type.strip(" \t").lower() == "application/json"

  def _handle(self):
    config = self.server.config
    started = time.monotonic()
    origin = (self.headers.get("Origin") or "").lower()
    self._cors_origin = origin if origin in config.cors_allowed_origins else None

    # The body is read further down, once the caller has been checked. Until
    # then, an answer must also end the connection: body bytes left unread on
    # a connection that stays open would be taken for the next request, and a
    # caller could hide a request of its own in them. When a proxy shares one
    # connection between several users, that request would be answered to
    # somebody else.
    keep_alive = not self.close_connection
    if self._announces_body():
      self.close_connection = True

    # The gateway's own health endpoint: never forwarded, never authenticated.
    if self.path == HEALTH_PATH:
      self._send_simple(200, "ok")
      return

    if (not self.path.startswith("/") or not self.path.isascii() or any(
        ord(char) <= 0x20 or ord(char) == 0x7f for char in self.path)):
      # Only plain paths are passed on. "http://other-host/..." as a request
      # target, for one, could mean another destination to the next hop.
      self.close_connection = True
      self._send_simple(400, "invalid request target")
      return

    # A browser asks permission before a cross-origin call, and it asks without
    # credentials. Only answered when cross-origin use is configured at all.
    if (self.command == "OPTIONS" and config.cors_allowed_origins and origin
        and self.headers.get("Access-Control-Request-Method")):
      self._answer_preflight()
      return

    if self._cors_origin is None and self._from_another_site(origin):
      # A browser attaches the administrator's remembered credential to what
      # any page asks of the gateway. Withholding the permission to read the
      # answer would not undo what the request did, so it is not carried out.
      self._send_json(403, {"error": "requests from other web sites are not accepted"})
      return

    proof = self._authenticate()
    if proof is None:
      self._send_simple(
          401, "authentication required",
          {"WWW-Authenticate": 'Basic realm="looker-agent", charset="UTF-8"'})
      return

    if "upgrade" in (self.headers.get("Connection", "").lower()) or self.headers.get("Upgrade"):
      self._send_simple(501, "protocol upgrades (WebSocket) are not supported by this gateway")
      return

    confined = proof in ("chat", "token")
    if confined and not chat_may(self.command, self.path, config.adk_app_name):
      # Refused here, never forwarded: the developer API is not for the chat.
      self._send_json(403, {
          "error": "this credential is for the chat only: it may start and "
                   "poll agent turns and fetch their artifacts"})
      return

    split = urllib.parse.urlsplit(self.path)
    own_path = split.path == GATEWAY_ROOT or split.path.startswith(GATEWAY_ROOT + "/")
    if self.command == "POST" and split.path.startswith(JOBS_PREFIX) and not self._sends_json():
      # A job is passed on as JSON. Were the type supplied here for a caller
      # that names none, a form on any web page could post JSON to the agent.
      self._send_json(415, {"error": "a job needs Content-Type: application/json"})
      return

    body = self._read_body(
        config.max_chat_request_bytes if confined else config.max_request_bytes)
    if body is None:
      return
    # The body has been read to its end: the connection can be used again.
    self.close_connection = not keep_alive

    headers = self._headers_to_pass_on(confined)
    if confined:
      try:
        body = self._chat_body(split.path, body, headers)
      except ValueError as problem:
        self._send_json(400, {"error": "not a request a chat may send: %s" % problem})
        return

    if own_path:
      # Never forwarded: these paths belong to the gateway.
      self._handle_gateway_path(split, body, headers, confined, proof)
      return

    upstream = None
    try:
      upstream = router_connection(self.server)
      response = send_upstream(
          self.server, upstream, self.command, self.path, headers, body,
          self.client_address[0])
    except UpstreamError as error:
      if upstream is not None:
        upstream.close()
      LOG.error("upstream error for %s %s: %s", self.command, logged_path(self.path), error)
      self._send_simple(502, "could not reach the agent through the Substrate router")
      return

    status = response.status
    try:
      problem = framing_problem(response)
      if problem:
        LOG.error("the answer to %s %s has %s", self.command, logged_path(self.path), problem)
        status = 502
        self._send_simple(502, "the agent's answer was not put together properly")
      else:
        self._relay_response(response, confined)
    except (BrokenPipeError, ConnectionResetError):
      # The caller went away mid-response.
      self.close_connection = True
    except (OSError, http.client.HTTPException) as error:
      LOG.error("relay error for %s %s: %r", self.command, logged_path(self.path), error)
      self.close_connection = True
    finally:
      upstream.close()
      LOG.info("%s %s -> %s in %.3fs", self.command, logged_path(self.path), status,
               time.monotonic() - started)

  def _headers_to_pass_on(self, confined):
    """The caller's headers as the router and the agent get them.

    For a confined caller, a short list and the gateway's own Host. For the
    administrator, all but the ones named at the top of this file, and the
    Host as sent: ADK's developer UI compares it with the browser's Origin.
    """
    config = self.server.config
    named_by_connection = {
        token.strip().lower()
        for token in self.headers.get("Connection", "").split(",") if token.strip()}
    host = None if confined else self.headers.get("Host")
    passed = [("Host", host or config.router_server_name)]
    for name, value in self.headers.items():
      lowered = name.lower()
      if lowered in HOP_BY_HOP or lowered in named_by_connection:
        continue
      if confined:
        if lowered in CONFINED_REQUEST_HEADERS:
          passed.append((name, value))
      elif lowered not in NEVER_FORWARDED and not lowered.startswith(NEVER_FORWARDED_PREFIXES):
        passed.append((name, value))
    return passed

  def _chat_body(self, path, body, headers):
    """The body of a confined caller's request as it is passed on.

    Raises ValueError, with what is wrong, for a request a chat may not send.
    """
    config = self.server.config
    text = ""
    if path == RUN_JOB_PATH:
      body, text = chat_run_request(body, config.adk_app_name)
    elif self.command == "POST" and path != TOKEN_PATH:
      # A new conversation takes no settings from a chat.
      if body not in (b"", b"{}"):
        raise ValueError('the body has to be empty or "{}"')
    elif body:
      raise ValueError("this request has no body")
    # Looker puts the chat's credential in wherever a caller writes its
    # placeholder. In anything the agent gets, it could come back in an answer.
    passed_on = [self.path, text] + [value for _, value in headers]
    if config.carries_chat_credential(body) or any(
        config.carries_chat_credential(item.encode("utf-8")) for item in passed_on):
      raise ValueError("it carries the gateway credential")
    return body

  def _announces_body(self):
    """Whether a body may follow the request head.

    Also true for a head that is not clear about it. Two length headers are
    malformed even when they agree, and nothing that follows such a request
    on the connection is trusted.
    """
    if self.headers.get("Transfer-Encoding") is not None:
      return True
    lengths = self.headers.get_all("Content-Length") or []
    return len(lengths) > 1 or any(
        value.strip(" \t") not in ("", "0") for value in lengths)

  def _read_body(self, limit):
    """Reads a request body of at most `limit` bytes.

    Answers the caller and returns None when it cannot. Where the body ends
    must be beyond doubt: a proxy that guesses is how one request gets hidden
    inside another.
    """
    self.close_connection = True  # until the body has been read to its end
    deadline = time.monotonic() + self.timeout
    encodings = self.headers.get_all("Transfer-Encoding") or []
    lengths = self.headers.get_all("Content-Length") or []
    if encodings:
      # Some HTTP clients send even a small body in chunks, and which client
      # Looker's server proxy uses is not documented. So chunks are read.
      if len(encodings) > 1 or encodings[0].strip(" \t").lower() != "chunked" or lengths:
        # Another coding, or two statements about where the body ends.
        self._send_simple(400, "unsupported or ambiguous Transfer-Encoding")
        return None
      body, problem = read_chunked(self.stream, limit, deadline)
      if problem:
        self._send_simple(413 if problem == "too large" else 400, "request body: " + problem)
        return None
      return body
    if len(lengths) > 1:
      self._send_simple(400, "more than one Content-Length")
      return None
    # Digits only, with at most spaces or tabs around them. int() would also
    # take "+5", "5_0" and digits of other scripts.
    text = lengths[0].strip(" \t") if lengths else "0"
    if not _DECIMAL.fullmatch(text) or len(text) > 18:
      self._send_simple(400, "invalid Content-Length")
      return None
    length = int(text)
    if length > limit:
      self._send_simple(413, "request body too large")
      return None
    body = self.stream.read(length, deadline)
    if len(body) != length:
      return None
    return body

  def _answer_preflight(self):
    # A preflight has no body. If this one announced one, it is not read, and
    # the connection ends with the answer (see _handle).
    if self._cors_origin is None:
      self._send_simple(403, "this origin is not allowed to call the gateway")
      return
    self.send_response(204)
    for name, value in self._cors_headers().items():
      self.send_header(name, value)
    self.send_header("Access-Control-Allow-Methods", CORS_ALLOW_METHODS)
    self.send_header("Access-Control-Allow-Headers", CORS_ALLOW_HEADERS)
    self.send_header("Access-Control-Max-Age", "600")
    if self.close_connection:
      self.send_header("Connection", "close")
    self.end_headers()

  def _handle_gateway_path(self, split, body, headers, confined, proof):
    if split.path == TOKEN_PATH:
      if self.command != "POST":
        self._send_json(405, {"error": "use POST"}, {"Allow": "POST"})
        return
      if proof == "token":
        # A token must not be able to renew itself for ever.
        self._send_json(
            401, {"error": "the token endpoint takes the Basic credential"},
            {"WWW-Authenticate": 'Basic realm="looker-agent", charset="UTF-8"'})
        return
      token, ttl = self.server.tokens.issue()
      self._send_json(
          200, {"access_token": token, "token_type": "Bearer", "expires_in": ttl})
      return
    if split.path.startswith(JOBS_PREFIX):
      rest = split.path[len(JOBS_PREFIX):]
      if self.command == "POST":
        self._start_job(rest, split.query, body, headers, confined)
      elif self.command == "GET":
        self._show_job(rest, split.query, confined)
      else:
        self._send_json(405, {"error": "use POST or GET"}, {"Allow": "GET, POST"})
      return
    self._send_json(404, {"error": "unknown gateway path"})

  def _start_job(self, rest, query, body, headers, confined):
    agent_path = "/" + rest
    if not rest or agent_path == GATEWAY_ROOT or agent_path.startswith(GATEWAY_ROOT + "/"):
      self._send_json(
          400, {"error": "name the agent path to call, for example /_gateway/jobs/run"})
      return
    if query:
      agent_path += "?" + query
    job = self.server.jobs.create(confined)
    if job is None:
      self._send_json(
          429, {"error": "too many requests are already in progress"},
          {"Retry-After": "5"})
      return
    # A job is the caller's POST without the caller: only what the agent needs
    # to read the body goes with it.
    job_headers = [headers[0], ("Content-Type", "application/json"),
                   ("Accept", "application/json")]
    thread = threading.Thread(
        target=run_job, name="job-" + job.id[:8], daemon=True,
        args=(self.server, job, agent_path, job_headers, body, self.client_address[0]))
    try:
      thread.start()
    except RuntimeError:
      # No thread to be had. Nothing would ever finish the job, and a running
      # job keeps its place for as long as it runs: end it here.
      self.server.jobs.finish(job, error="the gateway could not start the request")
      self._send_json(
          503, {"error": "the gateway is too busy to start another request"},
          {"Retry-After": "5"})
      return
    self._send_body(202, "application/json", job.answer())

  def _show_job(self, job_id, query, confined):
    wait = 0.0
    values = urllib.parse.parse_qs(query).get("wait")
    if values:
      try:
        wait = float(values[0])
      except ValueError:
        wait = math.nan
      if not math.isfinite(wait):
        self._send_json(400, {"error": "wait must be a number of seconds"})
        return
    job = self.server.jobs.get(job_id)
    if job is None or (confined and not job.confined):
      # The same answer for a job that is not the chat's as for none at all.
      self._send_json(404, {"error": "unknown or expired job"})
      return
    wait = max(0.0, min(wait, self.server.config.max_job_wait))
    if wait > 0:
      job.done.wait(wait)
    self._send_body(200, "application/json", job.answer())

  def _relay_response(self, response, confined):
    """Passes on an answer whose framing framing_problem() found in order."""
    has_body = not (self.command == "HEAD" or response.status in (204, 304))
    announced = response.getheader("Content-Length")
    length = int(announced) if announced is not None else None
    # Re-frame with chunked encoding when the upstream did not announce a
    # length, which is the streaming (server-sent events) case.
    rechunk = has_body and length is None
    http10_client = self.request_version == "HTTP/1.0"

    dropped = set(HOP_BY_HOP) | OWN_RESPONSE_HEADERS
    dropped.update(
        token.strip().lower()
        for token in (response.getheader("Connection") or "").split(",") if token.strip())
    if confined:
      dropped.update(CONFINED_RESPONSE_DROPS)

    self.send_response_only(response.status, response.reason)
    for name, value in response.getheaders():
      lowered = name.lower()
      if lowered in dropped:
        continue
      if lowered.startswith("access-control-"):
        # Which sites may read an answer is this gateway's decision
        # (CORS_ALLOWED_ORIGINS), never the agent's.
        continue
      self.send_header(name, value)
    if confined:
      self.send_header("Cache-Control", "no-store")
    for name, value in self._cors_headers().items():
      self.send_header(name, value)
    if length is not None:
      self.send_header("Content-Length", str(length))
    if rechunk and not http10_client:
      self.send_header("Transfer-Encoding", "chunked")
    if rechunk and http10_client:
      # HTTP/1.0 has no chunking: the end of the body is the end of the connection.
      self.close_connection = True
    if self.close_connection:
      self.send_header("Connection", "close")
    self.end_headers()

    if not has_body:
      return
    written = 0
    while True:
      # read1 returns what has arrived instead of waiting to fill the buffer,
      # so streamed events reach the caller as they are produced.
      chunk = response.read1(65536)
      if not chunk:
        break
      written += len(chunk)
      if rechunk and not http10_client:
        self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
      else:
        self.wfile.write(chunk)
      self.wfile.flush()
    if rechunk and not http10_client:
      self.wfile.write(b"0\r\n\r\n")
      self.wfile.flush()
    elif length is not None and written != length:
      # The agent stopped short of the length that the caller has been told.
      # Only the end of the connection can say so now.
      LOG.error("the answer to %s %s ended after %d of %d bytes", self.command,
                logged_path(self.path), written, length)
      self.close_connection = True


class GatewayServer(http.server.ThreadingHTTPServer):
  """Serves a limited number of connections at once, each in a thread of its own."""

  daemon_threads = True
  allow_reuse_address = True
  # Connections that wait to be accepted. http.server's 5 are full after a
  # handful of callers arriving together, and the rest wait a second.
  request_queue_size = 128

  _BUSY = (b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain; charset=utf-8\r\n"
           b"Content-Length: 21\r\nRetry-After: 1\r\nConnection: close\r\n\r\n"
           b"too many connections\n")

  def __init__(self, config):
    self.config = config
    self.router_tls = TlsContextCache(
        (config.router_ca_file, config.client_cred_bundle), router_client_context,
        "client certificate or router CA")
    self.serving_tls = None
    if config.tls_enabled:
      self.serving_tls = TlsContextCache(
          (config.tls_cert_file, config.tls_key_file), serving_context,
          "serving certificate", keep_last_good=True)
      self.serving_tls.get()  # not to find out at the first caller that it cannot be read
    self.tokens = TokenSigner(config.token_ttl)
    self.jobs = JobStore(
        config.job_ttl, config.max_running_jobs, config.max_stored_jobs,
        config.max_stored_job_bytes, config.max_chat_running_jobs)
    self.refused_credentials = RefusalLog()
    self._places = threading.BoundedSemaphore(config.max_connections)
    super().__init__((config.listen_host, config.listen_port), GatewayHandler)

  def process_request(self, request, client_address):
    """Called for each new connection, in the one thread that accepts them."""
    if not self._places.acquire(blocking=False):
      self._turn_away(request)
      return
    try:
      super().process_request(request, client_address)  # starts the connection's thread
    except BaseException:
      self._places.release()
      raise

  def _turn_away(self, request):
    """Ends a connection for which there is no place, without waiting for anything.

    Over plain HTTP it is told why. Over TLS that would take a handshake,
    which is the very work the limit keeps away.
    """
    try:
      request.settimeout(0)
      if self.serving_tls is None:
        try:
          request.recv(65536)  # unread bytes would turn the close into a reset
        except OSError:
          pass
        request.send(self._BUSY)
    except OSError:
      pass
    self.shutdown_request(request)

  def process_request_thread(self, request, client_address):
    """The connection's own thread: the TLS handshake, if any, and then the requests."""
    try:
      if self.serving_tls is not None:
        request = self._handshake(request, client_address)
      if request is not None:
        super().process_request_thread(request, client_address)
    finally:
      self._places.release()

  def _handshake(self, request, client_address):
    """Returns the connection with TLS on it, or None when the caller did not manage."""
    try:
      # A handshake has as long as a request head, in all.
      request.settimeout(self.config.head_timeout)
      return self.serving_tls.get().wrap_socket(request, server_side=True)
    except OSError as error:  # ssl.SSLError is one
      LOG.info("TLS handshake with %s failed: %s", client_address[0], error)
      self.shutdown_request(request)
      return None

  def handle_error(self, request, client_address):
    """A connection that ended badly is a line in the log, not a traceback on stderr."""
    error = sys.exc_info()[1]
    if isinstance(error, (ConnectionError, TimeoutError, ssl.SSLError)):
      LOG.info("%s connection ended: %r", client_address[0], error)
    else:
      LOG.exception("%s unexpected error while serving the connection", client_address[0])


class HealthListener:
  """Answers GET /healthz on a port of its own, for the kubelet's probes.

  One thread serves all its connections and waits for none of them. So the
  answer comes when the main listener has no place left, and when the process
  can start no further thread. When its own few places are taken, the oldest
  connection makes room for the newest: a caller that connects and sends
  nothing cannot keep the kubelet out.
  """

  MAX_CONNECTIONS = 32
  MAX_HEAD_BYTES = 2048
  HEAD_TIMEOUT = 5.0
  _ANSWER = (b"HTTP/1.1 %s\r\nContent-Type: text/plain; charset=utf-8\r\n"
             b"Content-Length: %d\r\nCache-Control: no-store\r\n"
             b"X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n")

  def __init__(self, host, port):
    self._listener = socket.create_server((host, port), backlog=128)
    self._listener.setblocking(False)
    self.port = self._listener.getsockname()[1]
    self._selector = selectors.DefaultSelector()
    self._selector.register(self._listener, selectors.EVENT_READ)
    self._connections = {}  # socket -> [bytes received, time accepted]; oldest first
    self._stopping = threading.Event()

  def serve_forever(self):
    while not self._stopping.is_set():
      for key, _ in self._selector.select(timeout=0.5):
        if key.fileobj is self._listener:
          self._accept()
        else:
          self._read(key.fileobj)
      self._drop_overdue()
    for connection in list(self._connections):
      self._close(connection)
    self._selector.close()
    self._listener.close()

  def stop(self):
    self._stopping.set()

  def _accept(self):
    for _ in range(self.MAX_CONNECTIONS):  # then the ones that are waiting get their turn
      try:
        connection, _ = self._listener.accept()
      except OSError:
        return
      connection.setblocking(False)
      if len(self._connections) >= self.MAX_CONNECTIONS:
        self._close(next(iter(self._connections)))
      self._connections[connection] = [bytearray(), time.monotonic()]
      self._selector.register(connection, selectors.EVENT_READ)

  def _read(self, connection):
    if connection not in self._connections:
      return  # closed a moment ago, to make room
    received = self._connections[connection][0]
    try:
      chunk = connection.recv(self.MAX_HEAD_BYTES)
    except BlockingIOError:
      return
    except OSError:
      chunk = b""
    received += chunk
    complete = b"\r\n\r\n" in received
    if chunk and not complete and len(received) < self.MAX_HEAD_BYTES:
      return  # the rest of the head is still to come
    if complete:
      try:
        connection.send(self._answer_to(bytes(received)))
      except OSError:
        pass
    self._close(connection)

  def _answer_to(self, head):
    words = head.split(b"\r\n", 1)[0].split(b" ")
    asked = len(words) == 3 and words[2] in (b"HTTP/1.0", b"HTTP/1.1") and words[:2]
    if asked == [b"GET", HEALTH_PATH.encode("ascii")]:
      return self._ANSWER % (b"200 OK", 3) + b"ok\n"
    if asked == [b"HEAD", HEALTH_PATH.encode("ascii")]:
      return self._ANSWER % (b"200 OK", 3)
    return self._ANSWER % (b"404 Not Found", 10) + b"not found\n"

  def _drop_overdue(self):
    now = time.monotonic()
    for connection, (_, accepted) in list(self._connections.items()):
      if now - accepted < self.HEAD_TIMEOUT:
        break
      self._close(connection)

  def _close(self, connection):
    del self._connections[connection]
    self._selector.unregister(connection)
    connection.close()


def main():
  handler = logging.StreamHandler(sys.stdout)
  handler.setFormatter(LineFormatter("%(asctime)s %(levelname)s %(message)s"))
  logging.basicConfig(level=logging.INFO, handlers=[handler])
  health = None
  try:
    config = Config()
    config.validate()
    if config.health_port:
      health = HealthListener(config.listen_host, config.health_port)
    server = GatewayServer(config)
  except (ValueError, OSError) as error:
    # A setting that is wrong, a certificate that cannot be read, a port that is taken.
    LOG.error("configuration error: %s", error)
    return 2

  if not config.auth_enabled:
    LOG.warning(
        "ALLOW_UNAUTHENTICATED=true: anyone who can reach this gateway can use "
        "the agent and its developer API")
  LOG.info(
      "listening on %s:%d (%s), forwarding to %s:%d (server name %s) for actor %s",
      config.listen_host, server.server_address[1], "TLS" if config.tls_enabled else "plain HTTP",
      config.router_host, config.router_port, config.router_server_name, config.target_actor)
  if health is not None:
    LOG.info("answering %s on port %d as well", HEALTH_PATH, health.port)
    threading.Thread(target=health.serve_forever, name="health", daemon=True).start()
  if config.cors_allowed_origins:
    LOG.info("cross-origin callers allowed from: %s",
             ", ".join(sorted(config.cors_allowed_origins)))
  if config.auth_enabled and not config.chat_auth_enabled:
    LOG.warning(
        "CHAT_AUTH_USER/CHAT_AUTH_PASSWORD are not set: do not give the "
        "administrator password to a chat front end, it opens the agent's "
        "developer API to every chat user")

  def stop(signum, _frame):
    LOG.info("signal %d received, shutting down", signum)
    # shutdown() blocks until serve_forever returns, so call it off this thread.
    threading.Thread(target=server.shutdown, daemon=True).start()

  signal.signal(signal.SIGTERM, stop)
  signal.signal(signal.SIGINT, stop)
  server.serve_forever()
  server.server_close()
  if health is not None:
    health.stop()
  return 0


if __name__ == "__main__":
  sys.exit(main())
