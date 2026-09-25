'use strict';
//
//  dom-test.js
//  Drives the injected scraper script (ScraperScript.swift) against a tiny DOM shim, so the rules
//  that turn a card into a lot number can be checked without a browser, a network or an auction
//  site. Run it through Tools/scraper-js-check/run.sh, which compiles the Swift side and hands the
//  generated JavaScript to this file.
//
//  The shim models only what the scraper touches: `querySelectorAll` with simple *compound* selectors
//  (tag, `.class`, `[attr]`, `[attr*=value]`, `[attr^=value]`, `[attr=value]`, any run of those, with
//  the ` i` flag), `getAttribute`, `textContent`, `closest` (always null) and `addEventListener` (a
//  no-op). Descendant selectors are not modelled and deliberately match nothing — the selectors the
//  profile uses to name a gallery container, a description block or a card are all compound ones, so
//  the element under test is always found.
//
const fs = require('fs');
// The generated script comes from run.sh (or from the environment); `--debug` is a flag, not a path.
const scriptPath = process.env.SCRAPER_JS
  || process.argv.slice(2).find(argument => argument.charAt(0) !== '-')
  || '/tmp/scraper.js';

// ---- a very small DOM, only what the scraper touches -------------------------
//
// A part is one *compound* selector — a tag, any number of `.class` tokens and any number of
// `[attr...]` tests run together (`div.auc_slide.left`, `ul.mediaThumbnails`, `img[data-src]`) — or
// `*`, which the scraper walks a container with so its elements come back in document order. That is
// the shape the profile names a gallery container and a description block in, so it has to match here,
// or the lot-page checks would be proving something no browser would agree with. Descendant combinators
// are still not modelled and deliberately match nothing.
function matches(el, part) {
  // `*` is how the scraper walks a container, so its elements come back in document order.
  if (part === '*') return true;

  const token = /([a-zA-Z][\w-]*)|\.([\w-]+)|\[([^\]]*)\]/g;
  let consumed = 0;
  let m = token.exec(part);
  while (m) {
    if (m.index !== consumed) return false;
    consumed = token.lastIndex;
    if (m[1] !== undefined) {
      if (el.tag.toLowerCase() !== m[1].toLowerCase()) return false;
      m = token.exec(part);
      continue;
    }
    if (m[2] !== undefined) {
      if (String(el.attrs.class || '').split(/\s+/).indexOf(m[2]) < 0) return false;
      m = token.exec(part);
      continue;
    }
    const inner = m[3].replace(/\s+i$/, '');
    const eq = inner.match(/^([\w-]+)\s*(?:([*^$~|]?)=\s*['"]?([^'"\]]*)['"]?)?$/);
    if (!eq) return false;
    const attr = eq[1];
    const op = eq[2];
    const value = eq[3];
    const actual = el.attrs[attr];
    if (actual === undefined) return false;
    if (op !== undefined) {
      const hay = String(actual).toLowerCase();
      const needle = String(value).toLowerCase();
      if (op === '*' && hay.indexOf(needle) < 0) return false;
      if (op === '^' && hay.indexOf(needle) !== 0) return false;
      if (op === '=' && hay !== needle) return false;
    }
    m = token.exec(part);
  }
  return consumed > 0 && consumed === part.length;
}

class El {
  constructor(tag, attrs, text, kids) {
    this.tag = tag;
    this.attrs = attrs || {};
    this.ownText = text || '';
    this.kids = kids || [];
    // Parent pointers, so the scraper's search for the anchor a card *lives in* can be driven here
    // exactly as it is in a browser.
    for (const kid of this.kids) kid.parentElement = this;
  }
  getAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null;
  }
  get textContent() {
    return (this.ownText + ' ' + this.kids.map(k => k.textContent).join(' ')).replace(/\s+/g, ' ').trim();
  }
  descendants() {
    return this.kids.reduce((all, k) => all.concat([k], k.descendants()), []);
  }
  querySelectorAll(selector) {
    const parts = String(selector).split(',').map(s => s.trim()).filter(Boolean);
    const out = [];
    for (const part of parts) {
      // Whitespace *inside* a bracket is a case-insensitivity flag, not a descendant combinator.
      const outside = part.replace(/\[[^\]]*\]/g, '');
      if (/\s/.test(outside) || part.indexOf('>') >= 0) continue; // descendant selectors are not modelled
      for (const el of this.descendants()) if (matches(el, part) && out.indexOf(el) < 0) out.push(el);
    }
    return out;
  }
  contains(other) {
    let node = other;
    while (node) {
      if (node === this) return true;
      node = node.parentElement;
    }
    return false;
  }
  closest() { return null; }
  addEventListener() {}
}

// ---- a very small HTML scanner, standing in for DOMParser --------------------
//
// `window.__PAS.lotPageImages` parses a fetched page with `DOMParser` and walks it exactly like a
// card. Modelling that means handing the script something with `querySelectorAll` on it, so this turns
// the fixture markup into a nested `El` tree. It reads tags, keeps the text of `<script>`/`<style>` so
// gallery JSON blobs can be checked, and understands quoted, single-quoted and bare attributes.
function attrsOf(text) {
  const attrs = {};
  const pattern = /([\w:-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/g;
  let match = pattern.exec(text);
  while (match) {
    const value = match[2] !== undefined ? match[2]
      : match[3] !== undefined ? match[3]
        : match[4] !== undefined ? match[4] : '';
    attrs[match[1]] = value;
    match = pattern.exec(text);
  }
  return attrs;
}

// Tags that never wrap anything, so they are never pushed onto the open-element stack.
const VOID_TAGS = ['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta',
  'param', 'source', 'track', 'wbr'];

// A nested tree, because the lot-page reader is *container-scoped*: it asks a gallery element for the
// `img`s inside it and a description element for its text, and a flat list of tags would make every
// container childless and every one of those answers empty. Text between tags is kept on the element
// that contains it, because that is what `textContent` is built from — a `<h3>Description</h3>` and
// the copy under it have to come back as one string with the heading first.
function parseHTML(html) {
  const root = new El('html', {}, '', []);
  const stack = [root];
  const pattern = /<(\/?)([a-zA-Z][\w-]*)((?:[^>"']|"[^"]*"|'[^']*')*?)(\/?)>|([^<]+)/g;
  let match = pattern.exec(html);
  while (match) {
    const top = stack[stack.length - 1];
    // Text, a comment-free run of it: appended to whatever element is open at the time.
    if (match[5] !== undefined) {
      top.ownText = top.ownText + ' ' + match[5];
      match = pattern.exec(html);
      continue;
    }
    const tag = match[2].toLowerCase();
    if (match[1] === '/') {
      // Close the nearest matching element; a stray close for a tag never opened changes nothing.
      for (let index = stack.length - 1; index > 0; index -= 1) {
        if (stack[index].tag === tag) { stack.length = index; break; }
      }
      match = pattern.exec(html);
      continue;
    }
    const element = new El(tag, attrsOf(match[3]), '', []);
    element.parentElement = top;
    top.kids.push(element);
    if (match[4] !== '/' && (tag === 'script' || tag === 'style')) {
      // Raw text: the JSON blobs a gallery is declared in have to survive intact.
      const close = html.indexOf('</' + tag, pattern.lastIndex);
      element.ownText = html.slice(pattern.lastIndex, close < 0 ? html.length : close);
      pattern.lastIndex = close < 0 ? html.length : close;
      match = pattern.exec(html);
      continue;
    }
    if (match[4] !== '/' && VOID_TAGS.indexOf(tag) < 0) stack.push(element);
    match = pattern.exec(html);
  }
  return root;
}

class FakeDOMParser {
  parseFromString(html) { return parseHTML(String(html)); }
}

// One page: a lot card with a title, one photo and one link.
function scrape(attrs, options) {
  const opts = options || {};
  const kids = [
    new El('h3', { class: 'product-title' }, 'Assorted plumbing fittings, 30 pieces'),
    new El('img', { src: '/img/fittings.jpg' }),
    new El('p', { class: 'description' }, 'Used goods, mixed departments, sold as one pallet.')
  ];
  if (opts.lotIdText) kids.push(new El('span', { class: 'lot-id' }, opts.lotIdText));
  if (opts.statusBadge) kids.push(new El('span', { class: 'lot-status' }, opts.statusBadge));
  // An anchor that is *not* the lot's page, in front of the one that is: a share button, a lightbox.
  if (opts.firstLink) kids.push(new El('a', { href: opts.firstLink }, ''));
  if (opts.withLink !== false) kids.push(new El('a', { href: '/auction/lot/19002' }, ''));

  const cardAttrs = Object.assign({ class: 'lot-card' }, attrs);
  const card = new El('div', cardAttrs, '', kids);
  // An empty catalogue: no cards at all, and the widget says so in its own words.
  let pageKids = opts.empty
    ? [new El('div', { class: 'no-results' }, 'Results: No Items Found.')]
    : [card];
  // A layout whose tile *is* a link: the card that matched is the inner body, and the address is on
  // the anchor around it (see `detailLink`'s third source).
  if (opts.cardInsideLink) {
    const link = new El('a', { href: opts.cardInsideLink }, '');
    link.kids = [card];
    card.parentElement = link;
    pageKids = [link];
  }
  // Addresses that sit elsewhere on the page rather than on the card: the other half of a catalog
  // grid, a "recently viewed" strip, or the templates a JS router renders from.
  if (opts.strayLinks) {
    pageKids.push(new El('nav', { class: 'recent' }, '', opts.strayLinks.map(href => new El('a', { href }, ''))));
  }
  // The catalogue's own pagination, for the checks that ask how many pages a listing reports. The
  // container is what those checks vary: a numbered `nav.pagination`, a nav labelled only by
  // `aria-label`, or no nav at all.
  if (opts.pagination) {
    const spec = opts.pagination;
    const nav = new El('nav', spec.attrs || { class: 'pagination' }, spec.text || '',
      (spec.links || []).map(href => new El('a', { href }, '')));
    if (spec.next) nav.kids.push(new El('a', { rel: 'next', href: spec.next }, 'Next'));
    pageKids.push(nav);
  }
  const body = new El('body', {}, '', pageKids);
  const root = new El('div', { class: 'result-grid' }, '', [body]);

  const document = {
    title: 'Auction',
    body: body,
    querySelectorAll: s => root.querySelectorAll(s),
    addEventListener() {},
    documentElement: root
  };
  const window = {
    webkit: { messageHandlers: { palletLog: { postMessage() {} } } },
    setTimeout: setTimeout,
    clearTimeout: clearTimeout
  };
  const location = { href: 'https://example.test/auction' };
  function MutationObserver() { this.observe = () => {}; this.disconnect = () => {}; }

  // The lot page half of the shim: a `fetch` and a `DOMParser` just real enough to drive
  // `window.__PAS.lotPageImages(url)` without a browser. The fetch records what it was asked for, so
  // the checks can assert that the request went to the *lot's* address with the session's cookies
  // (credentials: 'same-origin') rather than to the listing.
  const fetches = [];
  const detail = opts.detail || {};
  function fakeFetch(url, init) {
    fetches.push({ url: url, init: init || {} });
    if (detail.fails) return Promise.reject(new Error(detail.fails));
    const status = detail.status || 200;
    const type = detail.type === undefined ? 'text/html; charset=utf-8' : detail.type;
    return Promise.resolve({
      ok: status >= 200 && status < 300,
      status: status,
      headers: { get: name => (String(name).toLowerCase() === 'content-type' ? type : null) },
      text: () => Promise.resolve(detail.html || '')
    });
  }

  const source = fs.readFileSync(scriptPath, 'utf8');
  if (source.indexOf('window.__PAS = {') < 0) {
    throw new Error('the scraper script no longer exposes window.__PAS the way this check expects');
  }
  const hooked = source.replace(
    'window.__PAS = {',
    'window.__PAS = { debugLot: function (raw, text) { return String(normalizeLotNumber(raw, text)); },'
      + ' debugUnwrap: function (v) { return String(unwrapDOMId(v)); },'
      + ' debugHolder: function () { const el = collectCards().elements[0];'
      + ' const holder = firstElement(el, CONFIG.lotNumberSelectors);'
      + ' return JSON.stringify({ holder: holder ? textOf(holder) : null,'
      + ' tag: el.tag, cardClass: el.getAttribute("class"),'
      + ' spans: each(el, "span").map(function (s) { return s.getAttribute("class") + ":" + textOf(s); }),'
      + ' lots: collectCards().elements.length,'
      + ' attrs: attributeOf(el, CONFIG.lotNumberAttributeCandidates),'
      + ' normalized: normalizeLotNumber(holder ? textOf(holder) : "", textOf(el)) }); },'
      + ' debugURL: function (v) { return String(lotNumberFromURL(v)); },'
  );
  const sandbox = new Function(
    'window', 'document', 'location', 'URL', 'MutationObserver', 'fetch', 'DOMParser', 'AbortController',
    hooked + '\nreturn window.__PAS;'
  );
  const api = sandbox(
    window, document, location, URL, MutationObserver,
    fakeFetch, FakeDOMParser, typeof AbortController === 'function' ? AbortController : undefined
  );
  // The recorded lot-page requests, for the checks that care where the read went and with what.
  api.__fetches = fetches;
  if (opts.debug || opts.api) return api;
  return JSON.parse(api.extractLots());
}

// A diagnostic mode: prints the raw extraction for the awkward cards, which is what to reach for
// when the profile's selectors change. The assertions further down are what run.sh gates on.
if (process.argv.indexOf('--debug') > 0) {
  for (const fixture of [
    { id: 'ItemMain19002' },
    { id: 'ItemMain19002', lotIdText: 'Lot Number 142' },
    { id: 'ItemMain19002', 'data-lot-number': 'ABC123' },
    { 'data-key': 'ItemMain19002' }
  ]) {
    console.log(JSON.stringify(fixture));
    console.log('  ->', JSON.stringify(scrape(fixture).lots[0]));
  }
  process.exit(0);
}

const failures = [];
function check(condition, message, detail) {
  if (condition) console.log('  PASS  ' + message);
  else {
    failures.push(message);
    console.log('  FAIL  ' + message + (detail === undefined ? '' : ' — ' + detail));
  }
}

console.log('page-side extraction');
let result = scrape({ id: 'ItemMain19002' });
check(result.cardCount === 1, 'the card is found', result.cardCount);
check(result.lots[0].lotNumber === '19002', 'a DOM id is never reported as the lot number', JSON.stringify(result.lots[0].lotNumber));
check(result.lots[0].detailURLString === 'https://example.test/auction/lot/19002', 'the deep link is kept', result.lots[0].detailURLString);

result = scrape({ id: 'ItemMain19002' }, { withLink: false });
check(result.lots[0].lotNumber === '19002', 'with no link at all the id is still unwrapped', JSON.stringify(result.lots[0].lotNumber));

result = scrape({ 'data-key': 'ItemMain19002' }, { withLink: false });
check(result.lots[0].lotNumber === '19002', 'a row key is unwrapped the same way', JSON.stringify(result.lots[0].lotNumber));

result = scrape({ id: 'ItemMain19002' }, { lotIdText: 'Lot #142' });
check(result.lots[0].lotNumber === '142', 'a printed lot number beats the id', JSON.stringify(result.lots[0].lotNumber));

result = scrape({ id: 'ItemMain19002' }, { lotIdText: 'Lot Number 142' });
check(result.lots[0].lotNumber === '142', 'even a two-word label', JSON.stringify(result.lots[0].lotNumber));

result = scrape({ id: 'ItemMain19002', 'data-lot-number': 'ABC123' });
check(result.lots[0].lotNumber === 'ABC123', 'a real SKU is left alone', JSON.stringify(result.lots[0].lotNumber));

result = scrape({});
check(result.lots[0].lotNumber === '19002', 'a card with nothing but a link borrows its number', JSON.stringify(result.lots[0].lotNumber));

result = scrape({}, { withLink: false });
check(result.lots[0].lotNumber === '', 'and a card with nothing at all reports nothing', JSON.stringify(result.lots[0].lotNumber));

console.log('\nthe lot\'s own page (what the Open button is given)');

// The ordinary case, and the shape the profile's `detailLinkSelectors` name outright.
result = scrape({ id: 'ItemMain19002' });
check(result.lots[0].detailURLString === 'https://example.test/auction/lot/19002',
  'a tile that is a link keeps its address', result.lots[0].detailURLString);

// A share button in front of the lot's own link must not be what the browser opens.
result = scrape({ id: 'ItemMain19002' }, { firstLink: '/share?ref=twitter' });
check(result.lots[0].detailURLString === 'https://example.test/auction/lot/19002',
  'a share button in front of the lot link is skipped', result.lots[0].detailURLString);

// The awkward shape: the share link quotes the lot's own address, so it matches the profile's
// patterns too. The furniture rule is what rejects it — not the fact that nothing named it.
result = scrape({ id: 'ItemMain19002' }, { firstLink: '/share?url=/auction/lot/19002' });
check(result.lots[0].detailURLString === 'https://example.test/auction/lot/19002',
  'a share link that merely quotes the lot address is skipped too', result.lots[0].detailURLString);

// A lightbox is not a lot page either — and an address that is a file is never handed to Open.
result = scrape({ id: 'ItemMain19002' }, { withLink: false, firstLink: '/img/19002-large.jpg' });
check(result.lots[0].detailURLString === null,
  'an anchor pointing at a photograph is not a lot page', result.lots[0].detailURLString);

// ...but it still names the lot, which is what a card with no printed number has to go on.
result = scrape({}, { withLink: false, firstLink: '/img/lot-19002.jpg' });
check(result.lots[0].lotNumber === '19002',
  'the address of a photograph still gives up the number', JSON.stringify(result.lots[0].lotNumber));
check(result.lots[0].detailURLString === null, 'while offering nothing to open');

// The card the profile matched is often the *inner body* of the tile, with the address on the
// anchor that wraps it. The address shape here matches none of the profile's named patterns, so this
// can only come from the search for the anchor the card lives in.
result = scrape({ id: 'ItemMain19002' }, { withLink: false, cardInsideLink: '/catalog/19002' });
check(result.lots[0].detailURLString === 'https://example.test/catalog/19002',
  'the address on the link wrapping the card is found', result.lots[0].detailURLString);

// A catalog grid whose cards are not links at all: the number the card prints is in the address of
// the page that holds it, which is somewhere else on the listing.
result = scrape({ id: 'ItemMain19002' }, { withLink: false, strayLinks: ['/catalog/19002'] });
check(result.lots[0].detailURLString === 'https://example.test/catalog/19002',
  'an address elsewhere on the page names the lot and is taken', result.lots[0].detailURLString);

// ...but only when it really names it: `190021` is a different lot, not a decorated `19002`.
result = scrape({ id: 'ItemMain19002' }, { withLink: false, strayLinks: ['/catalog/190021'] });
check(result.lots[0].detailURLString === null,
  'a longer number is a different lot and is left alone', result.lots[0].detailURLString);

// The card's own anchor is still better evidence than a neighbour's address when the number matched
// nothing: the first usable anchor on the card wins, not the grid's.
result = scrape({ id: 'ItemMain19002' }, { withLink: false, firstLink: '/catalog/19002', strayLinks: ['/catalog/999'] });
check(result.lots[0].detailURLString === 'https://example.test/catalog/19002',
  'the card beats the rest of the page', result.lots[0].detailURLString);

console.log('\nlot status and empty catalogues');

// The base fixture's own description ends "…, sold as one pallet." — sale format, not state.
result = scrape({});
check(result.lots[0].isSold === false,
  'a card whose copy says "sold as one pallet" is left active', JSON.stringify(result.lots[0].statusText));
check(result.lots[0].statusText === '', 'and has no status label to show');

result = scrape({}, { statusBadge: 'SOLD' });
check(result.lots[0].isSold === true, 'a SOLD badge marks the lot sold', JSON.stringify(result.lots[0]));
check(result.lots[0].statusText === 'SOLD', 'and the badge text comes back with it', result.lots[0].statusText);

result = scrape({}, { statusBadge: 'Sold' });
check(result.lots[0].isSold === true, 'the badge is matched however the site cases it');

result = scrape({ 'data-status': 'Sold' });
check(result.lots[0].isSold === true, 'an attribute-only marker is read too', JSON.stringify(result.lots[0]));

result = scrape({}, { statusBadge: 'Active' });
check(result.lots[0].isSold === false, 'an "Active" badge leaves the lot biddable');

let api = scrape({}, { api: true });
check(JSON.parse(api.noResults()).present === false,
  'a populated page reports no empty-catalogue message');

api = scrape({}, { empty: true, api: true });
check(api.cardCount() === 0, 'an empty catalogue has no cards at all');
const emptyReport = JSON.parse(api.noResults());
check(emptyReport.present === true, 'and its own no-results message is found', JSON.stringify(emptyReport));
check(emptyReport.text.indexOf('No Items Found') >= 0, "with the page's own words for the log", emptyReport.text);
check(api.noResultsPresent() === true, 'the cheap boolean agrees');

// ---- how many pages the listing reports -------------------------------------
//
// The **Pages** control is a menu of page counts, so it has to ask the catalogue how long it is.
// The answer comes out of the pagination the site already renders — its numbered links first, then
// the count it prints in words — and it is a hint for that menu, never a plan: the scraper walks
// until the pages run out, and `pages: null` means the site simply does not say.
console.log('\npagination report');

let pages = JSON.parse(scrape({}, {
  api: true,
  pagination: { links: ['/auction?page=1', '/auction?page=2', '/auction?page=24'] }
}).pagination());
check(pages.pages === 24, 'the highest numbered page link is the count', JSON.stringify(pages));
check(pages.source.indexOf('numbered links') >= 0, 'and the report says where it read that', pages.source);
check(pages.hasNext === false, 'a listing with no next control has nothing after this page');

// A "recently viewed" strip one column over carries a much larger page number: the count has to come
// from the catalogue's own pagination, not from whichever address happens to be biggest.
pages = JSON.parse(scrape({}, {
  api: true,
  pagination: { links: ['/auction?page=2'] },
  strayLinks: ['/auction?page=99']
}).pagination());
check(pages.pages === 2, 'a page number outside the pagination does not inflate the count',
  JSON.stringify(pages));

pages = JSON.parse(scrape({}, {
  api: true,
  pagination: { attrs: { 'aria-label': 'Pagination' }, links: ['/auction/page/7'] }
}).pagination());
check(pages.pages === 7, 'a path-shaped page address is read as well', JSON.stringify(pages));

pages = JSON.parse(scrape({}, { api: true, pagination: { text: 'Page 1 of 24' } }).pagination());
check(pages.pages === 24, 'with no numbers in the links, the "Page 1 of 24" it prints is used',
  JSON.stringify(pages));

pages = JSON.parse(scrape({}, { api: true, pagination: { text: 'Showing 1-24 of 480 lots' } }).pagination());
check(pages.pages === 20, 'and a result range is turned into a page count', JSON.stringify(pages));

pages = JSON.parse(scrape({}, {
  api: true,
  pagination: { next: '/auction?page=2' }
}).pagination());
check(pages.pages === null, 'a site that only offers "next" reports no count at all', JSON.stringify(pages));
check(pages.hasNext === true, 'but says there is a page after this one', JSON.stringify(pages));
check(pages.source.length > 0, 'and still explains itself in the log', pages.source);

pages = JSON.parse(scrape({}, { api: true }).pagination());
check(pages.pages === null && pages.hasNext === false,
  'a listing with no pagination at all reports nothing', JSON.stringify(pages));

pages = JSON.parse(scrape({}, {
  api: true,
  pagination: { links: ['/auction?p=9999', '/auction?page=99999'] }
}).pagination());
check(pages.pages === null,
  'neither a bare "?p=" nor an impossible page number is read as a count', JSON.stringify(pages));

// ---- the address of a later page --------------------------------------------
//
// The walk is by address: page 2 is `?page=2`, page 3 is `?page=3`, until a page comes back with no
// lots on it. The app builds those addresses itself, but a listing that *prints* them — a numbered
// strip, a "next" link — is asked in its own words first, because that is the only thing that covers a
// path-shaped pagination (`/page/4`) the app could never guess. These checks pin both halves: the
// address a listing prints, and the parameter name the app rewrites when it prints nothing.
console.log('\npage addresses');

let pageApi = scrape({}, {
  api: true,
  pagination: { links: ['/auction?page=1', '/auction?page=2', '/auction?page=24'] }
});
check(pageApi.pageAddress(2) === 'https://example.test/auction?page=2',
  'the address a page link points at is handed over absolute', pageApi.pageAddress(2));
check(pageApi.pageAddress(24) === 'https://example.test/auction?page=24',
  'for any page the strip prints', pageApi.pageAddress(24));
check(pageApi.pageAddress(3) === null,
  'a page the strip never printed has no address, and the app rewrites its own', pageApi.pageAddress(3));

// A "next"-only listing: its control *is* the address of the page after this one, which is what makes
// the fallback path unnecessary on most sites.
pageApi = scrape({}, { api: true, pagination: { next: '/auction?page=2' } });
check(pageApi.pageAddress(2) === 'https://example.test/auction?page=2',
  'a "next" link is the next page\'s address', pageApi.pageAddress(2));
check(pageApi.pageAddress(3) === null, 'and says nothing about the page after that');

// A "related auctions" strip one column over carries page numbers of its own. Following one would walk
// a different catalogue's lots into the table, so only addresses for the listing being read are used.
pageApi = scrape({}, {
  api: true,
  pagination: { links: ['/auction?page=2'] },
  strayLinks: ['/other-catalog/57?page=2']
});
check(pageApi.pageAddress(2) === 'https://example.test/auction?page=2',
  'a neighbouring listing\'s page link is not mistaken for this one\'s', pageApi.pageAddress(2));

pageApi = scrape({}, {
  api: true,
  strayLinks: ['/other-catalog/57?page=2']
});
check(pageApi.pageAddress(2) === null,
  'and with none of its own, the neighbouring address is refused outright', pageApi.pageAddress(2));

// A path-shaped pagination — `/page/4` — has no parameter for the app to rewrite, so the address the
// strip prints is the only way to follow it, and it is recognised as this listing's.
pageApi = scrape({}, {
  api: true,
  pagination: { attrs: { 'aria-label': 'Pagination' }, links: ['/auction/page/3'] }
});
check(pageApi.pageAddress(3) === 'https://example.test/auction/page/3',
  'a path-shaped page address for the same listing is handed over', pageApi.pageAddress(3));

// The name the app must rewrite, read off the listing's own links.
pageApi = scrape({}, { api: true, pagination: { links: ['/auction?paged=9'] } });
let shape = JSON.parse(pageApi.pagination());
check(shape.parameter === 'paged',
  'the parameter the listing numbers its pages with is reported to the app', JSON.stringify(shape));

shape = JSON.parse(scrape({}, {
  api: true,
  pagination: { links: ['/auction?page=2'] }
}).pagination());
check(shape.parameter === 'page', 'the ordinary name is reported like any other', JSON.stringify(shape));

// A path-shaped pagination carries no parameter name at all: there is nothing to rewrite, so the app
// walks the addresses the strip prints and stops at the count it read from the same strip.
shape = JSON.parse(scrape({}, {
  api: true,
  pagination: { attrs: { 'aria-label': 'Pagination' }, links: ['/auction/page/7'] }
}).pagination());
check(shape.pages === 7 && shape.parameter === null,
  'a path-shaped pagination reports its count but no parameter to rewrite', JSON.stringify(shape));

// ---- lot page reading -------------------------------------------------------
//
// What a scan actually sends: the photographs on the lot's *own* page, however many that is. The
// listing only ever carries thumbnails, so this is the half of the rule that decides the count —
// there is no `Images / lot` setting left to argue with.
//
// The page is not the lot, though. A lot page also carries the site's logo, its promotion carousel,
// a "recently viewed" rail and the neighbouring lots a footer links to, and a vision model asked to
// price a promotion banner will price it. So only the containers the profile names are read — the
// main frame (`.auc_slide.left`) and the thumbnail strip (`ul.mediaThumbnails`) — and the fixture
// deliberately puts look-alike junk *outside* them: a header logo, a promo background, a
// "recently viewed" photograph, a `og:image` meta and a JSON-LD blob. None of the last two is a
// gallery, and both are what a JavaScript-rendered gallery falls back to, so each is exercised where
// it belongs: ignored here, used on the page that has no gallery markup at all.
//
// The fixture deliberately serves the gallery from a different host than the listing
// (`lots.example.test` vs `example.test`), because a relative `/img/...` must resolve against the
// page it was fetched *from*: joining it onto the listing's address is a silent 404.
const galleryHTML = [
  '<html><head>',
  '<meta property="og:image" content="https://cdn.example.test/og/208.jpg">',
  '<link rel="image_src" href="/img/208-lead.jpg">',
  '<script type="application/ld+json">',
  '{"@type":"Product","image":["https://cdn.example.test/json/208.jpg","https://cdn.example.test/json/208-2.jpg"]}',
  '</script>',
  '</head><body>',
  '<img class="site-logo" src="/img/logo.png">',
  '<div class="promo" style="background-image:url(/img/promo-banner.jpg)"></div>',
  '<div class="auc_slide left">',
  '<img src="/img/208-1-thumb.jpg">',
  '<img data-src="/img/208-2-thumb.jpg" src="">',
  '<img src="/img/spinner.svg">',
  '<img src="/img/placeholder.png">',
  '<picture><source srcset="/img/208-3-small.jpg 400w, /img/208-3-large.jpg 1200w"></picture>',
  '</div>',
  '<ul class="mediaThumbnails">',
  '<li><img src="/img/208-1-thumb.jpg"></li>',
  '<li><img src="/img/208-4-thumb.jpg"></li>',
  '<li><img data-src="/img/208-5-thumb.jpg" src=""></li>',
  '<li><img src="/img/208-6-thumb.jpg"></li>',
  '</ul>',
  '<div class="recently-viewed"><img src="/img/other-lot-99.jpg"></div>',
  '<div class="auc_info right">',
  '<div class="bid-box">Current bid: $640.00</div>',
  '<div class="active ins_cnt description-info-content">',
  '<h3 class="auc_title">Description</h3>',
  '<p>Lot 208 — a pallet of mixed kitchen appliances.</p>',
  '<p>Includes   6x Ninja BL610 blenders, UPC 622356528163, and 4x Instant Pot Duo 6qt.</p>',
  '</div>',
  '<div class="auc_ask">Ask a question</div>',
  '</div>',
  '</body></html>'
].join('');

(async function lotPageChecks() {
  console.log('\nlot page images');

  const page = scrape({}, { api: true, detail: { html: galleryHTML } });
  const report = JSON.parse(await page.lotPageImages('https://lots.example.test/auction/lot/208'));

  check(report.ok === true, 'the lot page is read', JSON.stringify(report.error));
  check(report.url === 'https://lots.example.test/auction/lot/208', 'and the report names the page it read', report.url);
  check(report.images.length === 6, "every photograph the lot's own gallery shows comes back",
    JSON.stringify(report.images));
  check(report.images.length > 4, 'uncapped: the card limit does not apply to a lot page',
    JSON.stringify(report.images.length));

  check(
    report.images.indexOf('https://lots.example.test/img/208-1.jpg') >= 0,
    'a relative address resolves against the lot page and has its thumbnail suffix stripped',
    JSON.stringify(report.images)
  );
  check(report.images.indexOf('https://lots.example.test/img/208-2.jpg') >= 0, 'a lazy-loaded photo is picked up too');
  check(report.images.indexOf('https://lots.example.test/img/208-3-large.jpg') >= 0, 'the widest srcset candidate wins');
  check(report.images.indexOf('https://lots.example.test/img/208-4.jpg') >= 0,
    'the thumbnail strip is read as well as the frame', JSON.stringify(report.images));
  check(report.images.indexOf('https://lots.example.test/img/208-6.jpg') >= 0, 'right to its last thumbnail');
  check(report.images.every(url => url.indexOf('spinner') < 0 && url.indexOf('placeholder') < 0),
    'the page spinner and the placeholder are left out', JSON.stringify(report.images));
  check(report.images.every(url => url.indexOf('http') === 0), 'and every address is absolute', JSON.stringify(report.images));

  // The page is not the lot: everything outside the gallery containers belongs to somebody else, and a
  // vision model asked to price a promotion banner will price it. These are the addresses the old
  // whole-page scan used to hand over — the site's logo, its promotion banner, a neighbouring lot, and
  // the lead image a page declares for social cards.
  const outside = ['logo.png', 'promo-banner.jpg', 'other-lot-99.jpg',
    'og/208.jpg', '208-lead.jpg', 'json/208.jpg', 'json/208-2.jpg'];
  check(report.images.every(url => outside.every(name => url.indexOf(name) < 0)),
    'nothing outside the gallery is sent', JSON.stringify(report.images));

  // The gallery is named twice — the frame is both `div.auc_slide.left` and `div.auc_slide`, the strip
  // is both `ul.mediaThumbnails` and `[class*='mediaThumbnails']` — and the strip repeats the frame's
  // first photograph, as real galleries do. None of that may double a photograph.
  check(new Set(report.images).size === report.images.length,
    'a container matched twice, and a photograph held in two containers, are still counted once',
    JSON.stringify(report.images));

  // The reported shape — lot 23 of catalogue 29 — and the count the operator saw: one frame showing a
  // photograph at a time over a strip of eight thumbnails, handed to the model as seventeen images.
  // Every photograph arrived three times (the frame's copy, the strip's thumbnail, and the full-size
  // copy the thumbnail *opens*), the site's own carousel — which reuses `auc_slide` — added another
  // lot's photograph, and the arrows beside the frame came along for the ride. What a scan is meant to
  // send is one address per photograph, at the size the viewer would open.
  //
  // The strip is *inside* the left column here, as it is on the site, so the column and the strip
  // overlap: the container the strip is named by must not be walked a second time.
  const carouselHTML = [
    '<html><body>',
    '<img class="site-logo" src="/img/logo.png">',
    '<div class="auc_slide right"><img src="/photos/other-lot-31.jpg"></div>',
    '<div class="auc_slide left">',
    '<a href="/photos/23-1.jpg?w=1800"><img src="/photos/23-1.jpg?w=1800"></a>',
    '<a href="#" class="next"><img src="/img/arrow-right.png"></a>',
    '<ul class="mediaThumbnails">',
    '<li><a href="/photos/large/23-1.jpg"><img src="/photos/thumb/23-1.jpg"',
    ' data-large_image="/photos/large/23-1.jpg"></a></li>',
    '<li><a href="/photos/large/23-2.jpg"><img src="/photos/thumb/23-2.jpg"></a></li>',
    '<li><a href="/photos/thumb/23-3.jpg"><img src="/photos/thumb/23-3.jpg"',
    ' data-large_image="/photos/large/23-3.jpg"></a></li>',
    '<li><a href="/photos/large/23-4.jpg"><img data-src="/photos/thumb/23-4.jpg" src=""></a></li>',
    '<li><img data-src="/photos/23-5_thumb.jpg?w=90" src=""></li>',
    '<li><a href="/photos/large/23-6.jpg"><img src="/photos/thumb/23-6.jpg"',
    ' srcset="/photos/thumb/23-6.jpg 400w, /photos/large/23-6.jpg 1200w"></a></li>',
    '<li><a href="/photos/23-7_thumb.jpg"><img src="/photos/23-7_thumb.jpg"></a></li>',
    '<li><a href="/photos/large/23-8.jpg"><img src="/photos/large/23-8.jpg"></a></li>',
    '</ul>',
    '</div>',
    '<div class="recently-viewed"><img src="/photos/lot-99.jpg"></div>',
    '</body></html>'
  ].join('');

  const carousel = JSON.parse(
    await scrape({}, { api: true, detail: { html: carouselHTML } })
      .lotPageImages('https://lots.example.test/auction/lot/23')
  );
  const album = [
    'https://lots.example.test/photos/large/23-1.jpg',
    'https://lots.example.test/photos/large/23-2.jpg',
    'https://lots.example.test/photos/large/23-3.jpg',
    'https://lots.example.test/photos/large/23-4.jpg',
    'https://lots.example.test/photos/23-5.jpg',
    'https://lots.example.test/photos/large/23-6.jpg',
    'https://lots.example.test/photos/23-7.jpg',
    'https://lots.example.test/photos/large/23-8.jpg'
  ];
  check(carousel.ok === true && carousel.images.length === 8,
    'eight photographs on the page are eight images, not seventeen', JSON.stringify(carousel.images));
  check(carousel.images.join(' ') === album.join(' '),
    'in gallery order, at the address each thumbnail opens', JSON.stringify(carousel.images));
  check(carousel.images.indexOf('https://lots.example.test/photos/large/23-3.jpg') >= 0,
    'a thumbnail whose link is small and whose data-large_image is full is sent at full size',
    JSON.stringify(carousel.images));
  check(carousel.images.every(url => url.indexOf('thumb') < 0 && url.indexOf('w=') < 0),
    'no thumbnail copy and no resized copy of a photograph is sent', JSON.stringify(carousel.images));
  check(carousel.images.every(url => url.indexOf('arrow') < 0),
    "the carousel's own arrows sit inside the column and are still not photographs",
    JSON.stringify(carousel.images));
  check(carousel.images.every(url => url.indexOf('other-lot') < 0),
    'and the site\'s own carousel, classed `auc_slide`, is not read as this lot\'s gallery',
    JSON.stringify(carousel.images));

  // The live layout, copied off the site: one photograph printed under one name at three sizes — a
  // 56×100 `_s` in the strip, a 281×500 `_l` the frame shows and that the anchor also carries as
  // `data-image`, and the 720×1280 `_xl` the thumbnail *opens* — with a cache-busting `?ts=` that
  // differs between the copies of one photograph and between photographs. A Magic Zoom frame names the
  // first photograph again, and the arrows live inside the very column the gallery is read from.
  const strip = [
    ['112175', '1790278593', '1790278592', '1790278592'],
    ['112176', '1790278593', '1790278593', '1790278593'],
    ['112177', '1790278594', '1790278594', '1790278594'],
    ['112178', '1790278595', '1790278595', '1790278595'],
    ['112179', '1790278596', '1790278596', '1790278596'],
    ['112180', '1790278597', '1790278597', '1790278596'],
    ['112181', '1790278597', '1790278597', '1790278597'],
    ['112182', '1790278598', '1790278598', '1790278598'],
    ['112183', '1790278599', '1790278599', '1790278599'],
    ['112184', '1790278600', '1790278599', '1790278599'],
    ['112185', '1790278600', '1790278600', '1790278600']
  ];
  const lotFolder = 'https://bids.palletauctions.com/images/lot/1121/';
  const thumbnails = strip.map(function (photo) {
    return '<li><a data-zoom-id="Zoom-1" class="image-thumb-slide mz-thumb"'
      + ' href="' + lotFolder + photo[0] + '_xl.jpg?ts=' + photo[1] + '"'
      + ' data-image="' + lotFolder + photo[0] + '_l.jpg?ts=' + photo[2] + '">'
      + '<img src="' + lotFolder + photo[0] + '_s.jpg?ts=' + photo[3] + '" loading="lazy"></a></li>';
  }).join('');
  const magicZoomHTML = [
    '<html><head>',
    // A "recently viewed" rail, declared as data rather than markup: another lot, in its own folder.
    '<script>window.recentlyViewed = ["https://bids.palletauctions.com/images/lot/1187/118701_l.jpg?ts=8"];</script>',
    '</head><body>',
    '<div class="auc_slide left">',
    '<div id="Zoom-1" class="zoom"><a class="MagicZoom" href="' + lotFolder + '112175_xl.jpg?ts=1790278593">',
    '<img src="' + lotFolder + '112175_l.jpg?ts=1790278592"></a></div>',
    '<div class="carouselSlider"><ul class="mediaThumbnails">', thumbnails, '</ul></div>',
    '<a class="next" href="#"><img src="/images/arrow-next.png"></a>',
    '</div>',
    '<div class="auc_slide right"><img src="' + lotFolder + '112199_s.jpg?ts=7"></div>',
    '</body></html>'
  ].join('');

  const zoomed = JSON.parse(
    await scrape({}, { api: true, detail: { html: magicZoomHTML } })
      .lotPageImages('https://bids.palletauctions.com/auction/lot/1121')
  );
  const openedSizes = strip.map(photo => lotFolder + photo[0] + '_xl.jpg?ts=' + photo[1]);
  check(zoomed.ok === true && zoomed.images.length === 11,
    'eleven photographs under eleven names at three sizes are eleven images, not thirty-three',
    JSON.stringify(zoomed.images));
  check(zoomed.images.join(' ') === openedSizes.join(' '),
    'in strip order, at the `_xl` copy each thumbnail opens',
    JSON.stringify(zoomed.images));
  check(zoomed.images.every(url => url.indexOf('_s.jpg') < 0 && url.indexOf('_l.jpg') < 0),
    "the thumbnail's own size and the frame's copy of a photograph are not sent as well",
    JSON.stringify(zoomed.images));
  check(zoomed.note === '',
    'and a gallery the markup already held whole needs nothing from the page data', zoomed.note);

  // The strip on this site is built by its JavaScript, so the HTML a `fetch` returns can hold the frame
  // and an *empty* `ul.mediaThumbnails` — the addresses only exist in the data blob the script fills it
  // from. A lot's photographs share the lot's own folder, so those are taken; the logo in `/assets/` and
  // the neighbouring lot in `/lot/1187/` are not.
  const jsStripHTML = [
    '<html><head>',
    '<script>window.lotMedia = ["' + lotFolder + '112175_l.jpg?ts=1790278592",'
      + '"' + lotFolder + '112176_l.jpg?ts=1790278593",'
      + '"' + lotFolder + '112177_l.jpg?ts=1790278594",'
      + '"' + lotFolder + '112178_l.jpg?ts=1790278595",'
      + '"' + lotFolder + '112179_l.jpg?ts=1790278596",'
      + '"' + lotFolder + '112180_l.jpg?ts=1790278597",'
      + '"' + lotFolder + '112181_l.jpg?ts=1790278597",'
      + '"' + lotFolder + '112182_l.jpg?ts=1790278598",'
      + '"' + lotFolder + '112183_l.jpg?ts=1790278599",'
      + '"' + lotFolder + '112184_l.jpg?ts=1790278599",'
      + '"' + lotFolder + '112185_l.jpg?ts=1790278600",'
      + '"https://bids.palletauctions.com/assets/logo.png",'
      + '"https://bids.palletauctions.com/images/lot/1187/118701_l.jpg?ts=8"];</script>',
    '</head><body>',
    '<div class="auc_slide left">',
    '<a class="MagicZoom" href="' + lotFolder + '112175_xl.jpg?ts=1790278593">',
    '<img src="' + lotFolder + '112175_l.jpg?ts=1790278592"></a>',
    '<div class="carouselSlider"><ul class="mediaThumbnails"></ul></div>',
    '</div>',
    '</body></html>'
  ].join('');

  const built = JSON.parse(
    await scrape({}, { api: true, detail: { html: jsStripHTML } })
      .lotPageImages('https://bids.palletauctions.com/auction/lot/1121')
  );
  const expected = [lotFolder + '112175_xl.jpg?ts=1790278593'];
  for (let index = 1; index < strip.length; index += 1) {
    expected.push(lotFolder + strip[index][0] + '_l.jpg?ts=' + strip[index][2]);
  }
  check(built.ok === true && built.images.length === 11,
    'a strip the site builds in JavaScript is read from the page data it is built from',
    JSON.stringify(built.images));
  check(built.images.join(' ') === expected.join(' '),
    "the frame stays first and keeps the size it opens at; the rest arrive in the data blob's order",
    JSON.stringify(built.images));
  check(built.images.every(url => url.indexOf('/1187/') < 0 && url.indexOf('logo') < 0),
    "another lot's photographs and the site's logo live in their own folders and are left alone",
    JSON.stringify(built.images));
  check(built.note === 'the page data supplied 10 more photograph(s) than the gallery markup held',
    'and the log says where the extra photographs came from', built.note);

  // The description column: what the lot actually holds, rather than the card's teaser. The heading is
  // page furniture and the whitespace is the markup's, so both are cleaned off — and the column's other
  // furniture, the bid box and the "ask a question" form, must stay out of the copy.
  check(report.description === 'Lot 208 \u2014 a pallet of mixed kitchen appliances. '
    + 'Includes 6x Ninja BL610 blenders, UPC 622356528163, and 4x Instant Pot Duo 6qt.',
    'the description block is read whole, heading stripped and whitespace condensed',
    JSON.stringify(report.description));
  check(report.descriptionSelector === 'div.active.ins_cnt.description-info-content',
    'and the report names the rule that found it', report.descriptionSelector);
  check(report.description.indexOf('Current bid') < 0 && report.description.indexOf('Ask a question') < 0,
    "the column's other furniture is not mistaken for the copy", JSON.stringify(report.description));

  const request = page.__fetches[0];
  check(request && request.url === 'https://lots.example.test/auction/lot/208',
    'the read went to the lot page itself', request ? request.url : 'no request');
  check(request && request.init.credentials === 'same-origin',
    "with the session's cookies, because that is where the login lives");

  // Reading a lot page must not disturb the listing: the card's own extraction is unchanged.
  const stillScraping = JSON.parse(page.extractLots());
  check(stillScraping.lots[0].imageURLStrings.length === 1,
    'the listing on the page still scrapes exactly as before', JSON.stringify(stillScraping.lots[0].imageURLStrings));

  // A gallery built in JavaScript leaves no container to scope to, so *then* the page's declared lead
  // image and its data blobs are consulted, and the note says which of the two paths was taken.
  const declaredHTML = [
    '<html><head>',
    '<meta property="og:image" content="https://cdn.example.test/og/208.jpg">',
    '<script>window.__DATA = {"photos":["https://cdn.example.test/json/208.jpg"]};</script>',
    '</head><body><div class="auc_info right"><h3>Description</h3><p>Mixed appliances.</p></div></body></html>'
  ].join('');
  const declared = JSON.parse(
    await scrape({}, { api: true, detail: { html: declaredHTML } })
      .lotPageImages('https://lots.example.test/auction/lot/208')
  );
  check(declared.images.length === 2, 'with no gallery markup, the declared images are used',
    JSON.stringify(declared.images));
  check(declared.images.indexOf('https://cdn.example.test/og/208.jpg') >= 0
    && declared.images.indexOf('https://cdn.example.test/json/208.jpg') >= 0,
    'both the meta tag and the script blob', JSON.stringify(declared.images));
  check(typeof declared.note === 'string' && declared.note.indexOf('no gallery container') >= 0,
    'and the note explains that the gallery itself was never found', JSON.stringify(declared.note));
  check(declared.description === 'Mixed appliances.',
    'the description column is still read on a page with no gallery',
    JSON.stringify(declared.description));

  // The description ladder is a ladder: the column that contains the copy is the next rule up, so a
  // page whose own block carries no class still yields text rather than nothing.
  const columnHTML = [
    '<html><body><div class="auc_info right">',
    '<div class="bid-box">Current bid: $90.00</div>',
    '<div>Lot 300 \u2014 12x assorted power tools, untested.</div>',
    '</div></body></html>'
  ].join('');
  const fromColumn = JSON.parse(
    await scrape({}, { api: true, detail: { html: columnHTML } })
      .lotPageImages('https://lots.example.test/auction/lot/300')
  );
  check(fromColumn.description.indexOf('12x assorted power tools') >= 0,
    'a page with no named description block still yields its copy', JSON.stringify(fromColumn.description));
  check(fromColumn.descriptionSelector === 'div.auc_info.right',
    'from the column rule, named in the report', fromColumn.descriptionSelector);

  // A page that cannot be read is reported, never fatal: the scan then falls back to the card.
  const failing = scrape({}, { api: true, detail: { fails: 'Failed to fetch' } });
  const failed = JSON.parse(await failing.lotPageImages('https://lots.example.test/auction/lot/208'));
  check(failed.ok === false && failed.error === 'Failed to fetch', 'an unreachable page reports why', JSON.stringify(failed));
  check(failed.images.length === 0, 'and offers no images at all', JSON.stringify(failed.images));
  check(!failed.description, 'and no description to build a prompt from', JSON.stringify(failed.description));

  const missing = JSON.parse(
    await scrape({}, { api: true, detail: { status: 404 } })
      .lotPageImages('https://lots.example.test/auction/lot/404')
  );
  check(missing.ok === false && missing.error === 'HTTP 404', 'a 404 is named as such', JSON.stringify(missing));

  const blocked = JSON.parse(
    await scrape({}, { api: true, detail: { status: 200, type: 'application/pdf' } })
      .lotPageImages('https://lots.example.test/auction/lot/208')
  );
  check(blocked.ok === false && blocked.error.indexOf('not a web page') >= 0,
    'a challenge or error document is refused rather than parsed', JSON.stringify(blocked));

  const junk = JSON.parse(await scrape({}, { api: true }).lotPageImages('javascript:void 0'));
  check(junk.ok === false && junk.error === 'unusable lot page address',
    'an unusable address never reaches the page', JSON.stringify(junk));

  const empty = JSON.parse(
    await scrape({}, { api: true, detail: { html: '<html><body><p>Empty</p></body></html>' } })
      .lotPageImages('https://lots.example.test/auction/lot/208')
  );
  check(empty.ok === true && empty.images.length === 0, 'a page with no photographs answers with none', JSON.stringify(empty));
  check(typeof empty.note === 'string' && empty.note.length > 0,
    'and says so, instead of looking like a failure', JSON.stringify(empty.note));
  check(empty.description === '' && empty.descriptionSelector === '',
    'as does a page with no description column', JSON.stringify(empty));

  console.log(failures.length === 0 ? '\nPAGE-SIDE CHECKS PASSED' : '\n' + failures.length + ' PAGE-SIDE CHECK(S) FAILED');
  process.exit(failures.length === 0 ? 0 : 1);
})();
