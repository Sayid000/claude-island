//
//  WebSocketMessage.swift
//  ClaudeIsland
//
//  WebSocket message protocol for Mac-iOS communication
//

import Foundation

// MARK: - Main Message Type

struct WebSocketMessage: Codable {
    let type: MessageType
    let payload: Payload
    let timestamp: Date

    enum MessageType: String, Codable {
        case auth           // Authentication
        case sessionUpdate  // Session state updates
        case chatMessage    // Chat message updates
        case control        // Control commands
        case heartbeat      // Keep-alive
        case pushToken      // APNs push token
        case error          // Error messages
    }

    enum Payload: Codable {
        case auth(AuthPayload)
        case sessionUpdate(SessionUpdatePayload)
        case chatMessage(ChatMessagePayload)
        case control(ControlPayload)
        case heartbeat(HeartbeatPayload)
        case pushToken(PushTokenPayload)  // ← 新增
        case error(ErrorPayload)

        // Custom coding to handle enum cases
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()

            // Define wrapped payload structures for decoding
            struct WrappedAuth: Codable { let auth: AuthPayload }
            struct WrappedSession: Codable { let sessionUpdate: SessionUpdatePayload }
            struct WrappedChat: Codable { let chatMessage: ChatMessagePayload }
            struct WrappedControl: Codable { let control: ControlPayload }
            struct WrappedHeartbeat: Codable { let heartbeat: HeartbeatPayload }
            struct WrappedPushToken: Codable { let pushToken: PushTokenPayload }
            struct WrappedError: Codable { let error: ErrorPayload }

            // Try to decode wrapped payloads (iOS format)
            if let authWrapped = try? container.decode(WrappedAuth.self) {
                self = .auth(authWrapped.auth)
            } else if let sessionWrapped = try? container.decode(WrappedSession.self) {
                self = .sessionUpdate(sessionWrapped.sessionUpdate)
            } else if let chatWrapped = try? container.decode(WrappedChat.self) {
                self = .chatMessage(chatWrapped.chatMessage)
            } else if let controlWrapped = try? container.decode(WrappedControl.self) {
                self = .control(controlWrapped.control)
            } else if let heartbeatWrapped = try? container.decode(WrappedHeartbeat.self) {
                self = .heartbeat(heartbeatWrapped.heartbeat)
            } else if let pushTokenWrapped = try? container.decode(WrappedPushToken.self) {
                self = .pushToken(pushTokenWrapped.pushToken)
            } else if let errorWrapped = try? container.decode(WrappedError.self) {
                self = .error(errorWrapped.error)
            } else {
                // Fallback: try direct decoding (for backward compatibility)
                if let authValue = try? container.decode(AuthPayload.self) {
                    self = .auth(authValue)
                } else if let sessionValue = try? container.decode(SessionUpdatePayload.self) {
                    self = .sessionUpdate(sessionValue)
                } else if let chatValue = try? container.decode(ChatMessagePayload.self) {
                    self = .chatMessage(chatValue)
                } else if let controlValue = try? container.decode(ControlPayload.self) {
                    self = .control(controlValue)
                } else if let heartbeatValue = try? container.decode(HeartbeatPayload.self) {
                    self = .heartbeat(heartbeatValue)
                } else if let pushTokenValue = try? container.decode(PushTokenPayload.self) {
                    self = .pushToken(pushTokenValue)
                } else if let errorValue = try? container.decode(ErrorPayload.self) {
                    self = .error(errorValue)
                } else {
                    throw WebSocketDecodingError.typeMismatch(Payload.self, "Unknown payload type")
                }
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .auth(let value):
                try container.encode(["auth": value])
            case .sessionUpdate(let value):
                try container.encode(["sessionUpdate": value])
            case .chatMessage(let value):
                try container.encode(["chatMessage": value])
            case .control(let value):
                try container.encode(["control": value])
            case .heartbeat(let value):
                try container.encode(["heartbeat": value])
            case .pushToken(let value):
                try container.encode(["pushToken": value])
            case .error(let value):
                try container.encode(["error": value])
            }
        }
    }
}

// MARK: - Auth Payload

struct AuthPayload: Codable {
    let token: String
    let deviceInfo: DeviceInfo

    struct DeviceInfo: Codable {
        let name: String
        let osVersion: String
        let appVersion: String
    }
}

// MARK: - Session Update Payload

struct SessionUpdatePayload: Codable {
    let sessions: [SessionStateDTO]
    let isProcessing: Bool
    let hasWaitingForInput: Bool
    let hasPendingPermissions: Bool
}

// MARK: - Chat Message Payload

struct ChatMessagePayload: Codable {
    let sessionId: String
    let messageId: String
    let content: String
    let role: String
    let timestamp: Date
    let isToolUse: Bool
    let toolName: String?

    // NEW FIELDS for enhanced iOS display
    let toolInput: [String: String]?           // Structured tool input
    let toolResult: String?                    // Raw result text
    let toolStatus: String?                    // "running", "success", "error", "waitingForApproval"
    let structuredResult: String?             // Structured result (as JSON string for now)
    let thinking: String?                      // Thinking content
    let isInterrupted: Bool?                   // Interrupted state
}

// MARK: - Control Payload

struct ControlPayload: Codable {
    let command: ControlCommand
    let sessionId: String?

    enum ControlCommand: String, Codable {
        case openSession
        case closeSession
        case focusSession
        case sendInput
        case stopProcessing
        case approvePermission
        case denyPermission
    }
}

// MARK: - Heartbeat Payload

struct HeartbeatPayload: Codable {
    let sequence: Int
    let serverTime: Date
}

// MARK: - Push Token Payload

struct PushTokenPayload: Codable {
    let token: String
    let deviceInfo: String
}

// MARK: - Error Payload

struct ErrorPayload: Codable {
    let code: ErrorCode
    let message: String
    let details: String?

    enum ErrorCode: String, Codable {
        case invalidToken = "E-001"
        case connectionTimeout = "E-002"
        case serverOverloaded = "E-003"
        case versionMismatch = "E-004"
        case networkError = "E-005"
    }
}

// MARK: - Connection Info

struct ConnectionInfo: Codable {
    let host: String
    let port: Int
    let token: String
    let macName: String
    let lastConnected: Date
    let version: String

    var webSocketURL: URL {
        URL(string: "ws://\(host):\(port)/?token=\(token)")!
    }

    var qrCodeString: String {
        "claude-island://connect?host=\(host)&port=\(port)&token=\(token)&version=\(version)"
    }
}

// MARK: - Decoding Error

enum WebSocketDecodingError: Swift.Error {
    case typeMismatch(Any.Type, String)
}

extension WebSocketDecodingError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .typeMismatch(_, let message):
            return message
        }
    }
}
