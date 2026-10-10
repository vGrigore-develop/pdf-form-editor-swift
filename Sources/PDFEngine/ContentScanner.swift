import Foundation

/// q/Q balance of a content stream (SPEC 5.2 guard). A small tokenizer that skips
/// strings, comments, hex strings, names, dict/array brackets and inline image data.
/// Ported from spikes/cut.py `q_balance`, whose unit tests it mirrors.
public enum ContentScanner {
    /// (minimum depth reached, final depth). Balanced means (0, 0).
    public static func qBalance(_ data: Data) -> (minDepth: Int, finalDepth: Int) {
        let d = [UInt8](data)
        let n = d.count
        var i = 0
        var depth = 0, minDepth = 0
        let ws: Set<UInt8> = [0x20, 0x09, 0x0D, 0x0A, 0x0C, 0x00]
        let delim: Set<UInt8> = Set("()<>[]{}/%".utf8)
        func isWS(_ c: UInt8) -> Bool { ws.contains(c) }

        while i < n {
            let c = d[i]
            if isWS(c) {
                i += 1
            } else if c == UInt8(ascii: "%") {
                while i < n && d[i] != 0x0D && d[i] != 0x0A { i += 1 }
            } else if c == UInt8(ascii: "(") {
                var lvl = 1
                i += 1
                while i < n && lvl > 0 {
                    let ch = d[i]
                    if ch == 0x5C { i += 2; continue }
                    if ch == 0x28 { lvl += 1 } else if ch == 0x29 { lvl -= 1 }
                    i += 1
                }
            } else if i + 1 < n && ((c == UInt8(ascii: "<") && d[i + 1] == UInt8(ascii: "<")) || (c == UInt8(ascii: ">") && d[i + 1] == UInt8(ascii: ">"))) {
                i += 2
            } else if c == UInt8(ascii: "<") {
                while i < n && d[i] != UInt8(ascii: ">") { i += 1 }
                i += 1
            } else if "[]{}".utf8.contains(c) {
                i += 1
            } else if c == UInt8(ascii: "/") {
                i += 1
                while i < n && !isWS(d[i]) && !delim.contains(d[i]) { i += 1 }
            } else {
                var j = i
                while j < n && !isWS(d[j]) && !delim.contains(d[j]) { j += 1 }
                let isQ = j - i == 1 && d[i] == UInt8(ascii: "q")
                let isBigQ = j - i == 1 && d[i] == UInt8(ascii: "Q")
                let isID = j - i == 2 && d[i] == UInt8(ascii: "I") && d[i + 1] == UInt8(ascii: "D")
                i = max(j, i + 1)
                if isQ {
                    depth += 1
                } else if isBigQ {
                    depth -= 1
                    minDepth = min(minDepth, depth)
                } else if isID {
                    // Inline image data: skip one whitespace byte, then find whitespace + "EI" + (whitespace | end).
                    i += 1
                    var found = false
                    var k = i
                    while k + 2 < n {
                        if isWS(d[k]) && d[k + 1] == UInt8(ascii: "E") && d[k + 2] == UInt8(ascii: "I") &&
                            (k + 3 == n || isWS(d[k + 3])) {
                            i = k + 3
                            found = true
                            break
                        }
                        k += 1
                    }
                    if !found { i = n }
                }
            }
        }
        return (minDepth, depth)
    }

    public static func isBalanced(_ data: Data) -> Bool {
        let b = qBalance(data)
        return b.minDepth == 0 && b.finalDepth == 0
    }
}
