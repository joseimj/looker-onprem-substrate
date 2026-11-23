// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// How a request gets from the extension to the agent gateway.
//
// An extension runs in a sandboxed iframe and has no network access of its
// own. Looker offers two ways out, both reached through the Extension SDK:
//
//   serverProxy  Looker's *server* makes the call. It can fill in a secret
//                that is stored in Looker (a hidden user attribute), so this
//                code never holds the gateway password. That does not make
//                the password a secret from the people who use the chat: see
//                createTransport below.
//   fetchProxy   The Looker page in the user's *browser* makes the call.
//
// Both return a whole response at once: no streaming, text or JSON only.
//
// Two transports are built on them:
//
//   "server"   Every call goes through serverProxy. Nothing but Looker has to
//              reach the gateway, so it can stay inside the cluster.
//   "browser"  serverProxy is used once, to trade the password for a
//              short-lived token; the calls themselves go through fetchProxy.
//              This is the pattern the Extension SDK documentation describes
//              for serverProxy. It needs the gateway on an https address that
//              browsers can reach.

import { clipped } from './markdown.js';

export class TransportError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TransportError';
  }
}

function trimTrailingSlash(url) {
  return String(url || '').replace(/\/+$/, '');
}

// The SDK decides how to decode a body from its content type and falls back
// to text. Decode JSON that arrived as text, so callers get one shape.
function normalize(response) {
  if (!response || typeof response !== 'object') {
    throw new TransportError('Looker returned no response for the request to the agent gateway.');
  }
  let body = response.body;
  if (typeof body === 'string') {
    const trimmed = body.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        body = JSON.parse(trimmed);
      } catch (error) {
        // Not JSON after all: keep the text.
      }
    }
  }
  const status = Number(response.status) || 0;
  return { ok: status >= 200 && status < 300, status, body };
}

function requestInit(method, authorization, body) {
  const init = { method, headers: { Authorization: authorization } };
  if (body !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  return init;
}

async function callProxy(proxy, url, init, what) {
  try {
    return normalize(await proxy(url, init));
  } catch (error) {
    if (error instanceof TransportError) throw error;
    // What Looker or the browser reports, quoted in one line.
    const detail = clipped(error && error.message ? error.message : String(error), 200);
    throw new TransportError(`${what} could not reach the agent gateway at ${url}: ${detail}`);
  }
}

// Returns {request(method, path, body) -> Promise<{ok, status, body}>}.
// `now` is injectable for tests.
export function createTransport(extensionSdk, config, now = () => Date.now()) {
  const serverUrl = trimTrailingSlash(config.serverGatewayUrl);
  if (!serverUrl) {
    throw new TransportError('The extension is not configured: serverGatewayUrl is empty (src/config.js).');
  }
  // Looker's server replaces this tag with the value of the hidden user
  // attribute before it sends the request, so the value is never in this
  // code or in the bundle. It is still within reach of everyone who may use
  // the chat: Looker replaces the tag wherever a caller puts it, in a header
  // or in a body. That is why the gateway gives this credential the reach of
  // a chat and no more, and refuses a request that carries it in its body.
  const basic = `Basic ${extensionSdk.createSecretKeyTag(config.secretKeyName)}`;
  const viaServer = (url, init) => extensionSdk.serverProxy(url, init);

  if (config.transport === 'server') {
    return {
      name: 'server',
      request(method, path, body) {
        return callProxy(viaServer, serverUrl + path, requestInit(method, basic, body), "Looker's server");
      },
    };
  }

  if (config.transport !== 'browser') {
    throw new TransportError(`Unknown transport "${config.transport}" in src/config.js: use "server" or "browser".`);
  }
  const browserUrl = trimTrailingSlash(config.browserGatewayUrl);
  if (!browserUrl.startsWith('https://')) {
    throw new TransportError('The "browser" transport needs browserGatewayUrl to be an https:// address (src/config.js).');
  }
  const viaBrowser = (url, init) => extensionSdk.fetchProxy(url, init);
  let token = null;
  let tokenExpiresAt = 0;
  let pendingToken = null;

  async function fetchToken() {
    const response = await callProxy(
      viaServer, `${serverUrl}/_gateway/token`, requestInit('POST', basic), "Looker's server",
    );
    const granted = response.body;
    if (!response.ok || !granted || typeof granted.access_token !== 'string') {
      const error = new TransportError(`The agent gateway did not issue a token (HTTP ${response.status}).`);
      error.status = response.status;
      throw error;
    }
    token = granted.access_token;
    // Renew a minute early so a token does not expire in flight.
    const lifetime = Number(granted.expires_in) > 0 ? Number(granted.expires_in) : 300;
    tokenExpiresAt = now() + Math.max(lifetime - 60, 5) * 1000;
    return token;
  }

  function currentToken() {
    if (token && now() < tokenExpiresAt) return Promise.resolve(token);
    // Share one exchange between calls that start at the same moment.
    if (!pendingToken) {
      pendingToken = fetchToken().finally(() => { pendingToken = null; });
    }
    return pendingToken;
  }

  return {
    name: 'browser',
    async request(method, path, body) {
      const send = async () => callProxy(
        viaBrowser, browserUrl + path, requestInit(method, `Bearer ${await currentToken()}`, body),
        'Your browser',
      );
      let response = await send();
      if (response.status === 401) {
        // The gateway restarted (its tokens died with it) or the token ran
        // out early. One fresh token, one more try.
        token = null;
        response = await send();
      }
      return response;
    },
  };
}
