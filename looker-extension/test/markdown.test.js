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
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import {
  clipped, escapeHtml, installMarkdownPolicy, markdownLiteral, markdownPolicy,
} from '../src/markdown.js';

const LOOKER = 'https://looker.example.com';
const SIGNED = `${LOOKER}/login/embed/${encodeURIComponent('/embed/dashboards/12?Country=Brazil')}`
  + '?nonce=%22abc%22&time=1700000000&force_logout_login=true&signature=c2lnbmF0dXJl';

// Stand-ins for the two pieces of other people's code the policy meets. They
// are written from the sources (remarkable 2.0.1: lib/rules.js, lib/index.js;
// deep-chat 2.5.1: views/chat/messages/remarkable/remarkableConfig.ts), not
// copied, and are not those libraries: neither runs here.

// remarkable turns each token into HTML with rules[token.type](tokens, index,
// options). These are its rules for a link and for an image, in short.
function remarkableRules() {
  return {
    link_open: (tokens, index, options) => {
      const target = options.linkTarget ? ` target="${options.linkTarget}"` : '';
      return `<a href="${escapeHtml(tokens[index].href)}"${target}>`;
    },
    image: (tokens, index) => `<img src="${escapeHtml(tokens[index].src)}" alt="${escapeHtml(tokens[index].alt || '')}">`,
  };
}

// What deep-chat does each time it builds its renderer: apply the plugins it
// finds on `window`, each with remarkable.use(), then replace remarkable's
// check of link addresses by one that accepts everything.
function rendererAsDeepChatBuildsIt(windowObject) {
  const remarkable = {
    options: { breaks: true, linkTarget: '_blank' },
    inline: { validateLink: (address) => !/^\s*(javascript|vbscript|file|data):/i.test(address) },
    renderer: { rules: remarkableRules() },
    use(plugin, options) { plugin(this, options); return this; },
  };
  const plugins = windowObject.remarkable_plugins;
  if (plugins) plugins.forEach((entry) => remarkable.use(entry.plugin, entry.options));
  remarkable.inline.validateLink = () => true;
  return remarkable;
}

function html(remarkable, token) {
  return remarkable.renderer.rules[token.type]([token], 0, remarkable.options, {}, remarkable.renderer);
}

function withPolicy(options = { lookerOrigin: LOOKER }) {
  const windowObject = {};
  installMarkdownPolicy(windowObject, options);
  return rendererAsDeepChatBuildsIt(windowObject);
}

const link = (href) => ({ type: 'link_open', href, title: 'Looker sign-in' });
const image = (src, alt) => ({ type: 'image', src, alt, title: '' });

test('without the policy, any link and any image become live', () => {
  // This is the starting point the policy exists for. If these stand-ins did
  // not behave like that, the tests below would prove nothing.
  const plain = rendererAsDeepChatBuildsIt({});
  assert.equal(plain.inline.validateLink('javascript:alert(1)'), true);
  assert.equal(html(plain, link('javascript:alert(1)')), '<a href="javascript:alert(1)" target="_blank">');
  assert.equal(html(plain, image('https://evil.example/p.png?d=42', 'chart')),
    '<img src="https://evil.example/p.png?d=42" alt="chart">');
});

test('an image written in markdown is never loaded', () => {
  const remarkable = withPolicy();
  for (const src of ['https://evil.example/p.png?d=revenue%3D42', 'data:image/png;base64,iVBORw0KGgo=',
    `${LOOKER}/dashboards/12`, '//evil.example/p.png', 'javascript:alert(1)', '']) {
    const out = html(remarkable, image(src, 'Sales by region'));
    assert.equal(out, '[image: Sales by region]', src);
  }
  // The description is text: it cannot bring an element with it.
  assert.equal(html(remarkable, image('x', '"><img src=x onerror=alert(1)>')),
    '[image: &quot;&gt;&lt;img src=x onerror=alert(1)&gt;]');
  assert.equal(html(remarkable, image('x', '')), '[image]');
  assert.equal(html(remarkable, image('x', undefined)), '[image]');
  assert.equal(html(remarkable, image('x', 'a'.repeat(500))).length, '[image: ...]'.length + 200);
});

test('a link keeps an address only when it opens a dashboard, a Look or an explore of this Looker', () => {
  const remarkable = withPolicy();
  const kept = '<a href="https://looker.example.com/dashboards/12?Country=Brazil" target="_blank" rel="noopener noreferrer">';
  assert.equal(html(remarkable, link(`${LOOKER}/dashboards/12?Country=Brazil`)), kept);
  assert.equal(html(remarkable, link('/embed/dashboards/12?Country=Brazil')), kept);
  // A signed embed link turns into the plain page: its signature is not in the page.
  assert.equal(html(remarkable, link(SIGNED)), kept);
  assert.equal(html(remarkable, link(`${LOOKER}/explore/thelook/orders?f[orders.status]=(none)`)),
    '<a href="https://looker.example.com/explore/thelook/orders?f%5Borders.status%5D=%28none%29" target="_blank" rel="noopener noreferrer">');

  // Everything else stays as text with nothing to click, open or copy.
  for (const href of ['javascript:alert(1)', 'JAVASCRIPT:alert(1)', 'data:text/html,<script>alert(1)</script>',
    'vbscript:x', 'https://evil.example/login', `${LOOKER}//evil.example/login`, `${LOOKER}/logout`, '/admin/users',
    SIGNED.replace('/login/embed/', '/login//embed/'), SIGNED.replace('looker.example.com', 'other.example.com'),
    `${LOOKER}/login/embed/${encodeURIComponent(SIGNED.slice(LOOKER.length))}`, '#fn1', '', undefined]) {
    assert.equal(html(remarkable, link(href)), '<a>', String(href));
  }
  // A title is the model's text shown as a tooltip: it is not carried over.
  assert.doesNotMatch(html(remarkable, link(`${LOOKER}/looks/5`)), /title|Looker sign-in/);
});

test('a listed site keeps its address, and only that site', () => {
  const remarkable = withPolicy({ lookerOrigin: LOOKER, allowedLinkOrigins: ['https://docs.example.com'] });
  assert.equal(html(remarkable, link('https://docs.example.com/a?b=c&d="e"')),
    '<a href="https://docs.example.com/a?b=c&amp;d=%22e%22" target="_blank" rel="noopener noreferrer">');
  assert.equal(html(remarkable, link('https://docs.example.com.evil.example/a')), '<a>');
  assert.equal(html(remarkable, link(`${LOOKER}/looks/5`)),
    '<a href="https://looker.example.com/looks/5" target="_blank" rel="noopener noreferrer">');
});

test('without knowing where Looker lives, no link gets an address', () => {
  const remarkable = withPolicy({ lookerOrigin: undefined });
  for (const href of [SIGNED, '/dashboards/12', `${LOOKER}/dashboards/12`, 'https://evil.example/']) {
    assert.equal(html(remarkable, link(href)), '<a>', href);
  }
  // The plugin can be built without any setting at all.
  const bare = { renderer: { rules: remarkableRules() } };
  markdownPolicy()(bare);
  assert.equal(bare.renderer.rules.link_open([link('/dashboards/12')], 0, {}), '<a>');
});

test('the policy is put where deep-chat looks for it: last, and once', () => {
  const other = { plugin: () => {}, options: { a: 1 } };
  const windowObject = { remarkable_plugins: [other] };
  const first = installMarkdownPolicy(windowObject, { lookerOrigin: LOOKER });
  assert.equal(windowObject.remarkable_plugins.length, 2);
  assert.equal(windowObject.remarkable_plugins[0], other);
  assert.equal(windowObject.remarkable_plugins[1].plugin, first);
  // Installing it again, with other settings, replaces it.
  const second = installMarkdownPolicy(windowObject, { lookerOrigin: 'https://other.example.com' });
  assert.deepEqual(windowObject.remarkable_plugins.map((entry) => entry.plugin), [other.plugin, second]);
  // Something that is not a list is replaced by one.
  const odd = { remarkable_plugins: 'nonsense' };
  installMarkdownPolicy(odd, { lookerOrigin: LOOKER });
  assert.equal(odd.remarkable_plugins.length, 1);
  // A plugin that came first cannot undo it: the policy's rules are set last.
  const undoing = { remarkable_plugins: [{ plugin: (remarkable) => { remarkable.renderer.rules.image = () => '<img src="x">'; } }] };
  installMarkdownPolicy(undoing, { lookerOrigin: LOOKER });
  assert.equal(html(rendererAsDeepChatBuildsIt(undoing), image('https://evil.example/p.png', 'x')), '[image: x]');
});

test('the policy was written against deep-chat 2.5.1', () => {
  // How the plugin is picked up was read in that version's source. Before
  // changing the version, read views/chat/messages/remarkable/remarkableConfig.ts
  // of the new one: it must still apply window.remarkable_plugins to every
  // renderer it builds. Then change the number here.
  const manifest = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(manifest.dependencies['deep-chat'], '2.5.1');
});

test('every package the bundle is built from is named by one exact version', () => {
  // A range ("^5.89.0") lets a later build take another version than the one
  // that was read and tried. Without a lock file this is the only pin there is.
  const manifest = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  const named = { ...manifest.dependencies, ...manifest.devDependencies };
  assert.deepEqual(Object.keys(named).sort(), ['@looker/extension-sdk', 'deep-chat', 'webpack', 'webpack-cli']);
  for (const [name, version] of Object.entries(named)) {
    assert.match(version, /^[0-9]+\.[0-9]+\.[0-9]+$/, name);
  }
});

// What remarkable does with a backslash: before one of these characters it
// stands for the character itself (lib/rules_inline/escape.js).
const ESCAPABLE = /\\([\\!"#$%&'()*+,./:;<=>?@[\]^_`{|}~-])/g;
// Characters that start a markdown construct inside a line.
const ACTIVE = /[\\`*_[\]<>#|~&]/;

test('literal text cannot act as markdown', () => {
  const samples = [
    '[click to sign in again](https://evil.example/login)',
    '![x](https://evil.example/p.png?d=1)',
    '<https://evil.example/> and <img src=x onerror=alert(1)>',
    '**bold** _emphasis_ `code` ~~gone~~',
    '# heading', '> quote', '| a | b |', '&#106;avascript&colon;alert(1)', 'back\\slash \\[x\\]',
    '[1]: https://evil.example "ref"', 'x_](https://evil.example/a)_[y.png', '*[HTML]: abbreviation', '[^1]: footnote',
    'plain words, with (brackets) and a full stop.',
  ];
  for (const sample of samples) {
    const literal = markdownLiteral(sample, 300);
    // Once the escapes remarkable honours are taken away, nothing active is left...
    assert.doesNotMatch(literal.replace(ESCAPABLE, ''), ACTIVE, sample);
    // ...and what remarkable shows is the text as it was.
    assert.equal(literal.replace(ESCAPABLE, '$1'), sample, sample);
  }
  assert.equal(markdownLiteral('[x](https://evil.example)'), '\\[x\\](https://evil.example)');
  // Text without such characters is not touched: messages stay readable.
  assert.equal(markdownLiteral('The agent could not answer (HTTP 500): model call failed.'),
    'The agent could not answer (HTTP 500): model call failed.');
});

test('literal text is one line that does not start a list', () => {
  assert.equal(markdownLiteral('- item'), '\\- item');
  assert.equal(markdownLiteral('+ item'), '\\+ item');
  assert.equal(markdownLiteral('12. item'), '12\\. item');
  assert.equal(markdownLiteral('3) item'), '3\\) item');
  assert.equal(markdownLiteral('---'), '\\---');
  assert.equal(markdownLiteral('2024 was a good year'), '2024 was a good year');
  // Line breaks would allow headings, tables and code blocks further down.
  assert.equal(markdownLiteral('first\n\n# second\r\n    third\tfourth'), 'first \\# second third fourth');
  assert.equal(markdownLiteral('   padded   '), 'padded');
  for (const nothing of [undefined, null, '', '   ', '\n']) assert.equal(markdownLiteral(nothing), '');
  assert.equal(markdownLiteral(42), '42');
});

test('quoted text is cut to a length', () => {
  assert.equal(clipped('a'.repeat(500), 300), `${'a'.repeat(300)}...`);
  assert.equal(clipped('short', 300), 'short');
  assert.equal(markdownLiteral('*'.repeat(500), 10), `${'\\*'.repeat(10)}...`);
  assert.equal(markdownLiteral('a'.repeat(500)).length, 303);
  // Characters that turn the direction of text around are taken out: they
  // can make a line read differently from what it holds.
  assert.equal(clipped('abc\u202Etxt.exe\u2066 \u200Fz', 50), 'abc txt.exe z');
  assert.equal(clipped('a\u0000b\u001Fc\u007Fd\u0085e\u2028f', 50), 'a b c d e f');
});

test('HTML is escaped for text and for attribute values alike', () => {
  assert.equal(escapeHtml('<a href="x" title=\'y\'>&</a>'), '&lt;a href=&quot;x&quot; title=&#39;y&#39;&gt;&amp;&lt;/a&gt;');
  assert.equal(escapeHtml(42), '42');
});
