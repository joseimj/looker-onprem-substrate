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

// Deployment-specific settings. Empty here: the defaults in config.js apply.
//
// `./deploy.sh extension` builds from a copy of this folder in which this file
// is written from config.env. To build by hand instead, put your values here,
// for example:
//
//   export const deployment = {
//     transport: "server",
//     serverGatewayUrl: "http://looker-agent-gateway.looker-agent-gateway.svc.cluster.local",
//   };

export const deployment = {};
