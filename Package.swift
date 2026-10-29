// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MeetingNotes",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MeetingNotes",
            path: "Sources/MeetingNotes",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Speech"),
                .linkedFramework("EventKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
