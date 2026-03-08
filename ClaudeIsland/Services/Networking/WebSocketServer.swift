//
//  WebSocketServer.swift
//  ClaudeIsland
//
//  WebSocket server for iOS companion app connections
//

import Foundation
import Combine
import Network

// MARK: - Data Extension for Hex String

extension Data {
    var hexString: String {
        return self.map { String(format: "%02x", $0) }.joined()
    }
}

extension Array where Element == UInt8 {
    var hexString: String {
        return self.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - WebSocket Server

@MainActor
class WebSocketServer: ObservableObject {
    static let shared = WebSocketServer()

    // MARK: - Published State

    @Published var isRunning: Bool = false
    @Published var connectedClients: [WebSocketClient] = []
    @Published var port: UInt16 = 8081

    // MARK: - Private

    private var listener: NWListener?
    private let authTokenManager = AuthTokenManager.shared
    private let tokenStorage = TokenStorage.shared

    // MARK: - Dependencies

    private let sessionMonitor = ClaudeSessionMonitor()
    private let chatHistoryManager = ChatHistoryManager.shared

    // Track last broadcast message counts per session
    fileprivate var lastMessageCounts: [String: Int] = [:]

    // MARK: - Singleton

    private init() {
        setupSessionMonitoring()
        setupChatHistoryMonitoring()
    }

    // MARK: - Session Monitoring

    private func setupSessionMonitoring() {
        // Monitor session changes and broadcast to connected clients
        sessionMonitor.$instances
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.broadcastSessionUpdate(sessions)
            }
            .store(in: &cancellables)
    }

    // MARK: - Chat History Monitoring

    private func setupChatHistoryMonitoring() {
        // Monitor chat history changes and broadcast new messages to iOS
        chatHistoryManager.$histories
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] histories in
                self?.broadcastNewChatMessages(histories)
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Server Control

    /// Start the WebSocket server
    func start() throws {
        guard !isRunning else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.allowFastOpen = true

        // Note: WebSocket upgrade will be handled manually in connection handler

        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        guard let listener = listener else {
            throw WebSocketError.listenerCreationFailed
        }

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleStateChange(state)
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener.start(queue: .main)
        isRunning = true
        print("📡 WebSocket Server started on port \(port)")
    }

    /// Stop the WebSocket server
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        connectedClients.removeAll()
        print("📡 WebSocket Server stopped")
    }

    // MARK: - Connection Handling

    private func handleStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            break
        case .failed(let error):
            print("❌ WebSocket Server failed: \(error)")
            stop()
        case .waiting(let error):
            print("⚠️ WebSocket Server waiting: \(error)")
        default:
            break
        }
    }

    private nonisolated func handleNewConnection(_ connection: NWConnection) {
        // Create client and pass connection for immediate use
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            let client = WebSocketClient(connection: connection)

            // Start receiving immediately
            client.beginReceiving { [weak self] message in
                Task { @MainActor in
                    await self?.handleMessage(from: client, message: message)
                }
            }

            self.connectedClients.append(client)

            // Start connection timeout timer
            Task {
                try? await Task.sleep(nanoseconds: UInt64(5 * 1_000_000_000))
                if await !client.isAuthenticated {
                    await client.disconnect()
                    Task { @MainActor in
                        self.connectedClients.removeAll { $0.id == client.id }
                    }
                }
            }
        }

        // Start connection on a background queue
        let queue = DispatchQueue(label: "com.claudeisland.connection")
        connection.start(queue: queue)
        print("📱 Connection started")
    }

    // MARK: - Message Handling

    private func handleMessage(from client: WebSocketClient, message: WebSocketMessage) async {
        switch message.type {
        case .auth:
            await handleAuthMessage(from: client, payload: message.payload)
        case .control:
            await handleControlMessage(from: client, payload: message.payload)
        case .pushToken:
            await handlePushTokenMessage(from: client, payload: message.payload)
        default:
            break
        }
    }

    private func handleAuthMessage(from client: WebSocketClient, payload: WebSocketMessage.Payload) async {
        guard case .auth(let authPayload) = payload else { return }

        print("📝 [Auth] Received authentication request")
        print("   Device: \(authPayload.deviceInfo.name)")
        print("   Token prefix: \(authPayload.token.prefix(20))...")

        // Validate token
        let validationResult = authTokenManager.validateToken(authPayload.token)

        switch validationResult {
        case .valid(let tokenData):
            print("✅ [Auth] Token signature is valid")

            // Check if token was already used (one-time use)
            if tokenStorage.isTokenUsed(authPayload.token) {
                print("❌ [Auth] Token was already used (one-time use)")
                await client.send(errorCode: .invalidToken)
                await client.disconnect()
                return
            }

            // Mark token as used
            tokenStorage.markTokenUsed(authPayload.token)
            print("✅ [Auth] Token marked as used")

            // Authenticate client
            await client.authenticate(deviceInfo: authPayload.deviceInfo)

            print("✅ [Auth] Client authenticated: \(authPayload.deviceInfo.name)")

            // Send initial session state
            let dto = sessionMonitor.instances.map { SessionStateDTO(from: $0) }
            print("📤 [Auth] Sending \(dto.count) sessions to client")
            await client.send(sessions: dto, isProcessing: false, hasWaitingForInput: false, hasPendingPermissions: false)

        case .invalid(let error):
            print("❌ [Auth] Token validation failed: \(error)")
            await client.send(errorCode: .invalidToken)
            await client.disconnect()
        }
    }

    private func handleControlMessage(from client: WebSocketClient, payload: WebSocketMessage.Payload) async {
        guard case .control(let controlPayload) = payload else { return }

        // Only process control from authenticated clients
        guard await client.isAuthenticated else {
            await client.disconnect()
            return
        }

        switch controlPayload.command {
        case .openSession:
            if let sessionId = controlPayload.sessionId {
                // Handle opening session (notify Mac app)
                NotificationCenter.default.post(
                    name: .openSessionFromiOS,
                    object: nil,
                    userInfo: ["sessionId": sessionId]
                )
            }
        case .stopProcessing:
            // Handle stop command
            NotificationCenter.default.post(
                name: .stopProcessingFromiOS,
                object: nil
            )
        default:
            break
        }
    }

    private func handlePushTokenMessage(from client: WebSocketClient, payload: WebSocketMessage.Payload) async {
        guard case .pushToken(let pushTokenPayload) = payload else { return }

        // Process push token registration
        // Only accept from authenticated clients
        guard await client.isAuthenticated else {
            await client.disconnect()
            return
        }

        // Register the push token with SimplePushService
        SimplePushService.shared.registerDeviceToken(
            deviceId: client.id.uuidString,
            pushToken: pushTokenPayload.token,
            deviceInfo: pushTokenPayload.deviceInfo
        )

        print("✅ Push token registered for device: \(pushTokenPayload.deviceInfo)")
    }

    // MARK: - Broadcasting

    private func broadcastSessionUpdate(_ sessions: [SessionState]) {
        let isProcessing = sessions.contains { $0.phase == .processing || $0.phase == .compacting }
        let hasWaitingForInput = sessions.contains { $0.phase == .waitingForInput }
        let hasPendingPermissions = sessions.contains { $0.phase.isWaitingForApproval }

        let dto = sessions.map { SessionStateDTO(from: $0) }

        Task {
            for client in connectedClients {
                if await client.isAuthenticated {
                    await client.send(sessions: dto, isProcessing: isProcessing, hasWaitingForInput: hasWaitingForInput, hasPendingPermissions: hasPendingPermissions)
                }
            }
        }
    }

    private func broadcastNewChatMessages(_ histories: [String: [ChatHistoryItem]]) {
        Task {
            for client in connectedClients {
                if await client.isAuthenticated {
                    await client.broadcastChatMessages(histories)
                }
            }
        }
    }

    // MARK: - Message Conversion

    /// Convert ChatHistoryItem to ChatMessagePayload for iOS
    fileprivate func convertToChatMessagePayload(_ item: ChatHistoryItem, sessionId: String) -> ChatMessagePayload? {
        let timestamp = item.timestamp

        switch item.type {
        case .user(let content):
            return ChatMessagePayload(
                sessionId: sessionId,
                messageId: item.id,
                content: content,
                role: "user",
                timestamp: timestamp,
                isToolUse: false,
                toolName: nil,
                toolInput: nil,
                toolResult: nil,
                toolStatus: nil,
                structuredResult: nil,
                thinking: nil,
                isInterrupted: false
            )

        case .assistant(let content):
            return ChatMessagePayload(
                sessionId: sessionId,
                messageId: item.id,
                content: content,
                role: "assistant",
                timestamp: timestamp,
                isToolUse: false,
                toolName: nil,
                toolInput: nil,
                toolResult: nil,
                toolStatus: nil,
                structuredResult: nil,
                thinking: nil,
                isInterrupted: false
            )

        case .thinking(let content):
            return ChatMessagePayload(
                sessionId: sessionId,
                messageId: item.id,
                content: "",  // Thinking messages have no content
                role: "system",
                timestamp: timestamp,
                isToolUse: false,
                toolName: nil,
                toolInput: nil,
                toolResult: nil,
                toolStatus: nil,
                structuredResult: nil,
                thinking: content,
                isInterrupted: false
            )

        case .interrupted:
            return ChatMessagePayload(
                sessionId: sessionId,
                messageId: item.id,
                content: "",
                role: "system",
                timestamp: timestamp,
                isToolUse: false,
                toolName: nil,
                toolInput: nil,
                toolResult: nil,
                toolStatus: nil,
                structuredResult: nil,
                thinking: nil,
                isInterrupted: true
            )

        case .toolCall(let tool):
            // Convert tool status to string
            let toolStatus: String?
            switch tool.status {
            case .running:
                toolStatus = "running"
            case .waitingForApproval:
                toolStatus = "waitingForApproval"
            case .success:
                toolStatus = "success"
            case .error, .interrupted:
                toolStatus = "error"
            }

            // Use input preview for content
            let content = "🔧 \(tool.name): \(tool.inputPreview)"

            return ChatMessagePayload(
                sessionId: sessionId,
                messageId: item.id,
                content: content,
                role: "assistant",
                timestamp: timestamp,
                isToolUse: true,
                toolName: tool.name,
                toolInput: tool.input,
                toolResult: tool.result,
                toolStatus: toolStatus,
                structuredResult: nil,  // TODO: Implement ToolResultData -> JSON conversion
                thinking: nil,
                isInterrupted: false
            )
        }
    }

    // MARK: - Cleanup

    func disconnectClient(_ client: WebSocketClient) {
        Task { @MainActor in
            connectedClients.removeAll { $0.id == client.id }
            await client.disconnect()
        }
    }
}

// MARK: - WebSocket Client

@MainActor
class WebSocketClient: Identifiable {
    let id = UUID()
    private let connection: NWConnection
    private(set) var isAuthenticated = false
    private var deviceInfo: AuthPayload.DeviceInfo?
    private var isHandshakeComplete = false
    private var onMessageCallback: ((WebSocketMessage) -> Void)?
    private let connectionQueue = DispatchQueue(label: "com.claudeisland.websocket.client")

    // Buffer for handshake data received before connection is ready
    private var bufferedHandshakeData: Data?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func beginReceiving(onMessage: @escaping (WebSocketMessage) -> Void) {
        self.onMessageCallback = onMessage
        // Start receiving immediately on main queue
        receiveData()
    }

    private func receiveData() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                let errMsg = "❌ WebSocket receive error: \(error)"
                print(errMsg)
                self.writeLog(errMsg)
                return
            }

            if let data = data, !data.isEmpty {
                let logMsg = "📥 [Receive] Got \(data.count) bytes, handshakeComplete: \(self.isHandshakeComplete)"
                print(logMsg)
                self.writeLog(logMsg)

                // Process immediately
                if !self.isHandshakeComplete {
                    self.handleHandshake(data: data)
                } else {
                    self.handleMessage(data: data)
                }
            }

            // Continue receiving as long as there's no error
            // Ignore isComplete flag as it may be incorrectly set after successful receives
            if error == nil {
                self.receiveData()
            } else {
                let logMsg = "🔚 [Receive] Connection error, stopping receive loop"
                print(logMsg)
                self.writeLog(logMsg)
            }
        }
    }

    private func writeLog(_ message: String) {
        // Use thread-safe file writing with a lock
        let logPath = "/tmp/claude-server-debug.txt"
        if let data = (message + "\n").data(using: .utf8) {
            // Use FileHandle with proper synchronization
            if let handle = FileHandle(forWritingAtPath: logPath) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                // Create file if it doesn't exist
                try? data.write(to: URL(fileURLWithPath: logPath), options: .atomic)
            }
        }
    }

    private func handleHandshake(data: Data) {
        // Log raw data for debugging
        writeLog("🤝 [Handshake] Entering handleHandshake with \(data.count) bytes")

        // Parse HTTP request
        guard let requestString = String(data: data, encoding: .utf8) else {
            writeLog("❌ Failed to convert handshake data to string")
            print("❌ Failed to convert handshake data to string")
            return
        }

        writeLog("✅ Converted to string: \(requestString.count) chars")
        print("🤝 [Handshake] Received handshake request")
        print("   Request (first 200 chars): \(requestString.prefix(200))")

        // Check if this is a WebSocket upgrade request
        if requestString.contains("Upgrade: websocket") {
            // Extract Sec-WebSocket-Key
            let lines = requestString.components(separatedBy: "\r\n")
            var webSocketKey: String?
            for line in lines {
                if line.lowercased().hasPrefix("sec-websocket-key:") {
                    webSocketKey = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
                    break
                }
            }

            guard let key = webSocketKey else {
                print("❌ Missing WebSocket key in handshake")
                return
            }

            print("✅ [Handshake] WebSocket key extracted: \(key.prefix(10))...")

            // Compute accept key
            let acceptKey = self.computeAcceptKey(key)
            print("✅ [Handshake] Accept key computed: \(acceptKey.prefix(10))...")

            // Send HTTP 101 response (no indentation to avoid extra spaces)
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n"

            if let responseData = response.data(using: .utf8) {
                print("📤 [Handshake] Sending HTTP 101 response (\(responseData.count) bytes)")

                // Mark handshake as complete immediately so we can start receiving messages
                self.isHandshakeComplete = true
                print("✅ [Handshake] Handshake complete, ready to receive messages")

                // Send handshake response (don't block waiting for completion)
                connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        print("❌ Failed to send handshake response: \(error)")
                    } else {
                        print("✅ [Handshake] Response sent successfully")
                    }
                })
            }
        } else {
            print("⚠️ Received non-WebSocket upgrade request")
            print("   Content: \(requestString.prefix(500))")
        }
    }

    private func computeAcceptKey(_ key: String) -> String {
        let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magicGUID
        guard let combinedData = combined.data(using: .utf8) else { return "" }
        let hash = combinedData.sha1()
        return hash.base64EncodedString()
    }

    private func handleMessage(data: Data) {
        let logMessage = "📨 [Message] Received data: \(data.count) bytes"
        print(logMessage)
        writeLog(logMessage)

        let hexMsg = "   Hex: \(data.prefix(50).hexString)"
        print(hexMsg)
        writeLog(hexMsg)

        // Parse WebSocket frame
        // Client-to-server messages MUST be masked (RFC 6455)
        guard data.count > 2 else {
            let errorMsg = "❌ [Message] Data too short: \(data.count) bytes"
            print(errorMsg)
            writeLog(errorMsg)
            return
        }

        let byte0 = data[0]
        let byte1 = data[1]
        let isMasked = (byte1 & 0x80) != 0
        var payloadLength = Int(byte1 & 0x7F)
        var offset = 2

        let byteInfo = "   Byte0: 0x\(String(byte0, radix: 16)) (FIN: \((byte0 & 0x80) != 0), Opcode: \(byte0 & 0x0F))"
        let byteInfo2 = "   Byte1: 0x\(String(byte1, radix: 16)) (MASK: \(isMasked), Length: \(payloadLength))"
        print(byteInfo)
        print(byteInfo2)
        writeLog(byteInfo)
        writeLog(byteInfo2)

        // Handle extended payload length
        if payloadLength == 126 {
            guard data.count >= 4 else {
                let error = "❌ [Message] Extended length header incomplete"
                print(error)
                writeLog(error)
                return
            }
            payloadLength = Int(data[2]) << 8 | Int(data[3])
            offset += 2
            let extLenMsg = "   Extended length: \(payloadLength)"
            print(extLenMsg)
            writeLog(extLenMsg)
        } else if payloadLength == 127 {
            guard data.count >= 10 else {
                let error = "❌ [Message] 64-bit length header incomplete"
                print(error)
                writeLog(error)
                return
            }
            payloadLength = Int(data[2]) << 56 | Int(data[3]) << 48 |
                          Int(data[4]) << 40 | Int(data[5]) << 32 |
                          Int(data[6]) << 24 | Int(data[7]) << 16 |
                          Int(data[8]) << 8  | Int(data[9])
            offset += 8
            let len64Msg = "   64-bit length: \(payloadLength)"
            print(len64Msg)
            writeLog(len64Msg)
        }

        // Extract masking key if present
        var maskingKey: [UInt8]?
        if isMasked {
            guard data.count >= offset + 4 else {
                let error = "❌ [Message] Masking key incomplete"
                print(error)
                writeLog(error)
                return
            }
            maskingKey = Array(data[offset..<offset+4])
            offset += 4
            let maskMsg = "   Mask: \(maskingKey!.hexString)"
            print(maskMsg)
            writeLog(maskMsg)
        } else {
            let warning = "⚠️ [Message] Message is not masked (client messages should be masked)"
            print(warning)
            writeLog(warning)
        }

        // Extract and unmask payload
        guard data.count >= offset + payloadLength else {
            let error = "❌ [Message] Payload incomplete (need \(offset + payloadLength), got \(data.count))"
            print(error)
            writeLog(error)
            return
        }
        var payload = Array(data[offset..<offset+payloadLength])

        if let mask = maskingKey {
            // Unmask payload using XOR
            for i in 0..<payload.count {
                payload[i] = payload[i] ^ mask[i % 4]
            }
            let unmaskMsg = "   ✅ Unmasked payload: \(payload.count) bytes"
            print(unmaskMsg)
            writeLog(unmaskMsg)
        }

        // Parse JSON
        let jsonData = Data(payload)
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            let jsonMsg = "   📄 JSON string (\(jsonString.count) chars): \(jsonString.prefix(200))"
            print(jsonMsg)
            writeLog(jsonMsg)

            // Log full JSON for debugging
            writeLog("   📋 Full JSON: \(jsonString)")
        }

        do {
            let message = try JSONDecoder().decode(WebSocketMessage.self, from: jsonData)
            let successMsg = "✅ [Message] Successfully decoded message type: \(message.type.rawValue)"
            print(successMsg)
            writeLog(successMsg)
            onMessageCallback?(message)
        } catch {
            let errorMsg = "❌ [Message] Failed to decode WebSocket message: \(error)"
            print(errorMsg)
            writeLog(errorMsg)
        }
    }

    func authenticate(deviceInfo: AuthPayload.DeviceInfo) async {
        self.deviceInfo = deviceInfo
        self.isAuthenticated = true
    }

    func send(sessions: [SessionStateDTO], isProcessing: Bool, hasWaitingForInput: Bool, hasPendingPermissions: Bool) async {
        let payload = SessionUpdatePayload(
            sessions: sessions,
            isProcessing: isProcessing,
            hasWaitingForInput: hasWaitingForInput,
            hasPendingPermissions: hasPendingPermissions
        )

        let message = WebSocketMessage(
            type: .sessionUpdate,
            payload: .sessionUpdate(payload),
            timestamp: Date()
        )

        send(message)
    }

    func send(errorCode: ErrorPayload.ErrorCode) async {
        let payload = ErrorPayload(
            code: errorCode,
            message: "Authentication failed",
            details: nil
        )

        let message = WebSocketMessage(
            type: .error,
            payload: .error(payload),
            timestamp: Date()
        )

        send(message)
    }

    private func send(_ message: WebSocketMessage) {
        guard let jsonData = try? JSONEncoder().encode(message) else { return }
        let frame = encodeWebSocketFrame(data: jsonData, opcode: .text)
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error = error {
                print("❌ WebSocket send error: \(error)")
            }
        })
    }

    private enum WebSocketOpcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    private func encodeWebSocketFrame(data: Data, opcode: WebSocketOpcode) -> Data {
        var frame = Data()

        // Byte 0: FIN + RSV + Opcode
        let byte0: UInt8 = 0x80 | opcode.rawValue  // FIN=1, RSV=0
        frame.append(byte0)

        // Byte 1: MASK + Payload Length
        let length = data.count

        if length < 126 {
            // MASK=0 (server to client), 7-bit length
            frame.append(UInt8(length))
        } else if length < 65536 {
            // MASK=0, 16-bit length
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            // MASK=0, 64-bit length
            frame.append(127)
            frame.append(UInt8((length >> 56) & 0xFF))
            frame.append(UInt8((length >> 48) & 0xFF))
            frame.append(UInt8((length >> 40) & 0xFF))
            frame.append(UInt8((length >> 32) & 0xFF))
            frame.append(UInt8((length >> 24) & 0xFF))
            frame.append(UInt8((length >> 16) & 0xFF))
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        }

        // Payload (no masking key for server->client)
        frame.append(data)

        return frame
    }

    func disconnect() async {
        connection.cancel()
        isAuthenticated = false
    }

    // MARK: - Chat Message Broadcasting

    func broadcastChatMessages(_ histories: [String: [ChatHistoryItem]]) async {
        let server = WebSocketServer.shared

        for (sessionId, items) in histories {
            let lastCount = server.lastMessageCounts[sessionId] ?? 0

            // Only send new messages since last broadcast
            if items.count > lastCount {
                let newMessages = Array(items.dropFirst(lastCount))

                for item in newMessages {
                    if let payload = server.convertToChatMessagePayload(item, sessionId: sessionId) {
                        let message = WebSocketMessage(
                            type: .chatMessage,
                            payload: .chatMessage(payload),
                            timestamp: Date()
                        )

                        await send(message)
                    }
                }

                // Update last count
                server.lastMessageCounts[sessionId] = items.count
            }
        }
    }

    // MARK: - Cleanup
}

// MARK: - Errors

enum WebSocketError: Swift.Error {
    case listenerCreationFailed
    case invalidPort
    case serverNotRunning
}

// MARK: - Notifications

extension Notification.Name {
    static let openSessionFromiOS = Notification.Name("openSessionFromiOS")
    static let stopProcessingFromiOS = Notification.Name("stopProcessingFromiOS")
}
