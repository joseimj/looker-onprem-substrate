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

// What markdown in the chat may turn into.
//
// deep-chat shows every text it is given as markdown: answers, error
// messages, the greeting. It renders with the "remarkable" library, and
// deep-chat 2.5.1 switches remarkable's check of link addresses off, so that
// a link with any scheme, javascript: included, becomes a live link, and an
// image with any address is fetched as soon as it is shown. The text of an
// answer is written by the model from data anyone may have put into Looker,
// so neither can be left as it is.
//
// Two things are done about it here:
//
//   markdownPolicy()   A remarkable plugin that decides, at the moment a link
//                      or an image is turned into HTML, what it becomes. A
//                      link keeps an address only if links.js allows it. An
//                      image written in markdown is never loaded; its
//                      description is shown as text. Images the agent
//                      rendered do not come this way: they arrive as files.
//   markdownLiteral()  For text that is not markdown and must not act like
//                      it: a file name, an error detail, a person's name.
//
// How deep-chat picks the plugin up, read in its 2.5.1 source
// (views/chat/messages/remarkable/remarkableConfig.ts): every time it builds
// its renderer it applies the entries of window.remarkable_plugins, each as
// remarkable.use(entry.plugin, entry.options), and only then replaces the
// address check. A plugin that changes renderer rules therefore stays in
// effect. This depends on that version; package.json names it exactly, and
// test/markdown.test.js fails when the version is changed, as a reminder to
// read that file again.
//
// No browser dependency here: testable with `node --test`.

import { pageAddress, resolveLink } from './links.js';

export function escapeHtml(text) {
  return String(text)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// One line of at most `maxLength` characters: line breaks, control characters
// and characters that change the direction of text become spaces.
export function clipped(value, maxLength) {
  const text = String(value === undefined || value === null ? '' : value)
    .replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u2028-\u202e\u2066-\u2069]+/g, ' ')
    .replace(/ {2,}/g, ' ')
    .trim();
  return text.length > maxLength ? `${text.slice(0, maxLength)}...` : text;
}

// Text that markdown shows as it is written: no link, no image, no emphasis,
// no heading, whatever the text contains. Every character that starts a
// markdown construct gets a backslash, which remarkable takes as "this
// character itself". The text is cut to `maxLength` first.
export function markdownLiteral(value, maxLength = 300) {
  return clipped(value, maxLength)
    .replace(/[\\`*_[\]<>#|~&]/g, '\\$&')
    // At the start of a line these would begin a list.
    .replace(/^([-+]|[0-9]+(?=[.)]))/, (start) => (/[-+]/.test(start) ? `\\${start}` : `${start}\\`));
}

// The remarkable plugin. `lookerOrigin` and `allowedLinkOrigins` are what
// resolveLink() in links.js decides with.
export function markdownPolicy({ lookerOrigin, allowedLinkOrigins = [] } = {}) {
  return (remarkable) => {
    const { rules } = remarkable.renderer;

    // ![description](address): the address is never used.
    rules.image = (tokens, index) => {
      const description = clipped(tokens[index].alt, 200);
      return escapeHtml(description ? `[image: ${description}]` : '[image]');
    };

    // [text](address), <address> and [text][reference] all arrive here. The
    // address written into the page is one this function built: the plain
    // address of a page of this Looker, or of a page of a listed site. In
    // every other case the text stays and the link has no address, so there
    // is nothing to click, to open in a new tab or to copy.
    rules.link_open = (tokens, index) => {
      const link = resolveLink(tokens[index].href, lookerOrigin, { allowedOrigins: allowedLinkOrigins });
      let address = '';
      if (link.action === 'looker') address = pageAddress(lookerOrigin, link.target);
      else if (link.action === 'external') address = link.target;
      if (address === '') return '<a>';
      return `<a href="${escapeHtml(address)}" target="_blank" rel="noopener noreferrer">`;
    };
  };
}

// Puts the plugin where deep-chat looks for it. Call it before the chat
// element renders for the first time; chat.js does.
export function installMarkdownPolicy(globalObject, options) {
  const plugin = markdownPolicy(options);
  plugin.lookerAgentPolicy = true;
  const others = Array.isArray(globalObject.remarkable_plugins)
    ? globalObject.remarkable_plugins.filter((entry) => !(entry && entry.plugin && entry.plugin.lookerAgentPolicy))
    : [];
  // Last, so that no other plugin's rules replace these.
  // eslint-disable-next-line no-param-reassign
  globalObject.remarkable_plugins = [...others, { plugin }];
  return plugin;
}
