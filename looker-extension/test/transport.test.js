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

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { createTransport, TransportError } from '../src/transport.js';
import { FakeExtensionSdk } from './fakes.js';

const SERVER_URL = 'http://looker-agent-gateway.looker-agent.svc.cluster.local';
const BROWSER_URL = 'https://agent.example.com';
const serverConfig = {
  transport: 'server', serverGatewayUrl: `${SERVER_URL}/`, secretKeyName: 'gateway_credential',
};
const browserConfig = {
  transport: 'browser', serverGatewayUrl: SERVER_URL, browserGatewayUrl: `${BROWSER_URL}/`,
  secretKeyName: 'gateway_credential',
};
const BASIC_WITH_TAG = 'Basic {{secret:gateway_credential}}';

test('server transport: every call goes through Looker\'s server with the secret tag', async () => {
  const sdk = new FakeExtensionSdk();
  sdk.onServer = () => ({ ok: true, status: 202, body: { id: 'job-1', status: 'running' } });
  const transport = createTransport(sdk, serverConfig);

  const response = await transport.request('POST', '/_gateway/jobs/run', { appName: 'looker_app' });
  assert.deepEqual(response, { ok: true, status: 202, body: { id: 'job-1', status: 'running' } });
  assert.deepEqual(sdk.serverCalls, [{
    url: `${SERVER_URL}/_gateway/jobs/run`,
    init: {
      method: 'POST',
      // The password is not here: only the tag Looker's server will replace.
      headers: { Authorization: BASIC_WITH_TAG, 'Content-Type': 'application/json' },
      body: '{"appName":"looker_app"}',
    },
    responseBodyType: undefined,
  }]);
  // The browser never calls the gateway in this mode.
  assert.equal(sdk.fetchCalls.length, 0);

  await transport.request('GET', '/_gateway/jobs/job-1?wait=5');
  assert.deepEqual(sdk.serverCalls[1].init, { method: 'GET', headers: { Authorization: BASIC_WITH_TAG } });
});

test('responses are normalized whatever shape the SDK returns', async () => {
  const sdk = new FakeExtensionSdk();
  const transport = createTransport(sdk, serverConfig);

  sdk.onServer = () => ({ ok: true, status: 200, body: ' [{"author":"looker_agent"}] ' });
  assert.deepEqual(await transport.request('GET', '/x'), {
    ok: true, status: 200, body: [{ author: 'looker_agent' }],
  });
  sdk.onServer = () => ({ ok: false, status: 502, body: 'could not reach the agent\n' });
  assert.deepEqual(await transport.request('GET', '/x'), {
    ok: false, status: 502, body: 'could not reach the agent\n',
  });
  sdk.onServer = () => ({ status: 200, body: '{not json' });
  assert.deepEqual(await transport.request('GET', '/x'), { ok: true, status: 200, body: '{not json' });
  // "ok" follows the status, not a flag that might be missing or wrong.
  sdk.onServer = () => ({ ok: true, status: 401, body: '' });
  assert.equal((await transport.request('GET', '/x')).ok, false);
  sdk.onServer = () => ({ body: {} });
  assert.deepEqual(await transport.request('GET', '/x'), { ok: false, status: 0, body: {} });
});

test('a call Looker cannot make is reported with the address it tried', async () => {
  const sdk = new FakeExtensionSdk();
  const transport = createTransport(sdk, serverConfig);
  sdk.onServer = () => { throw new Error('Extension not entitled to access external API url'); };
  await assert.rejects(transport.request('GET', '/list-apps'), (error) => {
    assert.ok(error instanceof TransportError);
    assert.match(error.message, /Looker's server could not reach the agent gateway at http:\/\/looker-agent-gateway\.looker-agent\.svc\.cluster\.local\/list-apps: Extension not entitled/);
    return true;
  });
  sdk.onServer = () => undefined;
  await assert.rejects(transport.request('GET', '/list-apps'), TransportError);
});

test('what Looker or the browser reports is quoted in one short line', async () => {
  const sdk = new FakeExtensionSdk();
  const transport = createTransport(sdk, serverConfig);
  sdk.onServer = () => { throw new Error(`first line\n\n# second line ${'x'.repeat(5000)}`); };
  await assert.rejects(transport.request('GET', '/x'), (error) => {
    assert.ok(error instanceof TransportError);
    const detail = error.message.slice(error.message.indexOf('/x: ') + 4);
    assert.equal(detail, `first line # second line ${'x'.repeat(175)}...`);
    return true;
  });
  // Something thrown that is not an Error is quoted the same way.
  sdk.onServer = () => { throw 'refused\nby policy'; }; // eslint-disable-line no-throw-literal
  await assert.rejects(transport.request('GET', '/x'), /\/x: refused by policy$/);
});

test('browser transport: the password buys a token once, calls go from the browser', async () => {
  const sdk = new FakeExtensionSdk();
  let issued = 0;
  sdk.onServer = () => {
    issued += 1;
    return { ok: true, status: 200, body: { access_token: `token-${issued}`, token_type: 'Bearer', expires_in: 900 } };
  };
  sdk.onFetch = () => ({ ok: true, status: 200, body: { id: 'job-1', status: 'running' } });
  let time = 0;
  const transport = createTransport(sdk, browserConfig, () => time);

  await transport.request('POST', '/_gateway/jobs/run', { appName: 'looker_app' });
  await transport.request('GET', '/_gateway/jobs/job-1?wait=5');

  // One exchange through Looker's server, with the secret tag...
  assert.deepEqual(sdk.serverCalls, [{
    url: `${SERVER_URL}/_gateway/token`,
    init: { method: 'POST', headers: { Authorization: BASIC_WITH_TAG } },
    responseBodyType: undefined,
  }]);
  // ...and the calls themselves from the browser, with the token only.
  assert.deepEqual(sdk.fetchCalls.map((call) => [call.url, call.init]), [
    [`${BROWSER_URL}/_gateway/jobs/run`, {
      method: 'POST',
      headers: { Authorization: 'Bearer token-1', 'Content-Type': 'application/json' },
      body: '{"appName":"looker_app"}',
    }],
    [`${BROWSER_URL}/_gateway/jobs/job-1?wait=5`, {
      method: 'GET', headers: { Authorization: 'Bearer token-1' },
    }],
  ]);
  for (const call of sdk.fetchCalls) assert.doesNotMatch(JSON.stringify(call), /secret:/);

  // A minute before it runs out, the token is renewed.
  time = (900 - 61) * 1000;
  await transport.request('GET', '/x');
  assert.equal(issued, 1);
  time = (900 - 59) * 1000;
  await transport.request('GET', '/x');
  assert.equal(issued, 2);
  assert.equal(sdk.fetchCalls.at(-1).init.headers.Authorization, 'Bearer token-2');
});

test('browser transport: a refused token is replaced once, then the refusal stands', async () => {
  const sdk = new FakeExtensionSdk();
  let issued = 0;
  sdk.onServer = () => {
    issued += 1;
    return { ok: true, status: 200, body: { access_token: `token-${issued}`, expires_in: 900 } };
  };
  // The gateway restarted: it only knows tokens it issued after that.
  sdk.onFetch = (url, init) => (init.headers.Authorization === 'Bearer token-1'
    ? { ok: false, status: 401, body: 'authentication required\n' }
    : { ok: true, status: 200, body: { fine: true } });
  const transport = createTransport(sdk, browserConfig, () => 0);
  assert.deepEqual(await transport.request('GET', '/x'), { ok: true, status: 200, body: { fine: true } });
  assert.equal(issued, 2);
  assert.equal(sdk.fetchCalls.length, 2);

  // Always refused: two tries, no loop.
  sdk.onFetch = () => ({ ok: false, status: 401, body: 'authentication required\n' });
  const refused = await transport.request('GET', '/x');
  assert.equal(refused.status, 401);
  assert.equal(sdk.fetchCalls.length, 4);
});

test('browser transport: calls that start together share one token exchange', async () => {
  const sdk = new FakeExtensionSdk();
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  sdk.onServer = async () => {
    await gate;
    return { ok: true, status: 200, body: { access_token: 'token-1', expires_in: 900 } };
  };
  const transport = createTransport(sdk, browserConfig, () => 0);
  const both = Promise.all([transport.request('GET', '/a'), transport.request('GET', '/b')]);
  release();
  await both;
  assert.equal(sdk.serverCalls.length, 1);
  assert.equal(sdk.fetchCalls.length, 2);
});

test('browser transport: no token, no call', async () => {
  const sdk = new FakeExtensionSdk();
  sdk.onServer = () => ({ ok: false, status: 401, body: 'authentication required\n' });
  const transport = createTransport(sdk, browserConfig, () => 0);
  await assert.rejects(transport.request('GET', '/x'), (error) => {
    assert.ok(error instanceof TransportError);
    assert.equal(error.status, 401);
    assert.match(error.message, /did not issue a token \(HTTP 401\)/);
    return true;
  });
  assert.equal(sdk.fetchCalls.length, 0);
  // A later call tries the exchange again instead of failing for ever.
  sdk.onServer = () => ({ ok: true, status: 200, body: { access_token: 'token-1', expires_in: 900 } });
  assert.equal((await transport.request('GET', '/x')).status, 200);

  // A 200 without a token is not a token.
  const other = new FakeExtensionSdk();
  other.onServer = () => ({ ok: true, status: 200, body: '<html>sign in</html>' });
  await assert.rejects(createTransport(other, browserConfig, () => 0).request('GET', '/x'), TransportError);
});

test('configuration mistakes are reported before any call', () => {
  const sdk = new FakeExtensionSdk();
  assert.throws(() => createTransport(sdk, { ...serverConfig, serverGatewayUrl: '' }), /serverGatewayUrl is empty/);
  assert.throws(() => createTransport(sdk, { ...serverConfig, transport: 'carrier-pigeon' }), /Unknown transport/);
  // fetchProxy only does https, and a browser on an https Looker page would
  // refuse plain http anyway.
  for (const url of ['', 'http://agent.example.com', 'agent.example.com']) {
    assert.throws(() => createTransport(sdk, { ...browserConfig, browserGatewayUrl: url }), /https:\/\//);
  }
  assert.equal(createTransport(sdk, serverConfig).name, 'server');
  assert.equal(createTransport(sdk, browserConfig).name, 'browser');
});
