import Foundation
import os

/// ASR client that connects to the local SenseVoice Python server via WebSocket.
actor SenseVoiceWSClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "com.type4me.asr", category: "SenseVoiceWS")

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    /// Running text from the server (latest partial or final).
    private var currentText: String = ""
    private var confirmedSegments: [String] = []

    // Qwen3 incremental speculative transcription
    private var qwen3DebounceTask: Task<Void, Never>?
    private var allAudioData: Data = Data()
    private var qwen3ConfirmedOffset: Int = 0
    private var qwen3ConfirmedSegments: [String] = []
    private var qwen3LatestText: String?
    private var qwen3HasPendingAudio: Bool = false

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        return stream
    }

    // MARK: - Connect

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        // Fresh event stream
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        currentText = ""
        confirmedSegments = []
        resetQwen3State()

        // Ensure server is running (may still be loading model from app launch)
        let mgr = SenseVoiceServerManager.shared
        let running = await mgr.isRunning
        if !running {
            try await mgr.start()
        }

        // Wait for server to become healthy (model loading can take ~10s)
        var healthy = false
        for _ in 0..<30 {
            if await mgr.isHealthy() { healthy = true; break }
            try await Task.sleep(for: .seconds(1))
        }
        guard healthy else {
            throw SenseVoiceWSError.serverNotHealthy
        }

        guard let url = await mgr.serverWSURL else {
            throw SenseVoiceWSError.serverNotRunning
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()
        self.webSocketTask = task

        startReceiveLoop()
        eventContinuation?.yield(.ready)
        logger.info("SenseVoiceWS connected to \(url)")
    }

    // MARK: - Send Audio

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }
        try await task.send(.data(data))

        // Accumulate audio for Qwen3 speculative transcription
        allAudioData.append(data)
        qwen3HasPendingAudio = true
        scheduleSpeculativeQwen3()
    }

    // MARK: - End Audio

    func endAudio() async throws {
        guard let task = webSocketTask else { return }
        qwen3DebounceTask?.cancel()

        let newAudioBytes = allAudioData.count - qwen3ConfirmedOffset
        let hasQwen3Result = !qwen3ConfirmedSegments.isEmpty
        let newAudioTrivial = newAudioBytes < 2 * 16000 * 2  // < 2s of new audio @ 16kHz 16-bit

        if hasQwen3Result && newAudioTrivial {
            // Qwen3 has confirmed most of the audio, only a short tail left
            var finalText = qwen3ConfirmedSegments.joined()

            if newAudioBytes > 3200, let port = SenseVoiceServerManager.currentQwen3Port {
                // Quick Qwen3 call for the short tail
                let deltaAudio = allAudioData.suffix(from: qwen3ConfirmedOffset)
                let url = URL(string: "http://127.0.0.1:\(port)/transcribe")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(deltaAudio)
                request.timeoutInterval = 10
                if let (data, _) = try? await URLSession.shared.data(for: request),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tailText = json["text"] as? String, !tailText.isEmpty {
                    finalText += tailText
                }
            }

            // Use Qwen3 assembled result directly
            task.cancel(with: .normalClosure, reason: nil)
            confirmedSegments = [finalText]
            currentText = ""
            let transcript = RecognitionTranscript(
                confirmedSegments: confirmedSegments,
                partialText: "",
                authoritativeText: finalText,
                isFinal: true
            )
            eventContinuation?.yield(.transcript(transcript))
            eventContinuation?.yield(.completed)
            DebugFileLogger.log("Qwen3 final: used incremental result (\(qwen3ConfirmedSegments.count) segments, \(finalText.count) chars)")
        } else {
            // No Qwen3 result or too much new audio, fall back to SenseVoice final
            try await task.send(.data(Data()))
            DebugFileLogger.log("SenseVoice final: fallback (Qwen3 segments=\(qwen3ConfirmedSegments.count), newAudio=\(newAudioBytes)b)")
        }

        resetQwen3State()
    }

    // MARK: - Qwen3 Speculative

    private func scheduleSpeculativeQwen3() {
        qwen3DebounceTask?.cancel()
        qwen3DebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard await self.qwen3HasPendingAudio else { return }
            guard let port = SenseVoiceServerManager.currentQwen3Port else { return }

            let deltaAudio = await self.allAudioData.suffix(from: self.qwen3ConfirmedOffset)
            guard deltaAudio.count > 3200 else { return }  // at least 100ms of audio

            let url = URL(string: "http://127.0.0.1:\(port)/transcribe")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(deltaAudio)
            request.timeoutInterval = 30

            DebugFileLogger.log("Qwen3 speculative: sending \(deltaAudio.count) bytes (offset \(await self.qwen3ConfirmedOffset))")

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["text"] as? String, !text.isEmpty {
                    await self.confirmQwen3Segment(text)
                }
            } catch {
                DebugFileLogger.log("Qwen3 speculative: failed \(error)")
            }
        }
    }

    private func confirmQwen3Segment(_ text: String) {
        qwen3ConfirmedSegments.append(text)
        qwen3ConfirmedOffset = allAudioData.count
        qwen3LatestText = nil
        qwen3HasPendingAudio = false
        DebugFileLogger.log("Qwen3 speculative: confirmed segment \(qwen3ConfirmedSegments.count): \(text.count) chars")
    }

    private func resetQwen3State() {
        allAudioData = Data()
        qwen3ConfirmedOffset = 0
        qwen3ConfirmedSegments = []
        qwen3LatestText = nil
        qwen3HasPendingAudio = false
    }

    // MARK: - Disconnect

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        logger.info("SenseVoiceWS disconnected")
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        await self.logger.info("SenseVoiceWS receive loop ended: \(error)")
                        await self.eventContinuation?.yield(.completed)
                    }
                    break
                }
            }
            await self.eventContinuation?.finish()
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { return }

            switch type {
            case "transcript":
                let recognizedText = json["text"] as? String ?? ""
                let isFinal = json["is_final"] as? Bool ?? false

                if isFinal {
                    if !recognizedText.isEmpty {
                        confirmedSegments.append(recognizedText)
                    }
                    currentText = ""
                } else {
                    currentText = recognizedText
                }

                let composedText = (confirmedSegments + (currentText.isEmpty ? [] : [currentText])).joined()

                let transcript = RecognitionTranscript(
                    confirmedSegments: confirmedSegments,
                    partialText: isFinal ? "" : currentText,
                    authoritativeText: isFinal ? composedText : "",
                    isFinal: isFinal
                )
                eventContinuation?.yield(.transcript(transcript))

                DebugFileLogger.log("SenseVoiceWS: confirmed=\(confirmedSegments.count) partial=\(currentText.count) composed=\(composedText.count) isFinal=\(isFinal)")

            case "completed":
                eventContinuation?.yield(.completed)
                logger.info("SenseVoiceWS: server signaled completion")

            case "error":
                let msg = json["message"] as? String ?? "Unknown server error"
                logger.error("SenseVoiceWS server error: \(msg)")
                eventContinuation?.yield(.error(NSError(
                    domain: "SenseVoice", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )))

            default:
                break
            }

        case .data:
            // We don't expect binary from server
            break

        @unknown default:
            break
        }
    }
}

// MARK: - Errors

enum SenseVoiceWSError: Error, LocalizedError {
    case serverNotRunning
    case serverNotHealthy

    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return L("SenseVoice 服务未启动", "SenseVoice server not running")
        case .serverNotHealthy:
            return L("SenseVoice 服务未就绪", "SenseVoice server not ready")
        }
    }
}
