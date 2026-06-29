import Foundation

struct FileSearchAccessIssue: Equatable, Sendable {
    let locationName: String
    let path: String
    let reason: String

    static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
}

protocol FileSearchAccessChecking: Sendable {
    func inaccessibleLocations(home: URL) -> [FileSearchAccessIssue]
}

struct ProtectedLocationFileSearchAccessChecker: FileSearchAccessChecking {
    private let locationNames: [String]

    init(locationNames: [String] = ["Desktop", "Documents", "Downloads"]) {
        self.locationNames = locationNames
    }

    func inaccessibleLocations(home: URL) -> [FileSearchAccessIssue] {
        locationNames.compactMap { locationName in
            inaccessibleLocation(named: locationName, home: home)
        }
    }

    private func inaccessibleLocation(named locationName: String, home: URL) -> FileSearchAccessIssue? {
        let url = home.appendingPathComponent(locationName, isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return nil
        } catch {
            guard Self.isPermissionDenied(error) else {
                return nil
            }
            return FileSearchAccessIssue(
                locationName: locationName,
                path: url.path,
                reason: Self.reason(for: error)
            )
        }
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionDenied(underlying)
        }
        return false
    }

    private static func reason(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) {
            return "Operation not permitted"
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EACCES) {
            return "Permission denied"
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return reason(for: underlying)
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError {
            return "Permission denied"
        }
        return nsError.localizedDescription
    }
}
