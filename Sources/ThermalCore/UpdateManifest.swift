import Foundation

/// `version.json`, published with every build next to the DMG/ZIP.
public struct UpdateManifest: Codable, Equatable {
    public var build: Int
    public var version: String
    /// What is new, one change per line.
    public var notes: String
    /// File name of the zipped app in the same release.
    public var zip: String

    public init(build: Int, version: String, notes: String, zip: String) {
        self.build = build
        self.version = version
        self.notes = notes
        self.zip = zip
    }

    public func isNewer(thanBuild local: Int) -> Bool { build > local }

    /// Notes as bullet lines without empty lines.
    public var noteLines: [String] {
        notes.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty }
    }
}
