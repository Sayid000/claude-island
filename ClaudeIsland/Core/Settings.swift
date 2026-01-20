//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let instancesWidth = "instancesWidth"
        static let instancesHeight = "instancesHeight"
        static let chatWidth = "chatWidth"
        static let chatHeight = "chatHeight"
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Window Sizes

    /// Instances panel width (default: 480)
    static var instancesWidth: CGFloat {
        get {
            CGFloat(defaults.float(forKey: Keys.instancesWidth))
        }
        set {
            defaults.set(Float(newValue), forKey: Keys.instancesWidth)
        }
    }

    /// Instances panel height (default: 320)
    static var instancesHeight: CGFloat {
        get {
            CGFloat(defaults.float(forKey: Keys.instancesHeight))
        }
        set {
            defaults.set(Float(newValue), forKey: Keys.instancesHeight)
        }
    }

    /// Chat panel width (default: 600)
    static var chatWidth: CGFloat {
        get {
            CGFloat(defaults.float(forKey: Keys.chatWidth))
        }
        set {
            defaults.set(Float(newValue), forKey: Keys.chatWidth)
        }
    }

    /// Chat panel height (default: 580)
    static var chatHeight: CGFloat {
        get {
            CGFloat(defaults.float(forKey: Keys.chatHeight))
        }
        set {
            defaults.set(Float(newValue), forKey: Keys.chatHeight)
        }
    }

    // MARK: - Default Sizes

    /// Default instances panel size
    static var defaultInstancesSize: CGSize {
        CGSize(width: 480, height: 320)
    }

    /// Default chat panel size
    static var defaultChatSize: CGSize {
        CGSize(width: 600, height: 580)
    }
}
