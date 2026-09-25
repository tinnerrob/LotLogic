#!/bin/bash
#
# Compiles and runs the offline free-tier harness.
#
# It pairs the real transport (Services/GeminiValuationService.swift) with a URLProtocol stub, so
# the 429 retry loop, Retry-After / RetryInfo parsing and RequestPacer pacing are exercised with
# no API key, no network traffic and no dependency on the app target. Exits non-zero on failure.
#
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

swiftc -swift-version 6 -o "$out/harness" \
    "$root/PalletAuctionBidTool/Models/DiscoveredItem.swift" \
    "$root/PalletAuctionBidTool/Models/Formatting.swift" \
    "$root/PalletAuctionBidTool/Models/LotNumber.swift" \
    "$root/PalletAuctionBidTool/Models/ScrapedLot.swift" \
    "$root/PalletAuctionBidTool/Models/LotItem.swift" \
    "$root/PalletAuctionBidTool/Models/BidTargeting.swift" \
    "$root/PalletAuctionBidTool/Models/ColumnWidths.swift" \
    "$root/PalletAuctionBidTool/Models/ColumnVisibility.swift" \
    "$root/PalletAuctionBidTool/Models/LotSearch.swift" \
    "$root/PalletAuctionBidTool/Models/LotSort.swift" \
    "$root/PalletAuctionBidTool/Models/PaginationPlan.swift" \
    "$root/PalletAuctionBidTool/Models/ScrapeProfile.swift" \
    "$root/PalletAuctionBidTool/Models/ScrapeProfilePresets.swift" \
    "$root/PalletAuctionBidTool/Models/ValuationProvider.swift" \
    "$root/PalletAuctionBidTool/Models/PhotoReading.swift" \
    "$root/PalletAuctionBidTool/Services/LotValuation.swift" \
    "$root/PalletAuctionBidTool/Services/LotImageDigest.swift" \
    "$root/PalletAuctionBidTool/Services/LotPhotoScan.swift" \
    "$root/PalletAuctionBidTool/Services/LotPhotoScanPrompt.swift" \
    "$root/PalletAuctionBidTool/Services/PhotoReadingStore.swift" \
    "$root/PalletAuctionBidTool/Services/GeminiValuationService.swift" \
    "$root/PalletAuctionBidTool/Services/DeepSeekValuationService.swift" \
    "$root/Tools/free-tier-harness/main.swift"

"$out/harness"
