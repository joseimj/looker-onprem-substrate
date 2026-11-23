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

// Wires the chat component to the agent.
//
// The chat itself is deep-chat (https://deepchat.dev), an existing web
// component: message list, input box, markdown, inline images, loading and
// error states all come from it. This file only sets its properties and gives
// it a handler, so the kit has no chat UI code of its own to maintain.
//
// It is also the one place where text is handed to deep-chat, which shows
// every text as markdown. What is handed over is therefore decided here:
// answers lose every embed sign-in address (links.js), error messages are
// made literal text (markdown.js), and what a link or an image in an answer
// may become is fixed before the component renders (markdown.js).
//
// Nothing here needs a real browser: `chat` can be any object, which is how
// test/chat.test.js exercises it.

import { lastUserText, MAX_QUESTION_CHARS } from './adk.js';
import {
  clickedAnchor, hrefOf, isDownloadWrapper, resolveLink, withoutEmbedSignIns,
} from './links.js';
import { installMarkdownPolicy, markdownLiteral } from './markdown.js';

// A system font stack. deep-chat's default is "Inter", which it fetches from
// fonts.googleapis.com unless another family is set: a call an on-prem network
// may block and Looker's content security policy may refuse.
const FONT_FAMILY = 'system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif';

// An error message names what to check and quotes a little of what the far
// side said. Longer than this, it is no longer a message.
const MAX_ERROR_CHARS = 800;
const MAX_NAME_CHARS = 60;

// deep-chat calls this for every message the user sends:
//   body    = {messages: [{role: 'user', text: '...'}]}
//   signals = {onResponse(response)}; response is {text, files} or {error}
// `lookerOrigin` is the origin of the Looker page hosting the extension.
export function createHandler(client, { lookerOrigin } = {}) {
  // deep-chat renders an error text as markdown too. An error is a plain
  // sentence, with words from the gateway, the agent or Looker in it.
  const failure = (message) => ({
    error: markdownLiteral(withoutEmbedSignIns(message, lookerOrigin), MAX_ERROR_CHARS),
  });
  return (body, signals) => {
    const text = lastUserText(body);
    if (!text) {
      signals.onResponse({ error: 'Type a question first.' });
      return undefined;
    }
    if (text.length > MAX_QUESTION_CHARS) {
      signals.onResponse(failure(`That question is too long (${text.length} characters). `
        + `The agent takes at most ${MAX_QUESTION_CHARS}.`));
      return undefined;
    }
    return client.ask(text).then(
      (answer) => {
        const response = {};
        const shown = answer.text ? withoutEmbedSignIns(answer.text, lookerOrigin) : '';
        if (shown) response.text = shown;
        if (answer.files && answer.files.length > 0) response.files = answer.files;
        if (response.text === undefined && response.files === undefined) response.text = '';
        signals.onResponse(response);
      },
      (error) => {
        signals.onResponse(failure(error && error.message ? error.message : String(error)));
      },
    );
  };
}

// Decides what a click on a link does. Nothing is left to the browser except
// saving an image the chat itself shows: a sandboxed iframe cannot open a
// page, so Looker opens it (openLooker(path), openExternal(url)), and only
// the pages links.js allows.
//
// The same listener serves "click" and "auxclick". A click with the middle
// button never raises "click"; without this it would bypass the decision.
export function createLinkClickListener({
  lookerOrigin, allowedLinkOrigins = [], openLooker, openExternal,
}) {
  return (event) => {
    // "auxclick" is also raised for the right button, which opens a menu and
    // must not open a page.
    if (event.type === 'auxclick' && event.button !== 1) return;
    const anchor = clickedAnchor(event);
    if (anchor === null) return;
    if (isDownloadWrapper(anchor)) return;
    event.preventDefault();
    const link = resolveLink(hrefOf(anchor), lookerOrigin, { allowedOrigins: allowedLinkOrigins });
    if (link.action === 'looker') openLooker(link.target);
    else if (link.action === 'external') openExternal(link.target);
  };
}

// Sets up a <deep-chat> element. Property names are deep-chat's own API.
// `globalObject` is the page's window: deep-chat looks there for markdown
// plugins.
export function configureChat(chat, {
  client, config, displayName, lookerOrigin, openLooker, openExternal, globalObject = globalThis,
}) {
  const allowedLinkOrigins = Array.isArray(config.allowedLinkOrigins) ? config.allowedLinkOrigins : [];
  // First, before any property is set: deep-chat builds its markdown renderer
  // when it first renders, and it must find the policy by then.
  installMarkdownPolicy(globalObject, { lookerOrigin, allowedLinkOrigins });

  // Looker's extension loader uses a strict doctype, under which a percentage
  // height collapses; viewport units do not.
  Object.assign(chat.style, {
    display: 'block',
    width: '100vw',
    height: '100vh',
    border: 'none',
    borderRadius: '0',
    fontFamily: FONT_FAMILY,
  });

  chat.connect = { handler: createHandler(client, { lookerOrigin }) };
  // Show the handler's own error text. deep-chat's default is a generic
  // "Error, please try again.", which hides what an admin needs to see.
  chat.errorMessages = { displayServiceErrorMessages: true };
  chat.textInput = { placeholder: { text: config.placeholder }, characterLimit: MAX_QUESTION_CHARS };
  // The name comes from the person's Looker account and is shown as markdown
  // like everything else, so it is made literal text.
  const name = markdownLiteral(displayName, MAX_NAME_CHARS);
  const greeting = name ? `Hi ${name}. ` : '';
  chat.introMessage = { text: `${greeting}${config.introMessage}` };
  chat.messageStyles = {
    default: { shared: { bubble: { maxWidth: '85%' } } },
    // Rendered dashboards are wide: let them use the width of the pane.
    image: { shared: { bubble: { maxWidth: '95%' } } },
  };

  // In the capture phase, so that the decision is made before anything
  // inside the component could stop the event on its way up.
  const onLink = createLinkClickListener({
    lookerOrigin, allowedLinkOrigins, openLooker, openExternal,
  });
  chat.addEventListener('click', onLink, true);
  chat.addEventListener('auxclick', onLink, true);
  return chat;
}
