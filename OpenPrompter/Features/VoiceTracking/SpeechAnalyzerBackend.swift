//
//  SpeechAnalyzerBackend.swift
//  OpenPrompter
//
//  V3 Design 05 — SpeechAnalyzer Biasing, Slice B (iOS 26+ backend).
//
//  An alternative transcription engine built on the modern iOS 26
//  `SpeechAnalyzer` + `SpeechTranscriber` API. It biases recognition with
//  `AnalysisContext.contextualStrings` set to the SAME distinctiveness-
//  ranked `ScriptBiasVocabulary` the SF path uses (Slice A). Emits the
//  same `[String]` cumulative word stream into the SAME
//  `handleRecognizerResult(allWords:)` sink, so the aligner + momentum
//  controller see no new shape.
//
//  ╭─────────────────────────── SAFETY POSTURE ──────────────────────────╮
//  │ This whole type is `@available(iOS 26, *)`. `VoiceTracker` only      │
//  │ instantiates it behind `if #available(iOS 26, *) &&                  │
//  │ Prefs.voiceUseSpeechAnalyzer` — DEBUG-on / Release-OFF for the first │
//  │ submission (per CLAUDE.md "don't promise a fix because the simulator │
//  │ is happy"). The SDK's locale / asset-availability APIs are all       │
//  │ `async`, so the synchronous `start()` can only check the cheap       │
//  │ synchronous `SpeechTranscriber.isAvailable`; the real model-         │
//  │ availability probe + analyzer bring-up run in a Task. If that Task   │
//  │ finds the model missing / locale unsupported / analyzer refused, it  │
//  │ calls `onUnavailable` (before any words) and VoiceTracker RETRIES    │
//  │ with `SFSpeechBackend` in the same session. The iOS 26 path can      │
//  │ NEVER make voice tracking worse than today — worst case it silently  │
//  │ uses the exact current engine.                                       │
//  ╰──────────────────────────────────────────────────────────────────────╯
//
//  We take from SpeechAnalyzer: contextual-string biasing (the whole
//  point), the volatile (partial) word stream, on-device transcription.
//  We IGNORE for now: `audioTimeRange` per-token attributes (requested via
//  attributeOptions so §8 pacing can consume them later, but consumed into
//  NO scroll math here).
//
//  See V3 Design 05 — SpeechAnalyzer Biasing.md §4.3, §6.2.
//

import AVFoundation
import Foundation
import Speech

@available(iOS 26, *)
@MainActor
final class SpeechAnalyzerBackend: SpeechBackend {

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?

    /// The mic tap engine. Buffers are yielded into the analyzer's input.
    private var audioEngine: AVAudioEngine?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    /// The task consuming `transcriber.results`. Cancelled on stop.
    private var resultsTask: Task<Void, Never>?
    /// The task that performs the async bring-up (availability probe +
    /// analyzer start). Cancelled on stop so a slow cold-start can't fire
    /// callbacks after the caller tore us down.
    private var bringUpTask: Task<Void, Never>?

    /// Set true once teardown has run, so late callbacks from the async
    /// bring-up are swallowed rather than delivered after stop().
    private var stopped = false

    init() {}

    @discardableResult
    func start(
        locale: Locale,
        contextualStrings: [String],
        onWords: @escaping @MainActor ([String]) -> Void,
        onTranscription: @escaping @MainActor (String) -> Void,
        onFinal: @escaping @MainActor () -> Void,
        onUnavailable: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) -> Bool {
        // Cheapest synchronous gate. If the framework says the transcriber
        // is unavailable on this device, don't even claim the mic — let
        // VoiceTracker use SF immediately (return false).
        guard SpeechTranscriber.isAvailable else {
            return false
        }

        // Everything else the SDK exposes is async. Kick the bring-up off in
        // a Task and return `true` optimistically. The Task decides whether
        // the engine actually runs; if not it calls `onUnavailable` and
        // VoiceTracker retries SF.
        bringUpTask = Task { [weak self] in
            await self?.bringUp(
                locale: locale,
                contextualStrings: contextualStrings,
                onWords: onWords,
                onTranscription: onTranscription,
                onFinal: onFinal,
                onUnavailable: onUnavailable,
                onError: onError
            )
        }
        return true
    }

    // MARK: - Async bring-up

    private func bringUp(
        locale: Locale,
        contextualStrings: [String],
        onWords: @escaping @MainActor ([String]) -> Void,
        onTranscription: @escaping @MainActor (String) -> Void,
        onFinal: @escaping @MainActor () -> Void,
        onUnavailable: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) async {
        // `bringUp` is MainActor-isolated (the whole type is @MainActor), so
        // callbacks and property writes here run on the main actor directly.
        // The `stopped` guard after each `await` swallows late work if the
        // caller tore us down mid-cold-start.

        // Resolve a supported locale equivalent to the requested one. If the
        // framework can't map it, the analyzer can't transcribe → fall back.
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            if !stopped { onUnavailable() }
            return
        }
        if stopped { return }

        // Build the transcriber. Request the time attribute so a future §8
        // pacing slice can consume it — we consume NONE here.
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        // §6.2 cold-start budget: if the on-device model isn't installed,
        // do NOT block the teleprompter on an asset download. Kick a
        // background install for next time and fall back to SF now.
        let status = await AssetInventory.status(forModules: [transcriber])
        if stopped { return }
        if status != .installed {
            // Fire-and-forget: kick the install for a LATER session but do NOT
            // await it here. Blocking the teleprompter start on a multi-minute
            // model download (mic engaged, zero words, no fallback) violates
            // §6.2. Fall back to SF immediately.
            Task { [weak self] in await self?.installInBackground(transcriber: transcriber) }
            if !stopped { onUnavailable() }
            return
        }

        // Modern, first-class biasing API: the direct replacement for
        // SFSpeechAudioBufferRecognitionRequest.contextualStrings. Keyed by
        // the `.general` tag.
        let context = AnalysisContext()
        if !contextualStrings.isEmpty {
            context.contextualStrings = [.general: contextualStrings]
        }
        // NOTE (§5.4): AnalysisContext.contextualStrings CAN be reassigned
        // on the live analyzer to re-bias toward cursor-local terms as the
        // reader advances. Intentionally NOT wired here — it touches cadence
        // and risks de-tuning latency. Do not enable without device A/B.

        // The analyzer consumes audio in a SPECIFIC format — NOT the mic's
        // native hardware format. Ask the SDK which format THIS transcriber
        // wants; the mic tap (below) converts every buffer into it. Feeding
        // raw mic buffers (e.g. 48 kHz Float32) when the analyzer expects a
        // different sample rate / layout makes `transcriber.results` throw on
        // the first buffer, which surfaced as the voice button flipping ON
        // then instantly OFF. If the SDK can't name a compatible format we
        // can't feed the analyzer safely → fall back to SF.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            if !stopped { onUnavailable() }
            return
        }
        if stopped { return }

        // Input stream the analyzer consumes. The mic tap yields buffers in.
        // The `inputSequence:` init begins analysis on creation — the analyzer
        // pulls from `stream` as the tap fills it, so there is NO separate
        // `start(inputSequence:)` call (that pairs with the module-only init).
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(
            inputSequence: stream,
            modules: [transcriber],
            analysisContext: context
        )

        // If we were torn down during the awaits above, clean up the
        // just-built analyzer + stream and bail without claiming the mic.
        if stopped {
            continuation.finish()
            return
        }

        // Stand up the mic tap. If the engine won't start, fall back to SF.
        guard startAudioEngineTap(analyzerFormat: analyzerFormat, into: continuation) else {
            continuation.finish()
            teardownPartial()
            if !stopped { onUnavailable() }
            return
        }

        // Commit our state (MainActor — no hop needed).
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.inputContinuation = continuation

        // Consume results OFF the main actor so the async iteration never
        // blocks UI. Each result carries the cumulative best transcription
        // (`.text`); map it to the same word-list shape SF produces and hop
        // to main to forward. A natural end of the stream → onFinal (re-arm
        // like SF isFinal). A thrown error after start → onError.
        //
        // Each hop routes through `deliver(_:)`, which runs on the main actor,
        // re-checks `stopped`, and invokes the callback. Binding `weak self`
        // to a single `let` (not re-capturing the mutable `self` var inside a
        // nested Sendable closure) avoids the Swift 6 SendableClosureCaptures
        // diagnostic.
        resultsTask = Task.detached { [weak self, weak transcriber] in
            guard let transcriber else { return }
            let backend = self
            do {
                for try await result in transcriber.results {
                    let words = Self.words(from: result.text)
                    let plain = String(result.text.characters)
                    await backend?.deliver { onTranscription(plain); onWords(words) }
                }
                await backend?.deliver { onFinal() }
            } catch {
                await backend?.deliver { onError("SpeechAnalyzer: \(String(describing: error))") }
            }
        }
    }

    /// Run `action` on the main actor iff we haven't been stopped. The single
    /// isolation hop makes the `stopped` re-check and the callback atomic with
    /// respect to `stop()` (both run on the main actor's serial executor).
    private func deliver(_ action: @MainActor () -> Void) {
        guard !stopped else { return }
        action()
    }

    // MARK: - Audio

    /// Install the mic tap. Converts each PCM buffer from the mic's native
    /// hardware format to the analyzer's required `analyzerFormat` (via
    /// `AVAudioConverter`) BEFORE yielding it into the analyzer input.
    ///
    /// SpeechAnalyzer does NOT resample / re-lay-out incompatible input on our
    /// behalf — the old "the analyzer performs any required format conversion
    /// internally" comment here was FALSE. Feeding raw mic buffers made
    /// `transcriber.results` throw on the first buffer (the voice-button ON→OFF
    /// flip). Every reference implementation (Apple's WWDC25 sample included)
    /// runs each tap buffer through an `AVAudioConverter` into
    /// `bestAvailableAudioFormat(compatibleWith:)` first — this does the same.
    ///
    /// Returns false if the engine refused to start or the converter couldn't
    /// be built.
    private func startAudioEngineTap(
        analyzerFormat: AVAudioFormat,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) -> Bool {
        _ = AudioSessionCoordinator.shared.claim(.voiceTracking, configuration: .capture)
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else { return false }

        // Build a converter only when the mic format differs from what the
        // analyzer needs (it virtually always does — the mic delivers 48 kHz
        // Float32; the analyzer typically wants a different sample rate). When
        // they already match we yield straight through. `.none` prime skips
        // seeding leading frames so the input/output timelines stay aligned
        // for live capture (matches Apple's WWDC25 sample).
        let converter: AVAudioConverter?
        if micFormat == analyzerFormat {
            converter = nil
        } else {
            guard let built = AVAudioConverter(from: micFormat, to: analyzerFormat) else {
                return false
            }
            built.primeMethod = .none
            converter = built
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { buffer, _ in
            guard let converter else {
                continuation.yield(AnalyzerInput(buffer: buffer))
                return
            }
            // A single failed convert is not fatal — drop that buffer and
            // keep capturing rather than tearing recognition down.
            guard let converted = Self.convert(
                buffer, using: converter, to: analyzerFormat
            ) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            return false
        }
        self.audioEngine = engine
        return true
    }

    /// Convert one mic buffer into the analyzer's format. Sizes the output
    /// buffer by the sample-rate ratio (rounded up) so a downsample never
    /// truncates, then runs a one-shot `convert(to:error:withInputFrom:)` that
    /// hands the whole input buffer over once and reports `.noDataNow`
    /// thereafter. Returns nil on a hard converter error (the caller drops the
    /// buffer). `nonisolated` so it runs on the tap queue without a hop.
    nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        // `.haveData` / `.inputRanDry` both leave valid frames in `output`
        // (the converter sets frameLength); only `.error` is fatal.
        guard status != .error else { return nil }
        return output
    }

    // MARK: - Teardown

    func stop() {
        guard !stopped else { return }
        stopped = true
        bringUpTask?.cancel()
        bringUpTask = nil
        teardownPartial()
    }

    /// Tear down whatever was brought up, whether or not `bringUp`
    /// completed. Idempotent.
    private func teardownPartial() {
        resultsTask?.cancel()
        resultsTask = nil

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
        inputContinuation?.finish()
        inputContinuation = nil

        // Ask the analyzer to finalize + tear down. Fire-and-forget: we're
        // stopping regardless of the result.
        if let analyzer = analyzer {
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }
        analyzer = nil
        transcriber = nil

        AudioSessionCoordinator.shared.release(.voiceTracking)
    }

    // MARK: - Helpers

    /// Kick a background download of the on-device model so the analyzer is
    /// ready on a later session. Fire-and-forget; failures are silent (we
    /// already fell back to SF this session).
    private func installInBackground(transcriber: SpeechTranscriber) async {
        guard let request = try? await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else { return }
        try? await request.downloadAndInstall()
    }

    /// Split an AttributedString transcription into surface words, matching
    /// the shape SF produces (`segments.map(\.substring)`): whitespace-
    /// separated tokens with surrounding punctuation trimmed, so the aligner
    /// (which does NOT re-tokenize the recognized buffer — it lowercases +
    /// phonetically encodes each word as-is) sees the same clean words from
    /// both backends. Empty tokens (pure punctuation) are dropped.
    nonisolated static func words(from text: AttributedString) -> [String] {
        let plain = String(text.characters)
        return plain
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { raw -> String in
                // Trim leading/trailing characters that aren't letters/digits
                // (quotes, commas, periods). Internal characters are left
                // alone — the aligner normalizes further downstream.
                var chars = Array(raw)
                while let first = chars.first, !first.isLetter, !first.isNumber {
                    chars.removeFirst()
                }
                while let last = chars.last, !last.isLetter, !last.isNumber {
                    chars.removeLast()
                }
                return String(chars)
            }
            .filter { !$0.isEmpty }
    }
}
