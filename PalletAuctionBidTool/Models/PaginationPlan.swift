//
//  PaginationPlan.swift
//  PalletAuctionBidTool
//
//  The address of a listing's later result pages, built the way the listing itself numbers them.
//

import Foundation

/// Which address asks a catalogue for one particular page of results.
///
/// The scraper walks a listing by *address*: it loads `…/auctions/catalog/id/29?page=1`, then
/// `?page=2`, then `?page=3`, and stops when a page turns up with no lots on it. A click is only as
/// reliable as the site's markup — the control has to be found by selector, be visible, be enabled
/// and read as "next" to the label rules — and the catalogue this tool targets prints a strip of
/// numbered links, which is the one shape those rules are worst at. An address needs no selector, is
/// what the operator would type, and cannot be mislabelled.
///
/// The parameter name is the site's own when one was seen (`page` on the target catalogue), so a
/// listing addressed `?paged=4` is asked for `?paged=5` instead of being handed a second, ignored
/// `?page=5`.
///
/// Nothing here talks to the network or to a web view: given the run's start address and a page
/// number it returns an address, which is what makes the walking rule testable off-device.
struct PaginationPlan: Sendable, Equatable {

    /// The query-string names sites use for a page number, in the order they are looked for.
    ///
    /// Bare `p` is deliberately absent, for the same reason the page-side reader skips it: on too many
    /// catalogues that is a product id wearing a page's clothes.
    static let parameterNames = ["page", "paged", "pg"]

    /// Every page address is a rewrite of this one — the address the run started on, once the site
    /// has settled on a canonical form.
    let baseURL: URL

    /// The query-string parameter this listing numbers its pages with.
    let parameter: String

    /// - Parameter parameter: the name the site was seen using, when the listing reported one.
    init(baseURL: URL, parameter: String? = nil) {
        self.baseURL = baseURL
        if let parameter, !parameter.isEmpty {
            self.parameter = parameter
        } else {
            self.parameter = PaginationPlan.parameter(of: baseURL) ?? PaginationPlan.parameterNames[0]
        }
    }

    /// The address that asks for `page`, `1`-based.
    ///
    /// An address that already carries a page number has *that* number replaced: the point of the
    /// rewrite is a different page, not a second parameter the site will ignore. One that carries
    /// none gains the parameter. `nil` only when the address cannot be taken apart at all.
    func url(page: Int) -> URL? {
        guard page > 0, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        if let index = items.firstIndex(where: { $0.name.caseInsensitiveCompare(parameter) == .orderedSame }) {
            // The site's own spelling is kept (`Page=2` stays `Page=3`), which is what an
            // already-numbered address is.
            items[index] = URLQueryItem(name: items[index].name, value: String(page))
        } else {
            items.append(URLQueryItem(name: parameter, value: String(page)))
        }
        components.queryItems = items
        return components.url
    }

    /// The parameter an address already numbers its pages with, spelling and all.
    static func parameter(of url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return items.first { item in
            parameterNames.contains { $0.caseInsensitiveCompare(item.name) == .orderedSame }
        }?.name
    }

    /// The page number an address asks for, when it carries one: `?page=3`, `?paged=12`, `/page/4`.
    ///
    /// What this is for is noticing that a site ignored the rewrite — answered page 1 for `?page=9`,
    /// or clamped to its last page — which is the difference between walking a listing and reading one
    /// page over and over. It reads the same shapes the page-side reader does.
    static func pageNumber(of url: URL) -> Int? {
        if let number = queryPageNumber(of: url) { return number }
        return pathPageNumber(of: url)
    }

    private static func queryPageNumber(of url: URL) -> Int? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        for name in parameterNames {
            for item in items where name.caseInsensitiveCompare(item.name) == .orderedSame {
                guard let value = item.value, let number = positive(value) else { continue }
                return number
            }
        }
        return nil
    }

    private static func pathPageNumber(of url: URL) -> Int? {
        let segments = url.path.split(separator: "/").map(String.init)
        for (index, segment) in segments.enumerated() {
            let lowered = segment.lowercased()
            if lowered == "page", index + 1 < segments.count, let number = positive(segments[index + 1]) {
                return number
            }
            if lowered.hasPrefix("page-"), let number = positive(String(lowered.dropFirst(5))) {
                return number
            }
        }
        return nil
    }

    /// A page number, or `nil` for anything that is not a positive whole one.
    ///
    /// The ceiling matches the page-side reader's: an address carrying a five-digit number where a
    /// page number belongs is a product id, not page 40,000.
    private static func positive(_ text: String) -> Int? {
        guard let number = Int(text.trimmingCharacters(in: .whitespaces)), number > 0 else { return nil }
        return number
    }
}
