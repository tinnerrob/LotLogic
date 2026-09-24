//
//  ScraperScript.swift
//  PalletAuctionBidTool
//
//  The DOM-automation script injected into the hidden WKWebView.
//

import Foundation

/// Builds the JavaScript that drives the auction site inside the hidden `WKWebView`.
///
/// Design notes
/// * Everything hangs off a single `window.__PAS` namespace, so nothing leaks into the page.
/// * Every public function returns a **JSON string**. That keeps the Swift side to a single
///   decoding path (`String` -> `Decodable`) and sidesteps `WKScriptMessageHandler`'s
///   implicit type coercion of dictionaries/arrays.
/// * No selector is hard-coded: the entire `ScrapeProfile` is injected as `CONFIG`, so
///   retargeting to another liquidation site is a data change, not a code change.
enum ScraperScript {

    /// `WKScriptMessageHandler` name used to stream page-side diagnostics to Swift.
    static let logHandlerName = "palletLog"

    /// Full automation source with `profile` embedded as the `CONFIG` constant.
    static func source(profile: ScrapeProfile) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let configJSON = String(decoding: try encoder.encode(profile), as: UTF8.self)
        return template.replacingOccurrences(of: "__PAS_CONFIG__", with: configJSON)
    }

    // swiftlint:disable line_length
    private static let template = #"""
    (function () {
      'use strict';

      const CONFIG = Object.assign({}, __PAS_CONFIG__);
      const state = { page: 1, sweeping: false, submittedAt: 0, lastClick: null, installedAt: Date.now() };
      const pendingLogs = [];

      function log(message) {
        const text = String(message);
        pendingLogs.push(text);
        if (pendingLogs.length > 200) pendingLogs.shift();
        try { window.webkit.messageHandlers.palletLog.postMessage(text); } catch (error) { /* handler not registered */ }
      }

      // ---------------------------------------------------------------- helpers

      function each(root, selector) {
        try { return Array.prototype.slice.call(root.querySelectorAll(selector)); } catch (error) { return []; }
      }

      function textOf(element) {
        return element ? String(element.textContent || '').replace(/\s+/g, ' ').trim() : '';
      }

      function attributeOf(element, names) {
        if (!element || !names) return '';
        for (let index = 0; index < names.length; index += 1) {
          const value = element.getAttribute(names[index]);
          if (value !== null && String(value).trim() !== '') return String(value).replace(/\s+/g, ' ').trim();
        }
        return '';
      }

      function firstElement(root, selectors) {
        for (let index = 0; index < selectors.length; index += 1) {
          const found = each(root, selectors[index])[0];
          if (found) return found;
        }
        return null;
      }

      function absolute(raw, base) {
        if (!raw) return null;
        const cleaned = String(raw).trim().replace(/^['"]|['"]$/g, '');
        if (!cleaned || cleaned.indexOf('data:') === 0 || cleaned.indexOf('blob:') === 0 || cleaned.indexOf('javascript:') === 0) return null;
        try {
          const url = new URL(cleaned, base || location.href);
          if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
          return url.href;
        } catch (error) { return null; }
      }

      // --------------------------------------------------- a lot's own page

      // What a *lot page* address cannot be: an in-page jump, a handler, an address that leaves the
      // web (mail, phone), or a file the browser downloads rather than renders. The site's own
      // furniture — a sign-in link, a wish-list button, a share sheet, the legal pages — is the
      // profile's business, since it differs per site: `nonLotHrefPattern`.
      const HREF_JUNK_PATTERN = /^(?:#|javascript:|mailto:|tel:|data:|blob:)/i;
      const HREF_ASSET_PATTERN = /\.(?:jpe?g|png|gif|webp|heic|avif|bmp|svg|ico|css|js|mjs|json|xml|pdf|zip|mp4|webm|mp3|wav|ogg|woff2?)(?:$|[?#])/i;
      const NON_LOT_HREF_PATTERN = (function () {
        try { return new RegExp(CONFIG.nonLotHrefPattern || '$^', 'i'); } catch (error) { return /$^/; }
      })();

      function pageHref(href) {
        const raw = String(href || '').trim();
        if (!raw) return null;
        if (HREF_JUNK_PATTERN.test(raw)) return null;
        if (HREF_ASSET_PATTERN.test(raw)) return null;
        if (NON_LOT_HREF_PATTERN.test(raw)) return null;
        return raw;
      }

      // Does this address name this lot? `/auction/lot/19002?v=2` does, `/auction/lot/190021` does
      // not. Used the other way round from `lotNumberFromURL`: there the address tells us the number,
      // here the number tells us which of a card's addresses is the lot's own.
      function urlCarriesLotNumber(url, lotNumber) {
        const token = String(lotNumber || '').replace(/[^0-9a-zA-Z]/g, '').toLowerCase();
        if (token.length < 3) return false;
        const text = String(url || '');
        // The cheap test first: both ways of matching below need the number's characters in the
        // address somewhere, and a page-wide search asks this of *every* anchor on the page.
        if (text.toLowerCase().indexOf(token) < 0) return false;
        const parts = text.split(/[^0-9a-zA-Z]+/);
        for (let index = 0; index < parts.length; index += 1) {
          const part = parts[index].toLowerCase();
          if (!part) continue;
          if (part === token) return true;
          // A site may glue a word onto the number (`item19002`). Only trusted when the number is
          // long enough to be evidence on its own, and never when the extra characters are digits —
          // those are a different number, not a decorated one.
          if (token.length >= 5 && part.indexOf(token) >= 0 && !/[0-9]/.test(part.replace(token, ''))) return true;
        }
        return false;
      }

      // The best address one level of the markup offers. A level only ever volunteers its first
      // usable anchor when it *is* the card (`allowAny`): one level up, a grid's first anchor is
      // some other lot's page, which would put the wrong row in the operator's browser.
      function bestAnchorIn(scope, lotNumber, allowAny) {
        const anchors = each(scope, 'a[href]');
        let fallback = null;
        for (let index = 0; index < anchors.length; index += 1) {
          const target = absolute(pageHref(anchors[index].getAttribute('href')));
          if (!target) continue;
          if (lotNumber && urlCarriesLotNumber(target, lotNumber)) return target;
          if (allowAny && fallback === null) fallback = target;
        }
        return fallback;
      }

      // The lot's own page, as the listing itself declares it. Four sources, best first:
      //
      //   1. an anchor the profile names (`detailLinkSelectors`) — a site that has a class for this
      //      says so, and naming it beats guessing;
      //   2. the card's own first usable anchor — the ordinary tile-that-is-a-link;
      //   3. the anchor the card *lives in*: a matched card is often the inner body of a tile whose
      //      link wraps the whole thing, which is where the address actually is;
      //   4. any anchor whose address carries the lot number — first around the card, then anywhere
      //      on the page. This is what puts an **Open** button on a listing whose cards are not
      //      links themselves (`<div onclick>`, a JS router): the number the card prints is in the
      //      address of the page it belongs to, and that address is in the listing.
      //
      // Source 4 needs the lot number, and the lot number can be derived from source 2 — hence the
      // two passes in `readCard`: the address first for what it says, then again for what it holds.
      function detailLink(element, lotNumber) {
        const namedSelectors = CONFIG.detailLinkSelectors || [];
        const named = firstElement(element, namedSelectors);
        if (named) {
          const target = absolute(pageHref(named.getAttribute ? named.getAttribute('href') : null));
          if (target) return target;
        }

        let node = element;
        for (let depth = 0; node && depth < 5; depth += 1, node = node.parentElement) {
          if (depth === 0) {
            const own = bestAnchorIn(node, lotNumber, true);
            if (own) return own;
            continue;
          }
          const anchors = each(node, 'a[href]');
          for (let index = 0; index < anchors.length; index += 1) {
            const target = absolute(pageHref(anchors[index].getAttribute('href')));
            if (!target) continue;
            if (anchors[index].contains(element)) return target;
            if (lotNumber && urlCarriesLotNumber(target, lotNumber)) return target;
          }
        }

        return lotNumber ? bestAnchorIn(document, lotNumber, false) : null;
      }

      function isVisible(element) {
        if (!element) return false;
        // A test shim (see Tools/scraper-js-check) models the DOM without layout, so a missing
        // `getBoundingClientRect` must not read as "hidden".
        if (typeof element.getBoundingClientRect !== 'function') return true;
        const rect = element.getBoundingClientRect();
        if (rect.width <= 1 || rect.height <= 1) return false;
        const style = window.getComputedStyle(element);
        if (!style) return true;
        return style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
      }

      function isDisabled(element) {
        if (!element) return true;
        if (element.disabled === true) return true;
        const aria = element.getAttribute('aria-disabled');
        return aria === 'true';
      }

      function describe(element) {
        if (!element) return 'null';
        const tag = element.tagName ? element.tagName.toLowerCase() : 'node';
        const id = element.id ? '#' + element.id : '';
        let classes = '';
        if (element.className && typeof element.className === 'string') {
          classes = element.className.trim().split(/\s+/).slice(0, 2).map(function (name) { return '.' + name; }).join('');
        }
        const name = element.getAttribute && element.getAttribute('name') ? '[name="' + element.getAttribute('name') + '"]' : '';
        return (tag + id + classes + name).slice(0, 80);
      }

      // ------------------------------------------------------------ form filling

      function dispatch(element, type) {
        try { element.dispatchEvent(new Event(type, { bubbles: true, cancelable: true, composed: true })); }
        catch (error) {
          try { element.dispatchEvent(new Event(type, { bubbles: true })); } catch (innerError) { /* give up */ }
        }
      }

      function setNativeValue(element, value) {
        const prototype = element.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
        let descriptor = null;
        try { descriptor = Object.getOwnPropertyDescriptor(prototype, 'value'); } catch (error) { descriptor = null; }
        if (descriptor && descriptor.set) descriptor.set.call(element, value);
        else element.value = value;
      }

      // Writes a value the way a human would, which keeps React/Vue/Angular bindings in sync.
      function fillElement(element, value) {
        try { element.focus(); } catch (error) { /* not focusable */ }
        setNativeValue(element, '');
        dispatch(element, 'input');
        setNativeValue(element, value);
        dispatch(element, 'input');
        dispatch(element, 'change');
        dispatch(element, 'keyup');
        try { element.setAttribute('data-pas-filled', '1'); } catch (error) { /* read-only */ }
        return String(element.value || '') === String(value);
      }

      function inputByLabel(patterns) {
        const labels = each(document, 'label');
        for (let index = 0; index < labels.length; index += 1) {
          const label = labels[index];
          const text = textOf(label).toLowerCase();
          if (!text) continue;
          let matches = false;
          for (let patternIndex = 0; patternIndex < patterns.length; patternIndex += 1) {
            if (patterns[patternIndex].test(text)) { matches = true; break; }
          }
          if (!matches) continue;
          let target = null;
          const forAttribute = label.getAttribute('for');
          if (forAttribute) {
            try { target = document.getElementById(forAttribute); } catch (error) { target = null; }
          }
          if (!target) target = firstElement(label, ['input', 'textarea']);
          if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA')) return target;
        }
        return null;
      }

      function isFillable(field) {
        if (!field) return false;
        if (field.tagName !== 'INPUT' && field.tagName !== 'TEXTAREA') return false;
        const type = String(field.getAttribute('type') || 'text').toLowerCase();
        if (type === 'hidden' || type === 'checkbox' || type === 'radio' || type === 'submit' || type === 'button' || type === 'file') return false;
        if (field.readOnly) return false;
        return true;
      }

      function findField(selectors, requireVisible) {
        for (let index = 0; index < selectors.length; index += 1) {
          const candidates = each(document, selectors[index]);
          for (let candidateIndex = 0; candidateIndex < candidates.length; candidateIndex += 1) {
            const candidate = candidates[candidateIndex];
            if (!isFillable(candidate)) continue;
            if (requireVisible !== false && !isVisible(candidate)) continue;
            return candidate;
          }
        }
        return null;
      }

      function passwordField() {
        return findField(CONFIG.loginPasswordSelectors, false) || inputByLabel([/pass ?word/, /pass ?code/, /pass ?phrase/]);
      }

      function emailField() {
        return findField(CONFIG.loginEmailSelectors, false) || inputByLabel([/e-?mail/, /user ?name/, /user ?id/, /login/, /account/]);
      }

      function hasLoginForm() {
        if (passwordField()) return true;
        if (inputByLabel([/pass ?word/])) return true;
        for (let index = 0; index < CONFIG.loginFormSelectors.length; index += 1) {
          if (each(document, CONFIG.loginFormSelectors[index]).length > 0) return true;
        }
        return false;
      }

      function fillLogin(payloadString) {
        let payload = {};
        try { payload = JSON.parse(payloadString); } catch (error) { return JSON.stringify({ ok: false, error: 'invalid-payload' }); }
        const email = String(payload.email || '');
        const password = String(payload.password || '');
        const emailTarget = emailField();
        const passwordTarget = passwordField();
        if (!emailTarget) return JSON.stringify({ ok: false, error: 'email-field-not-found' });
        if (!passwordTarget) return JSON.stringify({ ok: false, error: 'password-field-not-found' });
        const emailFilled = fillElement(emailTarget, email);
        const passwordFilled = fillElement(passwordTarget, password);
        log('filled ' + describe(emailTarget) + '=' + emailFilled + ' ' + describe(passwordTarget) + '=' + passwordFilled);
        return JSON.stringify({
          ok: emailFilled && passwordFilled,
          emailField: describe(emailTarget),
          passwordField: describe(passwordTarget),
          emailFilled: emailFilled,
          passwordFilled: passwordFilled
        });
      }

      function submitLogin() {
        for (let index = 0; index < CONFIG.loginSubmitSelectors.length; index += 1) {
          const candidates = each(document, CONFIG.loginSubmitSelectors[index]);
          for (let candidateIndex = 0; candidateIndex < candidates.length; candidateIndex += 1) {
            const candidate = candidates[candidateIndex];
            if (!isVisible(candidate) || isDisabled(candidate)) continue;
            const label = (textOf(candidate) + ' ' + attributeOf(candidate, ['value', 'name', 'id', 'aria-label'])).toLowerCase();
            if (/(sign ?up|register|create account|forgot|reset|cancel|close|dismiss)/.test(label)) continue;
            const affirmative = /(log ?in|sign ?in|submit|continue|enter|access)/.test(label);
            const isSubmitControl = candidate.tagName === 'BUTTON' || String(candidate.getAttribute('type') || '').toLowerCase() === 'submit';
            if (!affirmative && !isSubmitControl) continue;
            try { candidate.scrollIntoView({ block: 'center' }); } catch (error) { /* ignore */ }
            candidate.click();
            state.submittedAt = Date.now();
            log('submit via ' + describe(candidate));
            return JSON.stringify({ ok: true, via: 'control', control: describe(candidate), label: label.slice(0, 60) });
          }
        }
        const target = passwordField();
        if (target && target.form && typeof target.form.requestSubmit === 'function') {
          try {
            target.form.requestSubmit();
            state.submittedAt = Date.now();
            log('submit via form.requestSubmit()');
            return JSON.stringify({ ok: true, via: 'requestSubmit' });
          } catch (error) { log('requestSubmit failed: ' + String(error)); }
        }
        if (target) {
          try { target.focus(); } catch (error) { /* ignore */ }
          ['keydown', 'keypress', 'keyup'].forEach(function (type) {
            try {
              target.dispatchEvent(new KeyboardEvent(type, { bubbles: true, cancelable: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 }));
            } catch (error) { /* ignore */ }
          });
          state.submittedAt = Date.now();
          log('submit via Enter key');
          return JSON.stringify({ ok: true, via: 'enter-key' });
        }
        return JSON.stringify({ ok: false, error: 'submit-control-not-found' });
      }

      function isAuthenticated() {
        for (let index = 0; index < CONFIG.authenticatedSelectors.length; index += 1) {
          if (each(document, CONFIG.authenticatedSelectors[index]).length > 0) return true;
        }
        if (state.submittedAt > 0 && !hasLoginForm() && Date.now() - state.submittedAt > 600) return true;
        return false;
      }

      function manualCheck() {
        for (let index = 0; index < CONFIG.manualVerificationSelectors.length; index += 1) {
          const candidates = each(document, CONFIG.manualVerificationSelectors[index]);
          for (let candidateIndex = 0; candidateIndex < candidates.length; candidateIndex += 1) {
            if (isVisible(candidates[candidateIndex])) {
              return JSON.stringify({
                required: true,
                selector: CONFIG.manualVerificationSelectors[index],
                element: describe(candidates[candidateIndex])
              });
            }
          }
        }
        const stalled = hasLoginForm() && state.submittedAt > 0 && Date.now() - state.submittedAt > 3000;
        return JSON.stringify({ required: false, selector: '', stalledLoginForm: stalled });
      }

      // ---------------------------------------------------- image normalisation

      function bestFromSrcset(value) {
        if (!value) return null;
        const parts = String(value).split(',').map(function (part) { return part.trim(); }).filter(Boolean);
        let best = null;
        let bestScore = -1;
        for (let index = 0; index < parts.length; index += 1) {
          const tokens = parts[index].split(/\s+/);
          const candidate = tokens[0];
          const descriptor = tokens[1] || '';
          let score = 100;
          if (/^\d+w$/.test(descriptor)) score = parseInt(descriptor, 10);
          else if (/^\d+(\.\d+)?x$/.test(descriptor)) score = parseFloat(descriptor) * 1000;
          if (score > bestScore) { bestScore = score; best = candidate; }
        }
        return best;
      }

      // CDN thumbnails are frequently useless to a vision model, so strip the obvious
      // resizing/cropping parameters and swap thumbnail folders for full size ones.
      function upgradeImageURL(raw, base) {
        if (!raw) return raw;
        try {
          const parsed = new URL(raw, base || location.href);
          const noise = ['width', 'w', 'height', 'h', 'size', 'quality', 'q', 'fit', 'resize', 'crop', 'dpr', 'auto', 'format', 'thumbnail'];
          for (let index = 0; index < noise.length; index += 1) {
            try { parsed.searchParams.delete(noise[index]); } catch (error) { /* ignore */ }
          }
          let url = parsed.href;
          if (parsed.search === '' || parsed.search === '?') url = parsed.href.replace(/\?$/, '');
          url = url.replace(/\/(thumb|thumbs|thumbnail|thumbnails|small|mini)\//i, '/large/');
          url = url.replace(/[_-]thumb(nail)?(?=\.)/i, '');
          url = url.replace(/[_-]\d{2,4}x\d{2,4}(?=\.(jpe?g|png|webp|gif|heic))/i, '');
          url = url.replace(/[_-](small|sm|md|medium|preview|listing)(?=\.(jpe?g|png|webp|gif|heic))/i, '');
          return url;
        } catch (error) { return raw; }
      }

      // Every image address a root mentions, in the order it mentions them.
      //
      // - `root` is a card element or a whole parsed document.
      // - `base` is what relative addresses resolve against — the card's page, or the lot page that
      //   was fetched. Without it a gallery's `/images/12.jpg` would be joined onto the *listing's*
      //   address and 404.
      // - `extras` are further candidate addresses from outside the markup (a `og:image` meta, a URL
      //   inside a JSON blob), which go through the same junk filter and de-duplication.
      // - `uncapped` is the difference between a card and a lot's own page: a card's strip is bounded
      //   by `maxCardImages`, while a lot page is read in full because how many photographs a lot has
      //   is the lot's business, not a setting.
      function collectImages(root, base, extras, uncapped) {
        const urls = [];
        const seen = {};
        const ignored = /placeholder|spacer|blank\.|1x1|pixel\.(gif|png)|loading|spinner|no[-_]?image|sprite/i;
        const push = function (raw) {
          if (!raw) return;
          const resolved = absolute(upgradeImageURL(String(raw), base), base);
          if (!resolved || ignored.test(resolved)) return;
          if (seen[resolved] === true) return;
          seen[resolved] = true;
          urls.push(resolved);
        };
        const images = each(root, 'img');
        for (let imageIndex = 0; imageIndex < images.length; imageIndex += 1) {
          const image = images[imageIndex];
          for (let attributeIndex = 0; attributeIndex < CONFIG.imageAttributeCandidates.length; attributeIndex += 1) {
            const attribute = CONFIG.imageAttributeCandidates[attributeIndex];
            const value = image.getAttribute(attribute);
            if (!value) continue;
            if (attribute.toLowerCase().indexOf('srcset') >= 0) push(bestFromSrcset(value));
            else push(value);
          }
          if (String(image.getAttribute('src') || '').trim() === '') push(image.getAttribute('data-src'));
        }
        const sources = each(root, 'picture source, source[srcset], source[data-srcset]');
        for (let index = 0; index < sources.length; index += 1) {
          push(bestFromSrcset(sources[index].getAttribute('srcset') || sources[index].getAttribute('data-srcset')));
        }
        const styled = each(root, '[style*="background"]');
        for (let index = 0; index < styled.length; index += 1) {
          const declaration = styled[index].getAttribute('style') || '';
          const match = declaration.match(/url\(\s*['"]?([^'")]+)['"]?\s*\)/i);
          if (match) push(match[1]);
        }
        const anchors = each(root, 'a[href]');
        for (let index = 0; index < anchors.length; index += 1) {
          const href = anchors[index].getAttribute('href') || '';
          if (/\.(jpe?g|png|webp|heic|gif)(\?|$)/i.test(href)) push(href.split('?')[0]);
        }
        if (extras) {
          for (let index = 0; index < extras.length; index += 1) push(extras[index]);
        }
        if (uncapped) return urls;
        return urls.slice(0, Math.max(1, CONFIG.maxCardImages));
      }

      // ----------------------------------------------------------------- lot page

      // A card only ever carries thumbnails. The photographs worth appraising are the ones on the
      // lot's own page, and how many that is depends entirely on the lot: a single sealed pallet
      // may show two, a mixed one forty. So the page is read in full, uncapped, from *inside* the
      // loaded listing:
      //
      // * a same-origin `fetch` carries the operator's own session — cookies, and whatever the site
      //   handed out on the way in — which a second web view or a Swift-side `URLSession` would need
      //   a cookie copy to match;
      // * it costs one GET and no navigation, so the results page keeps its scroll position, its
      //   page number and the automation's own state;
      // * and the answer is parsed with `DOMParser` rather than navigated to, so a page that throws
      //   or blocks cannot take the run down with it.
      //
      // The answer is never assumed complete: a gallery that is built in JavaScript, a challenge
      // page and a 404 all parse into a document with no photographs in it, which comes back as an
      // empty list plus a note — the caller then falls back to the card's own thumbnails.
      const LOT_PAGE_IMAGE_PATTERN = /["'](https?:\/\/[^"'\s\\]+\.(?:jpe?g|png|webp|heic|gif)(?:\?[^"'\s\\]*)?)["']/gi;

      // Galleries are frequently declared only inside a data blob — a JSON-LD `image` array, a
      // Next.js `__NEXT_DATA__`, `window.__DATA` — where the addresses are strings in a document
      // rather than elements. Only quoted absolute http(s) addresses with a known image extension
      // are taken, and the same junk filter the markup scan uses still applies to them.
      function imageURLsInScripts(root) {
        const found = [];
        const scripts = each(root, 'script');
        for (let index = 0; index < scripts.length; index += 1) {
          const text = String(scripts[index].textContent || '');
          if (!text) continue;
          LOT_PAGE_IMAGE_PATTERN.lastIndex = 0;
          let match = LOT_PAGE_IMAGE_PATTERN.exec(text);
          while (match) {
            found.push(match[1]);
            match = LOT_PAGE_IMAGE_PATTERN.exec(text);
          }
        }
        return found;
      }

      // The addresses that are not in the markup: a page's declared lead image, then anything the
      // script blobs mention. Both are extras, so the markup scan stays the primary source.
      function lotPageExtraImages(document) {
        const extras = [];
        for (let index = 0; index < CONFIG.imageMetaSelectors.length; index += 1) {
          const metas = each(document, CONFIG.imageMetaSelectors[index]);
          for (let metaIndex = 0; metaIndex < metas.length; metaIndex += 1) {
            extras.push(attributeOf(metas[metaIndex], ['content', 'href']));
          }
        }
        const scripts = imageURLsInScripts(document);
        for (let index = 0; index < scripts.length; index += 1) extras.push(scripts[index]);
        return extras;
      }

      // Every image one lot's page mentions. Deliberately uncapped.
      function collectLotPageImages(document, base) {
        return collectImages(document, base, lotPageExtraImages(document), true);
      }

      // Reads one lot's own page. Resolves to a JSON string like every other public entry point, so
      // the Swift side keeps its single decode path; a page that cannot be read answers `ok:false`
      // with the reason instead of rejecting.
      function lotPageImages(url) {
        const target = absolute(url);
        if (!target) {
          return Promise.resolve(JSON.stringify({
            ok: false,
            url: String(url || ''),
            images: [],
            error: 'unusable lot page address'
          }));
        }
        const controller = typeof AbortController === 'function' ? new AbortController() : null;
        const timeout = Math.max(1, Number(CONFIG.lotPageTimeoutSeconds) || 20) * 1000;
        const timer = window.setTimeout(function () {
          if (controller) controller.abort();
        }, timeout);
        return fetch(target, {
          credentials: 'same-origin',
          headers: { Accept: 'text/html,application/xhtml+xml' },
          signal: controller ? controller.signal : undefined
        }).then(function (response) {
          if (!response || response.ok !== true) {
            throw new Error('HTTP ' + ((response && response.status) || '?'));
          }
          const type = String((response.headers && response.headers.get ? response.headers.get('content-type') : '') || '');
          if (type && /html/i.test(type) === false) throw new Error('not a web page (' + type + ')');
          return response.text();
        }).then(function (html) {
          const parsed = new DOMParser().parseFromString(String(html || ''), 'text/html');
          const images = collectLotPageImages(parsed, target);
          log('lot page ' + target + ': ' + images.length + ' image(s)');
          return JSON.stringify({
            ok: true,
            url: target,
            images: images,
            note: images.length === 0 ? 'the page carried no photographs' : ''
          });
        }).catch(function (error) {
          const message = String((error && error.message) || error);
          log('lot page ' + target + ' failed: ' + message);
          return JSON.stringify({ ok: false, url: target, images: [], error: message });
        }).then(function (result) {
          window.clearTimeout(timer);
          return result;
        });
      }

      // -------------------------------------------------------------- collection

      function isExcluded(element) {
        for (let index = 0; index < CONFIG.excludeCardSelectors.length; index += 1) {
          try { if (element.closest(CONFIG.excludeCardSelectors[index])) return true; }
          catch (error) { /* invalid selector, ignore */ }
        }
        return false;
      }

      function collectCards() {
        const elements = [];
        let winningSelector = '';
        for (let index = 0; index < CONFIG.cardSelectors.length; index += 1) {
          const selector = CONFIG.cardSelectors[index];
          const candidates = each(document, selector).filter(function (element) {
            if (isExcluded(element)) return false;
            return textOf(element).length >= CONFIG.minimumCardTextLength;
          });
          if (candidates.length === 0) continue;
          if (!winningSelector) winningSelector = selector;
          for (let candidateIndex = 0; candidateIndex < candidates.length; candidateIndex += 1) {
            if (elements.indexOf(candidates[candidateIndex]) < 0) elements.push(candidates[candidateIndex]);
          }
          if (CONFIG.stopAtFirstMatchingSelector) break;
        }
        return { selector: winningSelector, elements: elements };
      }

      // -------------------------------------------------------------- extraction

      function normalizeLotNumber(raw, cardText) {
        const pattern = new RegExp(CONFIG.lotNumberRegexPattern, 'i');
        let candidate = String(raw || '').replace(/\s+/g, ' ').trim();
        if (candidate) {
          const match = candidate.match(pattern);
          if (match && match[1] && !isFillerToken(match[1])) candidate = match[1];
          else {
            // Two-word labels ("Lot Number 142") and glued ids ("ItemMain19002") need more than one
            // pass, and `\b` keeps the strip away from a word glued to the digits.
            for (let pass = 0; pass < 3; pass += 1) {
              const stripped = candidate.replace(/^(?:no|num|number|lot|item|sku|pallet|auction|product|listing|id|code|ref)\b[\s:#\-_.]*/i, '');
              if (stripped === candidate) break;
              candidate = stripped;
            }
            candidate = candidate.replace(/^[^A-Za-z0-9]+/, '');
          }
          const unwrapped = unwrapDOMId(candidate);
          if (unwrapped) candidate = unwrapped;
          if (candidate.length > 40) candidate = candidate.slice(0, 40);
          if (candidate.length >= 1) return candidate;
        }
        const fromText = String(cardText || '').match(pattern);
        if (fromText && fromText[1] && !isFillerToken(fromText[1])) return fromText[1];
        return '';
      }

      // A capture that turned out to be another label word — "Lot Number 142" grabs "Number" — is
      // not a lot number. Rejecting it lets the caller try the address and the id instead.
      function isFillerToken(value) {
        return /^(?:no|num|number|id|code|ref|lot|item|sku|pallet|auction|product|listing)$/i
          .test(String(value || '').trim());
      }

      // A card's own id is usually a DOM address — `ItemMain19002`, `item-row-88` — rather than the
      // number the site prints, so a value that is exactly a known wrapper word plus digits is
      // reduced to the digits; a real SKU such as `ABC123` is returned untouched. Mirrors
      // `LotNumber.unwrappingDOMId` in the Swift app, which cleans values scraped by older builds.
      function unwrapDOMId(value) {
        const text = String(value || '').trim();
        const match = text.match(/^([A-Za-z]{1,24})[\s\-_.]*(\d{1,12})$/);
        if (!match) return '';
        return CONFIG.lotNumberWrapperWords.indexOf(match[1].toLowerCase()) >= 0 ? match[2] : '';
      }

      // Consulted only when nothing legible came off the card: the number in the page's own address
      // is what the operator would follow anyway (`/lot/19002`, `?itemid=19002`).
      function lotNumberFromURL(urlString) {
        const parts = String(urlString || '').split(/[^A-Za-z0-9]+/);
        for (let index = parts.length - 1; index >= 0; index -= 1) {
          const token = parts[index];
          if (!token) continue;
          const value = unwrapDOMId(token) || token;
          if (/^\d{1,12}$/.test(value)) return value;
        }
        return '';
      }

      // --------------------------------------------------------------- lot status

      // A lot is *active* while the site still takes bids on it, and *sold* once the site says so.
      // The site's own badge is the authority: its text is short by design, so a status element is
      // only believed when it is brief. The card's whole text is consulted last, and the regex is
      // built to leave catalog copy ("sold as one pallet") alone — see `soldTextPattern` in the
      // profile. Getting this wrong the other way would retire lots that are still biddable.
      function soldState(element, cardText) {
        let pattern = null;
        try { pattern = new RegExp(CONFIG.soldTextPattern, 'i'); } catch (error) { pattern = null; }
        if (!pattern) return { isSold: false, statusText: '' };

        for (let index = 0; index < CONFIG.lotStatusSelectors.length; index += 1) {
          const candidates = each(element, CONFIG.lotStatusSelectors[index]);
          for (let candidateIndex = 0; candidateIndex < candidates.length; candidateIndex += 1) {
            const candidate = candidates[candidateIndex];
            const text = textOf(candidate);
            if (text.length === 0 || text.length > 32) continue;
            if (pattern.test(text)) return { isSold: true, statusText: text.slice(0, 40) };
          }
        }

        // Some layouts only carry the state as an attribute, with no dedicated element.
        const attribute = attributeOf(element, ['data-status', 'data-lot-status', 'data-state', 'aria-label']);
        if (attribute.length > 0 && attribute.length <= 32 && pattern.test(attribute)) {
          return { isSold: true, statusText: attribute.slice(0, 40) };
        }

        // No badge at all: fall back to the card's own words, which is the only signal a
        // badge-free layout offers. The pattern's lookahead is what keeps listing copy safe.
        if (cardText && pattern.test(cardText)) return { isSold: true, statusText: '' };
        return { isSold: false, statusText: '' };
      }

      // ------------------------------------------------------------- empty auction

      // "There is nothing to bid on here." Two routes, cheapest first: a dedicated no-results
      // surface, then — only when the grid really is empty — the page's own words, because some
      // catalogs render the message inside the same widget as the results counter.
      function noResultsReport() {
        let pattern = null;
        try { pattern = new RegExp(CONFIG.noResultsTextPattern, 'i'); } catch (error) { pattern = null; }
        if (!pattern) return { present: false, selector: '', text: '' };

        for (let index = 0; index < CONFIG.noResultsSelectors.length; index += 1) {
          const candidates = each(document, CONFIG.noResultsSelectors[index]);
          for (let candidateIndex = 0; candidateIndex < candidates.length; candidateIndex += 1) {
            const candidate = candidates[candidateIndex];
            if (!isVisible(candidate)) continue;
            const text = textOf(candidate);
            if (text.length === 0 || text.length > 240) continue;
            const match = text.match(pattern);
            if (match) {
              return { present: true, selector: CONFIG.noResultsSelectors[index], text: text.slice(0, 120) };
            }
          }
        }

        if (collectCards().elements.length === 0) {
          const match = textOf(document.body).match(pattern);
          if (match) return { present: true, selector: 'body', text: match[0].slice(0, 120) };
        }
        return { present: false, selector: '', text: '' };
      }

      function readCard(element) {
        if (!element) return null;
        const cardText = textOf(element);
        if (cardText.length < CONFIG.minimumCardTextLength) return null;

        // The card's own address first, *before* the lot number is known: on layouts that expose no
        // lot number at all it is the number, and it is the link the row offers the operator. Only
        // the card and the tile that holds it are consulted here — an address found by lot number
        // (see `detailLink`) needs the number this pass exists to establish.
        const ownDetailURLString = detailLink(element, '');

        let lotNumber = attributeOf(element, CONFIG.lotNumberAttributeCandidates);
        if (lotNumber.length > 60) lotNumber = '';
        if (!lotNumber) {
          const holder = firstElement(element, CONFIG.lotNumberSelectors);
          if (holder) lotNumber = attributeOf(holder, CONFIG.lotNumberAttributeCandidates) || textOf(holder);
        }
        lotNumber = normalizeLotNumber(lotNumber, cardText);
        // Nothing legible yet. The deep link is what the operator would follow anyway, and the
        // card's own id is an element address rather than the printed number, so the address wins
        // and the raw id is only the last resort — unwrapped of its wrapper word either way.
        // The address is read loosely here on purpose: a card whose only anchor points at a
        // photograph has no page to open, but `/img/lot-19002.jpg` still named the lot.
        if (!lotNumber) {
          const firstAnchor = firstElement(element, ['a[href]']);
          const loose = firstAnchor ? absolute(firstAnchor.getAttribute('href')) : null;
          lotNumber = lotNumberFromURL(ownDetailURLString || loose);
        }
        if (!lotNumber) {
          const domId = attributeOf(element, CONFIG.lotNumberDOMIdAttributeCandidates);
          lotNumber = unwrapDOMId(domId) || normalizeLotNumber(domId, '');
        }

        // Now that the number is known, an address that merely *carries* it can be recognized too —
        // which is how a card that is not a link itself still ends up with one. The card's own,
        // weaker evidence is kept as the fallback: an address that names this lot is only a better
        // answer than the first anchor when it exists.
        const detailURLString = (lotNumber ? detailLink(element, lotNumber) : null) || ownDetailURLString;

        let title = textOf(firstElement(element, CONFIG.titleSelectors));
        if (!title) title = attributeOf(element, ['aria-label', 'title', 'data-title']);
        if (!title) {
          const titledAnchor = firstElement(element, ['a[title]', 'a[aria-label]']);
          if (titledAnchor) title = attributeOf(titledAnchor, ['title', 'aria-label']);
        }
        title = String(title || '').replace(/\s+/g, ' ').trim();

        let description = textOf(firstElement(element, CONFIG.descriptionSelectors));
        description = String(description || '').replace(/\s+/g, ' ').trim();
        if (!description) description = cardText.slice(0, 300);
        if (!title) title = description;
        if (!description) description = title;

        let bidText = '';
        const bidElement = firstElement(element, CONFIG.bidSelectors);
        if (bidElement) bidText = attributeOf(bidElement, CONFIG.bidAttributeCandidates) || textOf(bidElement);
        bidText = String(bidText || '').replace(/\s+/g, ' ').trim();
        if (!bidText) {
          const match = cardText.match(/(?:current\s*bid|high\s*bid|current\s*price|bid|price)\s*:?\s*[$€£]?\s*[\d.,]+/i);
          if (match) bidText = match[0];
        }

        const imageURLStrings = collectImages(element);

        // The site's own state marker: a sold lot is still scraped and shown, flagged, so the
        // operator can see the auction's history instead of a silently shorter table.
        const sold = soldState(element, cardText);

        if (!title && !lotNumber && imageURLStrings.length === 0) return null;

        return {
          lotNumber: lotNumber.slice(0, 60),
          title: title.slice(0, 300),
          rawDescription: description.slice(0, 600),
          bidText: bidText.slice(0, 80),
          imageURLStrings: imageURLStrings,
          detailURLString: detailURLString,
          sourcePage: state.page,
          isSold: sold.isSold,
          statusText: sold.statusText
        };
      }

      function extractLots() {
        const collected = collectCards();
        const lots = [];
        for (let index = 0; index < collected.elements.length; index += 1) {
          const lot = readCard(collected.elements[index]);
          if (lot) lots.push(lot);
        }
        log('extract page=' + state.page + ' selector=' + (collected.selector || 'none') + ' cards=' + collected.elements.length + ' lots=' + lots.length);
        return JSON.stringify({
          page: state.page,
          url: location.href,
          selector: collected.selector,
          cardCount: collected.elements.length,
          lots: lots
        });
      }

      function diagnostics() {
        const collected = collectCards();
        const empty = noResultsReport();
        return JSON.stringify({
          url: location.href,
          title: String(document.title || ''),
          readyState: String(document.readyState || ''),
          profileName: CONFIG.name,
          cardSelector: collected.selector || null,
          cardCount: collected.elements.length,
          hasPasswordField: passwordField() !== null,
          loginFormPresent: hasLoginForm(),
          authenticated: isAuthenticated(),
          nextControlCount: countNextControls(),
          bodyTextLength: textOf(document.body).length,
          noResults: empty.present,
          noResultsText: empty.text
        });
      }

      // -------------------------------------------------------------- page state

      function signatureValue() {
        const collected = collectCards();
        const sample = collected.elements.slice(0, 3).map(function (element) {
          const images = each(element, 'img').slice(0, 2).map(function (image) {
            return String(image.getAttribute('src') || image.getAttribute('data-src') || '');
          }).join(',');
          return textOf(element).slice(0, 140) + '|' + images;
        }).join('~');
        let hash = 2166136261;
        for (let index = 0; index < sample.length; index += 1) {
          hash ^= sample.charCodeAt(index);
          hash = Math.imul(hash, 16777619);
        }
        return {
          count: collected.elements.length,
          selector: collected.selector || null,
          hash: (hash >>> 0).toString(16),
          url: location.href
        };
      }

      function pageSignature() {
        return JSON.stringify(signatureValue());
      }

      function candidateLabel(element) {
        const parts = [
          textOf(element),
          attributeOf(element, ['aria-label', 'title', 'rel', 'data-testid', 'value', 'name'])
        ];
        return parts.join(' ').toLowerCase().trim();
      }

      function looksLikeNext(element) {
        const label = candidateLabel(element);
        const rel = String(element.getAttribute('rel') || '').toLowerCase();
        if (rel === 'next') return true;
        if (/(prev|previous|back|first|last|start|«|‹|←)/.test(label)) return false;
        if (/(next|more|load|show|view)/.test(label)) return true;
        if (/[›»→]/.test(label)) return true;
        return false;
      }

      function nextControlCandidates() {
        const found = [];
        for (let index = 0; index < CONFIG.nextPageSelectors.length; index += 1) {
          const candidates = each(document, CONFIG.nextPageSelectors[index]);
          for (let candidateIndex = 0; candidateIndex < candidates.length; candidateIndex += 1) {
            const candidate = candidates[candidateIndex];
            if (!isVisible(candidate) || isDisabled(candidate)) continue;
            if (!looksLikeNext(candidate)) continue;
            if (found.indexOf(candidate) >= 0) continue;
            found.push(candidate);
          }
        }
        return found;
      }

      function countNextControls() {
        return nextControlCandidates().length;
      }

      // ------------------------------------------------------------- pagination

      function clickNext(force) {
        const before = signatureValue();
        const candidates = nextControlCandidates();
        if (candidates.length === 0) {
          return JSON.stringify({ clicked: false, reason: 'no-next-control', signature: before });
        }
        const candidate = candidates[0];
        const fingerprint = before.hash + ':' + before.count;
        if (!force && state.lastClick && state.lastClick.element === candidate && state.lastClick.signature === fingerprint) {
          return JSON.stringify({ clicked: false, reason: 'already-clicked-unchanged', signature: before });
        }
        try { candidate.scrollIntoView({ block: 'center' }); } catch (error) { /* ignore */ }
        candidate.click();
        state.lastClick = {
          element: candidate,
          signature: fingerprint,
          at: Date.now(),
          label: candidateLabel(candidate).slice(0, 60)
        };
        log('clicked next: ' + describe(candidate) + ' [' + state.lastClick.label + ']');
        return JSON.stringify({
          clicked: true,
          control: describe(candidate),
          label: state.lastClick.label,
          alternatives: candidates.length,
          signature: before
        });
      }

      function nextControlCount() {
        return countNextControls();
      }

      // ------------------------------------------------------------- page count

      // How many result pages the listing says it has. Read off the site's own pagination — the
      // numbers in its page links, then the "page 3 of 24" it prints — because the app cannot know
      // a catalogue's length without asking it, and the operator picked a page budget *before*
      // pressing Run. The answer is a convenience for the **Pages** menu, never a plan: `pages:
      // null` means the site does not say, and `hasNext` is what the scraper itself walks by.
      // A page number above this is read as noise rather than as a long catalogue: an address can
      // carry a product id where a page number is expected, and a menu that lists 9,999 pages is
      // worse than one that admits it does not know.
      const PAGE_NUMBER_CEILING = 200;

      function clampPageNumber(value) {
        const number = Math.floor(Number(value) || 0);
        if (number < 1) return null;
        return Math.min(number, PAGE_NUMBER_CEILING);
      }

      // A "next" / "previous" link carries a page number too, but it is not a count: it says there is
      // one more page, which `hasNext` already says. Numbered links are the plain ones — "3", "4".
      function isStepControl(anchor) {
        const rel = String(anchor.getAttribute('rel') || '').toLowerCase();
        if (rel === 'next' || rel === 'prev' || rel === 'previous') return true;
        if (looksLikeNext(anchor)) return true;
        return /(prev|previous|next|first|last|back)/.test(candidateLabel(anchor));
      }

      // The query-string names a page number hides behind. Kept in step with `PaginationPlan`'s list
      // on the app side, which builds the addresses this reader recognises. Bare `p=` is deliberately
      // not read — on too many catalogues that is a product, not a page.
      const PAGE_PARAMETER_PATTERN = '[?&](page|paged|pg)(?:\\[\\])?=(\\d{1,7})';
      const PAGE_PATH_PATTERN = '\\/page[/-](\\d{1,7})(?:[/?#]|$)';

      // The page a link points at, when its address carries one: `?page=3`, `&paged=12`, `/page/4`.
      function pageNumberFromAddress(address) {
        const value = String(address || '');
        const query = value.match(new RegExp(PAGE_PARAMETER_PATTERN, 'i'));
        if (query) return Number(query[2]);
        const path = value.match(new RegExp(PAGE_PATH_PATTERN, 'i'));
        if (path) return Number(path[1]);
        return 0;
      }

      // The name that address gave its page number, when it gave one: `page` on the catalogue this
      // tool targets, `paged` on the WordPress-shaped ones. The app asks a listing for pages by
      // rewriting *this* name, so a site that ignores `?page=` is not asked with it.
      function pageParameterFromAddress(address) {
        const value = String(address || '');
        const query = value.match(new RegExp(PAGE_PARAMETER_PATTERN, 'i'));
        return query ? String(query[1]).toLowerCase() : null;
      }

      // The address the listing itself prints for `pageNumber`, when it prints one: the href of a link
      // that asks for exactly that page — which covers a numbered strip and a "next" link alike,
      // because a next link's address *is* the next page's. `null` means the site never printed it, and
      // the app falls back to rewriting the page number in the run's own address.
      function pageAddress(pageNumber) {
        const wanted = Math.floor(Number(pageNumber) || 0);
        if (wanted < 1) return null;
        const anchors = each(document, 'a[href]');
        for (let index = 0; index < anchors.length; index += 1) {
          const href = String(anchors[index].getAttribute('href') || '');
          if (!href || href.charAt(0) === '#') continue;
          if (pageNumberFromAddress(href) !== wanted) continue;
          const resolved = absolute(href);
          // A page number on somebody else's listing — a "related auctions" strip one column over, a
          // feed of the site's other catalogues — is not *this* listing's next page, and following it
          // would walk a different auction's lots into the table. Only an address for the same listing
          // is handed over; anything else falls back to the app's own rewrite, which is built from the
          // address being walked and so cannot leave it.
          if (!resolved || !sameListing(resolved)) continue;
          log('page ' + wanted + ' is addressed by ' + describe(anchors[index]) + ': ' + resolved);
          return resolved;
        }
        return null;
      }

      // The shape of an address with its page number taken out: everything two pages of one listing have
      // in common. A catalogue varies its path between listings (`…/catalog/id/29` vs `…/catalog/id/31`)
      // and its page number between pages, so the path minus the page part is the listing's identity.
      function listingPath(address) {
        return String(address).replace(/\/page(?:[/-]\d{1,7})?\/?$/, '').replace(/\/$/, '');
      }

      // Whether an address points at the listing being walked rather than at a neighbour.
      function sameListing(address) {
        try {
          return listingPath(new URL(address, location.href).pathname)
            === listingPath(new URL(location.href).pathname);
        } catch (error) {
          // An address that will not come apart cannot be confirmed as this listing's, so it is not
          // followed: the app's own rewrite is always available.
          return false;
        }
      }

      // The highest numbered page link in `root`, with the name that link gave its page number
      // (`page`, `paged`, …) so the app can ask for later pages in the site's own words. Pagination
      // containers are tried first so a page number from an unrelated strip ("recently viewed")
      // cannot win.
      function highestPageLink(root) {
        const anchors = each(root, 'a[href]');
        let highest = 0;
        let parameter = null;
        for (let index = 0; index < anchors.length; index += 1) {
          const anchor = anchors[index];
          if (isStepControl(anchor)) continue;
          const href = anchor.getAttribute('href') || anchor.href;
          const number = pageNumberFromAddress(href);
          if (number > highest && number <= PAGE_NUMBER_CEILING) {
            highest = number;
            parameter = pageParameterFromAddress(href);
          }
        }
        return { number: highest, parameter: parameter };
      }

      function paginationReport() {
        const report = { pages: null, hasNext: countNextControls() > 0, parameter: null, source: '' };
        // A pagination container is the ancestor half of a next-page selector: everything before the
        // control itself. Entries that *are* the control (`a[rel='next']`) say nothing about where
        // the numbers live, so they are skipped and the profile-wide fallbacks below cover them.
        const containers = [];
        for (let index = 0; index < CONFIG.nextPageSelectors.length; index += 1) {
          const entry = String(CONFIG.nextPageSelectors[index]).trim();
          const cut = entry.indexOf(' ');
          const ancestor = cut > 0 ? entry.slice(0, cut) : '';
          if (ancestor && containers.indexOf(ancestor) < 0) containers.push(ancestor);
        }
        containers.push("[class*='pagination' i]", "[class*='pager' i]", "nav[aria-label*='pagination' i]");
        let highest = 0;
        let parameter = null;
        let source = '';
        for (let index = 0; index < containers.length; index += 1) {
          const found = each(document, containers[index]);
          for (let inner = 0; inner < found.length; inner += 1) {
            const candidate = highestPageLink(found[inner]);
            if (candidate.number > highest) {
              highest = candidate.number;
              parameter = candidate.parameter;
              source = 'the numbered links in ' + describe(found[inner]);
            }
          }
        }
        if (highest <= 1) {
          const anywhere = highestPageLink(document);
          if (anywhere.number > highest) {
            highest = anywhere.number;
            parameter = anywhere.parameter;
            source = 'the numbered page links';
          }
        }
        if (highest > 1) {
          report.pages = clampPageNumber(highest);
          report.parameter = parameter;
          report.source = source;
          return report;
        }
        // The printed forms, in the order sites write them.
        const body = textOf(document.body);
        const ofPages = body.match(/\bpage\s+\d{1,4}\s*(?:of|\/)\s*(\d{1,4})\b/i)
          || body.match(/\bof\s+(\d{1,4})\s+pages?\b/i);
        if (ofPages) {
          const pages = clampPageNumber(ofPages[1]);
          if (pages) {
            report.pages = pages;
            report.source = 'the "' + ofPages[0].trim() + '" text';
            return report;
          }
        }
        const range = body.match(/\b(\d{1,4})\s*[-–]\s*(\d{1,4})\s+of\s+([\d,]{1,9})\b/i);
        if (range) {
          const perPage = Number(range[2]) - Number(range[1]) + 1;
          const total = Number(String(range[3]).replace(/,/g, ''));
          if (perPage > 0 && total > 0) {
            const pages = clampPageNumber(Math.ceil(total / perPage));
            if (pages) {
              report.pages = pages;
              report.source = total + ' item(s) at ' + perPage + ' per page';
              return report;
            }
          }
        }
        report.source = report.hasNext ? 'a next-page control, no count' : 'nothing to read';
        return report;
      }

      // Lazily-rendered grids often only materialise cards once the viewport passes
      // over them, so sweep the page before extracting.
      function scrollSweep() {
        if (state.sweeping) return JSON.stringify({ started: false, reason: 'already-sweeping' });
        const documentElement = document.documentElement;
        const body = document.body;
        const total = Math.max(
          documentElement ? documentElement.scrollHeight : 0,
          body ? body.scrollHeight : 0,
          window.innerHeight * 2
        );
        const steps = Math.max(4, Math.min(16, Math.ceil(total / 850)));
        state.sweeping = true;
        let index = 0;
        const tick = function () {
          index += 1;
          try { window.scrollTo(0, Math.round((total / steps) * index)); } catch (error) { /* ignore */ }
          if (index < steps) {
            window.setTimeout(tick, 130);
          } else {
            try { window.scrollTo(0, 0); } catch (error) { /* ignore */ }
            state.sweeping = false;
            log('scroll sweep done: ' + steps + ' steps over ' + total + 'px');
          }
        };
        window.setTimeout(tick, 70);
        return JSON.stringify({ started: true, steps: steps, totalHeight: total });
      }

      // ------------------------------------------------------------------ public






      window.__PAS = {
        ready: true,
        version: '1.0.0',
        configure: function (configJSON) {
          try { Object.assign(CONFIG, JSON.parse(configJSON)); log('CONFIG updated'); return JSON.stringify({ ok: true }); }
          catch (error) { return JSON.stringify({ ok: false, error: String(error) }); }
        },
        config: function () { return JSON.stringify(CONFIG); },
        logs: function () { return JSON.stringify(pendingLogs); },
        profileName: CONFIG.name,
        describeElement: describe,
        pageTitle: function () { return String(document.title || ''); },
        pageURL: function () { return location.href; },
        isSweeping: function () { return state.sweeping; },
        currentPage: function () { return state.page; },
        setPage: function (page) { state.page = Number(page) || 1; return state.page; },
        hasLoginForm: function () { return hasLoginForm(); },
        fillLogin: function (payloadJSON) { return fillLogin(payloadJSON); },
        submitLogin: function () { return submitLogin(); },
        isAuthenticated: function () { return isAuthenticated(); },
        manualCheck: function () { return manualCheck(); },
        pageSignature: function () { return pageSignature(); },
        extractLots: function () { return extractLots(); },
        cardCount: function () { return collectCards().elements.length; },
        noResults: function () { return JSON.stringify(noResultsReport()); },
        noResultsPresent: function () { return noResultsReport().present; },
        diagnostics: function () { return diagnostics(); },
        scrollSweep: function () { return scrollSweep(); },
        nextControlCount: function () { return nextControlCount(); },
        pagination: function () { return JSON.stringify(paginationReport()); },
        pageAddress: function (pageNumber) { return pageAddress(pageNumber); },
        clickNext: function (force) { return clickNext(force === true); },
        lotPageImages: function (url) { return lotPageImages(url); }
      };
      log('PAS script installed (profile: ' + CONFIG.name + ')');
    })();
    """#
}
