//
//  QRCodeGenerator.swift
//  ClaudeIsland
//
//  Generate QR codes for iOS companion app pairing
//

import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import AppKit

// MARK: - QR Code Generator

class QRCodeGenerator {
    private static let context = CIContext()
    private static let filter = CIFilter.qrCodeGenerator()

    // MARK: - Generate QR Code Image

    /// Generate a QR code image from a connection info
    static func generate(from connectionInfo: ConnectionInfo, size: CGFloat = 300) -> NSImage? {
        // Create QR code string
        let qrString = connectionInfo.qrCodeString

        guard let qrData = qrString.data(using: .utf8),
              let outputImage = generateQRCode(from: qrData, size: size) else {
            return nil
        }

        return outputImage
    }

    /// Generate a QR code image from raw data
    private static func generateQRCode(from data: Data, size: CGFloat) -> NSImage? {
        filter.message = data

        guard let outputImage = filter.outputImage else {
            return nil
        }

        // Scale the image
        let scaleX = size / outputImage.extent.width
        let scaleY = size / outputImage.extent.height
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Convert to NSImage
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
        return image
    }

    // MARK: - Generate with Styling

    /// Generate a styled QR code with rounded corners and logo placeholder
    static func generateStyled(from connectionInfo: ConnectionInfo, size: CGFloat = 300) -> NSImage? {
        guard let qrImage = generate(from: connectionInfo, size: size) else {
            return nil
        }

        // Create final image with styling
        let finalSize = NSSize(width: size, height: size)
        let finalImage = NSImage(size: finalSize)

        finalImage.lockFocus()

        // Draw background
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: finalSize)).fill()

        // Draw QR code with padding
        let padding: CGFloat = 20
        let qrRect = NSRect(
            x: padding,
            y: padding,
            width: size - (padding * 2),
            height: size - (padding * 2)
        )
        qrImage.draw(in: qrRect)

        // Draw logo in center (optional)
        let logoSize: CGFloat = 60
        let logoRect = NSRect(
            x: (size - logoSize) / 2,
            y: (size - logoSize) / 2,
            width: logoSize,
            height: logoSize
        )

        NSColor.white.setFill()
        NSBezierPath(ovalIn: logoRect).fill()

        // Draw crab icon (simplified)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 32, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        let crabString = "🦀" as NSString
        let textSize = crabString.size(withAttributes: attrs)
        let textRect = NSRect(
            x: logoRect.origin.x + (logoSize - textSize.width) / 2,
            y: logoRect.origin.y + (logoSize - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        crabString.draw(in: textRect, withAttributes: attrs)

        finalImage.unlockFocus()

        return finalImage
    }
}

// MARK: - SwiftUI Wrapper

struct QRCodeView: View {
    let connectionInfo: ConnectionInfo
    var size: CGFloat = 300

    var body: some View {
        if let nsImage = QRCodeGenerator.generateStyled(from: connectionInfo, size: size) {
            Image(nsImage: nsImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .cornerRadius(12)
                .shadow(radius: 5)
        } else {
            Text("Failed to generate QR Code")
                .foregroundColor(.red)
        }
    }
}

// MARK: - Connection Info Provider

class ConnectionInfoProvider: ObservableObject {
    @Published var connectionInfo: ConnectionInfo?

    private let webSocketServer = WebSocketServer.shared
    private let authTokenManager = AuthTokenManager.shared

    /// Generate new connection info for QR code
    func generateConnectionInfo() -> ConnectionInfo? {
        // Get server port
        let port = webSocketServer.port

        // Get Mac name
        let macName = Host.current().localizedName ?? "Mac"

        // Generate new token
        let token = authTokenManager.generateToken()

        // Get local IP address
        guard let host = getLocalIPAddress() else {
            return nil
        }

        // Create connection info
        let info = ConnectionInfo(
            host: host,
            port: Int(port),
            token: token,
            macName: macName,
            lastConnected: Date(),
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        )

        self.connectionInfo = info
        return info
    }

    /// Get the local IP address on the WiFi network
    private func getLocalIPAddress() -> String? {
        var addresses: [String: String] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            guard let interface = ptr?.pointee else { continue }
            let addrFamily = interface.ifa_addr.pointee.sa_family

            // Check for IPv4
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // Collect all interface IPs
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST
                    )
                    addresses[name] = String(cString: hostname)
                }
            }
        }

        // Prioritize en1 (WiFi) over en0 (Ethernet)
        // Note: en1 is typically Wi-Fi on Macs, en0 is usually Ethernet
        return addresses["en1"] ?? addresses["en0"]
    }
}
