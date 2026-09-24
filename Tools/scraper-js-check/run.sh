#!/bin/bash
#
# Compiles the injected scraper script and drives it against a tiny DOM shim in Node.
#
# The generation step is the app's own `ScraperScript.source(profile:)`, so what is tested is the
# exact JavaScript the hidden WKWebView is handed. Node is required; without it the check reports
# that it was skipped rather than failing, since the Swift app has no dependency on Node.
# Exits non-zero when a check fails.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

if ! command -v node >/dev/null 2>&1; then
  echo "node is not installed — skipping the scraper JS check"
  exit 0
fi

cat > "$out/main.swift" <<'SWIFT'
import Foundation

// Writes the generated page script to the path given as the first argument.
let destination = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scraper.js"
let source = try ScraperScript.source(profile: ScrapeProfile.genericBase())
try source.write(to: URL(fileURLWithPath: destination), atomically: true, encoding: .utf8)
SWIFT

swiftc -swift-version 6 -o "$out/dump" \
    "$root/PalletAuctionBidTool/Models/ScrapeProfile.swift" \
    "$root/PalletAuctionBidTool/Models/ScrapeProfilePresets.swift" \
    "$root/PalletAuctionBidTool/Services/ScraperScript.swift" \
    "$out/main.swift"

"$out/dump" "$out/scraper.js"
SCRAPER_JS="$out/scraper.js" node "$root/Tools/scraper-js-check/dom-test.js"
