//
//  AuthTokenManager.swift
//  ClaudeIsland
//
//  Token generation and validation for WebSocket connections
//

import CryptoKit
import Foundation

// MARK: - Auth Token Manager

class AuthTokenManager {
    static let shared = AuthTokenManager()

    private let signingKey: SymmetricKey
    private let tokenValidityInterval: TimeInterval = 24 * 60 * 60  // 24 hours

    private init() {
        // Use a FIXED signing key for development
        // IMPORTANT: This key must match the one used to generate the token in iOS app
        let fixedKeyString = "ClaudeIslandFixedKey12345678901234567890123"
        let fixedKeyData = fixedKeyString.data(using: .utf8)!
        self.signingKey = SymmetricKey(data: fixedKeyData)

        // Uncomment below for production (generate unique key per install)
        // if let keyData = UserDefaults.standard.data(forKey: "AuthTokenSigningKey") {
        //     self.signingKey = SymmetricKey(data: keyData)
        // } else {
        //     self.signingKey = SymmetricKey(size: .bits256)
        //     let keyData = signingKey.withUnsafeBytes { Data($0) }
        //     UserDefaults.standard.set(keyData, forKey: "AuthTokenSigningKey")
        // }
    }

    // MARK: - Token Generation

    /// Generate a new authentication token
    func generateToken() -> String {
        let tokenData = TokenData(
            uuid: UUID().uuidString,
            timestamp: Date(),
            nonce: UUID().uuidString
        )

        let tokenJSON = try! JSONEncoder().encode(tokenData)
        let signature = HMAC<SHA256>.authenticationCode(for: tokenJSON, using: signingKey)

        var tokenWithSignature = Data()
        tokenWithSignature.append(tokenJSON)
        tokenWithSignature.append(Data(signature))

        return tokenWithSignature.base64EncodedString()
    }

    // MARK: - Token Validation

    /// Validate an authentication token
    func validateToken(_ tokenString: String) -> ValidationResult {
        guard let tokenData = Data(base64Encoded: tokenString) else {
            return .invalid(.malformed)
        }

        // Minimum size check: JSON + HMAC signature (32 bytes)
        guard tokenData.count > 32 else {
            return .invalid(.malformed)
        }

        let signatureStart = tokenData.index(tokenData.endIndex, offsetBy: -32)
        let jsonPart = tokenData[..<signatureStart]
        let signatureData = tokenData[signatureStart...]

        // Verify signature
        let receivedSignature = signatureData
        let computedSignature = Data(HMAC<SHA256>.authenticationCode(for: Data(jsonPart), using: signingKey))

        guard receivedSignature == computedSignature else {
            return .invalid(.signatureMismatch)
        }

        // Decode token data
        guard let tokenDataStruct = try? JSONDecoder().decode(TokenData.self, from: jsonPart) else {
            return .invalid(.malformed)
        }

        // Check expiry
        let age = Date().timeIntervalSince(tokenDataStruct.timestamp)
        guard age < tokenValidityInterval else {
            return .invalid(.expired)
        }

        return .valid(tokenDataStruct)
    }

    // MARK: - Token Data

    struct TokenData: Codable {
        let uuid: String
        let timestamp: Date
        let nonce: String
    }

    // MARK: - Validation Result

    enum ValidationResult {
        case valid(TokenData)
        case invalid(TokenError)

        var isValid: Bool {
            if case .valid = self { return true }
            return false
        }
    }

    enum TokenError: Error {
        case malformed
        case signatureMismatch
        case expired
    }
}

// MARK: - One-Time Token Storage

class TokenStorage {
    static let shared = TokenStorage()

    private var usedTokens = Set<String>()
    private let tokenValidityInterval: TimeInterval = 5 * 60  // 5 minutes

    private init() {}

    /// Check if a token has been used before (one-time use)
    func isTokenUsed(_ token: String) -> Bool {
        return usedTokens.contains(token)
    }

    /// Mark a token as used
    func markTokenUsed(_ token: String) {
        usedTokens.insert(token)

        // Clean up old tokens after validity period
        DispatchQueue.main.asyncAfter(deadline: .now() + tokenValidityInterval) { [weak self] in
            self?.usedTokens.remove(token)
        }
    }

    /// Remove a specific token (e.g., on disconnect)
    func removeToken(_ token: String) {
        usedTokens.remove(token)
    }

    /// Clear all tokens
    func clearAllTokens() {
        usedTokens.removeAll()
    }
}
