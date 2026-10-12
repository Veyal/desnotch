import Foundation

// WP-LOGIC owns this file. Base commit: fail-closed stub with the final signature.

enum CommandRiskScanner {
    /// Scans the literal command text of an approval request.
    static func scan(_ command: String, displayLimit: Int = 2000) -> CommandRisk {
        // STUB (WP-LOGIC replaces this body): nothing scanned, nothing approvable.
        CommandRisk(flags: [.unscanned], sanitized: "", wasTruncated: false, tier: .t4)
    }
}
