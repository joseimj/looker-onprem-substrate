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

// Runs the extension's real code against a real gateway: the handler that
// deep-chat calls for every question, the client behind it and the transport.
// Started by tests/extension_gateway_test.py, which also starts the gateway
// and a stand-in for the agent behind it. Not part of the extension bundle.
//
// What is reported for each question is what deep-chat would be handed, so the
// test also sees what the extension does to an answer on its way to the page.
//
// The only pieces replaced are Looker's two proxies, because there is no
// Looker here. The stand-ins do what the documentation says Looker does:
//
//   serverProxy  Looker's server makes the call, after replacing the secret
//                tag with the value of the hidden user attribute, wherever
//                the tag stands: in a header or in the body.
//   fetchProxy   The Looker page in the browser makes the call. A browser
//                enforces CORS, so this stand-in does too: it sends the
//                preflight a browser would send and refuses to hand over a
//                response the gateway did not release to the Looker origin.
//
// Prints one JSON document with what happened.

import http from 'node:http';

import { userIdFor } from '../../looker-extension/src/adk.js';
import { createHandler } from '../../looker-extension/src/chat.js';
import { AgentClient } from '../../looker-extension/src/client.js';
import { createTransport } from '../../looker-extension/src/transport.js';

const env = process.env;
const GATEWAY = env.GATEWAY_URL; // http://127.0.0.1:<port>
// What browsers would use: https, through an ingress. The stand-in for the
// browser maps it to the local gateway, as the ingress would.
const BROWSER_GATEWAY = 'https://agent.example.test';
const LOOKER_ORIGIN = env.LOOKER_ORIGIN;
const CREDENTIAL = env.CHAT_CREDENTIAL_B64; // base64("user:password"), the user attribute's value
// The tag the real SDK builds for extension "looker_agent::chat".
const SECRET_TAG = '{{looker_agent_chat_gateway_credential}}';

const seen = { serverProxy: [], fetchProxy: [], preflights: 0, secretReachedBrowser: false };

// `chunked` picks how a body is delimited. Browsers announce a length. What
// Looker's server proxy does is not documented, so its stand-in uses the
// other way, chunks, and the gateway has to cope with both.
function httpRequest(url, { method = 'GET', headers = {}, body, chunked = false } = {}) {
  return new Promise((resolve, reject) => {
    const allHeaders = { ...headers };
    if (body !== undefined && !chunked) allHeaders['Content-Length'] = Buffer.byteLength(body);
    const request = http.request(url, { method, headers: allHeaders }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        text: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    request.on('error', reject);
    if (body !== undefined) request.write(body);
    request.end();
  });
}

// The shape the Extension SDK documents for both proxies. Without an explicit
// body type, the body is decoded by content type, text being the fallback.
function proxyResponse(response) {
  const contentType = response.headers['content-type'] || '';
  let body = response.text;
  if (contentType.includes('application/json')) {
    try { body = JSON.parse(response.text); } catch (error) { /* leave as text */ }
  }
  return {
    ok: response.status >= 200 && response.status < 300,
    status: response.status,
    statusText: '',
    headers: response.headers,
    body,
  };
}

async function serverProxy(url, init = {}) {
  seen.serverProxy.push(`${init.method || 'GET'} ${new URL(url).pathname}`);
  const filledIn = (value) => String(value).split(SECRET_TAG).join(CREDENTIAL);
  const headers = {};
  for (const [name, value] of Object.entries(init.headers || {})) {
    headers[name] = filledIn(value);
  }
  const body = init.body === undefined ? undefined : filledIn(init.body);
  return proxyResponse(await httpRequest(url, {
    method: init.method, headers, body, chunked: true,
  }));
}

async function fetchProxy(url, init = {}) {
  const method = init.method || 'GET';
  seen.fetchProxy.push(`${method} ${new URL(url).pathname}`);
  if (JSON.stringify(init).includes(SECRET_TAG) || JSON.stringify(init).includes(CREDENTIAL)) {
    seen.secretReachedBrowser = true;
  }
  if (!url.startsWith(`${BROWSER_GATEWAY}/`)) {
    throw new TypeError(`Failed to fetch: ${url} is not an address a browser here can reach`);
  }
  const local = GATEWAY + url.slice(BROWSER_GATEWAY.length);
  const requestHeaders = Object.keys(init.headers || {}).map((name) => name.toLowerCase());

  // A request with an Authorization header from another origin is preflighted.
  seen.preflights += 1;
  const preflight = await httpRequest(local, {
    method: 'OPTIONS',
    headers: {
      Origin: LOOKER_ORIGIN,
      'Access-Control-Request-Method': method,
      'Access-Control-Request-Headers': requestHeaders.join(','),
    },
  });
  const allowedMethods = (preflight.headers['access-control-allow-methods'] || '')
    .split(',').map((item) => item.trim().toUpperCase());
  const allowedHeaders = (preflight.headers['access-control-allow-headers'] || '')
    .split(',').map((item) => item.trim().toLowerCase());
  const preflightPassed = preflight.status >= 200 && preflight.status < 300
    && preflight.headers['access-control-allow-origin'] === LOOKER_ORIGIN
    && allowedMethods.includes(method)
    && requestHeaders.every((name) => allowedHeaders.includes(name));
  if (!preflightPassed) throw new TypeError('Failed to fetch');

  const response = await httpRequest(local, {
    method, headers: { ...init.headers, Origin: LOOKER_ORIGIN }, body: init.body,
  });
  if (response.headers['access-control-allow-origin'] !== LOOKER_ORIGIN) {
    throw new TypeError('Failed to fetch');
  }
  return proxyResponse(response);
}

const extensionSdk = {
  createSecretKeyTag: (keyName) => `{{looker_agent_chat_${keyName}}}`,
  serverProxy,
  fetchProxy,
};

const client = new AgentClient({
  transport: createTransport(extensionSdk, {
    transport: env.TRANSPORT,
    serverGatewayUrl: GATEWAY,
    browserGatewayUrl: BROWSER_GATEWAY,
    secretKeyName: 'gateway_credential',
  }),
  appName: 'looker_app',
  userId: userIdFor({ id: env.LOOKER_USER_ID }),
  credentialHint: 'Check the user attribute.',
  pollWaitSeconds: 1,
  turnTimeoutSeconds: 60,
  minPollIntervalMs: 50,
});

// The function deep-chat calls for every question. LOOKER_ORIGIN is the page
// the extension runs in, which is also the Looker its links are for.
const handler = createHandler(client, { lookerOrigin: LOOKER_ORIGIN });

const results = [];
for (const question of JSON.parse(env.QUESTIONS)) {
  const callsBefore = seen.serverProxy.length + seen.fetchProxy.length;
  const handed = [];
  // eslint-disable-next-line no-await-in-loop
  await handler(
    { messages: [{ role: 'user', text: question }] },
    { onResponse: (response) => { handed.push(response); } },
  );
  const result = { question, sessionId: client.sessionId };
  if (handed.length !== 1) {
    result.error = `the handler answered ${handed.length} times`;
  } else if (typeof handed[0].error === 'string') {
    result.error = handed[0].error;
  } else {
    result.answer = { text: handed[0].text || '', files: handed[0].files || [] };
  }
  result.calls = seen.serverProxy.length + seen.fetchProxy.length - callsBefore;
  results.push(result);
}

process.stdout.write(`${JSON.stringify({ results, seen })}\n`);
