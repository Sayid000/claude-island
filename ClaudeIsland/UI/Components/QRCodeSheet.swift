//
//  QRCodeSheet.swift
//  ClaudeIsland
//
//  Sheet view for displaying QR code to iOS companion app
//

import SwiftUI

struct QRCodeSheet: View {
    @ObservedObject var connectionInfoProvider: ConnectionInfoProvider
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 24) {
            // Header
            HStack {
                Text("連接 iOS 應用程式")
                    .font(.title2)
                    .foregroundColor(.white)
                    .fontWeight(.semibold)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)

            // Instructions
            VStack(spacing: 8) {
                Text("使用 iOS 應用程式掃描此 QR Code")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.8))

                Text("確保 iPhone 與 Mac 連接同一個 Wi-Fi 網路")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal)

            // QR Code
            if let connectionInfo = connectionInfoProvider.connectionInfo {
                VStack(spacing: 16) {
                    // QR Code image
                    QRCodeView(connectionInfo: connectionInfo, size: 280)

                    // Connection info
                    VStack(spacing: 6) {
                        HStack {
                            Image(systemName: "desktopcomputer")
                                .foregroundColor(.white.opacity(0.5))
                            Text(connectionInfo.macName)
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                        }

                        HStack {
                            Image(systemName: "server.rack")
                                .foregroundColor(.white.opacity(0.5))
                            Text("ws://\(connectionInfo.host):\(connectionInfo.port)")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }

                    // Token display with copy button
                    VStack(spacing: 12) {
                        HStack {
                            Text("Token:")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.5))

                            Spacer()

                            Button {
                                copyTokenToClipboard(connectionInfo.token)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                    Text("複製")
                                        .font(.caption)
                                }
                                .foregroundColor(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.green)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }

                        // Token display
                        Text(connectionInfo.token)
                            .font(.caption)
                            .foregroundColor(.green)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(8)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(16)
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
            }

            // Status
            if WebSocketServer.shared.isRunning {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("伺服器運行中 - \(WebSocketServer.shared.connectedClients.count) 個已連線裝置")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 400, height: 520)
        .background(Color.black)
    }
}

// MARK: - Helper Functions

private func copyTokenToClipboard(_ token: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(token, forType: .string)
    print("📋 Token copied to clipboard")
}

// MARK: - Preview

struct QRCodeSheet_Previews: PreviewProvider {
    static var previews: some View {
        QRCodeSheet(connectionInfoProvider: ConnectionInfoProvider())
    }
}
