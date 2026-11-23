#!/bin/bash
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

# Container start script for customer-hosted Looker.
#
# The JVM options, and the lines that read lookerstart.cfg, are the ones in
# Looker's own `looker21` startup script (startup_scripts/looker21 in
# github.com/looker-open-source/customer-scripts; MIT License, Copyright (c)
# 2015 Looker Data Sciences, Inc.). Two things differ, both because this runs
# in a container:
#   * the heap is a share of the container's memory limit (the JVM reads the
#     cgroup) instead of a share of /proc/meminfo, which reports the node;
#   * Looker stays in the foreground and logs JSON to stdout.
set -euo pipefail
cd /app

JAVAARGS="${JAVAARGS:-}"
LOOKERARGS="${LOOKERARGS:-}"
# Kubernetes mounts this file to set LOOKERARGS (and, if wanted, JAVAARGS).
if [ -r ./lookerstart.cfg ]; then
  # shellcheck disable=SC1091
  . ./lookerstart.cfg
fi

# Copied from looker21: quiet the reflective-access warnings, and open the
# modules JRuby needs on JDK 21.
REFLECTIVE_ACCESS_ARGS="--add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/java.math=ALL-UNNAMED --add-opens java.base/java.util=ALL-UNNAMED --add-opens java.base/java.util.concurrent=ALL-UNNAMED --add-opens java.base/java.net=ALL-UNNAMED --add-opens java.base/java.text=ALL-UNNAMED"
JDK21_MODULE_ARGS="--add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED"

HEAP_PERCENT="${LOOKER_HEAP_PERCENT:-60}"

# Word splitting of the *ARGS variables is intended: each holds several flags.
# shellcheck disable=SC2086
exec java \
  -XX:+UseG1GC -XX:MaxGCPauseMillis=2000 -XX:MaxMetaspaceSize=800m \
  -XX:InitialRAMPercentage="${HEAP_PERCENT}" -XX:MaxRAMPercentage="${HEAP_PERCENT}" \
  ${REFLECTIVE_ACCESS_ARGS} \
  ${JDK21_MODULE_ARGS} \
  ${JAVAARGS} \
  -jar /app/looker.jar start ${LOOKERARGS} \
  --no-daemonize --no-log-to-file --log-format=json
