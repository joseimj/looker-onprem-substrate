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

// What the extension knows about the ADK API server that serves the agent
// (agent/server.py): how to phrase a request, and how to read the answer.
//
// Everything here is a plain function with no browser, Looker or network
// dependency, so it can be tested with `node --test`.

const enc = encodeURIComponent;

// The gateway lets the chat's credential send only requests of a few exact
// shapes and refuses the rest (gateway/gateway.py). The limits below are the
// ones this file has to keep to. Checking them here as well means that a
// value taken from an answer never travels in a request path unless it has
// the expected form.
//
// One question, in characters.
export const MAX_QUESTION_CHARS = 16000;
// One to four parts separated by "/", none of them "." or "..".
const ARTIFACT_NAME_PART = /^[A-Za-z0-9_.:-]{1,128}$/;
// Looker's user ids are numbers.
const LOOKER_USER_ID = /^[0-9]{1,18}$/;

// What one answer may show. The agent renders a dashboard as one PNG of a few
// hundred kilobytes; an answer that names hundreds of files, or a file of
// another kind, did not come from the agent's tools.
export const MAX_ARTIFACTS_PER_ANSWER = 8;
export const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
// Kinds of image that are shown. `start` is the base64 text every file of
// that kind begins with (the PNG signature, the JPEG start-of-image marker).
const SHOWN_IMAGES = new Map([
  ['image/png', { start: 'iVBORw0K', named: /\.png$/i, ending: '.png' }],
  ['image/jpeg', { start: '/9j/', named: /\.jpe?g$/i, ending: '.jpg' }],
]);

// The ADK user id. Sessions and artifacts are stored per user id, so each
// Looker user gets their own conversations. It is NOT a security boundary:
// the browser sends it, and the gateway cannot check whose it is.
export function userIdFor(lookerUser) {
  const id = lookerUser && lookerUser.id;
  const text = id === undefined || id === null ? '' : String(id).trim();
  return LOOKER_USER_ID.test(text) ? `looker-${text}` : 'looker-unknown';
}

export function sessionsPath(appName, userId) {
  return `/apps/${enc(appName)}/users/${enc(userId)}/sessions`;
}

// Whether a name from an answer is the name of a file the chat may ask for.
// A name may hold "/" (ADK routes it as a path). LookML dashboards have ids
// like "thelook::overview", so ":" belongs to the allowed characters.
export function isArtifactName(name) {
  if (typeof name !== 'string') return false;
  const parts = name.split('/');
  return parts.length <= 4
    && parts.every((part) => ARTIFACT_NAME_PART.test(part) && part !== '.' && part !== '..');
}

export function artifactPath(appName, userId, sessionId, name, version) {
  if (!isArtifactName(name)) throw new TypeError('not the name of a file the chat may ask for');
  // The name goes into the path as it is. The gateway compares each part
  // with the same pattern, letter by letter, and "%3A" is not ":".
  const base = `${sessionsPath(appName, userId)}/${enc(sessionId)}/artifacts/${name}`;
  return Number.isInteger(version) && version >= 0 ? `${base}?version=${version}` : base;
}

// Body of POST /run. ADK accepts camelCase and snake_case field names.
export function runRequest({ appName, userId, sessionId, text }) {
  return {
    appName,
    userId,
    sessionId,
    newMessage: { role: 'user', parts: [{ text }] },
    streaming: false,
  };
}

// deep-chat hands its handler {messages: [{role, text}, ...]}. By default that
// is only the newest message; this also copes with a longer history.
export function lastUserText(body) {
  const messages = (body && Array.isArray(body.messages)) ? body.messages : [];
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const message = messages[i];
    if (message && (message.role === undefined || message.role === 'user')
        && typeof message.text === 'string' && message.text.trim() !== '') {
      return message.text.trim();
    }
  }
  return '';
}

// Reduces the events of one agent turn to what a chat shows:
//   text      - what the model said, tool chatter left out
//   artifacts - files the agent saved in this turn (the rendered images)
//   error     - a model or runtime error reported in the events, if any
export function summarizeEvents(events) {
  const texts = [];
  const versions = new Map();
  const errors = [];

  for (const event of Array.isArray(events) ? events : []) {
    if (!event || typeof event !== 'object') continue;

    // The tools save a rendered PNG as an artifact; ADK reports it here as
    // {filename: version}. Recorded even on partial events: it is a fact about
    // storage, not a draft of text.
    const delta = event.actions && event.actions.artifactDelta;
    if (delta && typeof delta === 'object') {
      for (const [name, version] of Object.entries(delta)) {
        versions.set(name, Number.isInteger(version) ? version : undefined);
      }
    }

    if (event.errorCode || event.errorMessage) {
      errors.push(event.errorMessage || `The agent reported error ${event.errorCode}.`);
    }

    // With streaming on, ADK sends drafts and then the complete text again.
    if (event.partial) continue;
    const content = event.content;
    const parts = content && Array.isArray(content.parts) ? content.parts : [];
    const fromUser = event.author === 'user' || (content && content.role === 'user');
    if (fromUser) continue;
    for (const part of parts) {
      // Skipped on purpose: the model's private reasoning (thought), and
      // functionCall / functionResponse parts, which are the tools at work.
      if (part && typeof part.text === 'string' && !part.thought && part.text.trim() !== '') {
        texts.push(part.text.trim());
      }
    }
  }

  return {
    text: texts.join('\n\n'),
    artifacts: Array.from(versions, ([name, version]) => ({ name, version })),
    error: errors.join('\n'),
  };
}

// ADK serializes bytes with pydantic's "base64" mode, which is the URL-safe
// alphabet ("-" and "_"). A data: URL needs the standard one ("+" and "/").
export function toStandardBase64(value) {
  const cleaned = String(value).replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/')
    .replace(/=+$/, '');
  return cleaned + '='.repeat((4 - (cleaned.length % 4)) % 4);
}

// Turns an artifact (a google.genai Part as JSON) into an image deep-chat can
// show: {file: {src, name, type: 'image'}}. Returns null for everything else.
//
// Only a PNG or a JPEG of a reasonable size is shown, and only when the data
// really starts like one. What the answer calls the file does not decide: the
// type written into the data: address is one of the two above, never a string
// taken from the answer, and the name the file would be saved under ends the
// way its kind does. deep-chat offers what it shows for saving, so a file of
// another kind under a name of the answer's choosing would be a download
// offered in the agent's name.
export function artifactToMessage(name, part) {
  if (!isArtifactName(name) || !part || typeof part !== 'object') return null;
  const blob = part.inlineData || part.inline_data;
  if (!blob || typeof blob.data !== 'string') return null;
  const declared = blob.mimeType || blob.mime_type;
  const mimeType = typeof declared === 'string' ? declared.split(';')[0].trim().toLowerCase() : '';
  const kind = SHOWN_IMAGES.get(mimeType);
  if (!kind) return null;
  // Four base64 characters stand for three bytes.
  if (blob.data.length > Math.ceil(MAX_IMAGE_BYTES / 3) * 4 + 4) return null;
  const data = toStandardBase64(blob.data);
  if (!data.startsWith(kind.start) || !/^[A-Za-z0-9+/]+={0,2}$/.test(data)) return null;
  const lastPart = name.split('/').pop();
  return {
    file: {
      src: `data:${mimeType};base64,${data}`,
      name: kind.named.test(lastPart) ? lastPart : lastPart + kind.ending,
      type: 'image',
    },
  };
}
