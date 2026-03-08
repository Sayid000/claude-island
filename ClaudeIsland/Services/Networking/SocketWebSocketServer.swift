//
//  SocketWebSocketServer.swift
//  ClaudeIsland
//
//  POSIX socket-based WebSocket server
//

import Foundation
import Network
import Combine

class SocketWebSocketServer {
    static let shared = SocketWebSocketServer()

    private var serverSocket: Int32 = -1
    private var isRunning: Bool = false
    private let port: UInt16 = 8081
    private let authTokenManager = AuthTokenManager.shared
    private var clients: [SocketClient] = []

    // Dependencies
    private let sessionMonitor = ClaudeSessionMonitor()
    private let chatHistoryManager = ChatHistoryManager.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupSessionMonitoring()
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

        // Monitor chat history changes and broadcast new messages to connected clients
        chatHistoryManager.$histories
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] histories in
                self?.broadcastChatHistoryUpdate(histories)
            }
            .store(in: &cancellables)
    }

    private func broadcastChatHistoryUpdate(_ histories: [String: [ChatHistoryItem]]) {
        guard let clientsCopy = clients.isEmpty ? nil : clients else { return }

        for client in clientsCopy {
            guard client.isAuthenticated else { continue }

            // For each session with messages
            for (sessionId, chatItems) in histories {
                // Get previously sent messages and their states for this client
                var sentMessages = client.sentMessageStates[sessionId] ?? [String: String]()

                // Find new or updated messages
                for chatItem in chatItems {
                    let messageId = chatItem.id
                    let currentState = stateOfMessage(chatItem)

                    // Check if this is a new message or state has changed
                    let previousState = sentMessages[messageId]
                    if previousState == nil || previousState != currentState {
                        let message = chatItemToMessage(chatItem, sessionId: sessionId)
                        client.sendChatMessage(message)

                        // Update state
                        sentMessages[messageId] = currentState
                    }
                }

                // Save updated states
                client.sentMessageStates[sessionId] = sentMessages
            }
        }
    }

    private func stateOfMessage(_ item: ChatHistoryItem) -> String {
        switch item.type {
        case .user, .assistant, .thinking, .interrupted:
            return "static"
        case .toolCall(let tool):
            return "tool_\(tool.status)"
        }
    }

    private func typeOfMessage(_ item: ChatHistoryItem) -> String {
        switch item.type {
        case .user: return "user"
        case .assistant: return "assistant"
        case .toolCall: return "toolCall"
        case .thinking: return "thinking"
        case .interrupted: return "interrupted"
        }
    }

    private func broadcastSessionUpdate(_ sessions: [SessionState]) {
        let isProcessing = sessions.contains { $0.phase == .processing || $0.phase == .compacting }
        let hasWaitingForInput = sessions.contains { $0.phase == .waitingForInput }
        let hasPendingPermissions = sessions.contains { $0.phase.isWaitingForApproval }

        let dto = sessions.map { SessionStateDTO(from: $0) }

        // WebSocket broadcast
        for client in clients {
            if client.isAuthenticated {
                client.send(sessions: dto, isProcessing: isProcessing, hasWaitingForInput: hasWaitingForInput, hasPendingPermissions: hasPendingPermissions)
            }
        }

        // Send simple push notifications for important events
        Task { @MainActor in
            for session in sessions {
                // 發送重要事件的普通推送通知
                await sendSimpleNotification(for: session)
            }
        }

        // APNs Push for background Live Activity updates (暫時禁用)
        // Task { @MainActor in
        //     for session in sessions {
        //         // 只推送有變化的 session
        //         let sessionDTO = SessionStateDTO(from: session)
        //         do {
        //             try await APNsPushService.shared.sendLiveActivityUpdate(sessionData: sessionDTO)
        //         } catch {
        //             print("❌ Failed to send APNs push: \(error)")
        //         }
        //     }
        // }
    }

    // MARK: - Simple Push Notifications

    /// 發送普通推送通知（不是 Live Activity）
    private func sendSimpleNotification(for session: SessionState) async {
        // 只在重要事件時發送通知
        switch session.phase {
        case .processing:
            // 開始處理
            let payload = SimplePushPayload(
                sessionId: session.sessionId,
                sessionTitle: session.displayTitle,
                phase: "processing",
                projectName: session.projectName,
                timestamp: Date().timeIntervalSince1970
            )
            try? await SimplePushService.shared.sendSimpleNotification(sessionData: payload)

        case .waitingForInput:
            // 等待輸入（重要）
            let payload = SimplePushPayload(
                sessionId: session.sessionId,
                sessionTitle: session.displayTitle,
                phase: "waitingForInput",
                projectName: session.projectName,
                timestamp: Date().timeIntervalSince1970
            )
            try? await SimplePushService.shared.sendSimpleNotification(sessionData: payload)

        case .waitingForApproval:
            // 等待批准（重要）
            let payload = SimplePushPayload(
                sessionId: session.sessionId,
                sessionTitle: session.displayTitle,
                phase: "waitingForApproval",
                projectName: session.projectName,
                timestamp: Date().timeIntervalSince1970
            )
            try? await SimplePushService.shared.sendSimpleNotification(sessionData: payload)

        case .idle:
            // 完成任務
            let payload = SimplePushPayload(
                sessionId: session.sessionId,
                sessionTitle: session.displayTitle,
                phase: "completed",
                projectName: session.projectName,
                timestamp: Date().timeIntervalSince1970
            )
            try? await SimplePushService.shared.sendSimpleNotification(sessionData: payload)

        default:
            // 其他階段不發送通知（避免過度通知）
            break
        }
    }

    func start() throws {
        guard !isRunning else { return }

        // Create socket
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket != -1 else {
            throw WebSocketError.listenerCreationFailed
        }

        // Set socket options
        var optval: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEPORT, &optval, socklen_t(MemoryLayout<Int32>.size))

        // Bind to port
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            close(serverSocket)
            serverSocket = -1
            throw WebSocketError.invalidPort
        }

        // Listen
        guard listen(serverSocket, 5) == 0 else {
            close(serverSocket)
            serverSocket = -1
            throw WebSocketError.listenerCreationFailed
        }

        isRunning = true
        print("🔌 Socket WebSocket Server listening on port \(port)")

        // Start accepting connections in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptConnections()
        }
    }

    func stop() {
        isRunning = false
        if serverSocket != -1 {
            close(serverSocket)
            serverSocket = -1
        }
        clients.forEach { $0.close() }
        clients.removeAll()
        print("🔌 Socket WebSocket Server stopped")
    }

    private func acceptConnections() {
        while isRunning {
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientSocket = accept(serverSocket,
                                     withUnsafeMutablePointer(to: &clientAddr) {
                                         $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                             $0
                                         }
                                     },
                                     &clientAddrLen)

            if clientSocket == -1 {
                if isRunning {
                    let errno = Darwin.errno
                    print("❌ [Accept] Failed to accept client connection, errno: \(errno)")
                }
                continue
            }

            // Get client IP for logging
            let clientIP = String(cString: inet_ntoa(clientAddr.sin_addr))
            print("✅ [Accept] Client connected from: \(clientIP)")

            let client = SocketClient(socket: clientSocket)
            clients.append(client)

            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak client] in
                self?.handleClient(client)
            }
        }
    }

    private func handleClient(_ client: SocketClient?) {
        guard let client = client else {
            print("❌ [HandleClient] Client is nil")
            return
        }

        print("🔌 [HandleClient] Starting handleClient for socket \(client.socket)")

        // Receive data
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }

        var readCount = 0
        while isRunning && !client.isHandshakeComplete {
            print("🔌 [HandleClient] Reading data... (attempt \(readCount + 1))")
            let bytesRead = read(client.socket, buffer, 4096)
            print("🔌 [HandleClient] Read \(bytesRead) bytes")

            if bytesRead <= 0 {
                print("⚠️ [HandleClient] Client disconnected or error, closing")
                client.close()
                DispatchQueue.main.async { [weak self] in
                    self?.clients.removeAll { $0.socket == client.socket }
                }
                return
            }

            let data = Data(bytes: buffer, count: bytesRead)
            print("📥 [HandleClient] Received \(data.count) bytes")
            readCount += 1

            // Log raw data for debugging
            if let preview = String(data: data.prefix(200), encoding: .utf8) {
                print("📄 [HandleClient] Data preview: \(preview)")
            }

            // Check for WebSocket handshake
            guard let requestString = String(data: data, encoding: .utf8) else {
                print("❌ [HandleClient] Failed to convert data to string")
                continue
            }

            print("🔍 [HandleClient] Checking for WebSocket upgrade...")
            if requestString.contains("Upgrade: websocket") {
                print("✅ [HandleClient] WebSocket upgrade detected, calling handleHandshake")
                handleHandshake(client: client, data: data, requestString: requestString)
            } else {
                print("⚠️ [HandleClient] Not a WebSocket upgrade request")
                print("   Content: \(requestString.prefix(200))")
            }
        }

        print("🔄 [HandleClient] Handshake phase complete, entering frame reading phase")
        print("   isHandshakeComplete: \(client.isHandshakeComplete)")
        print("   isAuthenticated: \(client.isAuthenticated)")

        // Continue reading WebSocket frames if handshake complete
        while isRunning {
            print("🔍 [FrameReading] Waiting for WebSocket frame...")
            // Read frame header (2 bytes minimum)
            let headerRead = read(client.socket, buffer, 2)
            print("📥 [FrameReading] Read \(headerRead) bytes for header")

            if headerRead <= 0 {
                print("⚠️ [FrameReading] Connection closed or error (read \(headerRead) bytes)")
                break
            }

            if headerRead != 2 {
                print("⚠️ [FrameReading] Incomplete header (got \(headerRead), expected 2)")
                break
            }

            // Parse frame
            let byte1 = buffer[0]
            let byte2 = buffer[1]
            let isMasked = (byte2 & 0x80) != 0
            var payloadLength = Int(byte2 & 0x7F)
            var offset = 2

            print("   📋 Frame: byte1=0x\(String(byte1, radix: 16)), byte2=0x\(String(byte2, radix: 16)), masked=\(isMasked), length=\(payloadLength)")

            // Extended payload length
            if payloadLength == 126 {
                let lenRead = read(client.socket, buffer.advanced(by: offset), 2)
                if lenRead != 2 { break }
                payloadLength = Int(buffer[offset]) << 8 | Int(buffer[offset + 1])
                offset += 2
                print("   📋 Extended length: \(payloadLength)")
            } else if payloadLength == 127 {
                let lenRead = read(client.socket, buffer.advanced(by: offset), 8)
                if lenRead != 8 { break }
                // Parse 64-bit length (simplified)
                offset += 8
            }

            // Masking key (if present)
            var maskingKey: [UInt8]?
            if isMasked {
                let maskRead = read(client.socket, buffer.advanced(by: offset), 4)
                if maskRead != 4 { break }
                var key = [UInt8](repeating: 0, count: 4)
                memcpy(&key, buffer.advanced(by: offset), 4)
                maskingKey = key
                offset += 4
                print("   🔑 Mask: \(key.map { String(format: "%02x", $0) }.joined(separator: ""))")
            }

            // Payload
            let payloadRead = read(client.socket, buffer, payloadLength)
            print("   📦 Read \(payloadRead) bytes of payload")

            if payloadRead != payloadLength { break }

            var payload = [UInt8](repeating: 0, count: Int(payloadRead))
            memcpy(&payload, buffer, Int(payloadRead))

            // Unmask if needed
            if let mask = maskingKey {
                for i in 0..<payload.count {
                    payload[i] = payload[i] ^ mask[i % 4]
                }
            }

            // Parse message
            if let messageString = String(bytes: payload, encoding: .utf8) {
                print("   📨 Raw message: \(messageString.prefix(100))...")

                // Try to decode with detailed error logging
                do {
                    let message = try JSONDecoder().decode(WebSocketMessage.self, from: Data(payload))
                    print("✅ [FrameReading] Received message: \(message.type.rawValue)")
                    handleMessage(client: client, message: message)
                } catch {
                    print("❌ [FrameReading] Failed to decode message: \(error)")
                    // Print full message for debugging
                    print("   Full message: \(messageString)")
                }
            } else {
                print("❌ [FrameReading] Failed to convert payload to string")
            }
        }

        client.close()
        DispatchQueue.main.async { [weak self] in
            self?.clients.removeAll { $0.socket == client.socket }
        }
    }

    private func handleHandshake(client: SocketClient, data: Data, requestString: String) {
        print("🤝 [Handshake] Processing handshake...")

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
            print("❌ [Handshake] Missing WebSocket key in handshake")
            print("   Request lines: \(lines.count)")
            return
        }

        print("✅ [Handshake] WebSocket key extracted: \(key.prefix(20))...")

        // Compute accept key
        let acceptKey = computeAcceptKey(key)
        print("✅ [Handshake] Accept key computed: \(acceptKey.prefix(20))...")

        // Send HTTP 101 response IMMEDIATELY
        let response = "HTTP/1.1 101 Switching Protocols\r\n" +
                      "Upgrade: websocket\r\n" +
                      "Connection: Upgrade\r\n" +
                      "Sec-WebSocket-Accept: \(acceptKey)\r\n" +
                      "\r\n"

        if let responseData = response.data(using: .utf8) {
            print("📤 [Handshake] Sending HTTP 101 response (\(responseData.count) bytes)")
            let sent = responseData.withUnsafeBytes { bytes in
                write(client.socket, bytes.baseAddress, bytes.count)
            }

            print("📊 [Handshake] Sent \(sent) bytes")

            if sent > 0 {
                client.isHandshakeComplete = true
                print("✅ [Handshake] Handshake complete!")
            } else {
                print("❌ [Handshake] Failed to send response (sent 0 bytes)")
            }
        } else {
            print("❌ [Handshake] Failed to encode response")
        }
    }

    private func computeAcceptKey(_ key: String) -> String {
        let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magicGUID
        guard let combinedData = combined.data(using: .utf8) else { return "" }
        let hash = combinedData.sha1()
        return hash.base64EncodedString()
    }

    private func handleMessage(client: SocketClient, message: WebSocketMessage) {
        switch message.type {
        case .auth:
            handleAuthMessage(client: client, payload: message.payload)
        case .pushToken:
            handlePushTokenMessage(client: client, payload: message.payload)
        case .control:
            handleControlMessage(client: client, payload: message.payload)
        default:
            break
        }
    }

    private func handleAuthMessage(client: SocketClient, payload: WebSocketMessage.Payload) {
        guard case .auth(let authPayload) = payload else { return }

        let validationResult = authTokenManager.validateToken(authPayload.token)

        switch validationResult {
        case .valid:
            client.isAuthenticated = true
            client.deviceInfo = authPayload.deviceInfo
            print("✅ Client authenticated: \(authPayload.deviceInfo.name)")

            // Send initial session state and chat history
            Task { @MainActor in
                let sessions = sessionMonitor.instances
                let dto = sessions.map { SessionStateDTO(from: $0) }
                let isProcessing = sessions.contains { $0.phase == .processing || $0.phase == .compacting }
                let hasWaitingForInput = sessions.contains { $0.phase == .waitingForInput }
                let hasPendingPermissions = sessions.contains { $0.phase.isWaitingForApproval }
                client.send(sessions: dto, isProcessing: isProcessing, hasWaitingForInput: hasWaitingForInput, hasPendingPermissions: hasPendingPermissions)

                // Send chat history for each session
                for session in sessions {
                    self.sendChatHistory(for: session, to: client)
                }
            }
        case .invalid(let error):
            print("❌ Authentication failed: \(error)")
            client.close()
        }
    }

    private func handlePushTokenMessage(client: SocketClient, payload: WebSocketMessage.Payload) {
        guard case .pushToken(let pushTokenPayload) = payload else { return }

        // 註冊到 SimplePushService（普通推送通知）
        SimplePushService.shared.registerDeviceToken(
            deviceId: client.id,
            pushToken: pushTokenPayload.token,
            deviceInfo: pushTokenPayload.deviceInfo
        )

        // 保存到 client 對象中
        client.pushToken = pushTokenPayload.token

        print("📢 [Mac] ✅ Push token registered")
    }

    private func sendChatHistory(for session: SessionState, to client: SocketClient) {
        let chatItems = chatHistoryManager.history(for: session.sessionId)
        print("📜 Sending chat history for session \(session.sessionId): \(chatItems.count) items")

        // Initialize sent message IDs and states for this session
        client.sentMessageIds[session.sessionId] = Set<String>()
        client.sentMessageStates[session.sessionId] = [:]

        // Send each chat item
        for chatItem in chatItems {
            let message = chatItemToMessage(chatItem, sessionId: session.sessionId)
            client.sendChatMessage(message)

            // Mark as sent
            client.sentMessageIds[session.sessionId]?.insert(chatItem.id)

            // Track initial state
            let state = stateOfMessage(chatItem)
            client.sentMessageStates[session.sessionId]?[chatItem.id] = state
        }
        print("💬 Sent \(chatItems.count) chat messages for session \(session.sessionId)")
    }

    private func chatItemToMessage(_ item: ChatHistoryItem, sessionId: String) -> WebSocketMessage {
        let content: String
        let role: String
        let isToolUse: Bool
        var toolName: String? = nil
        var toolInput: [String: String]? = nil
        var toolResult: String? = nil
        var toolStatus: String? = nil
        var structuredResult: String? = nil
        var thinking: String? = nil
        var isInterrupted: Bool = false

        switch item.type {
        case .user(let text):
            content = text
            role = "user"
            isToolUse = false
        case .assistant(let text):
            content = text
            role = "assistant"
            isToolUse = false
        case .toolCall(let tool):
            content = "🔧 Using \(tool.name)"
            role = "assistant"
            isToolUse = true
            toolName = tool.name
            toolInput = tool.input
            toolResult = tool.result
            toolStatus = statusToString(tool.status)
            // TODO: Convert ToolResultData to JSON string
            if let result = tool.structuredResult {
                structuredResult = resultToJSON(result)
            }
        case .thinking(let text):
            content = ""  // Empty content, thinking is in separate field
            role = "assistant"
            isToolUse = false
            thinking = text
            print("🧠 [Mac] Sending thinking message: \(text.prefix(50))...")
        case .interrupted:
            content = "⚠️ Interrupted"
            role = "assistant"
            isToolUse = false
            isInterrupted = true
        }

        let chatPayload = ChatMessagePayload(
            sessionId: sessionId,
            messageId: item.id,
            content: content,
            role: role,
            timestamp: item.timestamp,
            isToolUse: isToolUse,
            toolName: toolName,
            toolInput: toolInput,
            toolResult: toolResult,
            toolStatus: toolStatus,
            structuredResult: structuredResult,
            thinking: thinking,
            isInterrupted: isInterrupted
        )

        return WebSocketMessage(
            type: .chatMessage,
            payload: .chatMessage(chatPayload),
            timestamp: Date()
        )
    }

    private func statusToString(_ status: ToolStatus) -> String {
        switch status {
        case .running:
            return "running"
        case .success:
            return "success"
        case .error:
            return "error"
        case .waitingForApproval:
            return "waitingForApproval"
        case .interrupted:
            return "interrupted"
        }
    }

    private func resultToJSON(_ result: ToolResultData) -> String? {
        // For now, return nil - we'll implement proper serialization later
        // TODO: Implement ToolResultData -> JSON -> ToolResultDataDTO conversion
        return nil
    }

    private func handleControlMessage(client: SocketClient, payload: WebSocketMessage.Payload) {
        guard client.isAuthenticated else {
            print("❌ Control message from unauthenticated client")
            client.close()
            return
        }

        guard case .control(let controlPayload) = payload else { return }

        switch controlPayload.command {
        case .openSession:
            if let sessionId = controlPayload.sessionId {
                print("📱 iOS opening session: \(sessionId.prefix(8))")
                NotificationCenter.default.post(
                    name: .openSessionFromiOS,
                    object: nil,
                    userInfo: ["sessionId": sessionId]
                )
            }
        case .stopProcessing:
            print("📱 iOS requesting stop processing")
            NotificationCenter.default.post(
                name: .stopProcessingFromiOS,
                object: nil
            )
        case .approvePermission:
            if let sessionId = controlPayload.sessionId {
                print("✅ iOS approved permission for session: \(sessionId.prefix(8))")
                sessionMonitor.approvePermission(sessionId: sessionId)
            }
        case .denyPermission:
            if let sessionId = controlPayload.sessionId {
                print("❌ iOS denied permission for session: \(sessionId.prefix(8))")
                sessionMonitor.denyPermission(sessionId: sessionId, reason: nil)
            }
        default:
            break
        }
    }
}

class SocketClient {
    let id: String  // ← Unique client ID for push token mapping
    let socket: Int32
    var isAuthenticated = false
    var isHandshakeComplete = false
    var deviceInfo: AuthPayload.DeviceInfo?
    var sentMessageIds: [String: Set<String>] = [:]  // Track sent messages per session (deprecated)
    var sentMessageStates: [String: [String: String]] = [:]  // Track message states per session for updates
    var pushToken: String?  // ← APNs push token for Live Activity updates

    init(socket: Int32) {
        self.id = UUID().uuidString  // Generate unique ID
        self.socket = socket
    }

    func send(sessions: [SessionStateDTO], isProcessing: Bool, hasWaitingForInput: Bool, hasPendingPermissions: Bool) {
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

    func sendChatMessage(_ message: WebSocketMessage) {
        send(message)
    }

    private func send(_ message: WebSocketMessage) {
        guard let jsonData = try? JSONEncoder().encode(message) else { return }
        let frame = encodeWebSocketFrame(data: jsonData, opcode: .text)

        _ = frame.withUnsafeBytes { bytes in
            write(socket, bytes.baseAddress, bytes.count)
        }
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

    func close() {
        if socket != -1 {
            Darwin.close(socket)
        }
    }
}
