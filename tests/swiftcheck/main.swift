import Foundation

// swiftcheck FIXTURES OUTDIR -> OUTDIR/<fixture>.<method>.swift.mp4
let args = CommandLine.arguments
let fixtures = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let files = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "mp4" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
for f in files {
    let stem = f.deletingPathExtension().lastPathComponent
    try Mp4.silent(src: f, dst: out.appendingPathComponent("\(stem).silent.swift.mp4"))
    // the check the app runs on a Silent result must pass on a good one
    let frames = try Mp4.silentCheck(original: f, patched: out.appendingPathComponent("\(stem).silent.swift.mp4"))
    print("swift: silent check ok,", frames, "frames")
    try Mp4.inflate(src: f, dst: out.appendingPathComponent("\(stem).inflate.swift.mp4"))
    if stem.contains("60") { try Mp4.fps(src: f, dst: out.appendingPathComponent("\(stem).fps.swift.mp4"), divisor: 2) }
    print("swift:", f.lastPathComponent)
}
