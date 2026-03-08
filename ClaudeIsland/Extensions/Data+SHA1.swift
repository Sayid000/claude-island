//
//  Data+SHA1.swift
//  ClaudeIsland
//
//  SHA1 hashing extension for WebSocket handshake
//

import Foundation
import CommonCrypto

extension Data {
    func sha1() -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        self.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(self.count), &digest)
        }
        return Data(digest)
    }
}
