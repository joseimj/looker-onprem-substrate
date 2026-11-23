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

import { MAX_QUESTION_CHARS } from '../src/adk.js';
import { configureChat, createHandler, createLinkClickListener } from '../src/chat.js';
import { AgentClient } from '../src/client.js';
import { config, defaults } from '../src/config.js';
import { mentionsEmbedSignIn } from '../src/links.js';
import {
  anchor, FakeAgent, FakeClock, PNG_ADK_BASE64, PNG_STANDARD_BASE64, textEvent,
} from './fakes.js';

const LOOKER = 'https://looker.example.com';
const SIGNED = `${LOOKER}/login/embed/${encodeURIComponent('/embed/dashboards/12')}`
  + '?nonce=%22abc%22&time=1700000000&force_logout_login=true&signature=c2lnbmF0dXJl';

// What deep-chat passes as `signals`: onResponse may be called once per message.
function recordingSignals() {
  const responses = [];
  return { responses, signals: { onResponse: (response) => { responses.push(response); } } };
}

// deep-chat accepts a response only if it has a string `text`, `html` or
// `error`, or a `files` array (its RequestUtils.validateResponseFormat).
function acceptedByDeepChat(response) {
  return typeof response === 'object' && response !== null && (
    typeof response.error === 'string' || typeof response.text === 'string'
    || typeof response.html === 'string' || Array.isArray(response.files));
}

function fakeChatElement() {
  const listeners = {};
  return {
    style: {},
    listeners,
    addEventListener(type, listener, options) { listeners[type] = { listener, options }; },
  };
}

async function handed(client, question = 'q', options = { lookerOrigin: LOOKER }) {
  const { responses, signals } = recordingSignals();
  await createHandler(client, options)({ messages: [{ role: 'user', text: question }] }, signals);
  assert.equal(responses.length, 1);
  assert.ok(acceptedByDeepChat(responses[0]));
  return responses[0];
}

test('the handler sends the question to the agent and hands the answer to the chat', async () => {
  const asked = [];
  const client = {
    ask: async (text) => {
      asked.push(text);
      return { text: 'There are 42 orders.', files: [{ src: 'data:image/png;base64,AAAA', type: 'image', name: 'a.png' }] };
    },
  };
  const { responses, signals } = recordingSignals();
  await createHandler(client)({ messages: [{ role: 'user', text: 'how many orders?' }] }, signals);
  assert.deepEqual(asked, ['how many orders?']);
  assert.deepEqual(responses, [{
    text: 'There are 42 orders.',
    files: [{ src: 'data:image/png;base64,AAAA', type: 'image', name: 'a.png' }],
  }]);
  assert.ok(responses.every(acceptedByDeepChat));
});

test('the handler leaves out what an answer does not have', async () => {
  const answers = [
    [{ text: 'only text', files: [] }, { text: 'only text' }],
    [{ text: '', files: [{ src: 'data:image/png;base64,AAAA', type: 'image' }] },
      { files: [{ src: 'data:image/png;base64,AAAA', type: 'image' }] }],
    [{ text: '', files: [] }, { text: '' }],
  ];
  for (const [answer, expected] of answers) {
    const { responses, signals } = recordingSignals();
    // eslint-disable-next-line no-await-in-loop
    await createHandler({ ask: async () => answer })({ messages: [{ role: 'user', text: 'q' }] }, signals);
    assert.deepEqual(responses, [expected]);
    assert.ok(acceptedByDeepChat(responses[0]));
  }
});

test('the handler turns a failure into an error message in the chat', async () => {
  const { responses, signals } = recordingSignals();
  const failing = { ask: async () => { throw new Error('The agent gateway refused the request (HTTP 401).'); } };
  await createHandler(failing)({ messages: [{ role: 'user', text: 'q' }] }, signals);
  assert.deepEqual(responses, [{ error: 'The agent gateway refused the request (HTTP 401).' }]);
  assert.ok(acceptedByDeepChat(responses[0]));
});

test('the handler does not bother the agent with an empty message', async () => {
  let asked = 0;
  const { responses, signals } = recordingSignals();
  createHandler({ ask: async () => { asked += 1; return { text: 'x', files: [] }; } })({ messages: [] }, signals);
  assert.equal(asked, 0);
  assert.equal(responses.length, 1);
  assert.equal(typeof responses[0].error, 'string');
});

test('a question longer than the agent takes is refused here, not sent', async () => {
  let asked = 0;
  const client = { ask: async () => { asked += 1; return { text: 'x', files: [] }; } };
  const tooLong = await handed(client, 'a'.repeat(MAX_QUESTION_CHARS + 1));
  assert.match(tooLong.error, /too long \(16001 characters\).*at most 16000/);
  assert.equal(asked, 0);
  assert.deepEqual(await handed(client, 'a'.repeat(MAX_QUESTION_CHARS)), { text: 'x' });
  assert.equal(asked, 1);
});

test('no signed embed link is ever handed to the chat', async () => {
  const plain = 'https://looker.example.com/dashboards/12';
  // In an answer: the link stays, as the plain page.
  const answer = await handed({
    ask: async () => ({ text: `Here it is.\n\n[Open the interactive version in Looker](${SIGNED})`, files: [] }),
  });
  assert.deepEqual(answer, { text: `Here it is.\n\n[Open the interactive version in Looker](${plain})` });

  // Written so that only markdown would turn it back into the address, or for another Looker: gone.
  for (const text of [`[x](${SIGNED.replace('/login/embed/', '/login\\/embed/')})`,
    `see ${SIGNED.replace('signature=', 'signature&equals;')}`,
    `[x](${SIGNED.replace('looker.example.com', 'other.example.com')})`, SIGNED.replace('https://', '')]) {
    // eslint-disable-next-line no-await-in-loop
    const shown = await handed({ ask: async () => ({ text, files: [] }) });
    assert.equal(mentionsEmbedSignIn(shown.text), false, text);
    assert.doesNotMatch(shown.text, /c2lnbmF0dXJl/, text);
  }
  // An answer that was nothing but such a link is an empty answer.
  assert.deepEqual(await handed({ ask: async () => ({ text: SIGNED.replace('https://', ''), files: [] }) }), { text: '' });

  // In an error message, where the far side's words are quoted.
  const failure = await handed({ ask: async () => { throw new Error(`The agent could not answer (HTTP 500): see ${SIGNED}`); } });
  assert.equal(failure.error, `The agent could not answer (HTTP 500): see ${plain}`);

  // Without knowing where Looker lives, the link is taken out.
  const unknown = await handed({ ask: async () => ({ text: `[open](${SIGNED})`, files: [] }) }, 'q', {});
  assert.deepEqual(unknown, { text: '[open]()' });
});

test('an error message is shown as the text it is, and not at any length', async () => {
  const hostile = 'The agent could not answer (HTTP 500): [click to sign in again](https://evil.example/login) '
    + '![x](https://evil.example/p.png) <b>*now*</b>\n\n# Heading';
  const failure = await handed({ ask: async () => { throw new Error(hostile); } });
  assert.equal(failure.error, 'The agent could not answer (HTTP 500): '
    + '\\[click to sign in again\\](https://evil.example/login) !\\[x\\](https://evil.example/p.png) '
    + '\\<b\\>\\*now\\*\\</b\\> \\# Heading');
  const long = await handed({ ask: async () => { throw new Error(`failed: ${'A'.repeat(2_000_000)}`); } });
  assert.equal(long.error.length, 803);
  // Something that is not an Error is still a message.
  assert.deepEqual(await handed({ ask: async () => { throw 'plain [text]'; } }), { error: 'plain \\[text\\]' }); // eslint-disable-line no-throw-literal
});

function clickOn(listener, link, { type = 'click', button = 0, inside = { tagName: 'SPAN' } } = {}) {
  const event = {
    type,
    button,
    prevented: false,
    preventDefault() { this.prevented = true; },
    composedPath: () => (link === undefined ? [{ tagName: 'DIV' }] : [inside, link, { tagName: 'DIV' }]),
  };
  listener(event);
  return event.prevented;
}

test('clicks on links are decided here: Looker opens what may be opened, the rest does nothing', () => {
  const opened = [];
  const listener = createLinkClickListener({
    lookerOrigin: LOOKER,
    openLooker: (path) => opened.push(['looker', path]),
    openExternal: (url) => opened.push(['external', url]),
  });

  // A page of this Looker, as the policy in markdown.js writes it.
  assert.equal(clickOn(listener, anchor({ href: `${LOOKER}/dashboards/12?Country=Brazil` })), true);
  // A signed link, should one ever be in the page: the plain page, never the link.
  assert.equal(clickOn(listener, anchor({ href: SIGNED })), true);
  assert.deepEqual(opened, [['looker', '/dashboards/12?Country=Brazil'], ['looker', '/dashboards/12']]);

  // Stopped, and nothing opened.
  for (const href of ['https://cloud.google.com/looker/docs', 'https://evil.example/c?d=secret', 'javascript:alert(1)',
    `${LOOKER}/logout`, `${LOOKER}//evil.example/login`, SIGNED.replace('/login/embed/', '/login//embed/'),
    'data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==', 'data:image/png;base64,iVBORw0KGgo=',
    'blob:https://looker.example.com/1', '#fn1', undefined]) {
    assert.equal(clickOn(listener, anchor({ href })), true, String(href));
  }
  assert.equal(opened.length, 2);

  // The link deep-chat wraps around an image it shows: saving it is the browser's job.
  const wrapper = anchor({ href: `data:image/png;base64,${PNG_STANDARD_BASE64}`, download: 'dashboard_12.png', child: { tagName: 'IMG' } });
  assert.equal(clickOn(listener, wrapper, { inside: { tagName: 'IMG' } }), false);
  // Not a link at all.
  assert.equal(clickOn(listener, undefined), false);
  assert.equal(opened.length, 2);
});

test('a middle click is decided the same way, and a right click opens nothing', () => {
  const opened = [];
  const listener = createLinkClickListener({
    lookerOrigin: LOOKER, openLooker: (path) => opened.push(path), openExternal: (url) => opened.push(url),
  });
  const page = anchor({ href: `${LOOKER}/looks/5` });
  const elsewhere = anchor({ href: 'https://evil.example/' });
  // The middle button raises "auxclick", never "click".
  assert.equal(clickOn(listener, page, { type: 'auxclick', button: 1 }), true);
  assert.equal(clickOn(listener, elsewhere, { type: 'auxclick', button: 1 }), true);
  assert.deepEqual(opened, ['/looks/5']);
  // The right button raises it too, on its way to the context menu.
  assert.equal(clickOn(listener, page, { type: 'auxclick', button: 2 }), false);
  assert.deepEqual(opened, ['/looks/5']);
});

test('a listed site is opened through Looker as another site', () => {
  const opened = [];
  const listener = createLinkClickListener({
    lookerOrigin: LOOKER,
    allowedLinkOrigins: ['https://docs.example.com'],
    openLooker: (path) => opened.push(['looker', path]),
    openExternal: (url) => opened.push(['external', url]),
  });
  assert.equal(clickOn(listener, anchor({ href: 'https://docs.example.com/guide?x=1' })), true);
  assert.equal(clickOn(listener, anchor({ href: 'https://docs.example.com.evil.example/guide' })), true);
  assert.deepEqual(opened, [['external', 'https://docs.example.com/guide?x=1']]);
});

test('the chat element is set up through deep-chat\'s own properties', async () => {
  const agent = new FakeAgent();
  const clock = new FakeClock();
  agent.reply = () => [textEvent(`Hello from the agent. [Open](${SIGNED})`)];
  const client = new AgentClient({
    transport: agent.transport(), appName: config.appName, userId: 'looker-42', sleep: clock.sleep, now: clock.now,
  });
  const opened = [];
  const windowObject = {};
  const chat = configureChat(fakeChatElement(), {
    client,
    config,
    displayName: 'Ada',
    lookerOrigin: LOOKER,
    openLooker: (path) => opened.push(path),
    openExternal: (url) => opened.push(url),
    globalObject: windowObject,
  });

  // Sized for Looker's loader, and no web font to fetch.
  assert.equal(chat.style.height, '100vh');
  assert.equal(chat.style.width, '100vw');
  assert.ok(chat.style.fontFamily && !/Inter/.test(chat.style.fontFamily));
  // Errors are shown as written, not as deep-chat's generic text.
  assert.deepEqual(chat.errorMessages, { displayServiceErrorMessages: true });
  assert.equal(chat.introMessage.text, `Hi Ada. ${config.introMessage}`);
  assert.equal(chat.textInput.placeholder.text, config.placeholder);
  // The input box stops at what the agent takes.
  assert.equal(chat.textInput.characterLimit, MAX_QUESTION_CHARS);

  // What markdown may become is in place where deep-chat looks for it.
  assert.equal(windowObject.remarkable_plugins.length, 1);
  const remarkable = { renderer: { rules: {} } };
  windowObject.remarkable_plugins[0].plugin(remarkable);
  assert.equal(remarkable.renderer.rules.image([{ src: 'https://evil.example/p.png', alt: 'x' }], 0), '[image: x]');
  assert.equal(remarkable.renderer.rules.link_open([{ href: 'javascript:alert(1)' }], 0), '<a>');
  assert.match(remarkable.renderer.rules.link_open([{ href: '/looks/5' }], 0), /^<a href="https:\/\/looker\.example\.com\/looks\/5"/);

  // Clicks, with any button, are decided before anything inside the component sees them.
  for (const type of ['click', 'auxclick']) {
    assert.equal(typeof chat.listeners[type].listener, 'function', type);
    assert.equal(chat.listeners[type].options, true, type);
  }
  assert.equal(clickOn(chat.listeners.click.listener, anchor({ href: `${LOOKER}/dashboards/7` })), true);
  assert.deepEqual(opened, ['/dashboards/7']);

  // End to end through the pieces: handler -> client -> (fake) gateway -> agent.
  const { responses, signals } = recordingSignals();
  await chat.connect.handler({ messages: [{ role: 'user', text: 'hi' }] }, signals);
  assert.deepEqual(responses, [{ text: 'Hello from the agent. [Open](https://looker.example.com/dashboards/12)' }]);
  assert.equal(agent.runs[0].appName, 'looker_app');
  assert.equal(agent.runs[0].userId, 'looker-42');

  // No name known: no dangling greeting.
  const anonymous = configureChat(fakeChatElement(), { client, config, displayName: '', globalObject: {} });
  assert.equal(anonymous.introMessage.text, config.introMessage);
});

test('a person\'s name in the greeting is text, whatever it holds', () => {
  const client = { ask: async () => ({ text: '', files: [] }) };
  const greet = (displayName) => configureChat(fakeChatElement(), {
    client, config, displayName, lookerOrigin: LOOKER, globalObject: {},
  }).introMessage.text;
  assert.equal(greet('[Ada](https://evil.example) ![x](https://evil.example/p.png)'),
    `Hi \\[Ada\\](https://evil.example) !\\[x\\](https://evil.example/p.png). ${config.introMessage}`);
  assert.equal(greet('A'.repeat(500)), `Hi ${'A'.repeat(60)}.... ${config.introMessage}`);
  assert.equal(greet(undefined), config.introMessage);
});

test('the built-in settings open no other site and name the gateway in its own namespace', () => {
  // `defaults`, not `config`: a deployment may set its own values.
  assert.deepEqual(defaults.allowedLinkOrigins, []);
  assert.equal(defaults.serverGatewayUrl, 'http://looker-agent-gateway.looker-agent-gateway.svc.cluster.local');
  assert.equal(defaults.appName, 'looker_app');
  // A deployment file written before this setting existed still gives a list.
  const chat = configureChat(fakeChatElement(), {
    client: { ask: async () => ({ text: '', files: [] }) },
    config: { ...config, allowedLinkOrigins: undefined },
    displayName: '',
    lookerOrigin: LOOKER,
    globalObject: {},
  });
  assert.equal(clickOn(chat.listeners.click.listener, anchor({ href: 'https://evil.example/' })), true);
});

test('an image the agent rendered reaches the chat as a file to show', async () => {
  const agent = new FakeAgent();
  const clock = new FakeClock();
  agent.reply = (body) => {
    agent.saveArtifact(body.sessionId, 'dashboard_12.png', { inlineData: { data: PNG_ADK_BASE64, mimeType: 'image/png' } });
    return [{ actions: { artifactDelta: { 'dashboard_12.png': 0 } } }, textEvent('Here is dashboard 12.')];
  };
  const client = new AgentClient({
    transport: agent.transport(), appName: 'looker_app', userId: 'looker-42', sleep: clock.sleep, now: clock.now,
  });
  assert.deepEqual(await handed(client, 'show dashboard 12'), {
    text: 'Here is dashboard 12.',
    files: [{ src: `data:image/png;base64,${PNG_STANDARD_BASE64}`, name: 'dashboard_12.png', type: 'image' }],
  });
});
