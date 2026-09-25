//
//  PhotoReadingStore.swift
//  PalletAuctionBidTool
//
//  What the model read in each photograph, kept on this machine.
//
//  A thorough scan is one request per photograph, which is the price of reading a pallet properly:
//  the closer the model is asked to look, the better the line items. Paying that price a second time
//  for a lot whose gallery has not changed is not part of the deal, so every reading is written here
//  as it lands — the lot number, the model that produced it, and one `PhotoReading` per photograph
//  keyed by the address it was downloaded from. Re-scanning a lot then costs one reconciliation
//  request instead of *n* + 1, and the readings for the photographs that are still there are reused
//  as-is (see `LotPhotoScan`). A gallery that grew keeps the readings it had and reads only the new
//  frames.
//
//  It is a cache, deliberately: nothing here is authoritative, a failure to write is not a failed
//  scan, and forgetting everything costs only requests.
//

import Foundation

/// The on-disk record of what a model has read in each photograph of each lot.
///
/// An actor rather than a lock-wrapped class: the file I/O happens off the main actor, and the
/// in-memory copy means a run of **Price all** touches the disk once per lot rather than once per
/// photograph.
actor PhotoReadingStore {

    /// One lot's readings, as they sit on disk.
    struct Archive: Codable, Sendable {
        var lotNumber: String
        /// The model these readings came from. A reading is one model's opinion, so readings produced
        /// by a different model are not reused — and are not merged into, either.
        var modelID: String
        /// Prompt/decoding generation (see `currentVersion`).
        var version: Int
        var updatedAt: Date
        var readings: [PhotoReading]
    }

    /// Bumped whenever the photograph prompt or the decoded reading shape changes, which is what
    /// retires every reading already on disk: a reading answers the question it was asked, and an old
    /// answer to a different question is worse than no answer.
    static let currentVersion = 1

    /// The store the app uses.
    ///
    /// A shared instance because what is being cached is per *machine*, not per run or per service:
    /// the Gemini and DeepSeek services both write here, and a reading either of them produced saves
    /// the other the request.
    static let shared = PhotoReadingStore()

    /// Where the archives live. Read by the settings modal, so the cache is a file the operator can
    /// find rather than a mystery.
    nonisolated let directory: URL

    private let fileManager: FileManager
    private var cache: [String: CacheEntry] = [:]

    /// Either an archive this store has loaded, or the knowledge that this lot has none. Distinguishing
    /// the two is what keeps a gallery of forty photographs from re-reading a file that is not there
    /// forty times.
    private enum CacheEntry {
        case archive(Archive)
        case missing
    }

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
    }

    /// `~/Library/Application Support/<app>/PhotoReadings`, created on first write.
    ///
    /// Under Application Support rather than beside the app's `UserDefaults`: this is growing data,
    /// not a preference, and it belongs somewhere the operator can find and delete it. A sandboxed
    /// build resolves the same path inside its own container.
    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let app = Bundle.main.bundleIdentifier ?? "PalletAuctionBidTool"
        return base
            .appendingPathComponent(app, isDirectory: true)
            .appendingPathComponent("PhotoReadings", isDirectory: true)
    }

    // MARK: - Reading

    /// The readings already stored for a lot, or `[]` when there are none worth reusing.
    ///
    /// Empty is also the answer when the archive was written by a different model or a different
    /// prompt generation — the caller then simply reads the photographs again.
    func readings(forLot lotNumber: String, modelID: String) -> [PhotoReading] {
        guard let archive = archive(forLot: lotNumber) else { return [] }
        guard archive.version == Self.currentVersion, archive.modelID == modelID else { return [] }
        return archive.readings
    }

    // MARK: - Writing

    /// Adds readings to a lot's archive, the newest reading of a photograph winning.
    ///
    /// Merging rather than replacing matters for a gallery that grew: readings reused from the store
    /// (which were never re-requested) have to survive a scan that only read the photographs added
    /// since.
    func store(_ readings: [PhotoReading], forLot lotNumber: String, modelID: String) {
        guard !readings.isEmpty else { return }

        var merged = archive(forLot: lotNumber)?.readings ?? []
        for reading in readings {
            if let index = merged.firstIndex(where: { $0.imageURL == reading.imageURL }) {
                merged[index] = reading
            } else {
                merged.append(reading)
            }
        }

        let archive = Archive(
            lotNumber: lotNumber,
            modelID: modelID,
            version: Self.currentVersion,
            updatedAt: .now,
            readings: merged.sorted { $0.imageIndex < $1.imageIndex }
        )
        guard write(archive) else { return }
        cache[key(forLot: lotNumber)] = .archive(archive)
    }

    /// Drops one lot's readings.
    ///
    /// Not used by the pipeline on purpose — a reading costs nothing to keep — but reachable from the
    /// settings modal, where "forget what was read" is how an operator who has changed their mind
    /// about a model gets a clean re-read.
    func forget(lotNumber: String) {
        try? fileManager.removeItem(at: file(forLot: lotNumber))
        cache[key(forLot: lotNumber)] = .missing
    }

    /// Drops every reading on this machine.
    func forgetAll() {
        try? fileManager.removeItem(at: directory)
        cache.removeAll()
    }

    /// How many lots have readings stored, so the settings modal can say what **Forget** would cost.
    func storedLotCount() -> Int {
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.count { $0.pathExtension == "json" }
    }

    // MARK: - Files

    /// Loads a lot's archive, remembering the answer — including "there is none".
    private func archive(forLot lotNumber: String) -> Archive? {
        let cacheKey = key(forLot: lotNumber)
        switch cache[cacheKey] {
        case .archive(let archive):
            return archive
        case .missing:
            return nil
        case nil:
            break
        }

        guard let data = try? Data(contentsOf: file(forLot: lotNumber)),
              let archive = try? Self.decoder.decode(Archive.self, from: data) else {
            cache[cacheKey] = .missing
            return nil
        }
        cache[cacheKey] = .archive(archive)
        return archive
    }

    /// Writes an archive, atomically. A failure comes back as `false` and is otherwise ignored: this
    /// is a cache, and a lot that could not be cached is a lot that costs a little more next time.
    private func write(_ archive: Archive) -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(archive)
            try data.write(to: file(forLot: archive.lotNumber), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The file one lot's readings live in.
    ///
    /// Named after the lot number, with everything that is not a letter, a digit or a hyphen replaced:
    /// the name has to survive being a file name on a case-insensitive volume, and being looked at by
    /// a human — the lot the readings belong to is the interesting part, not a hash of it.
    private func file(forLot lotNumber: String) -> URL {
        directory.appendingPathComponent("lot-\(Self.fileStem(forLot: lotNumber)).json")
    }

    /// Sanitised, length-bounded stem of a lot number.
    static func fileStem(forLot lotNumber: String) -> String {
        let allowed = lotNumber.lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "-"
        }
        let stem = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return stem.isEmpty ? "unknown" : String(stem.prefix(60))
    }

    private func key(forLot lotNumber: String) -> String { lotNumber.lowercased() }

    /// Encoder/decoder pair, so the on-disk shape is one decision rather than two.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
