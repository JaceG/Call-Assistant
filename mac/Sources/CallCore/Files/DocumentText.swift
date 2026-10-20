import AppKit
import Foundation
import PDFKit

/// The text of documents that aren't plain text: PDFs, and Word, RTF and
/// OpenDocument files.
enum DocumentText {
    static let pdfExtensions: Set<String> = ["pdf"]
    static let documentTypes: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML,
        "doc": .docFormat,
        "rtf": .rtf,
        "odt": .openDocument,
    ]

    static func handles(_ fileExtension: String) -> Bool {
        pdfExtensions.contains(fileExtension) || documentTypes[fileExtension] != nil
    }

    /// The document's text, or nil if it couldn't be read.
    static func text(of url: URL) -> String? {
        let fileExtension = url.pathExtension.lowercased()
        if pdfExtensions.contains(fileExtension) {
            return PDFDocument(url: url)?.string
        }
        guard let type = documentTypes[fileExtension] else { return nil }
        return try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
    }
}
