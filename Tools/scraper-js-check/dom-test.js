'use strict';
//
//  dom-test.js
//  Drives the injected scraper script (ScraperScript.swift) against a tiny DOM shim, so the rules
//  that turn a card into a lot number can be checked without a browser, a network or an auction
//  site. Run it through Tools/scraper-js-check/run.sh, which compiles the Swift side and hands the
//  generated JavaScript to this file.
//
//  The shim models only what the scraper touches: `querySelectorAll` with simple selectors (tag,
//  `[attr]`, `[attr*=value]`, `[attr^=value]`, `[attr=value]`, with the ` i` flag), `getAttribute`,
//  `textContent`, `closest` (always null) and `addEventListener` (a no-op). Descendant selectors are
//  not modelled and deliberately match nothing — the card selectors the profile tries first are
//  simple ones, so the card under test is always found.
//
const fs = require('fs');
// The generated script comes from run.sh (or from the environment); `--debug` is a flag, not a path.
const scriptPath = process.env.SCRAPER_JS
  || process.argv.slice(2).find(argument => argument.charAt(0) !== '-')
  || '/tmp/scraper.js';

// ---- a very small DOM, only what the scraper touches -------------------------
function matches(el, part) {
  const m = part.match(/^([a-zA-Z]*)((?:\[[^\]]*\])*)$/);
  if (!m) return false;
  const tag = m[1].toLowerCase();
  if (tag && el.tag.toLowerCase() !== tag) return false;
  const conds = m[2] ? m[2].match(/\[[^\]]*\]/g) || [] : [];
  for (const raw of conds) {
    const inner = raw.slice(1, -1).replace(/\s+i$/, '');
    const eq = inner.match(/^([\w-]+)\s*(?:([*^$~|]?)=\s*['"]?([^'"\]]*)['"]?)?$/);
    if (!eq) return false;
    const attr = eq[1];
    const op = eq[2];
    const value = eq[3];
    const actual = el.attrs[attr];
    if (actual === undefined) return false;
    if (op === undefined) continue;
    const hay = String(actual).toLowerCase();
    const needle = String(value).toLowerCase();
    if (op === '*' && hay.indexOf(needle) < 0) return false;
    if (op === '^' && hay.indexOf(needle) !== 0) return false;
    if (op === '=' && hay !== needle) return false;
  }
  return true;
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
// card. Modelling that means handing the script something with `querySelectorAll` on it, so this
// turns the fixture markup into a flat `El` list. It reads every tag it finds (no nesting, which the
// image collector does not need), keeps the text of `<script>`/`<style>` so gallery JSON blobs can be
// checked, and understands quoted, single-quoted and bare attributes.
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

function parseHTML(html) {
  const root = new El('html', {}, '', []);
  const pattern = /<([a-zA-Z][\w-]*)((?:[^>"']|"[^"]*"|'[^']*')*?)(\/?)>/g;
  let match = pattern.exec(html);
  while (match) {
    const tag = match[1].toLowerCase();
    let text = '';
    if (match[3] !== '/' && (tag === 'script' || tag === 'style')) {
      const close = html.indexOf('</' + tag, pattern.lastIndex);
      text = html.slice(pattern.lastIndex, close < 0 ? html.length : close);
      pattern.lastIndex = close < 0 ? html.length : close;
    }
    root.kids.push(new El(tag, attrsOf(match[2]), text, []));
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
  '<img src="/img/208-1-thumb.jpg">',
  '<img data-src="/img/208-2-thumb.jpg" src="">',
  '<img src="/img/spinner.svg">',
  '<img src="/img/placeholder.png">',
  '<picture><source srcset="/img/208-3-small.jpg 400w, /img/208-3-large.jpg 1200w"></picture>',
  '<div style="background-image:url(/img/208-4-background.jpg)"></div>',
  '<a href="/img/208-5-full.jpg">open</a>',
  '</body></html>'
].join('');

(async function lotPageChecks() {
  console.log('\nlot page images');

  const page = scrape({}, { api: true, detail: { html: galleryHTML } });
  const report = JSON.parse(await page.lotPageImages('https://lots.example.test/auction/lot/208'));

  check(report.ok === true, 'the lot page is read', JSON.stringify(report.error));
  check(report.url === 'https://lots.example.test/auction/lot/208', 'and the report names the page it read', report.url);
  check(report.images.length === 9, 'every image the page mentions comes back', JSON.stringify(report.images));
  check(report.images.length > 4, 'uncapped: the card limit does not apply to a lot page', JSON.stringify(report.images.length));

  check(
    report.images.indexOf('https://lots.example.test/img/208-1.jpg') >= 0,
    'a relative address resolves against the lot page and has its thumbnail suffix stripped',
    JSON.stringify(report.images)
  );
  check(report.images.indexOf('https://lots.example.test/img/208-2.jpg') >= 0, 'a lazy-loaded photo is picked up too');
  check(report.images.indexOf('https://lots.example.test/img/208-3-large.jpg') >= 0, 'the widest srcset candidate wins');
  check(report.images.indexOf('https://lots.example.test/img/208-4-background.jpg') >= 0, 'a CSS background counts');
  check(report.images.indexOf('https://lots.example.test/img/208-5-full.jpg') >= 0, 'so does a link to an image');
  check(report.images.indexOf('https://cdn.example.test/og/208.jpg') >= 0, 'the page declares its lead image in a meta tag');
  check(report.images.indexOf('https://lots.example.test/img/208-lead.jpg') >= 0, 'and in a link tag');
  check(report.images.indexOf('https://cdn.example.test/json/208.jpg') >= 0, 'a gallery declared in a JSON blob is read');
  check(report.images.indexOf('https://cdn.example.test/json/208-2.jpg') >= 0, 'including its second photograph');
  check(report.images.every(url => url.indexOf('spinner') < 0 && url.indexOf('placeholder') < 0),
    'the page spinner and the placeholder are left out', JSON.stringify(report.images));
  check(report.images.every(url => url.indexOf('http') === 0), 'and every address is absolute', JSON.stringify(report.images));

  const request = page.__fetches[0];
  check(request && request.url === 'https://lots.example.test/auction/lot/208',
    'the read went to the lot page itself', request ? request.url : 'no request');
  check(request && request.init.credentials === 'same-origin',
    "with the session's cookies, because that is where the login lives");

  // Reading a lot page must not disturb the listing: the card's own extraction is unchanged.
  const stillScraping = JSON.parse(page.extractLots());
  check(stillScraping.lots[0].imageURLStrings.length === 1,
    'the listing on the page still scrapes exactly as before', JSON.stringify(stillScraping.lots[0].imageURLStrings));

  // A page that cannot be read is reported, never fatal: the scan then falls back to the card.
  const failing = scrape({}, { api: true, detail: { fails: 'Failed to fetch' } });
  const failed = JSON.parse(await failing.lotPageImages('https://lots.example.test/auction/lot/208'));
  check(failed.ok === false && failed.error === 'Failed to fetch', 'an unreachable page reports why', JSON.stringify(failed));
  check(failed.images.length === 0, 'and offers no images at all', JSON.stringify(failed.images));

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

  console.log(failures.length === 0 ? '\nPAGE-SIDE CHECKS PASSED' : '\n' + failures.length + ' PAGE-SIDE CHECK(S) FAILED');
  process.exit(failures.length === 0 ? 0 : 1);
})();
