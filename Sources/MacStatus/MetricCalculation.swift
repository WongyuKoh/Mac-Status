import Foundation

/// A bounded arithmetic language. Expressions never reach a scripting engine,
/// Foundation expression evaluator, shell, or other executable runtime.
enum MetricCalculation {
    static let maximumExpressionBytes = 512
    static let maximumTokens = 256
    static let maximumDepth = 32

    enum Failure: Error, LocalizedError, Equatable {
        case invalidExpression, divisionByZero, nonFinite, tooComplex

        var errorDescription: String? {
            switch self {
            case .invalidExpression:
                return "계산식은 value와 숫자, + - * /, 괄호로 입력해 주세요."
            case .divisionByZero:
                return "0으로 나눌 수 없어 계산 결과를 표시할 수 없습니다."
            case .nonFinite:
                return "계산 결과가 너무 크거나 유효한 숫자가 아닙니다."
            case .tooComplex:
                return "계산식이 너무 깁니다. 식을 짧고 간단하게 줄여 주세요."
            }
        }
    }

    /// Parse only. A syntactically valid expression such as value / 0 remains
    /// valid here; runtime arithmetic failures depend on the incoming value.
    static func validate(_ expression: String) throws {
        _ = try parse(expression)
    }

    static func evaluate(_ expression: String, value: Double) throws -> Double {
        guard value.isFinite else { throw Failure.nonFinite }
        return try evaluate(parse(expression), value: value)
    }

    private static func parse(_ expression: String) throws -> Node {
        guard expression.utf8.count <= maximumExpressionBytes else { throw Failure.tooComplex }
        var lexer = Lexer(bytes: Array(expression.utf8))
        var parser = Parser(tokens: try lexer.tokenize())
        return try parser.parse()
    }

    private static func evaluate(_ node: Node, value: Double) throws -> Double {
        let result: Double
        switch node {
        case .number(let number): result = number
        case .variable: result = value
        case .unary(let negative, let operand):
            let number = try evaluate(operand, value: value)
            result = negative ? -number : number
        case .binary(let operation, let left, let right):
            let lhs = try evaluate(left, value: value)
            let rhs = try evaluate(right, value: value)
            switch operation {
            case .add: result = lhs + rhs
            case .subtract: result = lhs - rhs
            case .multiply: result = lhs * rhs
            case .divide:
                guard rhs != 0 else { throw Failure.divisionByZero }
                result = lhs / rhs
            }
        }
        guard result.isFinite else { throw Failure.nonFinite }
        return result
    }

    private enum Operation { case add, subtract, multiply, divide }

    private indirect enum Node {
        case number(Double), variable
        case unary(negative: Bool, Node)
        case binary(Operation, Node, Node)

        var depth: Int {
            switch self {
            case .number, .variable: return 1
            case .unary(_, let child): return child.depth + 1
            case .binary(_, let left, let right): return max(left.depth, right.depth) + 1
            }
        }
    }

    private enum Token: Equatable {
        case number(Double), variable, plus, minus, multiply, divide, leftParenthesis, rightParenthesis, end
    }

    private struct Lexer {
        let bytes: [UInt8]
        var index = 0

        mutating func tokenize() throws -> [Token] {
            var tokens: [Token] = []
            while index < bytes.count {
                let byte = bytes[index]
                if [9, 10, 13, 32].contains(byte) { index += 1; continue }
                let token: Token
                switch byte {
                case 43: token = .plus; index += 1
                case 45: token = .minus; index += 1
                case 42: token = .multiply; index += 1
                case 47: token = .divide; index += 1
                case 40: token = .leftParenthesis; index += 1
                case 41: token = .rightParenthesis; index += 1
                case 46, 48...57: token = try number()
                case 118:
                    let end = index + 5
                    guard end <= bytes.count, Array(bytes[index..<end]) == Array("value".utf8) else { throw Failure.invalidExpression }
                    token = .variable; index = end
                default: throw Failure.invalidExpression
                }
                guard tokens.count < maximumTokens else { throw Failure.tooComplex }
                tokens.append(token)
            }
            tokens.append(.end)
            return tokens
        }

        private mutating func number() throws -> Token {
            let start = index
            var digitCount = consumeDigits()
            if index < bytes.count, bytes[index] == 46 {
                index += 1
                digitCount += consumeDigits()
            }
            guard digitCount > 0 else { throw Failure.invalidExpression }
            if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
                index += 1
                if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
                guard consumeDigits() > 0 else { throw Failure.invalidExpression }
            }
            guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else { throw Failure.invalidExpression }
            guard value.isFinite else { throw Failure.nonFinite }
            return .number(value)
        }

        @discardableResult
        private mutating func consumeDigits() -> Int {
            let start = index
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            return index - start
        }
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0

        mutating func parse() throws -> Node {
            if current == .end { return .variable }
            let node = try expression(depth: 1)
            guard current == .end else { throw Failure.invalidExpression }
            return node
        }

        private var current: Token { tokens[index] }

        private mutating func expression(depth: Int) throws -> Node {
            var node = try term(depth: depth)
            while current == .plus || current == .minus {
                let operation: Operation = current == .plus ? .add : .subtract
                index += 1
                let right = try term(depth: depth)
                node = try bounded(.binary(operation, node, right))
            }
            return node
        }

        private mutating func term(depth: Int) throws -> Node {
            var node = try unary(depth: depth)
            while current == .multiply || current == .divide {
                let operation: Operation = current == .multiply ? .multiply : .divide
                index += 1
                let right = try unary(depth: depth)
                node = try bounded(.binary(operation, node, right))
            }
            return node
        }

        private mutating func unary(depth: Int) throws -> Node {
            guard depth <= maximumDepth else { throw Failure.tooComplex }
            if current == .plus || current == .minus {
                let negative = current == .minus
                index += 1
                let operand = try unary(depth: depth + 1)
                return try bounded(.unary(negative: negative, operand))
            }
            switch current {
            case .number(let value): index += 1; return .number(value)
            case .variable: index += 1; return .variable
            case .leftParenthesis:
                index += 1
                let node = try expression(depth: depth + 1)
                guard current == .rightParenthesis else { throw Failure.invalidExpression }
                index += 1
                return node
            default: throw Failure.invalidExpression
            }
        }

        private func bounded(_ node: Node) throws -> Node {
            guard node.depth <= maximumDepth else { throw Failure.tooComplex }
            return node
        }
    }
}
