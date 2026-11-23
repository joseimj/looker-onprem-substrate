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

import { MAX_ARTIFACTS_PER_ANSWER } from '../src/adk.js';
import { AgentClient, AgentError } from '../src/client.js';
import {
  FakeAgent, FakeClock, PNG_ADK_BASE64, PNG_STANDARD_BASE64, textEvent,
} from './fakes.js';

function setup(options = {}) {
  const agent = new FakeAgent();
  const clock = new FakeClock();
  const client = new AgentClient({
    transport: agent.transport(),
    appName: 'looker_app',
    userId: 'looker-42',
    credentialHint: 'Check the user attribute.',
    pollWaitSeconds: 5,
    turnTimeoutSeconds: 600,
    sleep: clock.sleep,
    now: clock.now,
    ...options,
  });
  return { agent, clock, client };
}

test('a question starts a session, runs the agent and returns its text', async () => {
  const { agent, client } = setup();
  const answer = await client.ask('how many orders are complete?');
  assert.deepEqual(answer, { text: 'You said: how many orders are complete?', files: [] });

  // Both POSTs to the agent went through the gateway's job API...
  const started = agent.callsTo('POST', '/').map((call) => call.path);
  assert.deepEqual(started, [
    '/_gateway/jobs/apps/looker_app/users/looker-42/sessions',
    '/_gateway/jobs/run',
  ]);
  // ...and the agent got a run request for that session and user.
  assert.equal(agent.runs.length, 1);
  assert.deepEqual(agent.runs[0], {
    appName: 'looker_app',
    userId: 'looker-42',
    sessionId: client.sessionId,
    newMessage: { role: 'user', parts: [{ text: 'how many orders are complete?' }] },
    streaming: false,
  });
  assert.ok(agent.sessions.has(client.sessionId));
});

test('later questions stay in the same conversation', async () => {
  const { agent, client } = setup();
  await client.ask('first');
  const session = client.sessionId;
  await client.ask('second');
  await client.ask('third');
  assert.equal(agent.sessions.size, 1);
  assert.deepEqual(agent.runs.map((run) => run.sessionId), [session, session, session]);
  assert.deepEqual(agent.runs.map((run) => run.newMessage.parts[0].text), ['first', 'second', 'third']);
});

test('questions asked at the same moment are answered one after the other', async () => {
  const { agent, client } = setup();
  agent.pollsBeforeDone = 2;
  const answers = await Promise.all([client.ask('first'), client.ask('second'), client.ask('third')]);
  assert.deepEqual(answers.map((answer) => answer.text), [
    'You said: first', 'You said: second', 'You said: third',
  ]);
  // One conversation, not one per question, and the turns in the order asked.
  assert.equal(agent.sessions.size, 1);
  assert.deepEqual(agent.runs.map((run) => run.newMessage.parts[0].text), ['first', 'second', 'third']);
  assert.deepEqual(new Set(agent.runs.map((run) => run.sessionId)), new Set([client.sessionId]));
  // Never two requests to the agent in flight: the conversation is started
  // once, and each turn only after the one before has been collected.
  const order = agent.calls.map((call) => {
    if (call.method === 'GET') return 'poll';
    return call.path === '/_gateway/jobs/run' ? 'run' : 'start';
  });
  const collected = ['poll', 'poll', 'poll']; // twice "running", then the result
  assert.deepEqual(order, [
    'start', ...collected, 'run', ...collected, 'run', ...collected, 'run', ...collected,
  ]);
});

test('a question that fails does not hold up the next one', async () => {
  const { agent, client } = setup();
  agent.reply = (body) => {
    if (body.newMessage.parts[0].text === 'bad') throw new Error('unused');
    return [textEvent('fine')];
  };
  const original = agent.agent.bind(agent);
  agent.agent = (path, body) => (path === '/run' && body.newMessage.parts[0].text === 'bad'
    ? { status: 'done', http_status: 500, json: { detail: 'model call failed' } } : original(path, body));
  const [bad, good] = await Promise.allSettled([client.ask('bad'), client.ask('good')]);
  assert.equal(bad.status, 'rejected');
  assert.match(bad.reason.message, /model call failed/);
  assert.deepEqual(good, { status: 'fulfilled', value: { text: 'fine', files: [] } });
});

test('images the agent rendered are fetched and returned inline', async () => {
  const { agent, client } = setup();
  agent.reply = (body) => {
    agent.saveArtifact(body.sessionId, 'dashboard_12.png', {
      inlineData: { data: PNG_ADK_BASE64, mimeType: 'image/png' },
    });
    return [
      { author: 'looker_agent', content: { role: 'user', parts: [] }, actions: { artifactDelta: { 'dashboard_12.png': 2 } } },
      textEvent('Here is dashboard 12.'),
    ];
  };
  const answer = await client.ask('show me dashboard 12');
  assert.equal(answer.text, 'Here is dashboard 12.');
  assert.deepEqual(answer.files, [{
    src: `data:image/png;base64,${PNG_STANDARD_BASE64}`, name: 'dashboard_12.png', type: 'image',
  }]);
  // The exact version the agent saved in this turn is the one that is fetched.
  const fetched = agent.callsTo('GET', '/apps/').map((call) => call.path);
  assert.deepEqual(fetched, [
    `/apps/looker_app/users/looker-42/sessions/${client.sessionId}/artifacts/dashboard_12.png?version=2`,
  ]);
});

test('an answer with only an image has no text, and one with nothing says so', async () => {
  const { agent, client } = setup();
  agent.reply = (body) => {
    agent.saveArtifact(body.sessionId, 'look_5.png', { inlineData: { data: PNG_ADK_BASE64, mimeType: 'image/png' } });
    return [{ actions: { artifactDelta: { 'look_5.png': 0 } } }];
  };
  let answer = await client.ask('show look 5');
  assert.equal(answer.text, '');
  assert.equal(answer.files.length, 1);

  agent.reply = () => [];
  answer = await client.ask('anything');
  assert.match(answer.text, /without an answer/);
  assert.deepEqual(answer.files, []);
});

test('an image that cannot be loaded does not cost the rest of the answer', async () => {
  const { agent, client } = setup();
  agent.reply = (body) => {
    agent.saveArtifact(body.sessionId, 'good.png', { inlineData: { data: PNG_ADK_BASE64, mimeType: 'image/png' } });
    return [
      { actions: { artifactDelta: { 'missing.png': 0, 'good.png': 0, 'boom.png': 0 } } },
      textEvent('Two charts.'),
    ];
  };
  agent.intercept = (call) => {
    if (call.path.includes('boom.png')) throw new Error('network down');
    return undefined;
  };
  const answer = await client.ask('two charts');
  assert.deepEqual(answer.files.map((file) => file.name), ['good.png']);
  assert.match(answer.text, /^Two charts\./);
  assert.match(answer.text, /"missing\.png", but it could not be loaded/);
  assert.match(answer.text, /"boom\.png", but it could not be loaded/);
});

test('a file that is not an image is named, not shown', async () => {
  const { agent, client } = setup();
  agent.reply = (body) => {
    agent.saveArtifact(body.sessionId, 'report.pdf', { inlineData: { data: 'JVBERi0x', mimeType: 'application/pdf' } });
    agent.saveArtifact(body.sessionId, 'setup.exe', { inlineData: { data: 'TVqQAAMAAAAEAAAA', mimeType: 'application/x-msdownload' } });
    agent.saveArtifact(body.sessionId, 'notes.txt', { text: '![x](https://evil.example/t.png?d=1)' });
    agent.saveArtifact(body.sessionId, 'fake.png', { inlineData: { data: 'PGh0bWw+PHNjcmlwdD4=', mimeType: 'image/png' } });
    agent.saveArtifact(body.sessionId, 'real.png', { inlineData: { data: PNG_ADK_BASE64, mimeType: 'image/png' } });
    return [
      { actions: { artifactDelta: { 'report.pdf': 0, 'setup.exe': 0, 'notes.txt': 0, 'fake.png': 0, 'real.png': 0 } } },
      textEvent('Five files.'),
    ];
  };
  const answer = await client.ask('files');
  // Only the PNG reaches the chat, where it could be shown and saved.
  assert.deepEqual(answer.files, [{
    src: `data:image/png;base64,${PNG_STANDARD_BASE64}`, name: 'real.png', type: 'image',
  }]);
  for (const name of ['report.pdf', 'setup.exe', 'notes.txt', 'fake.png']) {
    assert.ok(answer.text.includes(`"${name}", which is not an image this chat shows`), name);
  }
  // The text of a text file is not passed on as part of the answer.
  assert.doesNotMatch(answer.text, /evil\.example/);
});

test('an answer shows a handful of images, not hundreds', async () => {
  const { agent, client } = setup();
  await client.ask('warm up');
  agent.calls.length = 0;
  agent.reply = (body) => {
    const delta = {};
    for (let i = 0; i < 2000; i += 1) {
      delta[`dashboard_${i}.png`] = 0;
      if (i < 20) agent.saveArtifact(body.sessionId, `dashboard_${i}.png`, { inlineData: { data: PNG_ADK_BASE64, mimeType: 'image/png' } });
    }
    return [{ actions: { artifactDelta: delta } }];
  };
  const answer = await client.ask('everything');
  assert.equal(answer.files.length, MAX_ARTIFACTS_PER_ANSWER);
  assert.deepEqual(answer.files.map((file) => file.name).slice(0, 2), ['dashboard_0.png', 'dashboard_1.png']);
  // No more requests than images shown: each one travels through Looker.
  assert.equal(agent.callsTo('GET', '/apps/').length, MAX_ARTIFACTS_PER_ANSWER);
  assert.match(answer.text, new RegExp(`^_${2000 - MAX_ARTIFACTS_PER_ANSWER} more files from the agent were left out`));
});

test('a name that is not a file name is not asked for, and is quoted as text', async () => {
  const { agent, client } = setup();
  const names = [
    'dashboard_x/../../../../../../../_gateway/jobs/J', '../secret.png', 'a b.png', 'q?version=9',
    'x_](https://evil.example/a)_[y.png', '![x](https://evil.example/p.png)', `${'n'.repeat(500)}.png`,
  ];
  agent.reply = () => [{ actions: { artifactDelta: Object.fromEntries(names.map((name) => [name, 0])) } }];
  const answer = await client.ask('odd names');
  assert.deepEqual(answer.files, []);
  // Not one of them was put into a request.
  assert.deepEqual(agent.callsTo('GET', '/apps/'), []);
  // Each is named, as text that cannot act as markdown and not at full length.
  assert.ok(answer.text.includes('"x\\_\\](https://evil.example/a)\\_\\[y.png", but it could not be loaded'));
  assert.ok(answer.text.includes('"!\\[x\\](https://evil.example/p.png)", but it could not be loaded'));
  assert.ok(answer.text.includes(`"${'n'.repeat(120)}...", but it could not be loaded`));
  assert.doesNotMatch(answer.text, /n{121}/);
});

test('the image of a LookML dashboard is asked for under its own name', async () => {
  const { agent, client } = setup();
  agent.reply = (body) => {
    agent.saveArtifact(body.sessionId, 'dashboard_thelook::overview.png', { inlineData: { data: PNG_ADK_BASE64, mimeType: 'image/png' } });
    return [{ actions: { artifactDelta: { 'dashboard_thelook::overview.png': 3 } } }];
  };
  const answer = await client.ask('show the overview');
  assert.deepEqual(answer.files.map((file) => file.name), ['dashboard_thelook::overview.png']);
  assert.deepEqual(agent.callsTo('GET', '/apps/').map((call) => call.path), [
    `/apps/looker_app/users/looker-42/sessions/${client.sessionId}/artifacts/dashboard_thelook::overview.png?version=3`,
  ]);
});

test('a problem the model reports is passed on with what it did say', async () => {
  const { agent, client } = setup();
  agent.reply = () => [textEvent('Partial.'), { errorCode: 'X', errorMessage: 'Quota exceeded.' }];
  const answer = await client.ask('q');
  assert.equal(answer.text, 'Partial.\n\nThe agent reported a problem: Quota exceeded.');
});

test('a problem the model reports is quoted as text, briefly', async () => {
  const { agent, client } = setup();
  agent.reply = () => [{ errorCode: 'X', errorMessage: '[retry here](https://evil.example/retry)\n\n# Sign in again' }];
  let answer = await client.ask('q');
  assert.equal(answer.text, 'The agent reported a problem: \\[retry here\\](https://evil.example/retry) \\# Sign in again');
  agent.reply = () => [{ errorCode: 'X', errorMessage: 'E'.repeat(100_000) }];
  answer = await client.ask('q');
  assert.equal(answer.text, `The agent reported a problem: ${'E'.repeat(300)}...`);
});

test('a lost session is replaced, and the user is told', async () => {
  const { agent, client } = setup();
  await client.ask('first');
  const lost = client.sessionId;
  agent.sessions.clear(); // the agent was restarted without its memory

  const answer = await client.ask('second');
  assert.notEqual(client.sessionId, lost);
  assert.ok(agent.sessions.has(client.sessionId));
  assert.match(answer.text, /earlier conversation is no longer available/);
  assert.match(answer.text, /You said: second$/);
  // The question was sent again, not dropped, and to the new session.
  assert.deepEqual(agent.runs.map((run) => run.sessionId), [lost, lost, client.sessionId]);

  // No note the next time.
  const next = await client.ask('third');
  assert.equal(next.text, 'You said: third');
});

test('a conversation id that cannot go into a request path is not used', async () => {
  for (const id of ['../../x', 'a b', 'short', 's'.repeat(129), 'session-1?x=1', 'session-1/artifacts', 42, '', undefined]) {
    const { agent, client } = setup();
    const original = agent.agent.bind(agent);
    agent.agent = (path, body) => (path.endsWith('/sessions')
      ? { status: 'done', http_status: 200, json: { id, appName: 'looker_app', userId: 'looker-42' } }
      : original(path, body));
    // eslint-disable-next-line no-await-in-loop
    await assert.rejects(client.ask('question'), (error) => {
      assert.ok(error instanceof AgentError, `${error}`);
      assert.match(error.message, /gave it an id this extension cannot use/);
      return true;
    }, String(id));
    assert.equal(client.sessionId, null);
    assert.deepEqual(agent.callsTo('POST', '/_gateway/jobs/run'), []);
  }
  // What ADK makes, a UUID, is used.
  const { agent, client } = setup();
  const original = agent.agent.bind(agent);
  agent.agent = (path, body) => {
    if (path.endsWith('/sessions')) {
      agent.sessions.add('0b6f2a54-58f0-4c8e-9a46-0c1d2e3f4a5b');
      return { status: 'done', http_status: 200, json: { id: '0b6f2a54-58f0-4c8e-9a46-0c1d2e3f4a5b' } };
    }
    return original(path, body);
  };
  assert.equal((await client.ask('question')).text, 'You said: question');
  assert.equal(client.sessionId, '0b6f2a54-58f0-4c8e-9a46-0c1d2e3f4a5b');
});

test('a finished request without the agent\'s HTTP status is not taken for an answer', async () => {
  const { agent, client } = setup();
  const original = agent.agent.bind(agent);
  for (const status of [undefined, null, '200', 200.5, {}]) {
    agent.agent = (path, body) => (path === '/run'
      ? { status: 'done', http_status: status, json: [textEvent('accepted although the status is missing')] }
      : original(path, body));
    // eslint-disable-next-line no-await-in-loop
    await assert.rejects(client.ask('question'), (error) => {
      assert.ok(error instanceof AgentError, `${error}`);
      assert.match(error.message, /returned an answer this extension cannot read/);
      return true;
    }, String(status));
  }
});

test('what the far side says about a failure is quoted in one short line', async () => {
  const { agent, client } = setup();
  const original = agent.agent.bind(agent);
  const failing = (answer) => { agent.agent = (path, body) => (path === '/run' ? answer : original(path, body)); };
  const message = async () => {
    try {
      await client.ask('question');
    } catch (error) {
      assert.ok(error instanceof AgentError, `${error}`);
      return error.message;
    }
    throw new Error('the question should have failed');
  };

  // A detail that is an object, of any size.
  failing({ status: 'done', http_status: 500, json: { detail: { blob: 'A'.repeat(2_000_000) } } });
  assert.equal(await message(), `The agent could not answer (HTTP 500): {"blob":"${'A'.repeat(291)}...`);
  // A detail that is text, with line breaks.
  failing({ status: 'done', http_status: 500, json: { detail: 'first line\n\n# second line\r\n   third' } });
  assert.equal(await message(), 'The agent could not answer (HTTP 500): first line # second line third');
  failing({ status: 'done', http_status: 502, text: `<html>${'x'.repeat(5000)}</html>` });
  assert.equal(await message(), `The agent could not answer (HTTP 502): <html>${'x'.repeat(294)}...`);
  // The gateway's own reason for a request that never reached the agent.
  failing({ status: 'failed', error: `could not reach the agent ${'y'.repeat(5000)}` });
  assert.equal((await message()).length, 'The request did not reach the agent: '.length + 300 + '....'.length);
  failing({ status: 'failed', error: { not: 'text' } });
  assert.equal(await message(), 'The request did not reach the agent: [object Object].');
  failing({ status: 'failed' });
  assert.equal(await message(), 'The request did not reach the agent: unknown error.');
});

test('a slow answer is collected with polls, without spinning', async () => {
  const { agent, clock, client } = setup();
  await client.ask('warm up'); // creates the session
  agent.calls.length = 0;
  clock.sleeps.length = 0;
  agent.pollsBeforeDone = 4;

  const answer = await client.ask('slow question');
  assert.equal(answer.text, 'You said: slow question');
  const polls = agent.callsTo('GET', '/_gateway/jobs/');
  assert.equal(polls.length, 5);
  // Each poll asks the gateway to hold the answer for pollWaitSeconds.
  for (const poll of polls) assert.match(poll.path, /^\/_gateway\/jobs\/job-\d+\?wait=5$/);
  // The fake answers instantly, so the client paces itself between polls.
  assert.deepEqual(clock.sleeps, [1000, 1000, 1000, 1000]);
});

test('a question is given up after the turn timeout', async () => {
  const { agent, clock, client } = setup({ turnTimeoutSeconds: 30 });
  await client.ask('warm up');
  agent.pollsBeforeDone = Number.POSITIVE_INFINITY;
  const before = clock.time;
  await assert.rejects(client.ask('never finishes'), (error) => {
    assert.ok(error instanceof AgentError);
    assert.match(error.message, /taking too long/);
    return true;
  });
  assert.ok(clock.time - before >= 30_000);
  assert.ok(clock.time - before < 35_000);
});

test('polls that fail in transit are retried, up to a point', async () => {
  const { agent, client } = setup();
  await client.ask('warm up');
  agent.pollsBeforeDone = 1;

  let failuresLeft = 3;
  agent.intercept = (call) => {
    if (call.method === 'GET' && call.path.startsWith('/_gateway/jobs/') && failuresLeft > 0) {
      failuresLeft -= 1;
      if (failuresLeft === 1) return { ok: false, status: 504, body: 'Gateway Timeout' };
      throw new Error('socket hang up');
    }
    return undefined;
  };
  const answer = await client.ask('flaky network');
  assert.equal(answer.text, 'You said: flaky network');

  failuresLeft = 4;
  await assert.rejects(client.ask('network gone'), (error) => {
    assert.ok(error instanceof AgentError);
    assert.match(error.message, /socket hang up/);
    return true;
  });
});

test('failures are reported in words a person can act on', async (t) => {
  const cases = [
    {
      name: 'the gateway could not reach the agent',
      arrange: (agent) => {
        agent.agent = () => ({ status: 'failed', error: 'could not reach the agent through the Substrate router' });
      },
      message: /did not reach the agent: could not reach the agent through the Substrate router/,
    },
    {
      name: 'the gateway restarted and forgot the job',
      arrange: (agent) => {
        agent.intercept = (call) => (call.method === 'GET'
          ? { ok: false, status: 404, body: { error: 'unknown or expired job' } } : undefined);
      },
      message: /lost track of this request/,
    },
    {
      name: 'too many jobs',
      arrange: (agent) => {
        agent.intercept = () => ({ ok: false, status: 429, body: { error: 'too many' } });
      },
      message: /busy with other requests/,
    },
    {
      name: 'a gateway without the job API',
      arrange: (agent) => {
        agent.intercept = () => ({ ok: false, status: 404, body: { detail: 'Not Found' } });
      },
      message: /does not offer background jobs/,
    },
    {
      name: 'a wrong or missing credential',
      arrange: (agent) => {
        agent.intercept = () => ({ ok: false, status: 401, body: 'authentication required\n' });
      },
      message: /refused the request \(HTTP 401\)\. Check the user attribute\./,
    },
    {
      name: 'a credential refused while polling',
      arrange: (agent) => {
        agent.intercept = (call) => (call.method === 'GET'
          ? { ok: false, status: 401, body: 'authentication required\n' } : undefined);
      },
      message: /refused the request \(HTTP 401\)\. Check the user attribute\./,
    },
    {
      name: 'a request the gateway does not allow this credential',
      arrange: (agent) => {
        agent.intercept = () => ({
          ok: false, status: 403, body: { error: 'this credential is for the chat only' },
        });
      },
      // Not a matter of the user attribute, and the message must not say so.
      message: /^The request to the agent gateway was refused \(HTTP 403\): this credential is for the chat only$/,
    },
    {
      name: 'a proxy refusing a poll',
      arrange: (agent) => {
        agent.intercept = (call) => (call.method === 'GET'
          ? { ok: false, status: 403, body: 'Forbidden\n' } : undefined);
      },
      message: /^The request to the agent gateway was refused \(HTTP 403\): Forbidden$/,
    },
    {
      name: 'no token because the credential is wrong',
      arrange: (agent) => {
        agent.intercept = () => {
          const error = new Error('The agent gateway did not issue a token (HTTP 401).');
          error.status = 401;
          throw error;
        };
      },
      message: /^The agent gateway did not issue a token \(HTTP 401\)\. Check the user attribute\.$/,
    },
    {
      name: 'no token because a proxy refused',
      arrange: (agent) => {
        agent.intercept = () => {
          const error = new Error('The agent gateway did not issue a token (HTTP 403).');
          error.status = 403;
          throw error;
        };
      },
      message: /^The agent gateway did not issue a token \(HTTP 403\)\.$/,
    },
    {
      name: 'a proxy in front of the gateway failing',
      arrange: (agent) => {
        agent.intercept = () => ({ ok: false, status: 502, body: 'Bad Gateway' });
      },
      message: /^The agent gateway is not reachable right now \(HTTP 502\): Bad Gateway$/,
    },
    {
      name: 'the transport itself failing',
      arrange: (agent) => {
        agent.intercept = () => { throw new Error("Looker's server could not reach the agent gateway"); };
      },
      message: /Looker's server could not reach the agent gateway/,
    },
    {
      name: 'the agent failing on the question',
      arrange: (agent) => {
        const original = agent.agent.bind(agent);
        agent.agent = (path, body) => (path === '/run'
          ? { status: 'done', http_status: 500, json: { detail: 'model call failed' } }
          : original(path, body));
      },
      message: /^The agent could not answer \(HTTP 500\): model call failed$/,
    },
    {
      name: 'the agent refusing to start a session',
      arrange: (agent) => {
        agent.agent = () => ({ status: 'done', http_status: 500, text: 'Internal Server Error' });
      },
      message: /^The agent could not start a conversation \(HTTP 500\): Internal Server Error$/,
    },
    {
      name: 'an answer that is not a list of events',
      arrange: (agent) => {
        const original = agent.agent.bind(agent);
        agent.agent = (path, body) => (path === '/run'
          ? { status: 'done', http_status: 200, text: '<html>login</html>' } : original(path, body));
      },
      message: /cannot read/,
    },
  ];
  for (const { name, arrange, message } of cases) {
    // eslint-disable-next-line no-await-in-loop
    await t.test(name, async () => {
      const { agent, client } = setup();
      arrange(agent);
      await assert.rejects(client.ask('question'), (error) => {
        assert.ok(error instanceof AgentError, `${error}`);
        assert.match(error.message, message);
        return true;
      });
    });
  }
});
