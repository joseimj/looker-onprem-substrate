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

"""Looker analytics agent for Gemini Enterprise.

Responsibilities:
  - Render Looker dashboards/Looks/charts and display them inline as images
    (via ADK artifacts -- the image bytes never pass through the model's text).
  - Answer data questions by querying Looker directly through its SDK.
  - Produce signed, interactive Looker embed links on demand (Looker signs them
    server-side, so we never hand-roll the signature).

Credentials arrive as environment variables (the Looker SDK reads LOOKERSDK_*).

This file is the agent from the original Agent Engine setup script. The prompt,
the tools and what each tool asks of Looker are the original's. What differs,
and why:

  - LOOKER_HOST: links are built from LOOKER_PUBLIC_URL when it is set, because
    the API address the agent uses from inside the cluster is not one a user's
    browser can open.
  - LOOKER_LINK_MODE: with "plain", the default, the three link tools return
    the ordinary address of the page (https://<host>/dashboards/12) and never
    ask Looker for a signed embed URL. A signed URL signs in whoever opens it,
    and a chat inside Looker is read by people who are signed in already.
    "signed" keeps the original links. One sentence of the instruction, the
    one that says what a link looks like, follows the mode.
  - LOOKER_MODELS is the list of models the tools may use. It used to be only
    a field of signed links, so that the data tools reached every model the
    API user could. list_looker_models shows only these models.
  - What the model sends where an id, a model or an explore belongs is checked
    before it is used, and `limit` is kept between 1 and 500 (_guarded).
  - No tool holds up the server while it waits for Looker: the calls to the
    Looker SDK run in threads. One slow dashboard used to stall every other
    request to the agent.
  - An error from Looker is passed on as one short line (_brief).
"""

import asyncio
import functools
import inspect
import os
import json
import re
from urllib.parse import urlencode, urlsplit

import looker_sdk
from looker_sdk import models40

from google.adk.agents import LlmAgent
from google.adk.planners.built_in_planner import BuiltInPlanner
from google.adk.tools import ToolContext
from google.adk.tools.load_artifacts_tool import load_artifacts_tool
from google.genai.types import ThinkingConfig, Part

# -----------------------------------------------------------------------------
# Configuration read from environment variables.
# -----------------------------------------------------------------------------
# LOOKERSDK_BASE_URL is where the agent calls the Looker API. LOOKER_PUBLIC_URL
# is where a person opens Looker. They differ when the agent uses an in-cluster
# service name, and signed embed links must carry the public one.
LOOKER_HOST = (
    (os.environ.get("LOOKER_PUBLIC_URL") or os.environ.get("LOOKERSDK_BASE_URL", ""))
    .replace("https://", "").replace("http://", "").rstrip("/")
)
LOOKER_MODELS_ENV = os.environ.get("LOOKER_MODELS", '["thelook"]')
# "plain": a link is the ordinary address of the page. "signed": the original
# signed embed links. Anything but "signed" means "plain".
LOOKER_LINK_MODE = os.environ.get("LOOKER_LINK_MODE", "plain").strip().lower()


def _models_list():
    """Parse LOOKER_MODELS into a list of model names, tolerant of formatting.

    Accepts valid JSON like '["a","b"]' but also forgives common slips such as
    '[a]' (missing quotes), 'a' (bare name), or 'a, b' (comma-separated). A
    signed embed URL requires at least one model name. These are also the only
    models a tool may be used with (see _guarded)."""
    raw = (LOOKER_MODELS_ENV or "").strip()
    try:
        val = json.loads(raw)
        return [val] if isinstance(val, str) else list(val)
    except Exception:
        cleaned = raw.strip("[]")
        return [m.strip().strip('"').strip("'") for m in cleaned.split(",") if m.strip()]


def _brief(error) -> str:
    """One short line of an exception, for a tool's "message".

    The message goes to the model and from there to the person asking. The full
    text of an exception can hold what neither needs: the in-cluster address of
    the Looker API, a page of SQL."""
    lines = str(error).strip().splitlines()
    text = lines[0].strip() if lines else type(error).__name__
    api_host = urlsplit(os.environ.get("LOOKERSDK_BASE_URL", "")).hostname
    if api_host:
        text = text.replace(api_host, "the Looker API")
    return text if len(text) <= 200 else text[:200] + "..."


# Permissions granted to the temporary embed user inside the signed link.
EMBED_PERMISSIONS = [
    "access_data", "see_looks", "see_user_dashboards",
    "see_lookml_dashboards", "explore", "save_content", "embed_browse_spaces",
]

# -----------------------------------------------------------------------------
# Reasoning model (swappable -- this does NOT affect image rendering).
#
# Rendering is handled by the tools below plus load_artifacts_tool, which work
# the same no matter which LLM drives the agent, so changing the model never
# breaks the image feature.
#
# Controlled by env vars (set in the script's config block):
#   AGENT_MODEL_PROVIDER = "claude"    -> Claude Sonnet on Vertex AI via LiteLlm
#                        = "anthropic" -> Claude Sonnet via the public Anthropic API
#                        = "gemini"    -> Gemini on Vertex AI
# For "claude" the model must be enabled in Vertex AI Model Garden and
# VERTEXAI_PROJECT / VERTEXAI_LOCATION must point to a region that serves it.
# For "anthropic" the ANTHROPIC_API_KEY env var must be set.
# -----------------------------------------------------------------------------
_PROVIDER = os.environ.get("AGENT_MODEL_PROVIDER", "gemini").lower()
_CLAUDE_MODEL = os.environ.get("CLAUDE_MODEL", "claude-sonnet-4-6")
if _PROVIDER == "claude":
    from google.adk.models.lite_llm import LiteLlm
    AGENT_MODEL = LiteLlm(model=f"vertex_ai/{_CLAUDE_MODEL}")
elif _PROVIDER == "claude_native":
    # ADK's native Anthropic-on-Vertex wrapper (NOT LiteLlm). Routes the model
    # string to the Claude class after registration. Needs anthropic[vertex] and
    # GOOGLE_CLOUD_PROJECT / GOOGLE_CLOUD_LOCATION. NOTE: older google-adk only
    # matched claude-3* model names; make sure you are on a recent version so
    # claude-sonnet-4-6 is recognized, otherwise it falls back / fails.
    from google.adk.models.anthropic_llm import Claude
    from google.adk.models.registry import LLMRegistry
    LLMRegistry.register(Claude)
    AGENT_MODEL = _CLAUDE_MODEL
elif _PROVIDER == "anthropic":
    from google.adk.models.lite_llm import LiteLlm
    AGENT_MODEL = LiteLlm(model=f"anthropic/{_CLAUDE_MODEL}")
else:
    AGENT_MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
# -----------------------------------------------------------------------------


def _signed_embed_url(embed_path: str, external_user_id: str = "gemini-user") -> str:
    """Ask Looker to mint a signed SSO embed URL.

    We let Looker create and sign the URL server-side via create_sso_embed_url
    instead of building the HMAC by hand. Hand-signing is error-prone (exact
    endpoint, field order, and SHA-1 vs SHA-256 all have to match), and the API
    does it correctly every time.

    `embed_path` is the embed target, e.g. "/embed/dashboards/1".

    With LOOKER_LINK_MODE "plain" Looker is not asked at all: the result is the
    ordinary address of the same page, "https://<host>/dashboards/1". Whoever
    opens it sees the page with their own Looker account.
    """
    if LOOKER_LINK_MODE != "signed":
        return f"https://{LOOKER_HOST}{embed_path.removeprefix('/embed')}"
    sdk = looker_sdk.init40()
    resp = sdk.create_sso_embed_url(
        body=models40.EmbedSsoParams(
            target_url=f"https://{LOOKER_HOST}{embed_path}",
            session_length=3600,
            force_logout_login=True,
            external_user_id=external_user_id,
            first_name="Gemini",
            last_name="User",
            permissions=EMBED_PERMISSIONS,
            models=_models_list(),
        )
    )
    return resp.url


# =============================================================================
# IMAGE TOOLS
#
# Each tool renders a PNG, stores it as an artifact, and returns ONLY the
# artifact filename. The image bytes are never returned as text. The agent then
# calls load_artifacts to display it. We deliberately do NOT create the embed
# link here -- that is a separate, on-demand tool (below), to keep rendering
# fast and off any extra network call.
#
# These three are coroutines, and the server runs every request on one event
# loop. Each call to the Looker SDK waits for the network, so it runs in a
# thread (asyncio.to_thread), and the pause between two polls is
# asyncio.sleep: other requests are served in the meantime.
# =============================================================================
async def show_dashboard_inline(dashboard_id: str, tool_context: ToolContext,
                                filters: dict = None) -> dict:
    """Render a Looker dashboard as an image and save it as an artifact.

    Args:
        dashboard_id: numeric dashboard ID.
        filters: optional dict of dashboard filters to apply before rendering,
            keyed by the dashboard's filter NAMES, e.g.
            {"Country": "Brazil", "Order Created Date": "30 days"}.
            Use list_dashboard_filters(dashboard_id) to discover valid names.
    """
    sdk = looker_sdk.init40()

    # Looker expects dashboard filters in URL-query format (name=value&...).
    dashboard_filters = urlencode(filters) if filters else ""

    # Dashboard rendering is asynchronous in Looker: create a render task, then
    # poll until it succeeds or fails.
    task = await asyncio.to_thread(
        sdk.create_dashboard_render_task,
        dashboard_id=dashboard_id,
        result_format="png",
        body=models40.CreateDashboardRenderTask(
            dashboard_style="tiled", dashboard_filters=dashboard_filters
        ),
        width=1200, height=800,
    )

    waited = 0
    while waited < 90:  # cap the wait so a heavy dashboard fails cleanly, not forever
        status = await asyncio.to_thread(sdk.render_task, task.id)
        if status.status == "success":
            break
        if status.status == "failure":
            return {"status": "error", "message": f"Render failed for dashboard {dashboard_id}"}
        await asyncio.sleep(2)
        waited += 2
    else:
        return {"status": "error", "message": f"Timed out rendering dashboard {dashboard_id}"}

    png_bytes = await asyncio.to_thread(sdk.render_task_results, task.id)
    filename = f"dashboard_{dashboard_id}.png"
    try:
        await tool_context.save_artifact(
            filename=filename,
            artifact=Part.from_bytes(data=png_bytes, mime_type="image/png"),
        )
    except Exception as e:
        return {"status": "error", "message": f"Could not save the image artifact: {_brief(e)}"}

    return {"status": "success", "artifact_filename": filename,
            "next_step": "Call load_artifacts with this filename to display the image."}


async def show_look_inline(look_id: str, tool_context: ToolContext) -> dict:
    """Render a Looker Look (saved chart) as an image and save it as an artifact.

    Args:
        look_id: numeric Look ID.
    """
    sdk = looker_sdk.init40()
    try:
        # run_look with PNG output is synchronous: it returns the bytes directly.
        png_bytes = await asyncio.to_thread(
            sdk.run_look, look_id=look_id, result_format="png",
            image_width=1000, image_height=700,
        )
    except Exception as e:
        return {"status": "error", "message": f"Could not render Look {look_id}: {_brief(e)}"}

    filename = f"look_{look_id}.png"
    try:
        await tool_context.save_artifact(
            filename=filename,
            artifact=Part.from_bytes(data=png_bytes, mime_type="image/png"),
        )
    except Exception as e:
        return {"status": "error", "message": f"Could not save the image artifact: {_brief(e)}"}

    return {"status": "success", "artifact_filename": filename,
            "next_step": "Call load_artifacts with this filename to display the image."}


async def show_query_inline(
    model: str, explore: str, fields: list, tool_context: ToolContext,
    vis_type: str = "looker_column",
) -> dict:
    """Build an ad-hoc query, render it as a chart, and save it as an artifact.

    Args:
        model: LookML model (e.g. "thelook").
        explore: explore name (e.g. "order_items").
        fields: list of LookML fields.
        vis_type: looker_column, looker_bar, looker_line, looker_pie, looker_scatter.
    """
    sdk = looker_sdk.init40()
    try:
        # vis_config makes Looker render the result as a chart rather than a table.
        query = await asyncio.to_thread(
            sdk.create_query,
            body=models40.WriteQuery(
                model=model, view=explore, fields=fields,
                limit="500", vis_config={"type": vis_type},
            )
        )
        png_bytes = await asyncio.to_thread(
            sdk.run_query, query_id=str(query.id), result_format="png",
            image_width=1000, image_height=700,
        )
    except Exception as e:
        return {"status": "error", "message": f"Could not run/render the query: {_brief(e)}"}

    filename = f"query_{model}_{explore}.png".replace("/", "_")
    try:
        await tool_context.save_artifact(
            filename=filename,
            artifact=Part.from_bytes(data=png_bytes, mime_type="image/png"),
        )
    except Exception as e:
        return {"status": "error", "message": f"Could not save the image artifact: {_brief(e)}"}

    return {"status": "success", "artifact_filename": filename,
            "next_step": "Call load_artifacts with this filename to display the chart."}


# =============================================================================
# SIGNED-LINK TOOLS (on demand)
#
# Dedicated tools so the agent can fetch a signed, interactive Looker URL
# explicitly. Kept separate from the render tools: the image displays first and
# the (network) call to mint the link never blocks or delays rendering.
# =============================================================================
def get_dashboard_link(dashboard_id: str, filters: dict = None) -> dict:
    """Return a signed, interactive Looker URL for a dashboard.

    Args:
        dashboard_id: numeric dashboard ID.
        filters: optional dict of dashboard filters (same names as the dashboard),
            so the opened link is pre-filtered, e.g. {"Country": "Brazil"}.
    """
    try:
        path = f"/embed/dashboards/{dashboard_id}"
        if filters:
            path += "?" + urlencode(filters)
        return {"status": "success", "signed_url": _signed_embed_url(path)}
    except Exception as e:
        return {"status": "error", "message": f"Could not create the signed link: {_brief(e)}"}


def get_look_link(look_id: str) -> dict:
    """Return a signed, interactive Looker URL for a Look."""
    try:
        return {"status": "success",
                "signed_url": _signed_embed_url(f"/embed/looks/{look_id}")}
    except Exception as e:
        return {"status": "error", "message": f"Could not create the signed link: {_brief(e)}"}


def get_explore_link(model: str, explore: str) -> dict:
    """Return a signed, interactive Looker URL for an explore."""
    try:
        return {"status": "success",
                "signed_url": _signed_embed_url(f"/embed/explore/{model}/{explore}")}
    except Exception as e:
        return {"status": "error", "message": f"Could not create the signed link: {_brief(e)}"}


# =============================================================================
# DATA TOOLS (text/table answers, no image)
# =============================================================================
def query_looker_data(
    model: str, explore: str, fields: list,
    filters: dict = None, sorts: list = None, limit: int = 100,
) -> dict:
    """Run a Looker query and return the rows as JSON.

    If this returns an access error, the cause is almost always Looker-side: the
    API credentials' role must include a permission set with access_data/explore
    AND a model set that contains `model`. Use list_looker_models to see which
    models the credentials can actually reach.

    Args:
        model: LookML model (e.g. "thelook").
        explore: explore name (e.g. "order_items").
        fields: LookML fields (e.g. ["order_items.status", "order_items.count"]).
        filters: optional dict of filters (e.g. {"order_items.status": "complete"}).
        sorts: optional list of sorts (e.g. ["order_items.count desc"]).
        limit: max rows (default 100).
    """
    sdk = looker_sdk.init40()
    try:
        query = sdk.create_query(
            body=models40.WriteQuery(
                model=model, view=explore, fields=fields,
                filters=filters or {}, sorts=sorts or [], limit=str(limit),
            )
        )
        rows = sdk.run_query(query_id=str(query.id), result_format="json")
        data = json.loads(rows) if isinstance(rows, str) else rows
        return {"status": "success", "row_count": len(data), "rows": data}
    except Exception as e:
        return {"status": "error",
                "message": f"Query failed (check model/explore/field names and the "
                           f"Looker role of the API user): {_brief(e)}"}


def list_looker_models() -> dict:
    """List the LookML models the API credentials can access, WITH their explores.

    This is the entry point for schema discovery: it returns each accessible model
    and the explores inside it, so you can pick a model+explore and then call
    list_looker_fields. If a model you expect is missing, the Looker role on the
    API credentials does not grant access to it (fix it in Looker Admin)."""
    sdk = looker_sdk.init40()
    try:
        models = sdk.all_lookml_models()
        allowed = _models_list()
        out = []
        for m in models:
            if not getattr(m, "name", None) or m.name not in allowed:
                continue
            explores = [e.name for e in (m.explores or []) if getattr(e, "name", None)]
            out.append({"model": m.name, "explores": explores})
        return {"status": "success", "models": out}
    except Exception as e:
        return {"status": "error", "message": f"Could not list models: {_brief(e)}"}


def list_looker_explores(model: str) -> dict:
    """List the explores available inside a LookML model (so you can query them).

    Use this when you know the model but not its explore names."""
    sdk = looker_sdk.init40()
    try:
        m = sdk.lookml_model(lookml_model_name=model)
        explores = [e.name for e in (m.explores or []) if getattr(e, "name", None)]
        return {"status": "success", "model": model, "explores": explores}
    except Exception as e:
        return {"status": "error", "message": f"Could not list explores for {model}: {_brief(e)}"}


def list_looker_fields(model: str, explore: str) -> dict:
    """List the dimensions and measures of an explore (to build valid queries)."""
    sdk = looker_sdk.init40()
    try:
        exp = sdk.lookml_model_explore(lookml_model_name=model, explore_name=explore)
        dims = [f.name for f in (exp.fields.dimensions or [])] if exp.fields else []
        meas = [f.name for f in (exp.fields.measures or [])] if exp.fields else []
        return {"status": "success", "dimensions": dims, "measures": meas}
    except Exception as e:
        return {"status": "error", "message": f"Could not list fields: {_brief(e)}"}


def list_available_dashboards(search_term: str = "") -> dict:
    """List available dashboards (id + title), optionally filtered by title."""
    sdk = looker_sdk.init40()
    if search_term:
        dashboards = sdk.search_dashboards(title=f"%{search_term}%", limit=20)
    else:
        dashboards = sdk.search_dashboards(limit=20)
    if not dashboards:
        return {"status": "success", "dashboards": []}
    return {"status": "success",
            "dashboards": [{"id": str(d.id), "title": d.title} for d in dashboards]}


def list_dashboard_filters(dashboard_id: str) -> dict:
    """List a dashboard's filters so you know what you can filter on.

    Returns each filter's name (use this as the key when passing filters),
    title, type (date/number/string/field) and default value."""
    sdk = looker_sdk.init40()
    try:
        dash = sdk.dashboard(dashboard_id=dashboard_id, fields="dashboard_filters")
        out = []
        for f in (dash.dashboard_filters or []):
            out.append({
                "name": f.name, "title": f.title,
                "type": f.type, "default_value": f.default_value,
            })
        return {"status": "success", "filters": out}
    except Exception as e:
        return {"status": "error", "message": f"Could not list dashboard filters: {_brief(e)}"}


# =============================================================================
# What every tool call goes through first.
#
# The arguments of a tool are written by the model, and the model reads what is
# in Looker (dashboard titles, cell values) as well as the question. So an id
# or a name is checked before a tool uses it in a file name, an address or a
# query, and a model has to be one of LOOKER_MODELS. Looker's own permissions
# still apply to whatever is asked; this is the agent's own limit on top.
# Dashboards and Looks are addressed by id and can show any model the API user
# may read: for those, the role of that user is the only limit.
# =============================================================================
# Letters, digits, "_" and "-". A LookML dashboard is "<model>::<dashboard>",
# hence the colon in an id.
_ID = re.compile(r"[A-Za-z0-9_:-]{1,100}")
_NAME = re.compile(r"[A-Za-z0-9_]{1,100}")
_ARGUMENT_FORMS = {"dashboard_id": _ID, "look_id": _ID, "model": _NAME, "explore": _NAME}
_MAX_ROWS = 500


def _refusal(arguments: dict):
    """Returns why a tool must not run with these arguments, or None."""
    for name, form in _ARGUMENT_FORMS.items():
        if name not in arguments:
            continue
        value = arguments[name]
        if isinstance(value, int) and not isinstance(value, bool):
            value = arguments[name] = str(value)  # 12 is the id "12"
        if not isinstance(value, str) or not form.fullmatch(value):
            return (f"'{name}' is not a Looker id or name: only letters, digits, "
                    f"'_' and '-' are accepted" + (" (and ':')." if form is _ID else "."))
    if "model" in arguments and arguments["model"] not in _models_list():
        return (f"The model '{arguments['model']}' is not one this agent may use. "
                f"It may use: {', '.join(_models_list()) or 'none (LOOKER_MODELS is empty)'}.")
    return None


def _guarded(tool):
    """Wraps a tool: checks what the model sent, then runs the tool.

    A plain function runs in a thread, because it waits for Looker and the
    server has one event loop for all requests. ADK reads a tool's name,
    docstring and parameters from the function it is given; functools.wraps
    hands it the original's."""
    signature = inspect.signature(tool)

    @functools.wraps(tool)
    async def guarded(*args, **kwargs):
        arguments = signature.bind(*args, **kwargs).arguments
        refusal = _refusal(arguments)
        if refusal:
            return {"status": "error", "message": refusal}
        if "limit" in arguments:
            try:
                arguments["limit"] = max(1, min(int(arguments["limit"]), _MAX_ROWS))
            except (TypeError, ValueError):
                arguments["limit"] = 100
        if inspect.iscoroutinefunction(tool):
            return await tool(**arguments)
        return await asyncio.to_thread(functools.partial(tool, **arguments))

    return guarded


# The one sentence of the instruction that depends on LOOKER_LINK_MODE: what a
# link from the tools looks like. For "signed" it is the original's, word for
# word.
if LOOKER_LINK_MODE == "signed":
    _REAL_LINK_SENTENCE = (
        'A real link looks like '
        'https://<host>/login/embed/...&signature=...; if you are about to output '
        'anything else (e.g. a plain /embed/dashboards/... URL, or a host you were '
        'not given by a tool), STOP - that is wrong. '
    )
else:
    _REAL_LINK_SENTENCE = (
        'A real link looks like https://<host>/dashboards/..., '
        'https://<host>/looks/... or https://<host>/explore/...; if you are about '
        'to output anything else (e.g. a /login/embed/... or /embed/... URL, or a '
        'host you were not given by a tool), STOP - that is wrong. '
    )


# =============================================================================
# Agent definition.
#   - model: swappable (see AGENT_MODEL above); rendering is unaffected.
#   - instruction: teaches the render -> load_artifacts -> link pattern and how
#     to answer data questions and diagnose access errors.
#   - planner: thinking disabled (budget 0) for direct, low-latency answers.
# =============================================================================
root_agent = LlmAgent(
    model=AGENT_MODEL,
    name='looker_agent',
    description='Looker agent: renders dashboards/charts as inline images and answers data questions via the Looker SDK.',
    instruction=(
        'You are a Looker analytics agent inside Gemini Enterprise.\n\n'
        'TO SHOW AN IMAGE (dashboard / look / chart):\n'
        '1. Call show_dashboard_inline, show_look_inline, or show_query_inline. '
        'Each renders the image and saves it as an artifact, returning '
        '"artifact_filename".\n'
        '2. Call load_artifacts with that filename to display it inline. This is '
        'the ONLY way the image renders; never output image bytes or base64.\n'
        '3. Then ALSO provide the interactive link: call get_dashboard_link / '
        'get_look_link / get_explore_link for the same item and output the '
        'returned "signed_url" as a markdown link '
        '"[Open the interactive version in Looker](signed_url)". Output the '
        'signed_url exactly as returned.\n\n'
        'IF THE USER ASKS ONLY FOR THE LINK: call the matching get_*_link tool '
        'directly and return the signed_url.\n\n'
        'APPLYING DASHBOARD FILTERS: if the user asks for a filtered view (e.g. '
        '"the sales dashboard for Brazil" or "last 30 days"), pass a "filters" '
        'dict to show_dashboard_inline (and to get_dashboard_link so the link is '
        'pre-filtered too). The dict is keyed by the dashboard\'s filter NAMES, '
        'e.g. {"Country": "Brazil", "Order Created Date": "30 days"}. If you do '
        'not know the exact filter names, call list_dashboard_filters(dashboard_id) '
        'first. Filter values use Looker syntax (a value like "Brazil", a date '
        'expression like "30 days" or "this month", a numeric expression like '
        '">50"). This only applies to dashboards.\n\n'
        'CRITICAL LINK RULE: NEVER write, guess, or construct a Looker URL from '
        'your own knowledge. The ONLY acceptable link is the exact "signed_url" '
        'string returned by a get_dashboard_link / get_look_link / get_explore_link '
        'call in THIS turn. ' + _REAL_LINK_SENTENCE + 'If a get_*_link tool returned '
        'status="error" or you have no signed_url from a tool this turn, do NOT '
        'output any link; instead tell the user the link could not be generated '
        'and show the tool\'s exact "message" field verbatim so the cause can be '
        'diagnosed.\n\n'
        'TO ANSWER A DATA QUESTION (numbers, no chart):\n'
        'You CAN discover the full schema yourself - never tell the user you '
        'cannot find the models or explores. Follow this chain:\n'
        '1. call list_looker_models -> returns each accessible model WITH its '
        'explores.\n'
        '2. pick the relevant model and explore (use list_looker_explores(model) '
        'if you need to re-list a single model\'s explores).\n'
        '3. call list_looker_fields(model, explore) to get the exact field names.\n'
        '4. call query_looker_data(model, explore, fields, ...) and summarize the '
        'rows in plain text or a small markdown table. Data is queried live, so '
        'the answer reflects current Looker data.\n'
        'If the user asks about a topic that no accessible model covers (e.g. they '
        'ask about water quality but only ecommerce models exist), say so plainly '
        'and list what data IS available, instead of guessing.\n'
        '- If a data tool returns an access error, call list_looker_models and '
        'tell the user which models are accessible; the Looker role of the API '
        'credentials may not grant access to the requested model.\n\n'
        'When any tool returns status="error", relay the message plainly and '
        'suggest a concrete fix.\n\n'
        'vis_type options: looker_column, looker_bar, looker_line, looker_pie, looker_scatter.'
    ),
    planner=BuiltInPlanner(
        thinking_config=ThinkingConfig(include_thoughts=False, thinking_budget=0)
    ),
    tools=[_guarded(tool) for tool in (
        show_dashboard_inline,
        show_look_inline,
        show_query_inline,
        get_dashboard_link,
        get_look_link,
        get_explore_link,
        query_looker_data,
        list_looker_models,
        list_looker_explores,
        list_looker_fields,
        list_available_dashboards,
        list_dashboard_filters,
    )] + [
        load_artifacts_tool,   # displays the saved artifacts in the chat
    ],
)
