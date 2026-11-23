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

"""Local test for the agent's tools (agents/looker_app/agent.py).

Standard library only. The Looker SDK, ADK and google.genai are not needed:
recording stand-ins take their place, so the tool functions are the kit's own
and everything they would ask of Looker is written down instead of sent.

It covers what this kit changed in the agent, and nothing of what the agent
does with a model:
  * links are plain page addresses unless LOOKER_LINK_MODE says "signed",
  * LOOKER_MODELS limits every tool that takes a model,
  * ids and names from the model are checked before use, `limit` is bounded,
  * no tool holds up the event loop while it waits for Looker,
  * an error from Looker is passed on as one short line,
  * and the tools are still what ADK reads them as: same names, docstrings and
    parameters.

Run:  python3 test_agent_tools.py
"""

import asyncio
import hashlib
import importlib.util
import inspect
import json
import os
import sys
import threading
import time
import types
import typing
import unittest
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT_FILE = os.path.join(HERE, "agents", "looker_app", "agent.py")
API_HOST = "looker-api.looker.svc.cluster.local"
# The instruction of the Agent Engine original, as a fingerprint. With
# LOOKER_LINK_MODE="signed" the agent's instruction must be exactly that text.
ORIGINAL_INSTRUCTION_SHA256 = "529893700fd58c1396bb8ea4233c862d7c9f3b36caca92edf5e262189be74ac4"
SIGNED_SENTENCE = (
    "A real link looks like https://<host>/login/embed/...&signature=...; if you "
    "are about to output anything else (e.g. a plain /embed/dashboards/... URL, or "
    "a host you were not given by a tool), STOP - that is wrong. ")
PLAIN_SENTENCE = (
    "A real link looks like https://<host>/dashboards/..., https://<host>/looks/... "
    "or https://<host>/explore/...; if you are about to output anything else (e.g. "
    "a /login/embed/... or /embed/... URL, or a host you were not given by a tool), "
    "STOP - that is wrong. ")
TOOL_NAMES = [
    "show_dashboard_inline", "show_look_inline", "show_query_inline",
    "get_dashboard_link", "get_look_link", "get_explore_link",
    "query_looker_data", "list_looker_models", "list_looker_explores",
    "list_looker_fields", "list_available_dashboards", "list_dashboard_filters",
]


class FakeLooker:
  """What the stand-in SDK does, and what it was asked."""

  def __init__(self):
    self.reset()

  def reset(self):
    self.calls = []           # (method name, keyword arguments)
    self.on_main_thread = []  # one entry per call
    self.delay = 0.0          # seconds each call blocks, like a slow network
    self.running_polls = 0    # render_task answers "running" this many times
    self.error = None         # raised by every call when set
    self.models = ["thelook", "hr_private", "system__activity"]

  def names(self):
    return [name for name, _ in self.calls]


LOOKER = FakeLooker()


class _Record:
  """A model of the SDK (WriteQuery, EmbedSsoParams, ...): just its fields."""

  def __init__(self, **fields):
    self.__dict__.update(fields)


class _Sdk:
  """looker_sdk.init40(): every method records its call."""

  def __init__(self):
    self._polls = 0

  def _call(self, name, **arguments):
    LOOKER.calls.append((name, arguments))
    LOOKER.on_main_thread.append(threading.current_thread() is threading.main_thread())
    if LOOKER.delay:
      time.sleep(LOOKER.delay)  # blocks its thread, as a real request does
    if LOOKER.error is not None:
      raise LOOKER.error

  def create_sso_embed_url(self, body):
    self._call("create_sso_embed_url", body=body)
    return types.SimpleNamespace(url="https://looker.example.com/login/embed/x?signature=made-by-looker")

  def create_dashboard_render_task(self, **arguments):
    self._call("create_dashboard_render_task", **arguments)
    return types.SimpleNamespace(id="task-1")

  def render_task(self, task_id):
    self._call("render_task", task_id=task_id)
    self._polls += 1
    return types.SimpleNamespace(
        status="success" if self._polls > LOOKER.running_polls else "running")

  def render_task_results(self, task_id):
    self._call("render_task_results", task_id=task_id)
    return b"\x89PNG\r\n\x1a\n"

  def run_look(self, **arguments):
    self._call("run_look", **arguments)
    return b"\x89PNG\r\n\x1a\n"

  def create_query(self, body):
    self._call("create_query", body=body)
    return types.SimpleNamespace(id=7)

  def run_query(self, **arguments):
    self._call("run_query", **arguments)
    if arguments.get("result_format") == "png":
      return b"\x89PNG\r\n\x1a\n"
    return json.dumps([{"orders.status": "complete", "orders.count": 42}])

  def all_lookml_models(self):
    self._call("all_lookml_models")
    return [types.SimpleNamespace(name=name, explores=[types.SimpleNamespace(name="orders")])
            for name in LOOKER.models]

  def lookml_model(self, **arguments):
    self._call("lookml_model", **arguments)
    return types.SimpleNamespace(explores=[types.SimpleNamespace(name="orders")])

  def lookml_model_explore(self, **arguments):
    self._call("lookml_model_explore", **arguments)
    return types.SimpleNamespace(fields=None)

  def search_dashboards(self, **arguments):
    self._call("search_dashboards", **arguments)
    return [types.SimpleNamespace(id=3, title="Sales")]

  def dashboard(self, **arguments):
    self._call("dashboard", **arguments)
    return types.SimpleNamespace(dashboard_filters=[])


class ToolContext:
  """ADK's ToolContext, as far as the tools use it."""

  def __init__(self):
    self.saved = []

  async def save_artifact(self, filename, artifact):
    self.saved.append(filename)
    return 0


class _Keeps:
  """LlmAgent, BuiltInPlanner, ThinkingConfig: they keep what they are given."""

  def __init__(self, **settings):
    self.__dict__.update(settings)


LOAD_ARTIFACTS_TOOL = object()


def install_stand_ins():
  """Puts stand-ins for the packages agent.py imports into sys.modules."""
  def module(name, **attributes):
    made = types.ModuleType(name)
    made.__dict__.update(attributes)
    sys.modules[name] = made
    return made

  models40 = types.SimpleNamespace(
      EmbedSsoParams=_Record, CreateDashboardRenderTask=_Record, WriteQuery=_Record)
  module("looker_sdk", init40=_Sdk, models40=models40)
  module("google")
  module("google.adk")
  module("google.adk.agents", LlmAgent=_Keeps)
  module("google.adk.planners")
  module("google.adk.planners.built_in_planner", BuiltInPlanner=_Keeps)
  module("google.adk.tools", ToolContext=ToolContext)
  module("google.adk.tools.load_artifacts_tool", load_artifacts_tool=LOAD_ARTIFACTS_TOOL)
  module("google.genai")
  module("google.genai.types", ThinkingConfig=_Keeps,
         Part=types.SimpleNamespace(from_bytes=lambda data, mime_type: (mime_type, data)))


_LOADED = [0]


def load_agent(**settings):
  """Imports agent.py afresh, with the environment it would have as an actor."""
  environment = {
      "LOOKERSDK_BASE_URL": "https://" + API_HOST,
      "LOOKER_PUBLIC_URL": "https://looker.example.com",
      "LOOKER_MODELS": '["thelook"]',
      "AGENT_MODEL_PROVIDER": "gemini",
  }
  environment.update(settings)
  names = set(environment) | {"LOOKER_LINK_MODE"}
  saved = {name: os.environ.get(name) for name in names}
  try:
    for name in names:
      os.environ.pop(name, None)
    os.environ.update({name: value for name, value in environment.items() if value is not None})
    _LOADED[0] += 1
    spec = importlib.util.spec_from_file_location("agent_under_test_%d" % _LOADED[0], AGENT_FILE)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    # _brief() and _models_list() read the environment when called.
    loaded.TEST_ENVIRONMENT = dict(os.environ)
    return loaded
  finally:
    for name, value in saved.items():
      if value is None:
        os.environ.pop(name, None)
      else:
        os.environ[name] = value


def tools_of(agent):
  """The tools as the agent lists them for ADK, by name."""
  return {tool.__name__: tool for tool in agent.root_agent.tools if tool is not LOAD_ARTIFACTS_TOOL}


async def longest_pause_while(awaitable):
  """Awaits `awaitable` next to a coroutine that only ticks.

  Returns the result and the longest time the ticking coroutine was kept
  waiting: what every other request to the server would have waited too.
  """
  pauses = []
  done = asyncio.Event()

  async def tick():
    last = time.monotonic()
    while not done.is_set():
      await asyncio.sleep(0.01)
      now = time.monotonic()
      pauses.append(now - last)
      last = now

  ticking = asyncio.create_task(tick())
  await asyncio.sleep(0.05)
  try:
    result = await awaitable
  finally:
    done.set()
    await ticking
  return result, max(pauses)


class AgentToolsTest(unittest.TestCase):

  @classmethod
  def setUpClass(cls):
    cls.saved_modules = dict(sys.modules)
    cls.saved_environment = dict(os.environ)
    install_stand_ins()
    os.environ["LOOKERSDK_BASE_URL"] = "https://" + API_HOST
    os.environ["LOOKER_MODELS"] = '["thelook"]'
    cls.plain = load_agent()
    cls.signed = load_agent(LOOKER_LINK_MODE="signed")

  @classmethod
  def tearDownClass(cls):
    for name in list(sys.modules):
      if name not in cls.saved_modules:
        del sys.modules[name]
    sys.modules.update(cls.saved_modules)
    os.environ.clear()
    os.environ.update(cls.saved_environment)

  def setUp(self):
    LOOKER.reset()

  def call(self, agent, name, *args, **kwargs):
    """Calls a tool the way ADK does: the listed function, awaited."""
    return asyncio.run(tools_of(agent)[name](*args, **kwargs))

  def assert_refused(self, result, *words):
    self.assertEqual(result.get("status"), "error", result)
    for word in words:
      self.assertIn(word, result["message"])
    self.assertEqual(LOOKER.calls, [], "Looker was asked all the same")


class LinkModeTest(AgentToolsTest):

  def test_a_link_is_the_ordinary_page_and_looker_is_not_asked_for_a_signed_one(self):
    self.assertEqual(self.plain.LOOKER_LINK_MODE, "plain")
    self.assertEqual(
        self.call(self.plain, "get_dashboard_link", dashboard_id="12", filters={"Country": "Brazil", "Created Date": "30 days"}),
        {"status": "success",
         "signed_url": "https://looker.example.com/dashboards/12?Country=Brazil&Created+Date=30+days"})
    self.assertEqual(
        self.call(self.plain, "get_dashboard_link", dashboard_id="thelook::overview"),
        {"status": "success", "signed_url": "https://looker.example.com/dashboards/thelook::overview"})
    self.assertEqual(
        self.call(self.plain, "get_look_link", look_id="5"),
        {"status": "success", "signed_url": "https://looker.example.com/looks/5"})
    self.assertEqual(
        self.call(self.plain, "get_explore_link", model="thelook", explore="order_items"),
        {"status": "success", "signed_url": "https://looker.example.com/explore/thelook/order_items"})
    # No call to Looker at all, least of all for a signed URL.
    self.assertEqual(LOOKER.calls, [])

  def test_signed_mode_keeps_the_original_links(self):
    self.assertEqual(self.signed.LOOKER_LINK_MODE, "signed")
    result = self.call(self.signed, "get_dashboard_link", dashboard_id="12", filters={"Country": "Brazil"})
    self.assertEqual(result, {
        "status": "success",
        "signed_url": "https://looker.example.com/login/embed/x?signature=made-by-looker"})
    ((name, arguments),) = LOOKER.calls
    self.assertEqual(name, "create_sso_embed_url")
    self.assertEqual(vars(arguments["body"]), {
        "target_url": "https://looker.example.com/embed/dashboards/12?Country=Brazil",
        "session_length": 3600,
        "force_logout_login": True,
        "external_user_id": "gemini-user",
        "first_name": "Gemini",
        "last_name": "User",
        "permissions": ["access_data", "see_looks", "see_user_dashboards", "see_lookml_dashboards",
                        "explore", "save_content", "embed_browse_spaces"],
        "models": ["thelook"],
    })
    LOOKER.reset()
    self.call(self.signed, "get_look_link", look_id="5")
    self.call(self.signed, "get_explore_link", model="thelook", explore="order_items")
    self.assertEqual(
        [arguments["body"].target_url for _, arguments in LOOKER.calls],
        ["https://looker.example.com/embed/looks/5",
         "https://looker.example.com/embed/explore/thelook/order_items"])

  def test_only_the_word_signed_asks_for_signed_links(self):
    for setting, mode in ((None, "plain"), ("", "plain"), ("plain", "plain"), ("yes", "plain"),
                          ("true", "plain"), ("SIGNED", "signed"), (" signed ", "signed")):
      agent = load_agent(LOOKER_LINK_MODE=setting)
      LOOKER.reset()
      url = self.call(agent, "get_look_link", look_id="5")["signed_url"]
      asked = LOOKER.names()
      if mode == "signed":
        self.assertEqual(asked, ["create_sso_embed_url"], setting)
      else:
        self.assertEqual((url, asked), ("https://looker.example.com/looks/5", []), setting)

  def test_the_instruction_is_the_original_but_for_one_sentence(self):
    signed = self.signed.root_agent.instruction
    plain = self.plain.root_agent.instruction
    # "signed": the Agent Engine original, to the letter.
    self.assertEqual(hashlib.sha256(signed.encode()).hexdigest(), ORIGINAL_INSTRUCTION_SHA256)
    self.assertEqual(signed.count(SIGNED_SENTENCE), 1)
    # "plain": the same text with the one sentence that says what a link looks like.
    self.assertEqual(plain, signed.replace(SIGNED_SENTENCE, PLAIN_SENTENCE))
    self.assertNotIn("signature=", plain)
    # Nothing else about the agent changed with the mode.
    for field in ("name", "description", "model"):
      self.assertEqual(getattr(self.plain.root_agent, field), getattr(self.signed.root_agent, field))


class ModelListTest(AgentToolsTest):

  def test_a_tool_is_not_used_with_a_model_outside_looker_models(self):
    for agent in (self.plain, self.signed):
      for model in ("hr_private", "system__activity", "THELOOK", "thelook2"):
        attempts = {
            "query_looker_data": dict(model=model, explore="salaries", fields=["employees.salary"]),
            "show_query_inline": dict(model=model, explore="user", fields=["user.email"], tool_context=ToolContext()),
            "list_looker_explores": dict(model=model),
            "list_looker_fields": dict(model=model, explore="salaries"),
            "get_explore_link": dict(model=model, explore="salaries"),
        }
        for name, arguments in attempts.items():
          with self.subTest(tool=name, model=model, mode=agent.LOOKER_LINK_MODE):
            LOOKER.reset()
            result = self.call(agent, name, **arguments)
            self.assert_refused(result, model, "not one this agent may use", "thelook")
            if "tool_context" in arguments:
              self.assertEqual(arguments["tool_context"].saved, [])

  def test_a_listed_model_is_used_as_before(self):
    result = self.call(
        self.plain, "query_looker_data", model="thelook", explore="orders",
        fields=["orders.status", "orders.count"], filters={"orders.status": "complete"},
        sorts=["orders.count desc"], limit=10)
    self.assertEqual(result, {
        "status": "success", "row_count": 1, "rows": [{"orders.status": "complete", "orders.count": 42}]})
    (_, created), (_, run) = LOOKER.calls
    self.assertEqual(vars(created["body"]), {
        "model": "thelook", "view": "orders", "fields": ["orders.status", "orders.count"],
        "filters": {"orders.status": "complete"}, "sorts": ["orders.count desc"], "limit": "10"})
    self.assertEqual(run, {"query_id": "7", "result_format": "json"})

    LOOKER.reset()
    context = ToolContext()
    result = self.call(self.plain, "show_query_inline", model="thelook", explore="orders",
                       fields=["orders.count"], tool_context=context)
    self.assertEqual(result["status"], "success")
    self.assertEqual(context.saved, ["query_thelook_orders.png"])
    self.assertEqual(LOOKER.names(), ["create_query", "run_query"])
    for name, arguments in (("list_looker_explores", dict(model="thelook")),
                            ("list_looker_fields", dict(model="thelook", explore="orders"))):
      LOOKER.reset()
      self.assertEqual(self.call(self.plain, name, **arguments)["status"], "success")
      self.assertEqual(len(LOOKER.calls), 1)

  def test_only_listed_models_are_shown(self):
    result = self.call(self.plain, "list_looker_models")
    self.assertEqual(result, {"status": "success", "models": [{"model": "thelook", "explores": ["orders"]}]})

  def test_the_list_is_read_from_looker_models_in_every_spelling(self):
    for setting, allowed in (('["thelook", "finance"]', ["thelook", "finance"]),
                             ("thelook, finance", ["thelook", "finance"]),
                             ('"finance"', ["finance"]),
                             ("[]", []), ("", []), (None, ["thelook"])):
      agent = load_agent(LOOKER_MODELS=setting)
      for model in ("thelook", "finance", "hr_private"):
        with self.subTest(setting=setting, model=model):
          LOOKER.reset()
          result = self.call(agent, "list_looker_explores", model=model)
          if model in allowed:
            self.assertEqual(result["status"], "success")
          else:
            self.assert_refused(result, "not one this agent may use")
    # With nothing listed, nothing is allowed, and the message says why.
    result = self.call(load_agent(LOOKER_MODELS="[]"), "list_looker_explores", model="thelook")
    self.assertIn("LOOKER_MODELS is empty", result["message"])


class ArgumentFormTest(AgentToolsTest):

  def test_an_id_is_an_id_before_it_is_used(self):
    hostile = ["12/../../explore/hr_private/salaries?fields=employees.salary", "1/../../../x", "../x",
               "5?version=1", "1#x", "a b", "", "x" * 101, "12;rm", "user:shared/..", "%2e%2e", "12\n13",
               None, 1.5, True, ["12"], {"id": 12}]
    for agent in (self.plain, self.signed):
      for value in hostile:
        attempts = {
            "show_dashboard_inline": dict(dashboard_id=value, tool_context=ToolContext()),
            "get_dashboard_link": dict(dashboard_id=value),
            "list_dashboard_filters": dict(dashboard_id=value),
            "show_look_inline": dict(look_id=value, tool_context=ToolContext()),
            "get_look_link": dict(look_id=value),
        }
        for name, arguments in attempts.items():
          with self.subTest(tool=name, value=value, mode=agent.LOOKER_LINK_MODE):
            LOOKER.reset()
            result = self.call(agent, name, **arguments)
            self.assert_refused(result, "is not a Looker id or name")
            if "tool_context" in arguments:
              self.assertEqual(arguments["tool_context"].saved, [])

  def test_ids_looker_uses_are_accepted(self):
    for value, text in (("12", "12"), (12, "12"), ("thelook::overview", "thelook::overview"),
                        ("AbC-dEf_123", "AbC-dEf_123")):
      with self.subTest(value=value):
        LOOKER.reset()
        context = ToolContext()
        result = self.call(self.plain, "show_dashboard_inline", dashboard_id=value, tool_context=context)
        self.assertEqual(result["status"], "success", result)
        self.assertEqual(context.saved, ["dashboard_%s.png" % text])
        self.assertEqual(LOOKER.calls[0][1]["dashboard_id"], text)
        self.assertEqual(self.call(self.plain, "get_dashboard_link", dashboard_id=value)["signed_url"],
                         "https://looker.example.com/dashboards/" + text)
    LOOKER.reset()
    context = ToolContext()
    self.assertEqual(self.call(self.plain, "show_look_inline", look_id=5, tool_context=context)["status"], "success")
    self.assertEqual((LOOKER.calls[0][1]["look_id"], context.saved), ("5", ["look_5.png"]))

  def test_a_model_or_an_explore_is_a_name_before_it_is_used(self):
    for value in ("orders?fields=employees.national_id", "a/b", "../x", "a b", "", "x" * 101, "orders#x",
                  "thelook::orders", "a-b", None, 7.5, ["orders"]):
      attempts = {
          "query_looker_data": dict(model="thelook", explore=value, fields=["orders.count"]),
          "show_query_inline": dict(model="thelook", explore=value, fields=["orders.count"], tool_context=ToolContext()),
          "list_looker_fields": dict(model="thelook", explore=value),
          "get_explore_link": dict(model="thelook", explore=value),
          "list_looker_explores": dict(model=value),
      }
      for name, arguments in attempts.items():
        with self.subTest(tool=name, value=value):
          LOOKER.reset()
          self.assert_refused(self.call(self.plain, name, **arguments), "is not a Looker id or name")

  def test_the_number_of_rows_is_kept_within_bounds(self):
    for asked, used in ((-1, "1"), (0, "1"), (1, "1"), (100, "100"), (500, "500"), (501, "500"),
                        (10 ** 9, "500"), ("250", "250"), ("many", "100"), (None, "100"), (2.9, "2")):
      with self.subTest(limit=asked):
        LOOKER.reset()
        result = self.call(self.plain, "query_looker_data", model="thelook", explore="orders",
                           fields=["orders.count"], limit=asked)
        self.assertEqual(result["status"], "success")
        self.assertEqual(LOOKER.calls[0][1]["body"].limit, used)
    # Not given at all: the tool's own default.
    LOOKER.reset()
    self.call(self.plain, "query_looker_data", model="thelook", explore="orders", fields=["orders.count"])
    self.assertEqual(LOOKER.calls[0][1]["body"].limit, "100")

  def test_other_arguments_reach_the_tool_unchanged(self):
    self.call(self.plain, "list_available_dashboards", search_term="sales 100%")
    self.assertEqual(LOOKER.calls, [("search_dashboards", {"title": "%sales 100%%", "limit": 20})])
    LOOKER.reset()
    self.call(self.plain, "show_dashboard_inline", dashboard_id="12", tool_context=ToolContext(),
              filters={"Country": "Brazil & Peru"})
    self.assertEqual(LOOKER.calls[0][1]["body"].dashboard_filters, "Country=Brazil+%26+Peru")


class EventLoopTest(AgentToolsTest):
  """The server answers every request on one event loop. While a tool waits
  for Looker, other requests must still be served."""

  # Each stand-in call blocks its own thread for DELAY seconds. A tool that
  # made the call on the loop would keep everything else waiting that long;
  # half of it is already too much.
  DELAY = 0.4
  LIMIT = 0.2

  def test_rendering_a_dashboard_does_not_hold_up_other_requests(self):
    LOOKER.delay = self.DELAY
    context = ToolContext()

    async def scenario():
      tool = tools_of(self.plain)["show_dashboard_inline"]
      return await longest_pause_while(tool(dashboard_id="12", tool_context=context))

    result, pause = asyncio.run(scenario())
    self.assertEqual(result["status"], "success", result)
    self.assertEqual(LOOKER.names(), ["create_dashboard_render_task", "render_task", "render_task_results"])
    self.assertEqual(LOOKER.on_main_thread, [False, False, False])
    self.assertLess(pause, self.LIMIT)

  def test_waiting_for_a_render_does_not_hold_up_other_requests(self):
    # Looker says "running" once, so the tool waits two seconds before it asks again.
    LOOKER.running_polls = 1

    async def scenario():
      tool = tools_of(self.plain)["show_dashboard_inline"]
      started = time.monotonic()
      result, pause = await longest_pause_while(tool(dashboard_id="12", tool_context=ToolContext()))
      return result, pause, time.monotonic() - started

    result, pause, took = asyncio.run(scenario())
    self.assertEqual(result["status"], "success", result)
    self.assertEqual(LOOKER.names().count("render_task"), 2)
    self.assertGreaterEqual(took, 2.0)
    self.assertLess(pause, self.LIMIT)

  def test_no_tool_calls_looker_on_the_event_loop(self):
    LOOKER.delay = self.DELAY
    calls = {
        "show_look_inline": dict(look_id="5", tool_context=ToolContext()),
        "show_query_inline": dict(model="thelook", explore="orders", fields=["orders.count"], tool_context=ToolContext()),
        "query_looker_data": dict(model="thelook", explore="orders", fields=["orders.count"]),
        "list_looker_models": {},
        "list_looker_explores": dict(model="thelook"),
        "list_looker_fields": dict(model="thelook", explore="orders"),
        "list_available_dashboards": dict(search_term="sales"),
        "list_dashboard_filters": dict(dashboard_id="12"),
    }
    for name, arguments in calls.items():
      with self.subTest(tool=name):
        LOOKER.calls, LOOKER.on_main_thread = [], []

        async def scenario(name=name, arguments=arguments):
          return await longest_pause_while(tools_of(self.plain)[name](**arguments))

        result, pause = asyncio.run(scenario())
        self.assertEqual(result["status"], "success", result)
        self.assertTrue(LOOKER.calls)
        self.assertEqual(set(LOOKER.on_main_thread), {False})
        self.assertLess(pause, self.LIMIT)
    # In "signed" mode the link tools ask Looker too.
    LOOKER.calls, LOOKER.on_main_thread = [], []

    async def signed_link():
      return await longest_pause_while(tools_of(self.signed)["get_look_link"](look_id="5"))

    _, pause = asyncio.run(signed_link())
    self.assertEqual((LOOKER.names(), LOOKER.on_main_thread), (["create_sso_embed_url"], [False]))
    self.assertLess(pause, self.LIMIT)


class WhatAdkReadsTest(AgentToolsTest):
  """ADK takes a tool's name, description and parameters from the function it
  is given (its FunctionTool: __name__, the docstring, inspect.signature, the
  type hints) and calls it with keyword arguments. The functions the agent
  lists wrap the original ones; ADK has to see the originals in them."""

  def test_the_listed_tools_are_the_twelve_and_adks_own_last(self):
    for agent in (self.plain, self.signed):
      listed = agent.root_agent.tools
      self.assertEqual([getattr(tool, "__name__", None) for tool in listed[:-1]], TOOL_NAMES)
      self.assertIs(listed[-1], LOAD_ARTIFACTS_TOOL)

  def test_each_listed_tool_reads_like_the_function_it_wraps(self):
    for name, listed in tools_of(self.plain).items():
      with self.subTest(tool=name):
        original = getattr(self.plain, name)
        self.assertIsNot(listed, original)
        self.assertEqual(listed.__name__, original.__name__)
        self.assertEqual(inspect.getdoc(listed), inspect.getdoc(original))
        self.assertTrue(inspect.getdoc(listed))
        self.assertEqual(inspect.signature(listed), inspect.signature(original))
        self.assertEqual(typing.get_type_hints(listed), typing.get_type_hints(original))
        # ADK awaits a coroutine function and would call anything else directly.
        self.assertTrue(inspect.iscoroutinefunction(listed))
        # The context parameter is found by name and by annotation.
        takes_context = name.startswith("show_")
        self.assertEqual("tool_context" in inspect.signature(listed).parameters, takes_context)
        if takes_context:
          self.assertIs(typing.get_type_hints(listed)["tool_context"], ToolContext)

  def test_a_call_with_the_wrong_arguments_fails_as_it_would_on_the_function(self):
    with self.assertRaises(TypeError):
      self.call(self.plain, "get_look_link")
    with self.assertRaises(TypeError):
      self.call(self.plain, "get_look_link", look_id="5", unknown=1)
    self.assertEqual(self.call(self.plain, "get_look_link", "5")["signed_url"], "https://looker.example.com/looks/5")


class ErrorTextTest(AgentToolsTest):

  ERROR = RuntimeError(
      "HTTPSConnectionPool(host='%s', port=443): Max retries exceeded with url: /api/4.0/queries/7/run/json\n"
      "SQL ERROR: relation \"finance.payroll_2026\" does not exist\n"
      "SELECT employees.salary FROM finance.payroll_2026" % API_HOST)

  def test_an_error_from_looker_is_passed_on_as_one_short_line(self):
    LOOKER.error = self.ERROR
    calls = {
        "show_look_inline": dict(look_id="5", tool_context=ToolContext()),
        "show_query_inline": dict(model="thelook", explore="orders", fields=["orders.count"], tool_context=ToolContext()),
        "query_looker_data": dict(model="thelook", explore="orders", fields=["orders.count"]),
        "list_looker_models": {},
        "list_looker_explores": dict(model="thelook"),
        "list_looker_fields": dict(model="thelook", explore="orders"),
        "list_dashboard_filters": dict(dashboard_id="12"),
    }
    for name, arguments in calls.items():
      with self.subTest(tool=name):
        result = self.call(self.plain, name, **arguments)
        self.assertEqual(result["status"], "error")
        message = result["message"]
        # What went wrong is still said...
        self.assertIn("Max retries exceeded", message)
        # ...without the address of the API inside the cluster, and without
        # what followed the first line.
        self.assertNotIn(API_HOST, message)
        self.assertIn("the Looker API", message)
        self.assertNotIn("payroll", message)
        self.assertNotIn("\n", message)
    result = self.call(self.signed, "get_dashboard_link", dashboard_id="12")
    self.assertEqual(result["status"], "error")
    self.assertNotIn(API_HOST, result["message"])
    self.assertNotIn("payroll", result["message"])

  def test_a_long_error_is_cut(self):
    brief = self.plain._brief  # pylint: disable=protected-access
    self.assertEqual(brief(ValueError("x" * 1000)), "x" * 200 + "...")
    self.assertEqual(brief(ValueError("short")), "short")
    self.assertEqual(brief(ValueError("  first  \n second")), "first")
    # An exception without a text is named by its kind.
    self.assertEqual(brief(KeyError()), "KeyError")
    self.assertEqual(brief(ValueError("\n")), "ValueError")
    LOOKER.error = ValueError("y" * 5000)
    message = self.call(self.plain, "list_looker_models")["message"]
    self.assertEqual(message, "Could not list models: " + "y" * 200 + "...")

  def test_the_address_of_the_api_is_only_removed_when_there_is_one(self):
    agent = load_agent(LOOKERSDK_BASE_URL=None)
    saved = os.environ.pop("LOOKERSDK_BASE_URL", None)
    try:
      self.assertEqual(agent._brief(ValueError("host looker.example.com refused")),  # pylint: disable=protected-access
                       "host looker.example.com refused")
    finally:
      if saved is not None:
        os.environ["LOOKERSDK_BASE_URL"] = saved


if __name__ == "__main__":
  unittest.main(verbosity=2)
