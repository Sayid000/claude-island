//
//  SessionStateDTO.swift
//  ClaudeIsland
//
//  Codable Data Transfer Object for SessionState over WebSocket
//

import Foundation

// MARK: - Session State DTO

/// Simplified, Codable version of SessionState for WebSocket transmission
struct SessionStateDTO: Codable, Identifiable, Equatable {
    let id: String
    let sessionId: String
    let title: String
    let projectName: String
    let phase: SessionPhaseDTO
    let lastActivity: Date
    let pendingApprovals: Int
    let isProcessing: Bool

    init(from session: SessionState) {
        self.id = session.sessionId
        self.sessionId = session.sessionId
        self.title = session.displayTitle
        self.projectName = session.projectName
        self.phase = SessionPhaseDTO(from: session.phase)
        self.lastActivity = session.lastActivity
        self.pendingApprovals = session.activePermission != nil ? 1 : 0
        self.isProcessing = session.phase.isActive
    }
}

// MARK: - Session Phase DTO

enum SessionPhaseDTO: String, Codable {
    case idle
    case processing
    case waitingForInput
    case waitingForApproval
    case compacting
    case closed

    init(from phase: SessionPhase) {
        switch phase {
        case .idle:
            self = .idle
        case .processing:
            self = .processing
        case .waitingForInput:
            self = .waitingForInput
        case .waitingForApproval:
            self = .waitingForApproval
        case .compacting:
            self = .compacting
        case .ended:
            self = .closed
        }
    }

    /// Convert back to SessionPhase (simplified, loses PermissionContext)
    func toSessionPhase() -> SessionPhase {
        switch self {
        case .idle:
            return .idle
        case .processing:
            return .processing
        case .waitingForInput:
            return .waitingForInput
        case .waitingForApproval:
            return .waitingForApproval(PermissionContext(
                toolUseId: "",
                toolName: "Unknown",
                toolInput: nil,
                receivedAt: Date()
            ))
        case .compacting:
            return .compacting
        case .closed:
            return .ended
        }
    }
}

// MARK: - Extensions

extension SessionStateDTO {
    /// Whether this session needs user attention
    var needsAttention: Bool {
        phase == .waitingForInput || phase == .waitingForApproval
    }

    /// Stable identity for SwiftUI
    var stableId: String {
        sessionId
    }

    /// Display title
    var displayTitle: String {
        title.isEmpty ? "Untitled" : title
    }
}
