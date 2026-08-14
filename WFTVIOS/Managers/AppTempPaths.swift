import Foundation

enum AppTempPaths {
    static let exportDirectoryName = "wftv_exports"

    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory
    }

    static var exportDirectoryURL: URL {
        temporaryDirectory.appendingPathComponent(exportDirectoryName, isDirectory: true)
    }

    static func makeExportFileURL(fileName: String) throws -> URL {
        try ensureDirectoryExists(at: exportDirectoryURL)
        return exportDirectoryURL.appendingPathComponent(fileName)
    }

    static func ensureDirectoryExists(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
