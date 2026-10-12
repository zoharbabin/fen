import Foundation
import NaturalLanguage

func memory() -> (footprint: Double, resident: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else {
        FileHandle.standardError.write(Data("task_info failed: \(status)\n".utf8))
        exit(1)
    }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.resident_size) / 1_048_576)
}

func report(_ step: String, since base: (footprint: Double, resident: Double)) {
    let now = memory()
    print(String(
        format: "%-34@ footprint %7.1f MB (%+7.1f)   resident %7.1f MB (%+7.1f)",
        step as NSString, now.footprint, now.footprint - base.footprint, now.resident, now.resident - base.resident
    ))
}

/// Deterministic, varied text of about 60 words per chunk, built from a small vocabulary.
let vocabulary = """
tag commit workflow builds app signs archive sends apple notarization upload copy notes external drive \
week keep copy site fire theft password manager reuse login sites factor authentication water tomatoes \
morning tie stems stake remove side shoots track monthly spending spreadsheet paycheck savings bills \
book flight march stay tram line trip coast roast vegetables olive oil garlic pasta firm sauce agenda \
sprint review bugs hiring plan action items board call tire leak patch tube brake pads ride novel \
lighthouse keeper history printing press guide bird songs bed hour night screens coffee rest error \
codes version endpoints document field response body
""".split(separator: " ").map(String.init)

func chunk(_ number: Int) -> String {
    var state = UInt64(number) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var words: [String] = []
    for _ in 0 ..< 60 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        words.append(vocabulary[Int(state >> 33) % vocabulary.count])
    }
    return words.joined(separator: " ") + "."
}

let arguments = CommandLine.arguments
guard arguments.count >= 2, ["sentence", "contextual"].contains(arguments[1]) else {
    print("usage: measure-embedding-memory sentence|contextual [chunks]")
    exit(2)
}

let chunks = arguments.count > 2 ? Int(arguments[2]) ?? 3000 : 3000
let texts = (0 ..< chunks).map(chunk)

let os = ProcessInfo.processInfo.operatingSystemVersionString
print("model: \(arguments[1])   chunks: \(chunks)   words per chunk: 60   macOS: \(os)")
let start = memory()
report("process start (texts prepared)", since: start)

var peak = start.footprint
func samplePeak() {
    peak = max(peak, memory().footprint)
}

if arguments[1] == "sentence" {
    guard let model = NLEmbedding.sentenceEmbedding(for: .english) else {
        print("The English sentence model isn't installed on this machine.")
        exit(3)
    }
    report("after loading the model", since: start)
    _ = model.vector(for: texts[0])
    report("after the first vector", since: start)
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for (position, text) in texts.enumerated() {
            autoreleasepool { _ = model.vector(for: text) }
            if position % 250 == 0 {
                samplePeak()
            }
        }
    }
    samplePeak()
    report("after \(chunks) chunks", since: start)
    print(String(format: "peak footprint while embedding   %7.1f MB (%+7.1f)", peak, peak - start.footprint))
    print("time: \(elapsed) (\(elapsed / chunks) per chunk)")
} else {
    guard let model = NLContextualEmbedding(language: .english), model.hasAvailableAssets else {
        print(
            "The English contextual model's assets aren't installed. Not measured: loading them would use the network."
        )
        exit(3)
    }
    do {
        try model.load()
    } catch {
        print("load failed: \(error)")
        exit(4)
    }
    report("after loading the model", since: start)
    func embed(_ text: String) {
        _ = try? model.embeddingResult(for: text, language: .english)
    }
    embed(texts[0])
    report("after the first result", since: start)
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for (position, text) in texts.enumerated() {
            autoreleasepool { embed(text) }
            if position % 250 == 0 {
                samplePeak()
            }
        }
    }
    samplePeak()
    report("after \(chunks) chunks", since: start)
    print(String(format: "peak footprint while embedding   %7.1f MB (%+7.1f)", peak, peak - start.footprint))
    print("time: \(elapsed) (\(elapsed / chunks) per chunk)")
    model.unload()
    report("after unload()", since: start)
}
