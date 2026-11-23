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
import { test } from 'node:test';

import {
  clickedAnchor, clickedHref, isDownloadWrapper, mentionsEmbedSignIn, pageAddress, resolveLink,
  withoutEmbedSignIns,
} from '../src/links.js';
import { anchor } from './fakes.js';

const LOOKER = 'https://looker.example.com';
const BLOCK = { action: 'block' };
const QUERY = '?permissions=%5B%22access_data%22%5D&models=%5B%22thelook%22%5D'
  + '&force_logout_login=true&nonce=%22abc%22&time=1700000000&signature=c2lnbmF0dXJl';

// Shaped like what Looker's create_sso_embed_url returns: the page travels
// URL-encoded in the path, the signature in the query. Looker encodes
// brackets and quotes too, which encodeURIComponent leaves alone.
function signed(target, origin = LOOKER) {
  const encoded = encodeURIComponent(target).replace(
    /[!'()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
  );
  return `${origin}/login/embed/${encoded}${QUERY}`;
}

// What a link may open, whatever was asked: a dashboard, a Look or an explore.
const PAGE = /^\/(dashboards|looks|explore)\/[A-Za-z0-9_:.~-]+(\/[A-Za-z0-9_:.~-]+)*([?#]|$)/;

test('a signed embed link resolves to the plain Looker page, as the reader', () => {
  assert.deepEqual(resolveLink(signed('/embed/dashboards/12'), LOOKER), {
    action: 'looker', target: '/dashboards/12',
  });
  assert.deepEqual(resolveLink(signed('/embed/looks/5'), LOOKER), { action: 'looker', target: '/looks/5' });
  assert.deepEqual(resolveLink(signed('/embed/explore/thelook/order_items'), LOOKER), {
    action: 'looker', target: '/explore/thelook/order_items',
  });
  // A LookML dashboard is named "<model>::<dashboard>".
  assert.deepEqual(resolveLink(signed('/embed/dashboards/thelook::overview'), LOOKER), {
    action: 'looker', target: '/dashboards/thelook::overview',
  });
  // Dashboard filters the agent added survive.
  assert.deepEqual(
    resolveLink(signed('/embed/dashboards/12?Country=Brazil&Created+Date=30+days'), LOOKER),
    { action: 'looker', target: '/dashboards/12?Country=Brazil&Created+Date=30+days' },
  );
  // Nothing of the signature is carried over: the reader's own session is used.
  const { target } = resolveLink(signed('/embed/dashboards/12'), LOOKER);
  assert.doesNotMatch(target, /signature|force_logout_login|login\/embed/);
});

test('a signed embed link for this host on another port or scheme is the same Looker', () => {
  // The browser keeps cookies per host name. Such a link would replace the
  // reader's session just the same, so it is treated the same.
  for (const origin of ['https://looker.example.com:9999', 'http://looker.example.com',
    'https://LOOKER.example.com:8443']) {
    assert.deepEqual(resolveLink(signed('/embed/dashboards/12?Country=Brazil', origin), LOOKER), {
      action: 'looker', target: '/dashboards/12?Country=Brazil',
    }, origin);
  }
  // The other way round: Looker opened on a port, links written without it.
  assert.deepEqual(resolveLink(signed('/embed/looks/5'), 'https://looker.example.com:9999'), {
    action: 'looker', target: '/looks/5',
  });
  // Another host is another site, whatever the port and however alike the
  // name. Its signed link is not opened at all.
  for (const origin of ['https://other-looker.example.com:9999', 'https://looker.example.com.evil.example',
    'https://example.com', 'https://xlooker.example.com', 'https://looker.example.com.',
    'https://looker.example.com@evil.example']) {
    assert.deepEqual(resolveLink(signed('/embed/looks/5', origin), LOOKER), BLOCK, origin);
  }
  // Links that are not signed do nothing to the session: for them the whole
  // origin counts, and a page on another port is another site.
  assert.deepEqual(resolveLink('https://looker.example.com:9999/looks/5', LOOKER), BLOCK);
  assert.deepEqual(resolveLink('http://looker.example.com/looks/5', LOOKER), BLOCK);
});

test('a signed embed link is never opened as it is, in any spelling', () => {
  const real = signed('/embed/dashboards/12');
  const inside = `/login/embed/${encodeURIComponent('/embed/dashboards/12')}${QUERY}`;
  const attempts = [
    // What it points at is not a page a link may open.
    signed('/dashboards/12/../../logout'), signed('/embed/admin/users'), signed('/logout'), signed(''),
    signed('//evil.example.com/x'), signed('https://evil.example.com/x'), signed('\\\\evil.example.com\\x'),
    signed('/embed//evil.example.com/x'), signed('javascript:alert(1)'),
    // A signed link carried inside a signed link.
    `${LOOKER}/login/embed/${encodeURIComponent(inside)}?x=1`,
    // The sign-in path written so that a server or a proxy in front of it may
    // still take it for the real one.
    real.replace('/login/embed/', '/login//embed/'), real.replace('/login/embed/', '/Login/Embed/'),
    real.replace('/login/embed/', '/login/embed%2F'), real.replace('/login/embed/', '/login/embed;x/'),
    real.replace('/login/embed/', '/%6cogin/embed/'), real.replace('/login/embed/', '/login/%65mbed/'),
    real.replace(LOOKER, `${LOOKER}/`), real.replace(`${LOOKER}/`, `${LOOKER}/\\`),
    // Carried in the filters of an honest page.
    `${LOOKER}/dashboards/12?next=${encodeURIComponent(real)}`,
    `${LOOKER}/dashboards/12?next=${encodeURIComponent(encodeURIComponent(real))}`,
    `${LOOKER}/dashboards/12#${real}`,
    // Not a page of this Looker at all.
    `${LOOKER}/login/embed/%E0%A4%A`,
  ];
  for (const href of attempts) {
    const result = resolveLink(href, LOOKER, { allowedOrigins: [LOOKER, 'https://evil.example.com'] });
    assert.deepEqual(result, BLOCK, href);
  }
  // Whatever the result, it never holds a signature.
  for (const href of [real, ...attempts]) {
    const result = resolveLink(href, LOOKER);
    assert.doesNotMatch(JSON.stringify(result), /signature|login\/embed/i, href);
    if (result.action === 'looker') assert.match(result.target, PAGE, href);
  }
  // The honest form, with a full address inside, still works. So does one
  // that a browser reads as the very same address.
  assert.deepEqual(resolveLink(signed('https://looker.example.com/embed/looks/5'), LOOKER), {
    action: 'looker', target: '/looks/5',
  });
  assert.deepEqual(resolveLink(real.replace('/login/embed/', '/login/./embed/'), LOOKER), {
    action: 'looker', target: '/dashboards/12',
  });
});

test('of this Looker, only dashboards, Looks and explores are opened', () => {
  assert.deepEqual(resolveLink(`${LOOKER}/dashboards/12?Country=Brazil#tile`, LOOKER), {
    action: 'looker', target: '/dashboards/12?Country=Brazil#tile',
  });
  assert.deepEqual(resolveLink(`${LOOKER}/embed/dashboards/12`, LOOKER), {
    action: 'looker', target: '/dashboards/12',
  });
  assert.deepEqual(resolveLink('/looks/5', LOOKER), { action: 'looker', target: '/looks/5' });
  assert.deepEqual(resolveLink('/explore/thelook/order_items?fields=orders.count&f[orders.status]=complete', LOOKER), {
    action: 'looker', target: '/explore/thelook/order_items?fields=orders.count&f[orders.status]=complete',
  });
  // Same host, default port written out: still this Looker.
  assert.deepEqual(resolveLink('https://LOOKER.example.com:443/looks/5', LOOKER), {
    action: 'looker', target: '/looks/5',
  });

  // Every other page is opened with the reader's own session too, and some of
  // them do something: /logout signs the reader out.
  for (const href of ['/logout', '/admin/users', '/login', '/', '', '#fn1', '/extensions/other::app',
    '/embedded/dashboards/1', '/dashboards', '/dashboards/', '/dashboards//12', '/looks/5/', '/dashboards/a b',
    '/dashboards/a%2Fb', '/api/4.0/user', '/browse', '/sql', `/dashboards/12?x=${'a'.repeat(5000)}`]) {
    assert.deepEqual(resolveLink(href, LOOKER), BLOCK, href);
  }
  // "Paths" that are another site once a browser reads them.
  for (const href of [`${LOOKER}//evil.example/login`, `${LOOKER}/\\evil.example/login`,
    `${LOOKER}/embed//evil.example/login`, '//evil.example/dashboards/1', '\\\\evil.example\\dashboards\\1',
    `${LOOKER}/dashboards/../logout`, `${LOOKER}/dashboards/%2e%2e/logout`]) {
    assert.deepEqual(resolveLink(href, LOOKER), BLOCK, href);
  }
});

test('other sites are not opened unless their origin is listed', () => {
  const docs = 'https://cloud.google.com/looker/docs?hl=en#top';
  assert.deepEqual(resolveLink(docs, LOOKER), BLOCK);
  assert.deepEqual(resolveLink('https://evil.example/c?d=revenue%3D42', LOOKER), BLOCK);
  const listed = { allowedOrigins: ['https://cloud.google.com'] };
  assert.deepEqual(resolveLink(docs, LOOKER, listed), { action: 'external', target: docs });
  // The origin has to be the listed one exactly.
  for (const href of ['http://cloud.google.com/looker', 'https://cloud.google.com:8443/looker',
    'https://cloud.google.com.evil.example/looker', 'https://evil.example/cloud.google.com',
    'https://cloud.google.com@evil.example/looker']) {
    assert.deepEqual(resolveLink(href, LOOKER, listed), BLOCK, href);
  }
  // Being listed does not make a signed link of that site one to open.
  assert.deepEqual(resolveLink(signed('/embed/dashboards/1', 'https://cloud.google.com'), LOOKER, listed), BLOCK);
});

test('only web addresses are links', () => {
  for (const bad of ['javascript:alert(1)', 'JaVaScRiPt:alert(1)', 'java\tscript:alert(1)', ' javascript:alert(1)',
    'vbscript:x', 'file:///etc/passwd', 'mailto:a@example.com', 'ftp://looker.example.com/dashboards/1',
    'data:image/png;base64,AAAA', 'data:text/html,<script>alert(1)</script>', 'blob:https://looker.example.com/1234',
    '', '   ', null, undefined, 42, {}]) {
    assert.deepEqual(resolveLink(bad, LOOKER, { allowedOrigins: [LOOKER] }), BLOCK, String(bad));
  }
});

test('when Looker does not say where it lives, signed links still give the page and nothing else is opened', () => {
  assert.deepEqual(resolveLink(signed('/embed/dashboards/12'), undefined), {
    action: 'looker', target: '/dashboards/12',
  });
  assert.deepEqual(resolveLink(signed('/embed/admin/users'), undefined), BLOCK);
  assert.deepEqual(resolveLink('https://cloud.google.com/looker/docs', undefined), BLOCK);
  assert.deepEqual(resolveLink('/looks/5', undefined), BLOCK);
  // Something that is not an origin is the same as none.
  assert.deepEqual(resolveLink('/looks/5', 'not an address'), BLOCK);
  assert.deepEqual(resolveLink('/looks/5', 'javascript:alert(1)'), BLOCK);
});

test('whatever the address, a link opens a listed page or nothing', () => {
  const pieces = ['', '/', '//', '\\', '/embed', '/login/embed/', '/dashboards/1', '/looks/2', '/explore/m/e',
    '/logout', 'evil.example', '@', ':', '?a=b', '#c', '%2F', '%252F', '..', '.', ';x', 'https://', 'javascript:',
    LOOKER, 'https://evil.example', QUERY, encodeURIComponent('/embed/dashboards/9'), '&signature=x'];
  let opened = 0;
  for (const first of pieces) {
    for (const second of pieces) {
      for (const third of pieces) {
        const href = first + second + third;
        const result = resolveLink(href, LOOKER);
        if (result.action === 'looker') {
          opened += 1;
          assert.match(result.target, PAGE, href);
          assert.equal(mentionsEmbedSignIn(result.target), false, href);
          assert.equal(new URL(result.target, LOOKER).origin, LOOKER, href);
        } else {
          // Nothing is listed, so no other site may come out.
          assert.deepEqual(result, BLOCK, href);
        }
      }
    }
  }
  // The loop did meet honest links, or it would prove nothing.
  assert.ok(opened > 50, `only ${opened} combinations were opened`);
});

test('the embed sign-in address is recognised through every way of writing it', () => {
  const real = signed('/embed/dashboards/12');
  for (const text of [
    real, '/login/embed/x', 'LOOKER.EXAMPLE.COM/LOGIN/EMBED/X', '/login//embed/x', '/login/./embed/x',
    '/login\\embed/x', '%2Flogin%2Fembed%2Fx', '%252Flogin%252Fembed', '/login\\/embed/x', '/login&sol;embed',
    '/login&#47;embed', '/login&#x2f;embed', '/lo&#103;in/embed', '/login%5C/embed',
    '?a=b&signature=abc', 'signature%3Dabc', 'signature&equals;abc', 'signature\\=abc', 'SIGNATURE=abc',
    '%25'.repeat(1) + '25'.repeat(8) + '2Flogin',
  ]) {
    assert.equal(mentionsEmbedSignIn(text), true, text);
  }
  for (const text of ['', 'https://looker.example.com/dashboards/12?Country=Brazil', '/login', '/embed/dashboards/1',
    'the signature of the contract', '100%25 sure', 'a & b', 'x\\_y', 'login / embed']) {
    assert.equal(mentionsEmbedSignIn(text), false, text);
  }
});

test('a text loses every embed sign-in address before it is shown', () => {
  const real = signed('/embed/dashboards/12?Country=Brazil');
  const plain = 'https://looker.example.com/dashboards/12?Country=Brazil';
  const cases = [
    // The agent's own form: the link stays, as the plain page.
    [`Here it is.\n\n[Open the interactive version in Looker](${real})`,
      `Here it is.\n\n[Open the interactive version in Looker](${plain})`],
    [`The link is ${real}.`, `The link is ${plain}.`],
    [`**${real}**`, `**${plain}**`],
    [`<${real}>`, `<${plain}>`],
    [`[a][1]\n\n[1]: ${real}`, `[a][1]\n\n[1]: ${plain}`],
    [`| Dashboard | ${real} |`, `| Dashboard | ${plain} |`],
    // Anything else that is or carries such an address is taken out.
    [`[x](${signed('/embed/admin/users')})`, '[x]()'],
    [`[x](${signed('/embed/dashboards/1', 'https://other.example.com')})`, '[x]()'],
    [`[x](${real.replace('/login/embed/', '/login//embed/')})`, '[x]()'],
    // Markdown shows "\/" as "/" and "&sol;" as "/": the reader would see, and
    // could copy, a working address.
    [`[x](${real.replace('/login/embed/', '/login\\/embed/')})`, '[x]()'],
    [`see ${real.replace('/login/embed/', '/login&sol;embed/')} now`, 'see  now'],
    ['see https&#58;//looker.example.com/login&#47;embed/abc?signature&#x3d;abc now', 'see  now'],
    ['looker.example.com/login/embed/abc?nonce=1&signature=abc', ''],
    [`x,${real}`, `x,${plain}`],
    // What stays untouched.
    ['Orders: 42. See /dashboards/12 (100%25 complete).', 'Orders: 42. See /dashboards/12 (100%25 complete).'],
    ['', ''],
  ];
  for (const [text, expected] of cases) {
    const shown = withoutEmbedSignIns(text, LOOKER);
    assert.equal(shown, expected, text);
    assert.equal(mentionsEmbedSignIn(shown), false, text);
  }
  // A page whose filters hold brackets stays one markdown link.
  const filtered = signed('/embed/dashboards/12?f[orders.status]=(none)&Name=O\'Brien*');
  assert.equal(
    withoutEmbedSignIns(`[open](${filtered})`, LOOKER),
    '[open](https://looker.example.com/dashboards/12?f%5Borders.status%5D=%28none%29&Name=O%27Brien%2A)',
  );
  // Without knowing where Looker lives there is no address to put in its place.
  assert.equal(withoutEmbedSignIns(`[open](${real})`, undefined), '[open]()');
  // Not a string: shown as text, like everything else.
  assert.equal(withoutEmbedSignIns(42, LOOKER), '42');
});

test('the address shown for a page is this Looker and that page', () => {
  assert.equal(pageAddress(LOOKER, '/dashboards/12?Country=Brazil'), 'https://looker.example.com/dashboards/12?Country=Brazil');
  assert.equal(pageAddress('https://looker.example.com:9999/some/page', '/looks/5'), 'https://looker.example.com:9999/looks/5');
  assert.equal(pageAddress(undefined, '/looks/5'), '');
  assert.equal(pageAddress('javascript:alert(1)', '/looks/5'), '');
  // What resolveLink() gives for it is the same page again.
  const address = pageAddress(LOOKER, '/explore/thelook/orders?f[orders.status]=(none)');
  assert.deepEqual(resolveLink(address, LOOKER), {
    action: 'looker', target: '/explore/thelook/orders?f%5Borders.status%5D=%28none%29',
  });
});

test('the clicked link is found through the shadow DOM path', () => {
  const link = anchor({ href: 'https://x.example/y' });
  const event = { composedPath: () => [{ tagName: 'IMG' }, link, { tagName: 'DIV' }, {}, null] };
  assert.equal(clickedAnchor(event), link);
  assert.equal(clickedHref(event), 'https://x.example/y');
  // A click that is not on a link is none of this file's business.
  assert.equal(clickedHref({ composedPath: () => [{ tagName: 'DIV' }, {}] }), null);
  assert.equal(clickedHref({}), null);
  // A link without an address is found, and resolves to "block".
  assert.equal(clickedHref({ composedPath: () => [anchor({})] }), '');
  assert.equal(clickedHref({ composedPath: () => [{ tagName: 'a', href: 'https://x.example/z' }] }), 'https://x.example/z');
});

test('only the link deep-chat puts around an image it shows is left to the browser', () => {
  const image = { tagName: 'IMG' };
  assert.equal(isDownloadWrapper(anchor({ href: 'data:image/png;base64,iVBORw0KGgo=', download: 'dashboard_12.png', child: image })), true);
  assert.equal(isDownloadWrapper(anchor({ href: 'data:image/jpeg;base64,/9j/4AAQ', download: 'a.jpg', child: image })), true);
  // A link the model wrote has no download attribute, whatever it points at.
  assert.equal(isDownloadWrapper(anchor({ href: 'data:image/png;base64,iVBORw0KGgo=', child: image })), false);
  // Another kind of content, or an address to fetch, is not an image the chat shows.
  for (const href of ['data:text/html;base64,PHNjcmlwdD4=', 'data:image/svg+xml;base64,PHN2Zz4=',
    'data:application/x-msdownload;base64,TVqQ', 'https://evil.example/a.png', 'blob:https://looker.example.com/1', '']) {
    assert.equal(isDownloadWrapper(anchor({ href, download: 'a.png', child: image })), false, href);
  }
  // The image has to be what the link is around.
  assert.equal(isDownloadWrapper(anchor({ href: 'data:image/png;base64,iVBORw0KGgo=', download: 'a.png' })), false);
  assert.equal(isDownloadWrapper(anchor({ href: 'data:image/png;base64,iVBORw0KGgo=', download: 'a.png', child: { tagName: 'DIV' } })), false);
  assert.equal(isDownloadWrapper(null), false);
  assert.equal(isDownloadWrapper({ tagName: 'A', href: 'data:image/png;base64,iVBORw0KGgo=' }), false);
});
