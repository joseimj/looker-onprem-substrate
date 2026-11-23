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

// Stand-ins for the pieces the extension talks to, for `node --test`.
// Nothing here is shipped in the bundle.

// A PNG signature followed by bytes chosen so that standard base64 contains
// "+" and "/", and the URL-safe form (what ADK sends) contains "-" and "_".
export const PNG_BYTES = Uint8Array.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0xfb, 0xff, 0xfe, 0x3e, 0x3f, 0xfa, 0x01,
]);
export const PNG_STANDARD_BASE64 = Buffer.from(PNG_BYTES).toString('base64');
// pydantic's "base64" mode: URL-safe alphabet, padding kept.
export const PNG_ADK_BASE64 = PNG_STANDARD_BASE64.replace(/\+/g, '-').replace(/\//g, '_');

export function textEvent(text, extra = {}) {
  return {
    author: 'looker_agent', content: { role: 'model', parts: [{ text }] }, ...extra,
  };
}

// The gateway and the ADK API server behind it, reduced to what the extension
// uses: background jobs, sessions, /run and artifacts. Reachable through
// transport(), which has the shape transport.js produces.
export class FakeAgent {
  constructor() {
    this.calls = [];
    this.sessions = new Set();
    this.jobs = new Map();
    this.artifacts = new Map();
    this.runs = [];
    // How many polls report "running" before a job reports its result.
    this.pollsBeforeDone = 0;
    // What the agent "says": (runRequestBody) -> list of ADK events.
    this.reply = (body) => [textEvent(`You said: ${body.newMessage.parts[0].text}`)];
    // Optional overrides: (call) -> response, or undefined to carry on.
    this.intercept = () => undefined;
    this.nextId = 1;
  }

  transport() {
    return {
      request: async (method, path, body) => {
        const call = { method, path, body };
        this.calls.push(call);
        // A client that never stops asking would hang the test run. Fail it.
        if (this.calls.length > 5000) throw new Error('runaway client: more than 5000 calls');
        const intercepted = await this.intercept(call);
        if (intercepted !== undefined) return intercepted;
        return this.handle(method, path, body);
      },
    };
  }

  callsTo(method, prefix) {
    return this.calls.filter((call) => call.method === method && call.path.startsWith(prefix));
  }

  saveArtifact(sessionId, name, part) {
    this.artifacts.set(`${sessionId}/${name}`, part);
  }

  handle(method, path, body) {
    const jobs = '/_gateway/jobs';
    if (method === 'POST' && path.startsWith(`${jobs}/`)) {
      const id = `job-${this.nextId}`;
      this.nextId += 1;
      this.jobs.set(id, { remaining: this.pollsBeforeDone, result: this.agent(path.slice(jobs.length), body) });
      return { ok: true, status: 202, body: { id, status: 'running' } };
    }
    if (method === 'GET' && path.startsWith(`${jobs}/`)) {
      const id = decodeURIComponent(path.slice(jobs.length + 1).split('?')[0]);
      const job = this.jobs.get(id);
      if (!job) return { ok: false, status: 404, body: { error: 'unknown or expired job' } };
      if (job.remaining > 0) {
        job.remaining -= 1;
        return { ok: true, status: 200, body: { id, status: 'running' } };
      }
      return { ok: true, status: 200, body: { id, ...job.result } };
    }
    const artifact = path.match(/^\/apps\/[^/]+\/users\/[^/]+\/sessions\/([^/]+)\/artifacts\/([^?]+)/);
    if (method === 'GET' && artifact) {
      const part = this.artifacts.get(`${decodeURIComponent(artifact[1])}/${decodeURIComponent(artifact[2])}`);
      if (!part) return { ok: false, status: 404, body: { detail: 'Artifact not found' } };
      return { ok: true, status: 200, body: part };
    }
    return { ok: false, status: 404, body: { detail: 'Not Found' } };
  }

  // The ADK API server. Returns what the gateway reports for a finished job.
  agent(path, body) {
    const done = (httpStatus, json) => ({ status: 'done', http_status: httpStatus, json });
    const sessions = path.match(/^\/apps\/([^/]+)\/users\/([^/]+)\/sessions$/);
    if (sessions) {
      const id = `session-${this.nextId}`;
      this.nextId += 1;
      this.sessions.add(id);
      return done(200, {
        id, appName: decodeURIComponent(sessions[1]), userId: decodeURIComponent(sessions[2]),
        state: {}, events: [],
      });
    }
    if (path === '/run') {
      this.runs.push(body);
      if (!this.sessions.has(body.sessionId)) {
        return done(404, { detail: `Session not found: ${body.sessionId}` });
      }
      return done(200, this.reply(body));
    }
    return done(404, { detail: 'Not Found' });
  }
}

// A link in the page, as far as the extension looks at one: its attributes
// and the first element inside it. `download` and `child` are optional.
export function anchor({ href, download, child } = {}) {
  const attributes = { href, download };
  return {
    tagName: 'A',
    getAttribute: (name) => (typeof attributes[name] === 'string' ? attributes[name] : null),
    firstElementChild: child || null,
  };
}

// A clock the tests move by hand. sleep() advances it instead of waiting.
export class FakeClock {
  constructor() {
    this.time = 1_000_000;
    this.sleeps = [];
    this.now = () => this.time;
    this.sleep = async (ms) => {
      this.sleeps.push(ms);
      this.time += ms;
    };
  }
}

// The slice of the Looker Extension SDK that transport.js uses.
export class FakeExtensionSdk {
  constructor() {
    this.serverCalls = [];
    this.fetchCalls = [];
    this.serverProxy = async (url, init, responseBodyType) => {
      this.serverCalls.push({ url, init, responseBodyType });
      return this.onServer(url, init);
    };
    this.fetchProxy = async (url, init, responseBodyType) => {
      this.fetchCalls.push({ url, init, responseBodyType });
      return this.onFetch(url, init);
    };
    this.onServer = () => ({ ok: true, status: 200, body: {} });
    this.onFetch = () => ({ ok: true, status: 200, body: {} });
  }

  // The real SDK returns a tag that Looker's server replaces with the secret.
  // eslint-disable-next-line class-methods-use-this
  createSecretKeyTag(name) {
    return `{{secret:${name}}}`;
  }
}
