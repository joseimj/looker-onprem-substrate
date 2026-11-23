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

import {
  artifactPath, artifactToMessage, isArtifactName, lastUserText, MAX_ARTIFACTS_PER_ANSWER, MAX_IMAGE_BYTES,
  MAX_QUESTION_CHARS, runRequest, sessionsPath, summarizeEvents, toStandardBase64, userIdFor,
} from '../src/adk.js';
import {
  PNG_ADK_BASE64, PNG_BYTES, PNG_STANDARD_BASE64, textEvent,
} from './fakes.js';

test('each Looker user gets their own ADK user id', () => {
  assert.equal(userIdFor({ id: '42', display_name: 'Ada' }), 'looker-42');
  assert.equal(userIdFor({ id: 7 }), 'looker-7');
  assert.notEqual(userIdFor({ id: '42' }), userIdFor({ id: '43' }));
  for (const unknown of [undefined, null, {}, { id: '' }, { id: '  ' }, { id: null }]) {
    assert.equal(userIdFor(unknown), 'looker-unknown');
  }
  // Looker's ids are numbers. The id becomes part of request paths, and the
  // gateway accepts "looker-<digits>" or "looker-unknown" and nothing else.
  assert.equal(userIdFor({ id: ' 42 ' }), 'looker-42');
  for (const odd of ['1/../2', '42abc', 'admin', '-1', '4.2', '1e3', '1'.repeat(19), '42?x=1', {}, [], true]) {
    assert.equal(userIdFor({ id: odd }), 'looker-unknown', String(odd));
  }
  for (const id of [0, 7, '1'.repeat(18)]) assert.match(userIdFor({ id }), /^looker-(unknown|[0-9]{1,18})$/);
});

test('paths are built for the ADK API server and encoded', () => {
  assert.equal(sessionsPath('looker_app', 'looker-42'), '/apps/looker_app/users/looker-42/sessions');
  assert.equal(sessionsPath('my app', 'a/b'), '/apps/my%20app/users/a%2Fb/sessions');
  assert.equal(
    artifactPath('looker_app', 'looker-42', 's 1', 'dashboard_12.png', 0),
    '/apps/looker_app/users/looker-42/sessions/s%201/artifacts/dashboard_12.png?version=0',
  );
  // ADK routes an artifact name as a path, so "/" stays.
  assert.equal(
    artifactPath('looker_app', 'u', 's', 'charts/q1.png', 3),
    '/apps/looker_app/users/u/sessions/s/artifacts/charts/q1.png?version=3',
  );
  // The image of a LookML dashboard: "::" goes into the path as it is. The
  // gateway compares the name letter by letter and would refuse "%3A%3A".
  assert.equal(
    artifactPath('looker_app', 'looker-42', 'session-1', 'dashboard_thelook::overview.png', 0),
    '/apps/looker_app/users/looker-42/sessions/session-1/artifacts/dashboard_thelook::overview.png?version=0',
  );
  // No version known, or something that is not one: ask for the latest.
  for (const version of [undefined, null, -1, 1.5, '2', NaN]) {
    assert.equal(
      artifactPath('looker_app', 'u', 's', 'a.png', version),
      '/apps/looker_app/users/u/sessions/s/artifacts/a.png',
    );
  }
});

test('a name from an answer is put into a path only when it is a file name', () => {
  for (const name of ['dashboard_12.png', 'look_5.png', 'query_thelook_order_items.png', 'dashboard_thelook::overview.png',
    'charts/q1.png', 'a/b/c/d.png', 'a', 'a.b-c_d:e', '...', 'x'.repeat(128)]) {
    assert.equal(isArtifactName(name), true, name);
  }
  for (const name of ['', '.', '..', 'a/../b.png', 'dashboard_x/../../../../_gateway/jobs/J', '../a.png', 'a/./b.png',
    '/a.png', 'a.png/', 'a//b.png', 'a/b/c/d/e.png', 'q1 #2.png', 'a?version=1', 'a#b', 'a%2Fb', 'a\\b', 'a\nb',
    'a\u0000b', 'user:x/..', 'x'.repeat(129), '\u00e9.png', 'x_](https://evil.example/a)_[y.png',
    undefined, null, 42, {}, ['a.png']]) {
    assert.equal(isArtifactName(name), false, String(name));
    assert.throws(() => artifactPath('looker_app', 'u', 's', name, 0), TypeError, String(name));
  }
});

test('the run request carries the question as a user message', () => {
  assert.deepEqual(
    runRequest({ appName: 'looker_app', userId: 'looker-42', sessionId: 's1', text: 'show dashboard 1' }),
    {
      appName: 'looker_app',
      userId: 'looker-42',
      sessionId: 's1',
      newMessage: { role: 'user', parts: [{ text: 'show dashboard 1' }] },
      streaming: false,
    },
  );
});

test('the newest user message is the question', () => {
  assert.equal(lastUserText({ messages: [{ role: 'user', text: ' how many orders? ' }] }), 'how many orders?');
  assert.equal(lastUserText({
    messages: [
      { role: 'user', text: 'first' }, { role: 'ai', text: 'answer' }, { role: 'user', text: 'second' },
    ],
  }), 'second');
  assert.equal(lastUserText({ messages: [{ role: 'user', text: 'q' }, { role: 'ai', text: 'a' }] }), 'q');
  for (const empty of [undefined, {}, { messages: [] }, { messages: [{ role: 'user', text: '   ' }] },
    { messages: [{ role: 'user', files: [] }] }]) {
    assert.equal(lastUserText(empty), '');
  }
});

test('a turn is reduced to the model text and the saved artifacts', () => {
  // Shaped like what ADK returns from POST /run for "show me dashboard 12".
  const events = [
    {
      author: 'looker_agent',
      content: {
        role: 'model',
        parts: [
          { text: 'private reasoning', thought: true },
          { text: 'Rendering the dashboard.' },
          { functionCall: { id: 'c1', name: 'show_dashboard_inline', args: { dashboard_id: '12' } } },
        ],
      },
      actions: { stateDelta: {}, artifactDelta: {} },
    },
    {
      author: 'looker_agent',
      content: {
        role: 'user',
        parts: [{
          functionResponse: {
            id: 'c1', name: 'show_dashboard_inline', response: { status: 'success', artifact_filename: 'dashboard_12.png' },
          },
        }],
      },
      actions: { stateDelta: {}, artifactDelta: { 'dashboard_12.png': 0 } },
    },
    textEvent('Here it is.\n\n[Open the interactive version in Looker](https://looker.example.com/login/embed/x)'),
  ];
  assert.deepEqual(summarizeEvents(events), {
    text: 'Rendering the dashboard.\n\nHere it is.\n\n'
      + '[Open the interactive version in Looker](https://looker.example.com/login/embed/x)',
    artifacts: [{ name: 'dashboard_12.png', version: 0 }],
    error: '',
  });
});

test('summaries skip what is not an answer', () => {
  const events = [
    { author: 'user', content: { role: 'user', parts: [{ text: 'my own question' }] } },
    textEvent('draft, sent again in full below', { partial: true }),
    textEvent('   '),
    textEvent('final'),
    null,
    'not an event',
    { author: 'looker_agent' },
  ];
  assert.deepEqual(summarizeEvents(events), { text: 'final', artifacts: [], error: '' });
  assert.deepEqual(summarizeEvents(undefined), { text: '', artifacts: [], error: '' });
  assert.deepEqual(summarizeEvents({ detail: 'not a list' }), { text: '', artifacts: [], error: '' });
});

test('summaries keep the newest version of each artifact, in order', () => {
  const events = [
    { actions: { artifactDelta: { 'a.png': 0, 'b.png': 0 } } },
    { actions: { artifactDelta: { 'a.png': 1 } } },
  ];
  assert.deepEqual(summarizeEvents(events).artifacts, [
    { name: 'a.png', version: 1 }, { name: 'b.png', version: 0 },
  ]);
});

test('summaries report model errors', () => {
  const events = [
    textEvent('partial answer'),
    { author: 'looker_agent', errorCode: 'RESOURCE_EXHAUSTED', errorMessage: 'Quota exceeded.' },
    { author: 'looker_agent', errorCode: 'UNKNOWN' },
  ];
  const summary = summarizeEvents(events);
  assert.equal(summary.text, 'partial answer');
  assert.equal(summary.error, 'Quota exceeded.\nThe agent reported error UNKNOWN.');
});

test('base64 from ADK is converted to the alphabet a data: URL needs', () => {
  // Guard the fixture: it must really exercise the difference.
  assert.match(PNG_STANDARD_BASE64, /[+/]/);
  assert.match(PNG_ADK_BASE64, /[-_]/);
  assert.doesNotMatch(PNG_ADK_BASE64, /[+/]/);

  assert.equal(toStandardBase64(PNG_ADK_BASE64), PNG_STANDARD_BASE64);
  // Without padding (base64url as most libraries write it), and with line breaks.
  const unpadded = Buffer.from(PNG_BYTES).toString('base64url');
  assert.equal(toStandardBase64(unpadded), PNG_STANDARD_BASE64);
  assert.equal(toStandardBase64(`${unpadded.slice(0, 5)}\n${unpadded.slice(5)}`), PNG_STANDARD_BASE64);
  // Already standard: unchanged.
  assert.equal(toStandardBase64(PNG_STANDARD_BASE64), PNG_STANDARD_BASE64);
  // Every length, so padding is right for each remainder.
  for (let length = 0; length <= 9; length += 1) {
    const bytes = Buffer.from(Array.from({ length }, (_, i) => 250 + (i % 6)));
    const converted = toStandardBase64(bytes.toString('base64url'));
    assert.equal(converted, bytes.toString('base64'));
    assert.deepEqual(Buffer.from(converted, 'base64'), bytes);
  }
});

test('an image artifact becomes an inline image', () => {
  const message = artifactToMessage('dashboard_12.png', {
    inlineData: { data: PNG_ADK_BASE64, mimeType: 'image/png' },
  });
  assert.deepEqual(message, {
    file: { src: `data:image/png;base64,${PNG_STANDARD_BASE64}`, name: 'dashboard_12.png', type: 'image' },
  });
  // What the browser will decode is the PNG the agent saved.
  const decoded = Buffer.from(message.file.src.split(',')[1], 'base64');
  assert.deepEqual(new Uint8Array(decoded), PNG_BYTES);

  // snake_case field names, a type with a parameter and in capitals: the same image.
  assert.deepEqual(
    artifactToMessage('dashboard_12.png', { inline_data: { data: PNG_ADK_BASE64, mime_type: 'IMAGE/PNG; q=1' } }),
    message,
  );
  // A JPEG is shown too. In a folder, the name to save under is the file's own.
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46]).toString('base64');
  assert.deepEqual(artifactToMessage('charts/q1.jpeg', { inlineData: { data: jpeg, mimeType: 'image/jpeg' } }), {
    file: { src: `data:image/jpeg;base64,${jpeg}`, name: 'q1.jpeg', type: 'image' },
  });
});

test('nothing but a PNG or a JPEG is shown, whatever the answer calls it', () => {
  const png = PNG_ADK_BASE64;
  const shown = (name, part) => artifactToMessage(name, part);
  // Another kind of file: deep-chat would offer it for saving under the name
  // the answer gave it.
  for (const [name, part] of [
    ['report.pdf', { inlineData: { data: 'JVBERi0x', mimeType: 'application/pdf' } }],
    ['report.exe', { inlineData: { data: 'TVqQAAMAAAAEAAAA', mimeType: 'application/x-msdownload' } }],
    ['page.xhtml', { inlineData: { data: 'PGh0bWw+', mimeType: 'application/xhtml+xml' } }],
    ['pic.svg', { inlineData: { data: 'PHN2Zz4=', mimeType: 'image/svg+xml' } }],
    ['pic.gif', { inlineData: { data: 'R0lGODlh', mimeType: 'image/gif' } }],
    ['blob', { inline_data: { data: png } }],
    ['notes.txt', { text: 'hello' }],
    // The type says PNG, the data does not start like one.
    ['dashboard_1.png', { inlineData: { data: 'PGh0bWw+PHNjcmlwdD4=', mimeType: 'image/png' } }],
    ['dashboard_1.png', { inlineData: { data: 'AAAA', mimeType: 'image/png' } }],
    ['dashboard_1.png', { inlineData: { data: png, mimeType: 'image/jpeg' } }],
    // A type that tries to bring content of its own into the data: address.
    ['x.png', { inlineData: { data: png, mimeType: 'text/html,<script>alert(1)</script>' } }],
    ['x.png', { inlineData: { data: png, mimeType: 'image/png,<svg onload=alert(1)>' } }],
    ['x.png', { inlineData: { data: png, mimeType: ['image/png'] } }],
    // Data that is not base64.
    ['x.png', { inlineData: { data: `${png}"><script>`, mimeType: 'image/png' } }],
    ['x.png', { inlineData: { data: `iVBORw0K,${png}`, mimeType: 'image/png' } }],
    ['x.png', { inlineData: { data: '', mimeType: 'image/png' } }],
    ['x.png', { inlineData: { data: 42, mimeType: 'image/png' } }],
    ['x.png', { inlineData: {} }], ['x.png', {}], ['x.png', null], ['x.png', undefined], ['x.png', 'x'],
    // A name that is not a file name.
    ['../x.png', { inlineData: { data: png, mimeType: 'image/png' } }],
    ['x_](https://evil.example/a)_[y.png', { inlineData: { data: png, mimeType: 'image/png' } }],
  ]) {
    assert.equal(shown(name, part), null, `${name} ${String(JSON.stringify(part)).slice(0, 80)}`);
  }

  // The name to save under ends the way a PNG's does, whatever the artifact was called.
  assert.equal(shown('report.exe', { inlineData: { data: png, mimeType: 'image/png' } }).file.name, 'report.exe.png');
  assert.equal(shown('a/b/chart', { inlineData: { data: png, mimeType: 'image/png' } }).file.name, 'chart.png');
  assert.equal(shown('CHART.PNG', { inlineData: { data: png, mimeType: 'image/png' } }).file.name, 'CHART.PNG');
});

test('an image larger than a rendered dashboard can be is not shown', () => {
  const pngOf = (bytes) => {
    const data = Buffer.alloc(bytes);
    Buffer.from(PNG_BYTES).copy(data);
    return { inlineData: { data: data.toString('base64'), mimeType: 'image/png' } };
  };
  assert.notEqual(artifactToMessage('big.png', pngOf(MAX_IMAGE_BYTES)), null);
  assert.equal(artifactToMessage('big.png', pngOf(MAX_IMAGE_BYTES + 16)), null);
});

test('the limits are the ones the gateway holds the chat to', () => {
  // gateway/gateway.py refuses a longer question; the extension says so first.
  assert.equal(MAX_QUESTION_CHARS, 16000);
  assert.ok(MAX_ARTIFACTS_PER_ANSWER >= 1 && MAX_ARTIFACTS_PER_ANSWER <= 16);
});
