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

// Settings of the chat extension.
//
// The defaults below match what deploy.sh installs when config.env is left at
// its defaults. The values that depend on a deployment (addresses, transport,
// names) come from deployment.js, which `./deploy.sh extension` writes from
// config.env, so that the bundle, the Looker manifest and the gateway agree.

import { deployment } from './deployment.js';

const defaults = {
  // "server"  - every call goes through Looker's server (serverProxy).
  // "browser" - Looker's server only fetches a short-lived token; the calls go
  //             from the user's browser (fetchProxy).
  transport: 'server',

  // Where Looker's SERVER reaches the agent gateway. With Looker in the same
  // cluster this is the gateway's in-cluster Service, in the gateway's own
  // namespace.
  serverGatewayUrl: 'http://looker-agent-gateway.looker-agent-gateway.svc.cluster.local',

  // Where BROWSERS reach the gateway. Only for transport "browser"; https only.
  browserGatewayUrl: '',

  // The ADK app, which is the folder name under agent/agents/.
  appName: 'looker_app',

  // Key of the gateway credential. Looker reads the value from the hidden
  // user attribute <project>_<application>_<key>; see README.md.
  secretKeyName: 'gateway_credential',
  // Only used in error messages, to name the thing to check.
  userAttributeName: 'looker_agent_chat_gateway_credential',

  // Seconds one poll may wait at the gateway for the agent to finish. Keep it
  // well under the timeout of every proxy on the way (and under 25).
  pollWaitSeconds: 5,
  // Seconds after which a question is given up.
  turnTimeoutSeconds: 600,
  // Milliseconds the Extension SDK waits for Looker to answer one message.
  chattyTimeoutMs: 120000,

  // Origins of other sites that a link in an answer may open, for example
  // ["https://docs.example.com"]. Empty: a link opens a dashboard, a Look or
  // an explore of this Looker, and nothing else (src/links.js). Looker must
  // allow the same sites, in new_window_external_urls of the manifest.
  allowedLinkOrigins: [],

  introMessage: 'Ask me about your Looker data. I can show a dashboard or a Look, '
    + 'chart a query, or answer with the numbers.',
  placeholder: 'Ask about your Looker data',
};

// Exported so that a test can look at the built-in values, whatever
// deployment.js holds.
export { defaults };

export const config = { ...defaults, ...deployment };
