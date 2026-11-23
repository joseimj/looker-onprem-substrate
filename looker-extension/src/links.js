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

// What a link in the chat may do.
//
// The text of an answer is written by the model, and the model reads whatever
// is in Looker: dashboard titles, filter values, the cells of a query result,
// the pixels of a rendered dashboard. Whoever can write such data can have a
// link put into an answer. So this file does not list what must not be
// opened. It lists what may be:
//
//   - a dashboard, a Look or an explore of this Looker, opened through Looker
//     with the reader's own session and permissions;
//   - a page of another site, only if its origin is listed in
//     allowedLinkOrigins (config.js). The list is empty unless a deployment
//     fills it;
//   - nothing else: no other page of this Looker (/logout, /admin/...), no
//     other scheme, and no address that only looks like a path of this Looker
//     (//other-host/...).
//
// Signed embed links
// ------------------
// The agent was written for a chat outside Looker, and its "open in Looker"
// links used to be signed embed URLs:
//
//     https://<looker>/login/embed/<encoded /embed/dashboards/12>?...&signature=...
//
// Such a URL signs in whoever opens it, as a temporary embed user. Looker's
// API notes say to protect it like a password. Opened from inside Looker it
// would also replace the reader's own session, because the agent asked for
// force_logout_login. With LOOKER_LINK_MODE="plain", which is what deploy.sh
// sets, the agent does not write them any more. Should one arrive anyway, it
// is never opened and never shown: where it points at a page of this Looker,
// the plain address of that page takes its place (/dashboards/12, opened as
// the reader); in every other case it is dropped.
//
// No browser or Looker dependency here: testable with `node --test`.

const EMBED_LOGIN_PREFIX = '/login/embed/';

// "/dashboards/12", "/dashboards/thelook::overview", "/looks/5",
// "/explore/thelook/order_items". After the first part, only characters that
// a Looker id or a LookML name can hold.
const PAGE_PATH = /^\/(?:dashboards|looks|explore)(?:\/[A-Za-z0-9_:.~-]+)+$/;
const ONLY_DOTS = /^\.+$/;
// Path, filters and fragment together. Explore addresses carry their whole
// query and get long; nothing honest gets longer than this.
const MAX_TARGET_LENGTH = 4000;

// What deep-chat puts around an image it shows, so that it can be saved.
const SHOWN_IMAGE = /^data:image\/(?:png|jpeg);base64,/;

// The few named entities that stand for a character an address is built
// from. Numeric entities are handled in general.
const NAMED_ENTITIES = {
  sol: '/', bsol: '\\', equals: '=', percnt: '%', amp: '&', quest: '?', colon: ':', period: '.',
  semi: ';', num: '#', lowbar: '_',
};

function characterFor(codePoint, unchanged) {
  return codePoint > 0 && codePoint <= 0x10ffff ? String.fromCodePoint(codePoint) : unchanged;
}

// Undoes one layer of the ways in which markdown and URLs let a character be
// written as something else.
function decodedOnce(text) {
  return text
    // Markdown: a backslash before punctuation stands for that character.
    .replace(/\\([!-\/:-@\[-`{-~])/g, '$1')
    // HTML entities, which markdown resolves in text and in link addresses.
    .replace(/&#x([0-9a-f]{1,6});?/gi, (all, hex) => characterFor(parseInt(hex, 16), all))
    .replace(/&#([0-9]{1,7});?/g, (all, digits) => characterFor(parseInt(digits, 10), all))
    .replace(/&([a-z]+);/gi, (all, name) => NAMED_ENTITIES[name.toLowerCase()] || all)
    // Percent-encoding, byte by byte: enough to recognise ASCII text.
    .replace(/%([0-9a-f]{2})/gi, (all, hex) => String.fromCharCode(parseInt(hex, 16)));
}

// Whether a piece of text is, or carries, the address of Looker's embed
// sign-in: its path, or the signature that makes such an address work. It
// looks through encodings on purpose. "/login//embed/", "/Login/Embed/",
// "%2Flogin%2Fembed", "/login\/embed" and "signature&equals;" all end up as
// an address a browser or a proxy may treat as the real one.
export function mentionsEmbedSignIn(text) {
  let value = String(text);
  for (let round = 0; round < 5; round += 1) {
    const flat = value.toLowerCase().replace(/\\/g, '/').replace(/\/(?:\.?\/)+/g, '/');
    if (flat.includes('/login/embed') || flat.includes('signature=')) return true;
    const decoded = decodedOnce(value);
    if (decoded === value) return false;
    value = decoded;
  }
  // Still changing after that many layers. Nothing honest is written like that.
  return true;
}

function originOf(address) {
  try {
    const url = new URL(address);
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.origin : '';
  } catch (error) {
    return '';
  }
}

function hostNameOf(origin) {
  try {
    return new URL(origin).hostname;
  } catch (error) {
    return '';
  }
}

// "/embed/dashboards/12?Country=Brazil" -> "/dashboards/12?Country=Brazil"
function withoutEmbedPrefix(path) {
  return path.startsWith('/embed/') ? path.slice('/embed'.length) : path;
}

// The page of this Looker that `url` is for, as "/dashboards/12?Country=Brazil",
// or null when it is not one of the pages a link may open.
function pageTarget(url) {
  const path = withoutEmbedPrefix(url.pathname);
  if (!PAGE_PATH.test(path)) return null;
  if (path.split('/').some((part) => ONLY_DOTS.test(part))) return null;
  const target = path + url.search + url.hash;
  if (target.length > MAX_TARGET_LENGTH) return null;
  // A sign-in address must not travel inside the filters of an honest one.
  if (mentionsEmbedSignIn(target)) return null;
  return target;
}

// Returns one of:
//   {action: 'looker',   target: '/dashboards/12'}  open this page of this Looker
//   {action: 'external', target: 'https://...'}     open a page of a listed site
//   {action: 'block'}                               do nothing
// `lookerOrigin` is the origin of the Looker page hosting the extension, for
// example "https://looker.example.com". `allowedOrigins` are the origins of
// other sites that may be opened; see allowedLinkOrigins in config.js.
export function resolveLink(href, lookerOrigin, { allowedOrigins = [] } = {}) {
  const block = { action: 'block' };
  if (typeof href !== 'string' || href.trim() === '') return block;
  const looker = originOf(lookerOrigin);
  let url;
  try {
    url = new URL(href.trim(), looker || undefined);
  } catch (error) {
    return block;
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return block;

  if (url.pathname.startsWith(EMBED_LOGIN_PREFIX)) {
    // A signed link signs the reader in with cookies, and a browser keeps
    // cookies per host name, not per port or scheme. Looker opened on port
    // 9999 and a link written without the port are the same Looker to the
    // browser. So for signed links the host name decides. A Looker older than
    // 21.8 does not say where it lives; a signed link is then taken to be for
    // this Looker, which is safe because only the page it names is used.
    if (looker && url.hostname !== hostNameOf(looker)) return block;
    // The page the link is for travels URL-encoded in the path.
    let inner;
    try {
      inner = new URL(decodeURIComponent(url.pathname.slice(EMBED_LOGIN_PREFIX.length)), url.origin);
    } catch (error) {
      return block;
    }
    // It has to be a page of this Looker, and one a link may open. Another
    // site's address, or a second signed link, is not taken from inside one.
    if (inner.origin !== url.origin) return block;
    const target = pageTarget(inner);
    return target === null ? block : { action: 'looker', target };
  }

  // The sign-in address in any other spelling, or carried inside another
  // address, is not opened: not as a page of this Looker and not as a page of
  // a listed site.
  if (mentionsEmbedSignIn(url.href)) return block;

  if (looker && url.origin === looker) {
    const target = pageTarget(url);
    return target === null ? block : { action: 'looker', target };
  }
  if (allowedOrigins.includes(url.origin)) return { action: 'external', target: url.href };
  return block;
}

// The address to show for a page of this Looker: "https://looker.example.com"
// and "/dashboards/12" give "https://looker.example.com/dashboards/12". Empty
// when Looker did not say where it lives.
//
// The address is also written back into markdown text, where brackets and a
// few other characters would end or change a link. A filter such as
// f[orders.status]=(none) keeps its meaning when they are percent-encoded.
export function pageAddress(lookerOrigin, target) {
  const looker = originOf(lookerOrigin);
  if (!looker) return '';
  return looker + target.replace(
    /[()[\]{}|\\*']/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

// Takes every embed sign-in address out of a text before it is shown.
//
// Where the address is a signed link to a page of this Looker, the plain
// address of that page takes its place. Anything else that is or carries such
// an address is removed. The text is looked at piece by piece, a piece being
// what stands between spaces, quotes and brackets, which is how an address
// appears both in prose and inside a markdown link.
export function withoutEmbedSignIns(text, lookerOrigin) {
  return String(text).replace(/[^\s<>"'`()[\]{}|]+/g, (piece) => {
    if (!mentionsEmbedSignIn(piece)) return piece;
    const start = piece.search(/https?:\/\//i);
    if (start === -1) return '';
    // Markdown or punctuation may cling to either end: "**https://...**."
    const address = piece.slice(start).replace(/[.,;:!?*_~]+$/, '');
    const link = resolveLink(address, lookerOrigin);
    const plain = link.action === 'looker' ? pageAddress(lookerOrigin, link.target) : '';
    if (plain === '') return '';
    const shown = piece.slice(0, start) + plain + piece.slice(start + address.length);
    return mentionsEmbedSignIn(shown) ? '' : shown;
  });
}

// Finds the link a click landed on. deep-chat renders inside a shadow root, so
// the event's target is the chat element itself; the real path is composedPath().
export function clickedAnchor(event) {
  const path = event && typeof event.composedPath === 'function' ? event.composedPath() : [];
  for (const node of path) {
    if (node && typeof node.tagName === 'string' && node.tagName.toUpperCase() === 'A') return node;
  }
  return null;
}

export function hrefOf(anchor) {
  const href = typeof anchor.getAttribute === 'function' ? anchor.getAttribute('href') : anchor.href;
  return typeof href === 'string' ? href : '';
}

// The address of the link a click landed on: null when the click was not on
// a link, '' when the link has no usable address.
export function clickedHref(event) {
  const anchor = clickedAnchor(event);
  return anchor === null ? null : hrefOf(anchor);
}

// Whether a link is the one deep-chat itself puts around an image it shows,
// so that the image can be saved: <a href="data:image/png;base64,..." download>
// with the <img> inside. Markdown cannot produce a download attribute, so a
// link written by the model never passes for one.
export function isDownloadWrapper(anchor) {
  if (!anchor || typeof anchor.getAttribute !== 'function') return false;
  if (typeof anchor.getAttribute('download') !== 'string') return false;
  if (!SHOWN_IMAGE.test(hrefOf(anchor))) return false;
  const child = anchor.firstElementChild;
  return Boolean(child && typeof child.tagName === 'string' && child.tagName.toUpperCase() === 'IMG');
}
