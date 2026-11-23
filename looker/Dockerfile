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

# Customer-hosted Looker image.
#
# Derived from builders/dockerfile in
# https://github.com/GoogleCloudPlatform/looker-hosting-reference-implementations
# (Apache-2.0). That file was last changed in June 2023 and installs OpenJDK 11
# on Ubuntu 20.04. Looker's install guide now requires OpenJDK 21 (Looker 26.4
# and later) and Git 2.39.1 or later, so this file moves the base image and the
# JDK forward. For a Looker release older than 26.4, build with
#   --build-arg JAVA_PACKAGE=openjdk-17-jdk-headless
#
# The build context must contain looker.jar and looker-dependencies.jar.
# deploy.sh downloads them with your license key. This kit does not ship them.
#
# NOT VERIFIED: this image has not been built or run. In particular, check which
# Chromium version your Looker release supports before relying on rendering;
# Google's apt repository below installs whichever version is current stable.
#
# To pin the base image by digest:
#   --build-arg BASE_IMAGE=ubuntu:24.04@sha256:<digest>
# To run Looker under RuntimeDefault seccomp (or on nodes without unprivileged
# user namespaces), build with --build-arg CHROMIUM_NO_SANDBOX=true so that the
# chromium wrapper passes the --no-sandbox flag instead.
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG JAVA_PACKAGE=openjdk-21-jdk-headless
ARG CHROMIUM_NO_SANDBOX=false

ENV DEBIAN_FRONTEND=noninteractive

# uid/gid 9999 match the reference image, so volumes it wrote stay readable.
# Chrome is installed from Google's signed apt repository rather than an
# unsigned .deb download so apt checks the package signature. openssl is
# included so deploy.sh's optional private-CA init container can build a PKCS12
# keystore without installing anything at run time.
RUN groupadd --gid 9999 looker \
 && useradd --uid 9999 --gid 9999 --home-dir /app --no-create-home --shell /bin/bash looker \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl fontconfig fonts-freefont-otf git openssl tzdata dumb-init "${JAVA_PACKAGE}" \
 && install -d /etc/apt/keyrings \
 && curl -fsSL -o /etc/apt/keyrings/google-chrome.asc https://dl.google.com/linux/linux_signing_key.pub \
 && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.asc] https://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends google-chrome-stable \
 && if [ "${CHROMIUM_NO_SANDBOX}" = "true" ]; then \
      printf '#!/bin/sh\nexec /usr/bin/google-chrome --no-sandbox "$@"\n' > /usr/local/bin/chromium \
      && chmod 0755 /usr/local/bin/chromium; \
    else \
      ln -sf /usr/bin/google-chrome /usr/local/bin/chromium; \
    fi \
 && rm -rf /var/lib/apt/lists/*

# Looker needs an unversioned libcrypt.so. Its own startup script creates this
# link at run time (the `fixcrypt` function in `looker21`); do it once here.
RUN crypt="$(ldconfig -p | awk '/libcrypt\.so\.[0-9]/ {print $NF; exit}')" \
 && test -n "${crypt}" \
 && ln -sf "${crypt}" /usr/local/lib/libcrypt.so \
 && ldconfig

WORKDIR /app
COPY --chown=9999:9999 looker.jar looker-dependencies.jar /app/
COPY --chown=9999:9999 bin/looker.sh /app/bin/looker.sh
RUN chmod 0755 /app/bin/looker.sh && chown 9999:9999 /app

USER 9999:9999
ENV HOME=/app
# 9999 is the web UI, 19999 the API. Both serve HTTPS with a self-signed
# certificate unless Looker is started with its own TLS options.
EXPOSE 9999 19999
ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/bin/bash", "/app/bin/looker.sh"]
