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

// One conversation with the agent: keeps the ADK session, asks a question and
// collects the answer, including the images the agent rendered.
//
// Why "jobs": the agent can take a minute or more to answer, and the request
// travels through proxies (Looker's, possibly an ingress) that may cut a slow
// call and cannot stream. So a question is handed to the gateway as a job,
// which answers at once, and the result is collected with short polls. See
// gateway/gateway.py.

import {
  artifactPath, artifactToMessage, isArtifactName, MAX_ARTIFACTS_PER_ANSWER, runRequest,
  sessionsPath, summarizeEvents,
} from './adk.js';
import { clipped, markdownLiteral } from './markdown.js';

// An error whose message is meant to be read by the person in the chat.
export class AgentError extends Error {
  constructor(message) {
    super(message);
    this.name = 'AgentError';
  }
}

const SESSION_RESTARTED_NOTE = '_The earlier conversation is no longer available on the agent, '
  + 'so this answer starts a new one._';

// How many polls in a row may fail before the turn is given up.
const MAX_FAILED_POLLS = 3;

// What comes back from the far side is quoted in messages, never trusted:
// one line, and no more of it than a person needs to see what went wrong.
const MAX_DETAIL_CHARS = 300;
const MAX_NAME_CHARS = 120;

// The id ADK gives a conversation (a UUID). It becomes part of request paths.
const SESSION_ID = /^[A-Za-z0-9_-]{8,128}$/;

function detailOf(body) {
  let detail = '';
  if (body && typeof body === 'object') {
    const value = body.detail !== undefined ? body.detail : body.error;
    if (typeof value === 'string') detail = value;
    else if (value !== undefined) detail = JSON.stringify(value) || '';
  } else if (typeof body === 'string') {
    detail = body;
  }
  return clipped(detail, MAX_DETAIL_CHARS);
}

// "The agent could not answer (HTTP 500): model call failed"
function withDetail(message, body) {
  const detail = detailOf(body);
  return detail ? `${message}: ${detail}` : `${message}.`;
}

export class AgentClient {
  // transport: {request(method, path, body)}, see transport.js.
  // sleep and now are injectable for tests.
  constructor({
    transport, appName, userId, credentialHint = '',
    pollWaitSeconds = 5, turnTimeoutSeconds = 600, minPollIntervalMs = 1000,
    sleep = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); }),
    now = () => Date.now(),
  }) {
    this.transport = transport;
    this.appName = appName;
    this.userId = userId;
    this.credentialHint = credentialHint;
    this.pollWaitSeconds = pollWaitSeconds;
    this.turnTimeoutMs = turnTimeoutSeconds * 1000;
    this.minPollIntervalMs = minPollIntervalMs;
    this.sleep = sleep;
    this.now = now;
    this.sessionId = null;
    this.previous = Promise.resolve();
  }

  // Asks the agent and resolves to {text, files} for the chat.
  //
  // Questions are answered one at a time, in the order they were asked. A
  // conversation is one line of turns on the agent, and two questions that
  // start together would otherwise each start a conversation of their own.
  ask(text) {
    const turn = () => this.askNow(text);
    // Whether the question before succeeded or failed makes no difference.
    const answer = this.previous.then(turn, turn);
    this.previous = answer.catch(() => undefined);
    return answer;
  }

  async askNow(text) {
    const deadline = this.now() + this.turnTimeoutMs;
    const notes = [];
    await this.ensureSession(deadline);
    let result = await this.post('/run', this.runBody(text), deadline);
    if (result.status === 404) {
      // The agent no longer has this session: it was restarted or replaced.
      // (Suspending and resuming an actor keeps its sessions.)
      this.sessionId = null;
      await this.ensureSession(deadline);
      notes.push(SESSION_RESTARTED_NOTE);
      result = await this.post('/run', this.runBody(text), deadline);
    }
    if (result.status < 200 || result.status >= 300) {
      throw new AgentError(withDetail(`The agent could not answer (HTTP ${result.status})`, result.body));
    }
    if (!Array.isArray(result.body)) {
      throw new AgentError('The agent returned an answer this extension cannot read.');
    }

    const summary = summarizeEvents(result.body);
    const texts = [...notes];
    if (summary.text) texts.push(summary.text);
    const files = [];
    // The text of the answer is markdown, by design. A file name or an error
    // text quoted next to it is not, and is written so that it cannot act as
    // markdown (markdownLiteral).
    for (const artifact of summary.artifacts.slice(0, MAX_ARTIFACTS_PER_ANSWER)) {
      const quoted = markdownLiteral(artifact.name, MAX_NAME_CHARS);
      // One image that fails to load should not cost the whole answer.
      // eslint-disable-next-line no-await-in-loop
      const loaded = await this.loadArtifact(artifact).catch(() => ({ fetched: false }));
      if (loaded.file) files.push(loaded.file);
      else if (loaded.fetched) texts.push(`_The agent produced "${quoted}", which is not an image this chat shows._`);
      else texts.push(`_The agent produced "${quoted}", but it could not be loaded._`);
    }
    if (summary.artifacts.length > MAX_ARTIFACTS_PER_ANSWER) {
      texts.push(`_${summary.artifacts.length - MAX_ARTIFACTS_PER_ANSWER} more files from the agent `
        + 'were left out: one answer shows at most '
        + `${MAX_ARTIFACTS_PER_ANSWER}._`);
    }
    if (summary.error) {
      texts.push(`The agent reported a problem: ${markdownLiteral(summary.error, MAX_DETAIL_CHARS)}`);
    }
    if (texts.length === 0 && files.length === 0) {
      texts.push('_The agent finished without an answer. Try rephrasing the question._');
    }
    return { text: texts.join('\n\n'), files };
  }

  runBody(text) {
    return runRequest({
      appName: this.appName, userId: this.userId, sessionId: this.sessionId, text,
    });
  }

  async ensureSession(deadline) {
    if (this.sessionId) return;
    const result = await this.post(sessionsPath(this.appName, this.userId), {}, deadline);
    const id = result.body && result.body.id;
    if (result.status < 200 || result.status >= 300) {
      throw new AgentError(withDetail(
        `The agent could not start a conversation (HTTP ${result.status})`, result.body,
      ));
    }
    if (typeof id !== 'string' || !SESSION_ID.test(id)) {
      throw new AgentError('The agent started a conversation, but gave it an id this extension cannot use.');
    }
    this.sessionId = id;
  }

  // Resolves to {fetched, file}: whether the gateway handed the file over,
  // and the image to show if it is one (see artifactToMessage in adk.js).
  async loadArtifact({ name, version }) {
    // A name that is not a file name is not put into a request at all.
    if (!isArtifactName(name)) return { fetched: false };
    const path = artifactPath(this.appName, this.userId, this.sessionId, name, version);
    const response = await this.transport.request('GET', path);
    if (!response.ok) return { fetched: false };
    const shown = artifactToMessage(name, response.body);
    return { fetched: true, file: shown ? shown.file : undefined };
  }

  // POSTs to the agent as a gateway job and waits for it.
  // Resolves to {status, body}: the agent's own HTTP status and body.
  async post(path, body, deadline) {
    const started = await this.send('POST', `/_gateway/jobs${path}`, body);
    if (started.status === 429) {
      throw new AgentError('The agent is busy with other requests. Please try again in a moment.');
    }
    if (started.status === 404 || started.status === 405) {
      throw new AgentError('The agent gateway does not offer background jobs. '
        + 'Deploy the gateway from this kit again (./deploy.sh gateway).');
    }
    const jobId = started.body && started.body.id;
    if (started.status !== 202 || typeof jobId !== 'string') {
      throw new AgentError(withDetail(
        `The agent gateway did not accept the request (HTTP ${started.status})`, started.body,
      ));
    }

    const pollPath = `/_gateway/jobs/${encodeURIComponent(jobId)}?wait=${this.pollWaitSeconds}`;
    let failures = 0;
    for (;;) {
      const pollStarted = this.now();
      let response = null;
      let failure = null;
      try {
        // eslint-disable-next-line no-await-in-loop
        response = await this.transport.request('GET', pollPath);
      } catch (error) {
        failure = this.explain(error);
      }

      let job = null;
      if (response) {
        if (response.status === 404) {
          throw new AgentError('The agent gateway lost track of this request (it may have restarted). '
            + 'Please ask again.');
        }
        if (response.status === 401 || response.status === 403) throw this.refusal(response);
        if (response.ok && response.body && typeof response.body.status === 'string') {
          job = response.body;
        } else {
          failure = new AgentError(
            `The agent gateway stopped answering while the agent was working (HTTP ${response.status}).`,
          );
        }
      }

      if (job === null) {
        // A poll that fails says nothing about the job, which is still
        // running on the gateway. Try a few more times before giving up.
        failures += 1;
        if (failures > MAX_FAILED_POLLS) throw failure;
      } else {
        failures = 0;
        if (job.status === 'done') {
          // Without the agent's HTTP status nothing says whether this is an
          // answer or an error page; it is not taken for an answer.
          if (!Number.isInteger(job.http_status)) {
            throw new AgentError('The agent gateway returned an answer this extension cannot read.');
          }
          return { status: job.http_status, body: job.json !== undefined ? job.json : job.text };
        }
        if (job.status === 'failed') {
          const reason = clipped(job.error, MAX_DETAIL_CHARS) || 'unknown error';
          throw new AgentError(`The request did not reach the agent: ${reason}.`);
        }
      }

      if (this.now() >= deadline) {
        throw new AgentError('The agent is taking too long to answer. Please try again, '
          + 'or ask for something smaller.');
      }
      // The gateway holds a poll open until the job ends or the wait is up.
      // If it answered sooner than that, do not spin.
      const elapsed = this.now() - pollStarted;
      if (elapsed < this.minPollIntervalMs) {
        await this.sleep(this.minPollIntervalMs - elapsed); // eslint-disable-line no-await-in-loop
      }
    }
  }

  // One call through the transport, with errors people can act on.
  async send(method, path, body) {
    let response;
    try {
      response = await this.transport.request(method, path, body);
    } catch (error) {
      throw this.explain(error);
    }
    if (response.status === 401 || response.status === 403) throw this.refusal(response);
    if (response.status === 502 || response.status === 503 || response.status === 504) {
      throw new AgentError(withDetail(
        `The agent gateway is not reachable right now (HTTP ${response.status})`, response.body,
      ));
    }
    return response;
  }

  // 401: the credential was not accepted, so the place to look is where the
  // credential is kept. 403: the caller was recognised and the request was
  // refused, by the gateway or by something in front of it. The credential is
  // then not the thing to check, and saying so would send people the wrong way.
  refusal(response) {
    if (response.status === 401) {
      return new AgentError(
        `The agent gateway refused the request (HTTP 401). ${this.credentialHint}`.trim(),
      );
    }
    return new AgentError(withDetail(
      'The request to the agent gateway was refused (HTTP 403)', response.body,
    ));
  }

  explain(error) {
    if (error instanceof AgentError) return error;
    if (error && error.status === 401) {
      return new AgentError(`${error.message} ${this.credentialHint}`.trim());
    }
    return new AgentError(error && error.message ? error.message : String(error));
  }
}
