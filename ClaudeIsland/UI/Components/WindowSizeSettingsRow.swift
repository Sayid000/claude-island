//
//  WindowSizeSettingsRow.swift
//  ClaudeIsland
//
//  Window size settings for instances and chat panels
//

import SwiftUI

struct WindowSizeSettingsRow: View {
    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var instancesWidth: Double
    @State private var instancesHeight: Double
    @State private var chatWidth: Double
    @State private var chatHeight: Double

    init() {
        // Load saved values or use defaults
        _instancesWidth = State(initialValue: Double(AppSettings.instancesWidth > 0 ? AppSettings.instancesWidth : 480))
        _instancesHeight = State(initialValue: Double(AppSettings.instancesHeight > 0 ? AppSettings.instancesHeight : 320))
        _chatWidth = State(initialValue: Double(AppSettings.chatWidth > 0 ? AppSettings.chatWidth : 600))
        _chatHeight = State(initialValue: Double(AppSettings.chatHeight > 0 ? AppSettings.chatHeight : 580))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Window Size")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Expanded settings
            if isExpanded {
                VStack(spacing: 8) {
                    // Instances panel size
                    SizeControlRow(
                        label: "Instances Panel",
                        width: $instancesWidth,
                        height: $instancesHeight,
                        defaultWidth: Double(AppSettings.defaultInstancesSize.width),
                        defaultHeight: Double(AppSettings.defaultInstancesSize.height),
                        onSave: {
                            AppSettings.instancesWidth = CGFloat(instancesWidth)
                            AppSettings.instancesHeight = CGFloat(instancesHeight)
                            triggerWindowRecreation()
                        }
                    )

                    Divider()
                        .background(Color.white.opacity(0.1))

                    // Chat panel size
                    SizeControlRow(
                        label: "Chat Panel",
                        width: $chatWidth,
                        height: $chatHeight,
                        defaultWidth: Double(AppSettings.defaultChatSize.width),
                        defaultHeight: Double(AppSettings.defaultChatSize.height),
                        onSave: {
                            AppSettings.chatWidth = CGFloat(chatWidth)
                            AppSettings.chatHeight = CGFloat(chatHeight)
                            triggerWindowRecreation()
                        }
                    )
                }
                .padding(.leading, 28)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private func triggerWindowRecreation() {
        // Notify to recreate the window
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
}

// MARK: - Size Control Row

private struct SizeControlRow: View {
    let label: String
    @Binding var width: Double
    @Binding var height: Double
    let defaultWidth: Double
    let defaultHeight: Double
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.7))

            HStack(spacing: 12) {
                // Width control
                SizeInput(
                    label: "W",
                    value: $width,
                    range: 300...800
                )

                // Height control
                SizeInput(
                    label: "H",
                    value: $height,
                    range: 200...800
                )

                // Reset button
                Button {
                    width = defaultWidth
                    height = defaultHeight
                    onSave()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Reset to default")

                Spacer()

                // Apply button
                Button {
                    onSave()
                } label: {
                    Text("Apply")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - Size Input

private struct SizeInput: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))

            TextField("", value: $value, format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .frame(width: 50)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.08))
                )

            // Stepper buttons
            VStack(spacing: 0) {
                Button {
                    value = min(range.upperBound, value + 10)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .frame(height: 12)

                Divider()
                    .background(Color.white.opacity(0.2))

                Button {
                    value = max(range.lowerBound, value - 10)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .frame(height: 12)
            }
            .frame(width: 20)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.08))
            )
        }
    }
}
