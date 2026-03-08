//
//  SimplePushService.swift
//  ClaudeIsland
//
//  Manages simple push notifications (not Live Activities) for iOS app
//  Sends regular push notifications that wake up the app in background
//

import Foundation
import CryptoKit
import Network

// MARK: - Simple Push Configuration

struct SimplePushConfiguration {
    let teamId: String
    let bundleId: String  // Main app bundle ID, NOT the widget
    let keyId: String
    let p8KeyPath: String
    var isProduction: Bool = false

    var serverURL: String {
        isProduction
            ? "https://api.push.apple.com/3/device"
            : "https://api.development.push.apple.com/3/device"
    }
}

// MARK: - Simple Push Payload

struct SimplePushPayload: Codable {
    let sessionId: String
    let sessionTitle: String
    let phase: String  // "processing", "waitingForInput", "waitingForApproval", "completed"
    let projectName: String?
    let timestamp: TimeInterval

    init(sessionId: String, sessionTitle: String, phase: String, projectName: String?, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.phase = phase
        self.projectName = projectName
        self.timestamp = timestamp
    }
}

// MARK: - Simple Push Service

class SimplePushService {
    static let shared = SimplePushService()

    private var config: SimplePushConfiguration
    private var devicePushTokens: [String: String] = [:]  // deviceId: pushToken

    private init() {
        // TODO: 從配置檔案讀取
        self.config = SimplePushConfiguration(
            teamId: "YOUR_TEAM_ID",
            bundleId: "com.celestial.ClaudeIslandiOS",  // 主應用的 bundle ID，不是 widget
            keyId: "YOUR_KEY_ID",
            p8KeyPath: "/path/to/AuthKey_YOURKEYID.p8",
            isProduction: false
        )

        print("📢 [SimplePush] Service initialized")
    }

    // MARK: - Token Management

    func registerDeviceToken(deviceId: String, pushToken: String, deviceInfo: String = "") {
        devicePushTokens[deviceId] = pushToken
        print("📢 [SimplePush] Device token registered for: \(deviceId)")
    }

    func unregisterDeviceToken(deviceId: String) {
        devicePushTokens.removeValue(forKey: deviceId)
        print("📢 [SimplePush] Device token unregistered: \(deviceId)")
    }

    // MARK: - Send Notification

    func sendSimpleNotification(sessionData: SimplePushPayload) async throws {
        guard !devicePushTokens.isEmpty else {
            print("⚠️ [SimplePush] No device tokens registered")
            return
        }

        print("📢 [SimplePush] Sending notification to \(devicePushTokens.count) devices")

        // Create JWT
        let jwt = try generateJWT()

        // Send to all registered devices
        for (deviceId, pushToken) in devicePushTokens {
            do {
                try await sendPush(
                    to: pushToken,
                    jwt: jwt,
                    payload: sessionData
                )
                print("✅ [SimplePush] Notification sent to device: \(deviceId)")
            } catch {
                print("❌ [SimplePush] Failed to send to device \(deviceId): \(error)")
            }
        }
    }

    // MARK: - JWT Generation

    private func generateJWT() throws -> String {
        let keyData = try Data(contentsOf: URL(fileURLWithPath: config.p8KeyPath))
        let p8Key = try P256.Signing.PrivateKey(rawRepresentation: keyData)

        let header = [
            "alg": "ES256",
            "kid": config.keyId
        ]

        let iat = Date().timeIntervalSince1970
        let exp = iat + (60 * 60)  // 1 hour

        let payload: [String: Any] = [
            "iss": config.teamId,
            "iat": iat,
            "exp": exp
        ]

        let headerData = try JSONSerialization.data(withJSONObject: header)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)

        let headerBase64 = headerData.base64EncodedURL()
        let payloadBase64 = payloadData.base64EncodedURL()

        let signingInput = "\(headerBase64).\(payloadBase64)"

        let signature = try p8Key.signature(for: signingInput.data(using: .utf8)!)

        let signatureBase64 = signature.rawRepresentation.base64EncodedURL()

        let jwt = "\(headerBase64).\(payloadBase64).\(signatureBase64)"

        return jwt
    }

    // MARK: - HTTP Request

    private func sendPush(to deviceToken: String, jwt: String, payload: SimplePushPayload) async throws {
        let url = URL(string: "\(config.serverURL)/\(deviceToken)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(config.bundleId, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")  // 普通通知
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")

        // 構建普通通知的 payload
        let notificationPayload: [String: Any] = [
            "aps": [
                "alert": [
                    "title": "Claude Island",
                    "body": notificationBody(for: payload)
                ],
                "badge": 1,
                "sound": "default"
            ],
            "sessionInfo": [
                "sessionId": payload.sessionId,
                "sessionTitle": payload.sessionTitle,
                "phase": payload.phase,
                "projectName": payload.projectName ?? ""
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: notificationPayload)

        // Send
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode != 200 {
                // 嘗試解析錯誤信息
                if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let reason = errorData["reason"] as? String {
                    print("❌ [SimplePush] APNs error: \(reason)")
                } else {
                    print("❌ [SimplePush] APNs error: HTTP \(httpResponse.statusCode)")
                }
                throw NSError(domain: "SimplePushError", code: httpResponse.statusCode, userInfo: nil)
            }
        }
    }

    // MARK: - Helper Methods

    private func notificationBody(for payload: SimplePushPayload) -> String {
        switch payload.phase {
        case "processing":
            return "🔧 Claude 開始處理"
        case "waitingForInput":
            return "⌨️ Claude 等待輸入 - 點擊查看"
        case "waitingForApproval":
            return "⚠️ Claude 等待批准 - 需要核准"
        case "completed":
            return "✅ Claude 處理完成"
        default:
            return "📱 Claude Island 通知"
        }
    }
}

// MARK: - Helper Extensions

extension Data {
    func base64EncodedURL() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .trimmingCharacters(in: .init(["="]))
    }
}
