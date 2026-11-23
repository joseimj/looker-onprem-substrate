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

// Entry point of the Looker extension. Looker loads the bundle built from this
// file into a sandboxed iframe (Extension Framework).
//
// It does three things:
//   1. connects to the Looker page that hosts it (Extension SDK),
//   2. asks Looker who the user is, so each user gets their own conversation,
//   3. puts one <deep-chat> element on the page and points it at the agent.
//
// The parts worth testing live in the other files of this folder and have no
// browser dependency. This file is the glue that only runs inside Looker.

import { connectExtensionHost, LookerExtensionSDK } from '@looker/extension-sdk';
// Registers the <deep-chat> custom element.
import 'deep-chat';

import { userIdFor } from './adk.js';
import { configureChat } from './chat.js';
import { AgentClient } from './client.js';
import { config } from './config.js';
import { createTransport } from './transport.js';

function documentReady() {
  if (document.readyState !== 'loading') return Promise.resolve();
  return new Promise((resolve) => {
    document.addEventListener('DOMContentLoaded', resolve, { once: true });
  });
}

function pageBody() {
  if (!document.body) {
    document.documentElement.appendChild(document.createElement('body'));
  }
  // Set through the style objects, not a <style> element: a content security
  // policy can refuse the element, it cannot refuse this.
  Object.assign(document.documentElement.style, { margin: '0', height: '100vh' });
  Object.assign(document.body.style, { margin: '0', height: '100vh', overflow: 'hidden' });
  return document.body;
}

function showProblem(error) {
  const box = document.createElement('div');
  Object.assign(box.style, {
    font: '14px system-ui, sans-serif', color: '#b3261e', padding: '24px', whiteSpace: 'pre-wrap',
  });
  box.textContent = `The Looker Agent chat could not start.\n\n${
    error && error.message ? error.message : String(error)}`;
  pageBody().appendChild(box);
}

async function start() {
  // chattyTimeout bounds how long the SDK waits for Looker to answer one
  // message; its default is 30 s. No call the chat makes should come near
  // that: a question is handed over at once and its answer is collected with
  // short polls. The one call that waits for the agent itself is the download
  // of a rendered image. The longer limit is room for a slow network.
  const extensionSdk = await connectExtensionHost({ chattyTimeout: config.chattyTimeoutMs });
  const coreSdk = LookerExtensionSDK.createClient(extensionSdk);
  const me = await coreSdk.me();
  const lookerUser = me && me.ok && me.value ? me.value : {};
  const hostData = extensionSdk.lookerHostData || {};

  const client = new AgentClient({
    transport: createTransport(extensionSdk, config),
    appName: config.appName,
    userId: userIdFor(lookerUser),
    credentialHint: `Ask a Looker admin to check the user attribute "${config.userAttributeName}" `
      + 'and its domain allowlist.',
    pollWaitSeconds: config.pollWaitSeconds,
    turnTimeoutSeconds: config.turnTimeoutSeconds,
  });

  await documentReady();
  // configureChat registers what markdown may become on `window`, where
  // deep-chat looks for it, in the same step that creates the element: the
  // component renders later, never before.
  const chat = configureChat(document.createElement('deep-chat'), {
    client,
    config,
    displayName: lookerUser.first_name || lookerUser.display_name || '',
    lookerOrigin: hostData.hostOrigin,
    globalObject: window,
    // Looker opens the window: a sandboxed iframe is not allowed to. Only
    // pages that src/links.js allows get this far.
    openLooker: (path) => extensionSdk.openBrowserWindow(path, '_blank'),
    openExternal: (url) => extensionSdk.openBrowserWindow(url, '_blank'),
  });
  pageBody().appendChild(chat);
}

start().catch(showProblem);
