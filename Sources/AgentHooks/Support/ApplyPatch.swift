import Foundation

/// The files an OpenAI Codex `apply_patch` script touches. Codex hands hooks the raw
/// patch as `tool_input.command` — there is no `file_path` field; `Edit` and `Write`
/// exist only as matcher aliases — so the paths come out of the script's own headers:
///
///     *** Begin Patch
///     *** Update File: src/a.swift
///     *** Move to: src/b.swift          (optional, follows an Update)
///     *** Add File: docs/new.md
///     *** Delete File: old.txt
///     *** End Patch
///
/// Pure text; paths are returned as written (relative paths are relative to the
/// session's `cwd`, which the hook payload carries).
public enum ApplyPatch {
    public enum Kind: Equatable { case update, add, delete }
    public struct Touch: Equatable {
        public let path: String
        public let kind: Kind
        public init(path: String, kind: Kind) { self.path = path; self.kind = kind }
    }

    /// Every file header in `patch`, in order. A `*** Move to:` replaces the path of
    /// the Update it follows (the file now lives at the new name).
    public static func touchedFiles(in patch: String) -> [Touch] {
        var out: [Touch] = []
        // `isNewline`, not `== "\n"`: a CRLF pair is a single Character in Swift and a
        // split on "\n" alone walks straight past a Windows-authored patch.
        for rawLine in patch.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let p = value(of: "*** Update File: ", in: line) { out.append(Touch(path: p, kind: .update)) }
            else if let p = value(of: "*** Add File: ", in: line) { out.append(Touch(path: p, kind: .add)) }
            else if let p = value(of: "*** Delete File: ", in: line) { out.append(Touch(path: p, kind: .delete)) }
            else if let p = value(of: "*** Move to: ", in: line), let last = out.last, last.kind == .update {
                out[out.count - 1] = Touch(path: p, kind: .update)
            }
        }
        return out
    }

    private static func value(of prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let p = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? nil : p
    }
}
