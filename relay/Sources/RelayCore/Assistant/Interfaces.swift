import Foundation

// Explicit seams between Relay's layers. Speech services only convert audio <-> text; they
// never decide what to do. Reasoning interprets text, planning turns that into tool steps,
// and the tool executor is the only component that changes anything.

// MARK: - Speech (input/output only)

public struct Transcript: Sendable, Equatable {
    public let text: String
    public let languageCode: String?
    /// Which service produced the text, e.g. "ElevenLabs Speech to Text (scribe_v2)".
    public let provider: String

    public init(text: String, languageCode: String?, provider: String) {
        self.text = text
        self.languageCode = languageCode
        self.provider = provider
    }
}

public protocol SpeechTranscriber: Sendable {
    var providerName: String { get }
    func transcribe(audio: Data, filename: String, mimeType: String, languageHint: String?) async throws -> Transcript
}

public struct SynthesizedAudio: Sendable, Equatable {
    public let data: Data
    public let mimeType: String
    public init(data: Data, mimeType: String) { self.data = data; self.mimeType = mimeType }
}

public protocol SpeechSynthesizer: Sendable {
    var providerName: String { get }
    func synthesize(text: String, languageCode: String?) async throws -> SynthesizedAudio
}

// MARK: - Reasoning

public enum Intent: Sendable, Equatable {
    case startTraining
    case nextStep
    case previousStep
    case repeatStep
    case acknowledgeWarning
    case askProcedure(String)
    case setLanguage(String)
    case addTask(String)
    case runSimulation
    case stopRunner
    case help
    case unknown(String)

    public var label: String {
        switch self {
        case .startTraining: return "Start warehouse training"
        case .nextStep: return "Next training step"
        case .previousStep: return "Previous training step"
        case .repeatStep: return "Repeat current step"
        case .acknowledgeWarning: return "Acknowledge safety warning"
        case let .askProcedure(q): return "Question about the procedure: \u{201C}\(q)\u{201D}"
        case let .setLanguage(code): return "Switch language to \(SupportedLanguage.name(code))"
        case let .addTask(title): return "Add task: \u{201C}\(title)\u{201D}"
        case .runSimulation: return "Run the Wybe simulation"
        case .stopRunner: return "Stop the Wybe runner"
        case .help: return "Explain what Relay can do"
        case .unknown: return "Not understood"
        }
    }
}

public struct ReasoningContext: Sendable {
    public var trainingActive: Bool
    public var language: String
    public init(trainingActive: Bool, language: String) {
        self.trainingActive = trainingActive
        self.language = language
    }
}

public struct Understanding: Sendable, Equatable {
    public let intent: Intent
    public let confidence: Double
    public let explanation: String
    /// Name of the reasoning engine, shown in the UI so users know what interpreted them.
    public let engine: String
}

public protocol Reasoner: Sendable {
    var engineName: String { get }
    func interpret(_ utterance: String, context: ReasoningContext) async -> Understanding
}

// MARK: - Planning

public struct PlannedStep: Sendable, Hashable {
    public let toolName: String
    public let arguments: [String: String]
    public let rationale: String
    public init(toolName: String, arguments: [String: String] = [:], rationale: String) {
        self.toolName = toolName
        self.arguments = arguments
        self.rationale = rationale
    }
}

public struct Plan: Sendable, Equatable {
    public let summary: String
    public let steps: [PlannedStep]
}

public protocol TaskPlanner: Sendable {
    func plan(for understanding: Understanding) -> Plan
}

// MARK: - Tool execution

public struct ToolDescriptor: Sendable, Equatable {
    public let name: String
    public let summary: String
    /// When true the executor will not run the tool until a person approves it.
    public let requiresApproval: Bool
}

public struct ToolOutput: Sendable, Equatable {
    public let reply: String
    public let needsAttention: Bool
    public init(reply: String, needsAttention: Bool = false) {
        self.reply = reply
        self.needsAttention = needsAttention
    }
}

public protocol Tool: Sendable {
    var descriptor: ToolDescriptor { get }
    func run(arguments: [String: String]) async throws -> ToolOutput
}

public enum ToolAttemptStatus: String, Sendable, Equatable {
    case succeeded, failed, needsAttention, awaitingApproval, declined, unknownTool
}

public struct ToolAttempt: Sendable, Equatable {
    public let step: PlannedStep
    public let status: ToolAttemptStatus
    public let output: String
}

public protocol ToolExecuting: Sendable {
    func descriptor(for name: String) -> ToolDescriptor?
    func execute(_ step: PlannedStep, approved: Bool) async -> ToolAttempt
}

/// A tool backed by a closure. Relay registers a fixed set; there is no arbitrary shell,
/// file-system or system-settings tool.
public struct ClosureTool: Tool {
    public let descriptor: ToolDescriptor
    private let handler: @Sendable ([String: String]) async throws -> ToolOutput

    public init(name: String, summary: String, requiresApproval: Bool = false,
                handler: @escaping @Sendable ([String: String]) async throws -> ToolOutput) {
        descriptor = ToolDescriptor(name: name, summary: summary, requiresApproval: requiresApproval)
        self.handler = handler
    }

    public func run(arguments: [String: String]) async throws -> ToolOutput { try await handler(arguments) }
}

/// Executes only registered tools, enforcing approval.
public struct ToolRegistry: ToolExecuting {
    private let tools: [String: Tool]

    public init(_ tools: [Tool]) {
        self.tools = Dictionary(tools.map { ($0.descriptor.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public var descriptors: [ToolDescriptor] { tools.values.map(\.descriptor).sorted { $0.name < $1.name } }

    public func descriptor(for name: String) -> ToolDescriptor? { tools[name]?.descriptor }

    public func execute(_ step: PlannedStep, approved: Bool) async -> ToolAttempt {
        guard let tool = tools[step.toolName] else {
            return ToolAttempt(step: step, status: .unknownTool, output: "No tool named \(step.toolName) is registered; nothing was done.")
        }
        if tool.descriptor.requiresApproval && !approved {
            return ToolAttempt(step: step, status: .awaitingApproval, output: "Waiting for your approval.")
        }
        do {
            let output = try await tool.run(arguments: step.arguments)
            return ToolAttempt(step: step, status: output.needsAttention ? .needsAttention : .succeeded, output: output.reply)
        } catch {
            return ToolAttempt(step: step, status: .failed, output: "Failed: \(error)")
        }
    }
}
