import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import RelayCore

// relay-runner — headless entry point. No window, speech service or per-action confirmation.

let usage = """
    relay-runner — Relay headless runner

    USAGE
      relay-runner wybe-sim [options]     Run the deterministic Night Shift SIMULATION
      relay-runner wybe-live              Explain what the live Wybe connection still needs (sends nothing)
      relay-runner warehouse [options]    Text-only warehouse training demo (reads commands from stdin)
      relay-runner export-procedure       Print the synthetic demo procedure as JSON
      relay-runner help

    wybe-sim OPTIONS
      --seed N            First shift seed (default 1). Shift i uses seed N+i.
      --shifts N          Number of simulated shifts (default 10)
      --faults LEVEL      none | typical | harsh  (default typical)
      --max-actions N     Action budget per shift (default 200)
      --min-interval S    Minimum seconds between requests (default 0 for the simulator)
      --stop-after N      Trip the stop control after N recorded actions (demonstrates stop)
      --stop-file PATH    Stop gracefully when this file appears
      --json PATH         Write the run reports (JSON) to PATH
      --verbose           Print each decision's rationale
      Ctrl-C              First press: stop before the next action. Second press: exit immediately.

    warehouse OPTIONS
      --lang CODE         en | nb | pl (default en)
      --procedure PATH    Load a procedure JSON instead of the built-in synthetic demo
    """

struct Arguments {
    var command: String
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        command = raw.first ?? "help"
        var index = 1
        while index < raw.count {
            let item = raw[index]
            if item.hasPrefix("--") {
                let key = String(item.dropFirst(2))
                if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                    options[key] = raw[index + 1]
                    index += 2
                    continue
                }
                flags.insert(key)
            }
            index += 1
        }
    }

    func int(_ key: String, _ fallback: Int) -> Int { options[key].flatMap(Int.init) ?? fallback }
    func double(_ key: String, _ fallback: Double) -> Double { options[key].flatMap(Double.init) ?? fallback }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Stop control

let stopSignal = StopSignal()
var signalSources: [DispatchSourceSignal] = []

func installInterruptHandler() {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    for sig in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            if stopSignal.isStopped {
                printError("\nSecond interrupt — exiting immediately.")
                exit(130)
            }
            printError("\nStop requested — no further actions will be sent. (Press Ctrl-C again to exit now.)")
            stopSignal.stop(reason: "Interrupted by operator")
        }
        source.resume()
        signalSources.append(source)
    }
}

func watchStopFile(_ path: String) -> Task<Void, Never> {
    Task.detached {
        while !Task.isCancelled && !stopSignal.isStopped {
            if FileManager.default.fileExists(atPath: path) {
                stopSignal.stop(reason: "Stop file \(path) appeared")
                printError("Stop file detected — stopping before the next action.")
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}

// MARK: - Commands

func runSimulation(_ args: Arguments) async -> Int32 {
    let seed = UInt64(max(0, args.int("seed", 1)))
    let shifts = max(1, args.int("shifts", 10))
    let faults: SimulatedNightShift.Faults
    switch args.options["faults"] ?? "typical" {
    case "none": faults = .none
    case "harsh": faults = .harsh
    case "typical": faults = .typical
    default:
        printError("Unknown --faults value. Use none, typical or harsh."); return 64
    }
    var configuration = RunnerConfiguration.simulation()
    configuration.maxActions = max(1, args.int("max-actions", 200))
    configuration.minRequestInterval = max(0, args.double("min-interval", 0))
    let stopAfter = args.options["stop-after"].flatMap(Int.init)
    let verbose = args.flags.contains("verbose")
    let stopFileWatcher = args.options["stop-file"].map(watchStopFile)
    installInterruptHandler()

    print("""
        ================================================================
         RELAY NIGHT SHIFT — SIMULATION MODE
         Scores below come from Relay's own simulator. They are NOT Wybe
         challenge results and say nothing about live performance.
        ================================================================
        """)

    let log = InMemoryEventLog()
    var reports: [RunReport] = []
    for index in 0..<shifts {
        if stopSignal.isStopped { break }
        let shiftSeed = seed + UInt64(index)
        let simulator = SimulatedNightShift(configuration: .init(seed: shiftSeed, faults: faults))
        let recorded = Counter()
        let runner = AutonomousRunner(adapter: simulator, policy: SimulatedShiftPolicy(), configuration: configuration,
                                      log: log, stop: stopSignal) { event in
            switch event {
            case let .recorded(record):
                let n = recorded.increment()
                let tries = record.attempts > 1 ? " after \(record.attempts) attempts" : ""
                let line = "  #\(record.sequence) [\(record.mode.label)] \(record.request.displayText) → "
                    + "\(record.status.rawValue)\(tries) (\(record.message))"
                print(line)
                if verbose { print("        why: \(record.rationale)") }
                if let stopAfter, n >= stopAfter { stopSignal.stop(reason: "Stop control tripped after \(stopAfter) actions (--stop-after)") }
            case let .finished(report):
                print("  — " + report.summary.replacingOccurrences(of: "\n", with: "\n    "))
            default:
                break
            }
        }
        print("\nShift \(index + 1)/\(shifts) (seed \(shiftSeed))")
        reports.append(await runner.run())
    }
    stopFileWatcher?.cancel()

    let scores = reports.compactMap(\.score).filter { $0.mode == .simulation }
    if !scores.isEmpty {
        let average = scores.map(\.value).reduce(0, +) / Double(scores.count)
        print("\nSIMULATED average over \(scores.count) shift(s): " +
              LabeledScore(mode: .simulation, value: average, source: "Relay simulator").displayText)
    }
    if let path = args.options["json"] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(reports).write(to: URL(fileURLWithPath: path))
            print("Wrote \(reports.count) report(s) to \(path)")
        } catch {
            printError("Could not write \(path): \(error)")
            return 1
        }
    }
    return 0
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

func runLive() async -> Int32 {
    print("LIVE MODE — nothing will be sent.\n")
    let log = InMemoryEventLog()
    let runner = AutonomousRunner(adapter: LiveNightShiftAdapter(), policy: SimulatedShiftPolicy(),
                                  configuration: RunnerConfiguration(expectedMode: .live, allowedActions: []),
                                  log: log, stop: stopSignal)
    let report = await runner.run()
    print(report.summary)
    return 2
}

func runWarehouse(_ args: Arguments) async -> Int32 {
    var procedure = DemoProcedure.procedure
    if let path = args.options["procedure"] {
        do {
            procedure = try Procedure.load(from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            printError("Could not load procedure: \(error)"); return 65
        }
    }
    let language = args.options["lang"] ?? "en"
    let log = InMemoryEventLog()
    let runtime = AssistantRuntime(procedure: procedure, language: language, log: log)
    let snapshot = await runtime.trainingSnapshot()
    print("""
        RELAY — Warehouse training (text mode)
        \(snapshot.procedureTitle)
        \(snapshot.disclaimer)
        Reasoning: \(await runtime.reasonerName)
        Commands: start · next · back · repeat · understood · help · language polski/norsk/english · quit
        Anything else is treated as a question about the procedure.
        """)
    while true {
        print("\n> ", terminator: "")
        guard let line = readLine() else { break }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        if ["quit", "exit", "q"].contains(text.lowercased()) { break }
        let interaction = await runtime.handle(HeardInput(text: text, source: .typed))
        print("  understood: \(interaction.understanding.intent.label)")
        print("  plan:       \(interaction.plan.steps.map(\.toolName).joined(separator: ", ").ifEmpty("nothing"))")
        print("  result:     \(interaction.status.rawValue)")
        print(interaction.reply.split(separator: "\n").map { "  │ " + $0 }.joined(separator: "\n"))
        if case let .answer(_, citation, _)? = await runtime.trainingSnapshot().lastAnswer {
            print("  source: \(citation.stepID) — \(citation.stepTitle): \u{201C}\(citation.quote)\u{201D}")
        }
    }
    let open = await runtime.tasks.tasks.filter { $0.state == .needsAttention }
    if !open.isEmpty {
        print("\nNeeds attention (\(open.count)):")
        for task in open { print("  • \(task.title)") }
    }
    return 0
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
let status: Int32
switch arguments.command {
case "wybe-sim": status = await runSimulation(arguments)
case "wybe-live": status = await runLive()
case "warehouse": status = await runWarehouse(arguments)
case "export-procedure":
    status = (try? DemoProcedure.procedure.jsonData()).map { print(String(decoding: $0, as: UTF8.self)); return 0 } ?? 1
case "help", "--help", "-h": print(usage); status = 0
default: print(usage); status = 64
}
exit(status)
