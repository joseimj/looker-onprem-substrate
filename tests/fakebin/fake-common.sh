#!/usr/bin/env bash
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

# Shared by the stub tools in this directory. Each one calls fake_record
# first. It writes the call into $FAKE_LOG, where the tests look for what was
# run and for secrets in command lines. It also notes when one of the
# operator's secrets is visible in the tool's environment: deploy.sh keeps
# them out of every tool it starts, and the tests check that it does.
FAKE_SECRET_SETTINGS="LOOKER_LICENSE_KEY LOOKER_CLIENT_SECRET LOOKER_DB_PASSWORD ANTHROPIC_API_KEY S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY GATEWAY_BASIC_AUTH_PASSWORD GATEWAY_CHAT_AUTH_PASSWORD"

fake_check_environment() {
  local tool="$1" name
  for name in $FAKE_SECRET_SETTINGS; do
    if [ -n "${!name:-}" ]; then
      echo "${tool}: ${name} is in its environment" >> "$FAKE_STATE/environment-leaks.log"
    fi
  done
}

fake_record() {
  local tool="$1"
  shift
  { printf '%s' "$tool"; printf ' %s' "$@"; echo; } >> "$FAKE_LOG"
  fake_check_environment "$tool"
}
