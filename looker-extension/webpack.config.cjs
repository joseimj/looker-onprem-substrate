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

// Builds the extension into ONE file, dist/bundle.js. A Looker extension is a
// single JavaScript file kept in a LookML project, so everything it needs
// (the Looker Extension SDK and the deep-chat component) is bundled in.
//
// Modelled on Looker's own "vanilla-javascript" extension template
// (github.com/looker-open-source/create-looker-extension). Babel is left out:
// the sources use only syntax current browsers run as it is.

const path = require('path');

module.exports = {
  entry: path.join(__dirname, 'src/index.js'),
  output: {
    path: path.join(__dirname, 'dist'),
    filename: 'bundle.js',
  },
  resolve: {
    extensions: ['.js'],
    // As in Looker's template: the Looker SDK mentions Node's "buffer", which
    // a browser bundle neither has nor needs.
    fallback: { buffer: false },
  },
  // One file by design: a size hint is of no use here.
  performance: { hints: false },
};
