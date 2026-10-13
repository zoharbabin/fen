#!/usr/bin/env swift
// Checks a Markdown file in iCloud Drive after `ICloudDocumentUITests` saved it from Fen (issue #59).
// Usage: swift scripts/check-icloud-file.swift <file> <original-text-file>
// Prints what it finds, then puts the original text back. Run it from a terminal that can read iCloud Drive.
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: check-icloud-file.swift <file> <original-text-file>")
    exit(2)
}

let file = URL(fileURLWithPath: args[1])
let original = try String(contentsOfFile: args[2], encoding: .utf8)
let text = try String(contentsOf: file, encoding: .utf8)
print("marker in file: \(text.contains("fen-icloud-check-"))")
let versions = NSFileVersion.otherVersionsOfItem(at: file) ?? []
print("saved versions: \(versions.count)")
for version in versions.prefix(5) {
    print("  \(version.modificationDate.map { "\($0)" } ?? "?") on \(version.localizedNameOfSavingComputer ?? "?")")
}

print("conflicts: \((NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []).count)")
let keys: Set<URLResourceKey> = [
    .ubiquitousItemIsUploadedKey,
    .ubiquitousItemIsUploadingKey,
    .ubiquitousItemUploadingErrorKey,
]
for _ in 0 ..< 45 {
    let values = try file.resourceValues(forKeys: keys)
    if values.ubiquitousItemIsUploaded == true {
        print("uploaded to iCloud: true")
        break
    }
    Thread.sleep(forTimeInterval: 2)
}

let final = try file.resourceValues(forKeys: keys)
print("uploaded: \(final.ubiquitousItemIsUploaded ?? false), uploading: \(final.ubiquitousItemIsUploading ?? false)")
try original.write(to: file, atomically: true, encoding: .utf8)
print("original text restored")
