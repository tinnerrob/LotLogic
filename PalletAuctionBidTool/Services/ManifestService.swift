//
//  ManifestService.swift
//  PalletAuctionBidTool
//
//  The manifest (identity) half of a batched appraisal, as a role any transport can fill.
//

import Foundation

/// One batch of a lot's photographs, as the question that reads it into manifest items.
///
/// The whole of what a batch request *is*: which frames of the gallery travel, the frames
/// themselves, the listing text, and the app's own reading of those frames. It is a value rather
/// than six parameters so that the batched route can hand the same question to whichever transport
/// the identity role is pointed at — the frame-by-frame transport builds a `:generateContent` body
/// from it, the batching transport an OpenAI-compatible body, and the two cannot drift from each
/// other about what a batch is told.
struct ManifestBatchRequest: Sendable {

    /// The lot's listing text, or `""` when its page carried none.
    let description: String

    /// 1-based number of this batch among the lot's batches.
    let batch: Int

    /// How many batches the lot's gallery was split into.
    let batchCount: Int

    /// The gallery numbers of the frames this batch carries, in gallery order — which is the
    /// numbering the answer's `views` and `unreadPhotos` are given in.
    let positions: [Int]

    /// The frames themselves, in the same order as `positions`.
    let images: [LotImage]

    /// How many photographs the lot's gallery holds, so a batch can say *"photograph 3 of 24 is
    /// attached"* rather than speaking as though its own frames were the pallet's first.
    let imageCount: Int

    /// What the app's own reader found on **these** frames (`LotImageDigest`), never the gallery's:
    /// a barcode decoded off photograph 3 is not evidence about photograph 9.
    let evidence: LotImageEvidence
}

/// Reads a batch of a lot's photographs into manifest items: the **identity** half of a batched
/// appraisal, separated from the pricing half that turns the inventory into money.
///
/// The batched route has always been one transport doing both jobs — DeepSeek read each batch of
/// frames into a manifest and then priced that inventory in text-only requests. The two jobs want
/// different models: reading a carton's printed identifiers and its count off a photograph is a
/// vision problem, and pricing a barcode afterwards is not. So the identity half is a role any
/// transport can fill (`AppSettings.identityProvider`), and `DeepSeekValuationService` takes one as
/// an optional dependency: with none given it reads its own batches exactly as it always has, and
/// with one given the frames' identity is decided by that model while the prices stay here.
///
/// Both transports conform, and they differ only in how the answer is *constrained*: Gemini is
/// handed `LotManifestPrompt.manifestSchema` as `responseSchema`, so the shape is enforced by the
/// API rather than requested in prose; DeepSeek offers `json_object` and no strict mode, so the same
/// schema is rendered to JSON Schema text (`jsonSchemaText`) and embedded in the prompt.
///
/// The answer is a `ManifestBatchAnswer` rather than a bare `[ManifestItem]`: it carries the
/// batch's *accounting* as well as its goods (`unreadPhotos`), because a frame in neither list is a
/// product the inventory may be short of, and that is something only the route can see
/// (`ManifestBatchAnswer.unaccountedFrames(among:)`).
protocol ManifestService: Sendable {

    /// The model that reads the batches — what the console line and the run's own record name, so the
    /// model a price was read through is a fact rather than an inference from which provider paid.
    var modelID: String { get }

    /// Reads one batch of a lot's photographs into manifest items.
    ///
    /// Throws for a refused or malformed request; the *route* decides what a failed batch costs (a
    /// hole in the inventory, reported to the console, rather than a failed lot).
    func manifestBatch(_ request: ManifestBatchRequest) async throws -> ManifestBatchAnswer
}
