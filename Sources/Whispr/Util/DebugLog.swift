import Foundation

/// Unbuffered debug logging to stderr (stdout is block-buffered when redirected).
func dbg(_ message: String) {
    let line = "[Whispr] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
