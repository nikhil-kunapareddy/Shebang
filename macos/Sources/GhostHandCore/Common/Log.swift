import os

public enum Log {
    public static let subsystem = "com.ghosthand.mac"

    public static let agent = Logger(subsystem: subsystem, category: "agent")
    public static let jev = Logger(subsystem: subsystem, category: "jev")
    public static let safety = Logger(subsystem: subsystem, category: "safety")
    public static let screen = Logger(subsystem: subsystem, category: "screen")
    public static let input = Logger(subsystem: subsystem, category: "input")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let speech = Logger(subsystem: subsystem, category: "speech")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
