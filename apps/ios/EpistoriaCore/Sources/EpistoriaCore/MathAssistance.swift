import Foundation

public enum MathAssistanceMode: String, Codable, CaseIterable, Sendable {
    case recognize = "RECOGNIZE"
    case workedSteps = "WORKED_STEPS"
    case graph = "GRAPH"
    case diagnose = "DIAGNOSE"
}

public struct MathGraphDomain: Codable, Equatable, Sendable {
    public var minimumX: Double
    public var maximumX: Double

    public init(minimumX: Double = -10, maximumX: Double = 10) {
        let lower = minimumX.isFinite ? min(max(minimumX, -1_000_000), 1_000_000) : -10
        let upper = maximumX.isFinite ? min(max(maximumX, -1_000_000), 1_000_000) : 10
        if upper - lower >= 0.000_001 {
            self.minimumX = lower
            self.maximumX = upper
        } else {
            self.minimumX = -10
            self.maximumX = 10
        }
    }
}

public struct MathWorkedStep: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var expression: String
    public var explanation: String

    public init(id: UUID = UUID(), expression: String, explanation: String) {
        self.id = id
        self.expression = expression
        self.explanation = explanation
    }
}

public enum MathErrorKind: String, Codable, CaseIterable, Sendable {
    case recognition = "RECOGNITION"
    case notation = "NOTATION"
    case conceptual = "CONCEPTUAL"
    case method = "METHOD"
    case algebra = "ALGEBRA"
    case arithmetic = "ARITHMETIC"
    case verification = "VERIFICATION"
}

public struct MathErrorDiagnosis: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: MathErrorKind
    public var observed: String
    public var explanation: String
    public var correction: String

    public init(
        id: UUID = UUID(),
        kind: MathErrorKind,
        observed: String,
        explanation: String,
        correction: String
    ) {
        self.id = id
        self.kind = kind
        self.observed = observed
        self.explanation = explanation
        self.correction = correction
    }
}

public struct MathAssistanceRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "math-assistance-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var noteId: UUID
    public var noteTitle: String?
    public var mode: MathAssistanceMode
    public var learnerInstructions: String?
    public var outputLanguage: String
    public var selectionSources: [NoteQuerySourceExcerpt]
    public var contextSources: [NoteQuerySourceExcerpt]
    public var disclosureAcknowledged: Bool
    public var providerRoute: AIProviderRouteSnapshot?
}

public struct MathAssistanceResponse: Codable, Equatable, Sendable {
    public var schemaVersion = "math-assistance-response/v1"
    public var recognizedExpression: String
    public var latex: String
    public var interpretation: String
    public var steps: [MathWorkedStep]
    public var finalAnswer: String?
    public var diagnoses: [MathErrorDiagnosis]
    /// An explicit-multiplication expression evaluated locally. Example: `sin(x) + 2*x`.
    public var graphExpression: String?
    public var graphDomain: MathGraphDomain?
    public var confidence: Double
    public var uncertainties: [String]
    public var citedSourceIds: [UUID]

    public init(
        recognizedExpression: String,
        latex: String = "",
        interpretation: String,
        steps: [MathWorkedStep] = [],
        finalAnswer: String? = nil,
        diagnoses: [MathErrorDiagnosis] = [],
        graphExpression: String? = nil,
        graphDomain: MathGraphDomain? = nil,
        confidence: Double,
        uncertainties: [String] = [],
        citedSourceIds: [UUID]
    ) {
        self.recognizedExpression = recognizedExpression
        self.latex = latex
        self.interpretation = interpretation
        self.steps = steps
        self.finalAnswer = finalAnswer
        self.diagnoses = diagnoses
        self.graphExpression = graphExpression
        self.graphDomain = graphDomain
        self.confidence = min(max(confidence.isFinite ? confidence : 0, 0), 1)
        self.uncertainties = uncertainties
        self.citedSourceIds = citedSourceIds
    }
}

public struct MathAssistanceArtifact: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion = "ai-artifact/math-assistance/v1"
    public var jobId: UUID
    public var noteId: UUID
    public var mode: MathAssistanceMode
    public var learnerInstructions: String?
    public var generatedAt: Date
    public var sourceIds: [UUID]
    public var trace: ProviderTrace
    public var response: MathAssistanceResponse
    public var reviewState: AIArtifactReviewState?
    public var reviewedAt: Date?
    public var editedResponse: MathAssistanceResponse?

    public var createdAt: Date { generatedAt }
    public var updatedAt: Date { reviewedAt ?? generatedAt }

    public init(
        jobId: UUID,
        noteId: UUID,
        mode: MathAssistanceMode,
        learnerInstructions: String? = nil,
        generatedAt: Date,
        sourceIds: [UUID],
        trace: ProviderTrace,
        response: MathAssistanceResponse,
        reviewState: AIArtifactReviewState? = nil,
        reviewedAt: Date? = nil,
        editedResponse: MathAssistanceResponse? = nil
    ) {
        self.jobId = jobId
        self.noteId = noteId
        self.mode = mode
        self.learnerInstructions = learnerInstructions
        self.generatedAt = generatedAt
        self.sourceIds = sourceIds
        self.trace = trace
        self.response = response
        self.reviewState = reviewState
        self.reviewedAt = reviewedAt
        self.editedResponse = editedResponse
    }
}

public struct PreparedMathAssistanceRequest: Equatable, Sendable {
    public var request: MathAssistanceRequest
    public var selectionCount: Int
    public var contextCount: Int
    public var imageCount: Int
    public var approximateTokens: Int
}

public enum MathExpressionError: Error, Equatable, LocalizedError {
    case empty
    case invalidToken(String)
    case unexpectedToken
    case unknownIdentifier(String)
    case divisionByZero
    case nonFiniteResult
    case tooComplex

    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a function of x."
        case .invalidToken(let token):
            "The graph expression contains an unsupported token: \(token)."
        case .unexpectedToken: "The graph expression has an unexpected token."
        case .unknownIdentifier(let name): "The graph expression uses an unsupported name: \(name)."
        case .divisionByZero: "The function is undefined at this value."
        case .nonFiniteResult: "The function produced a value outside the supported graph range."
        case .tooComplex: "The graph expression is too complex."
        }
    }
}

public struct MathGraphSample: Equatable, Sendable {
    public var x: Double
    public var y: Double?
}

public enum MathExpressionEvaluator {
    public static func evaluate(_ expression: String, x: Double) throws -> Double {
        var parser = try Parser(expression: expression, x: x)
        let result = try parser.parse()
        guard result.isFinite, abs(result) <= 1_000_000_000 else {
            throw MathExpressionError.nonFiniteResult
        }
        return result
    }

    public static func samples(
        expression: String,
        domain: MathGraphDomain,
        count: Int = 241
    ) throws -> [MathGraphSample] {
        let boundedCount = min(max(count, 41), 501)
        let span = domain.maximumX - domain.minimumX
        var values: [MathGraphSample] = []
        values.reserveCapacity(boundedCount)
        var successful = 0
        for index in 0..<boundedCount {
            let x = domain.minimumX + span * Double(index) / Double(boundedCount - 1)
            let y = try? evaluate(expression, x: x)
            if y != nil { successful += 1 }
            values.append(MathGraphSample(x: x, y: y))
        }
        guard successful > 1 else { throw MathExpressionError.nonFiniteResult }
        return values
    }

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case plus, minus, multiply, divide, power, leftParenthesis, rightParenthesis, end
    }

    private struct Parser {
        private var tokens: [Token]
        private var index = 0
        private let x: Double
        private var operations = 0

        init(expression: String, x: Double) throws {
            self.x = x
            tokens = try Self.tokenize(expression)
        }

        mutating func parse() throws -> Double {
            guard tokens != [.end] else { throw MathExpressionError.empty }
            let value = try additive()
            guard current == .end else { throw MathExpressionError.unexpectedToken }
            return value
        }

        private var current: Token { tokens[index] }

        private mutating func advance() { index = min(index + 1, tokens.count - 1) }

        private mutating func tick() throws {
            operations += 1
            if operations > 256 { throw MathExpressionError.tooComplex }
        }

        private mutating func additive() throws -> Double {
            var value = try multiplicative()
            while true {
                if current == .plus {
                    advance()
                    try tick()
                    value += try multiplicative()
                } else if current == .minus {
                    advance()
                    try tick()
                    value -= try multiplicative()
                } else {
                    return value
                }
            }
        }

        private mutating func multiplicative() throws -> Double {
            var value = try unary()
            while true {
                if current == .multiply {
                    advance()
                    try tick()
                    value *= try unary()
                } else if current == .divide {
                    advance()
                    try tick()
                    let divisor = try unary()
                    guard abs(divisor) > 1e-15 else { throw MathExpressionError.divisionByZero }
                    value /= divisor
                } else {
                    return value
                }
            }
        }

        private mutating func unary() throws -> Double {
            if current == .plus {
                advance()
                return try unary()
            }
            if current == .minus {
                advance()
                try tick()
                return -(try unary())
            }
            return try power()
        }

        private mutating func power() throws -> Double {
            var value = try primary()
            if current == .power {
                advance()
                try tick()
                value = Foundation.pow(value, try unary())
            }
            return value
        }

        private mutating func primary() throws -> Double {
            switch current {
            case .number(let value):
                advance()
                return value
            case .identifier(let name):
                advance()
                switch name {
                case "x": return x
                case "pi": return .pi
                case "e": return Foundation.exp(1)
                default:
                    guard current == .leftParenthesis else {
                        throw MathExpressionError.unknownIdentifier(name)
                    }
                    advance()
                    let argument = try additive()
                    guard current == .rightParenthesis else {
                        throw MathExpressionError.unexpectedToken
                    }
                    advance()
                    try tick()
                    return try Self.apply(name, to: argument)
                }
            case .leftParenthesis:
                advance()
                let value = try additive()
                guard current == .rightParenthesis else {
                    throw MathExpressionError.unexpectedToken
                }
                advance()
                return value
            default: throw MathExpressionError.unexpectedToken
            }
        }

        private static func apply(_ name: String, to value: Double) throws -> Double {
            switch name {
            case "sin": Foundation.sin(value)
            case "cos": Foundation.cos(value)
            case "tan": Foundation.tan(value)
            case "sqrt" where value >= 0: Foundation.sqrt(value)
            case "abs": Swift.abs(value)
            case "ln" where value > 0: Foundation.log(value)
            case "log" where value > 0: Foundation.log10(value)
            case "exp": Foundation.exp(value)
            default: throw MathExpressionError.unknownIdentifier(name)
            }
        }

        private static func tokenize(_ raw: String) throws -> [Token] {
            let normalized =
                raw
                .replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: "×", with: "*")
                .replacingOccurrences(of: "÷", with: "/")
                .replacingOccurrences(of: "π", with: "pi")
                .lowercased()
            var tokens: [Token] = []
            var cursor = normalized.startIndex
            while cursor < normalized.endIndex {
                let character = normalized[cursor]
                if character.isWhitespace {
                    cursor = normalized.index(after: cursor)
                    continue
                }
                if character.isNumber || character == "." {
                    let start = cursor
                    var hasDecimal = character == "."
                    cursor = normalized.index(after: cursor)
                    while cursor < normalized.endIndex {
                        let next = normalized[cursor]
                        if next.isNumber {
                            cursor = normalized.index(after: cursor)
                            continue
                        }
                        if next == "." && !hasDecimal {
                            hasDecimal = true
                            cursor = normalized.index(after: cursor)
                            continue
                        }
                        break
                    }
                    let text = String(normalized[start..<cursor])
                    guard let value = Double(text) else {
                        throw MathExpressionError.invalidToken(text)
                    }
                    tokens.append(.number(value))
                    continue
                }
                if character.isLetter {
                    let start = cursor
                    cursor = normalized.index(after: cursor)
                    while cursor < normalized.endIndex, normalized[cursor].isLetter {
                        cursor = normalized.index(after: cursor)
                    }
                    tokens.append(.identifier(String(normalized[start..<cursor])))
                    continue
                }
                let token: Token
                switch character {
                case "+": token = .plus
                case "-": token = .minus
                case "*": token = .multiply
                case "/": token = .divide
                case "^": token = .power
                case "(": token = .leftParenthesis
                case ")": token = .rightParenthesis
                default: throw MathExpressionError.invalidToken(String(character))
                }
                tokens.append(token)
                cursor = normalized.index(after: cursor)
                if tokens.count > 256 { throw MathExpressionError.tooComplex }
            }
            tokens.append(.end)
            return tokens
        }
    }
}
