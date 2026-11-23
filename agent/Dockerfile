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

# Looker agent, packaged to run as an Agent Substrate actor.
#
# Build context: this directory. deploy.sh stages a copy and, if you configured
# EXTRA_CA_FILE, puts that certificate in extra-ca.pem. The empty extra-ca.pem
# shipped here means "no private CA".

# The base image is a build argument so that it can be named by digest. A tag
# can be moved to other content, a digest cannot:
#   --build-arg BASE_IMAGE=python:3.12-slim@sha256:<digest>
ARG BASE_IMAGE=python:3.12-slim
FROM ${BASE_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    AGENTS_DIR=/app/agents \
    PORT=80 \
    LITELLM_LOCAL_MODEL_COST_MAP=True
# LITELLM_LOCAL_MODEL_COST_MAP stops LiteLLM from downloading its price table
# when it is imported. An actor has no network until it has an egress policy,
# and Substrate takes its first snapshot before that.

WORKDIR /app
COPY requirements.txt requirements.lock /app/
# requirements.lock, once it names packages, is the whole set to install: each
# file is checked against the hash written next to it, and nothing that is not
# listed is fetched. As shipped it holds comments only; then requirements.txt
# is installed, which takes whatever version is current on the day of the
# build. Either way the versions that were installed are recorded in
# /app/requirements.installed.
RUN if grep -Eqv '^[[:space:]]*(#|$)' /app/requirements.lock; then \
      pip install --require-hashes -r /app/requirements.lock; \
    else \
      pip install -r /app/requirements.txt; \
    fi \
 && pip freeze > /app/requirements.installed

COPY server.py extra-ca.pem /app/
COPY agents /app/agents

# Fail the build, not the first chat, if a dependency changed under the agent.
# The provider is a build argument because each one imports different modules.
ARG AGENT_MODEL_PROVIDER=gemini
RUN AGENT_MODEL_PROVIDER="${AGENT_MODEL_PROVIDER}" python -c "\
import sys; sys.path.insert(0, '/app/agents'); \
import looker_app.agent as a; print('agent import ok:', a.root_agent.name)" \
 && python -c "\
from google.adk.cli.fast_api import get_fast_api_app; import uvicorn; \
print('server imports ok')"

# The agent runs as a user that can read its code and cannot change it.
# Substrate runs the process as the image's USER. A process that was talked
# into misbehaving must not be able to rewrite the agent, least of all in a way
# its next snapshot keeps, so nothing under /app belongs to that user or is
# writable by it.
#
# This decides where ADK keeps conversations and rendered images. ADK stores
# them in files under the agents directory only when it can write to that
# directory, and a directory it can write to is also one it loads code from
# (another agent folder, a services.py). As it cannot write there, it keeps
# them in memory and says so in a warning when it starts (read in ADK 2.15,
# cli/utils/service_factory.py). Substrate's memory snapshots carry them
# across a suspend and a resume, as they did the files.
RUN useradd --uid 10001 --create-home agent && chmod -R a+rX,go-w /app
USER 10001:10001

EXPOSE 80
ENTRYPOINT ["python", "/app/server.py"]
