class_name FormulaEngine
extends RefCounted
## Formula parser and evaluator for spreadsheet formulas.
## Supports cell references, ranges, operators, and functions.
## Note: SpreadsheetData is passed as parameter to avoid circular dependency.

## Token types for the lexer
enum TokenType {
	NUMBER,
	STRING,
	CELL_REF,       # A1, B2, $A$1
	RANGE_REF,      # A1:B10
	FUNCTION,       # SUM, AVERAGE, etc.
	OPERATOR,       # +, -, *, /, ^, %
	LPAREN,
	RPAREN,
	COMMA,
	COLON,
	EQUALS,
	COMPARISON,     # <, >, <=, >=, <>, =
	EOF,
	ERROR,
}


## AST Node types
enum NodeType {
	NUMBER,
	STRING,
	CELL_REF,
	RANGE_REF,
	BINARY_OP,
	UNARY_OP,
	FUNCTION_CALL,
	ERROR,
}


## Token structure
class Token:
	var type: TokenType
	var value: Variant
	var position: int

	func _init(t: TokenType, v: Variant, pos: int) -> void:
		type = t
		value = v
		position = pos


## AST Node structure
class ASTNode:
	var type: NodeType
	var value: Variant
	var children: Array  # Array of ASTNode
	var error_message: String = ""

	func _init(t: NodeType, v: Variant = null) -> void:
		type = t
		value = v
		children = []


## Evaluation result
class EvalResult:
	var value: Variant
	var error: String = ""
	var is_error: bool = false

	static func ok(v: Variant) -> EvalResult:
		var result := EvalResult.new()
		result.value = v
		return result

	static func err(message: String) -> EvalResult:
		var result := EvalResult.new()
		result.error = message
		result.is_error = true
		return result


## Supported functions
const FUNCTIONS := {
	"SUM": true,
	"AVERAGE": true,
	"COUNT": true,
	"MIN": true,
	"MAX": true,
	"IF": true,
	"ABS": true,
	"ROUND": true,
	"FLOOR": true,
	"CEIL": true,
	"SQRT": true,
	"POW": true,
	"LEN": true,
	"UPPER": true,
	"LOWER": true,
	"TRIM": true,
	"CONCATENATE": true,
	"LEFT": true,
	"RIGHT": true,
	"MID": true,
	"NOW": true,
	"TODAY": true,
	"YEAR": true,
	"MONTH": true,
	"DAY": true,
}


## Operator precedence (higher = binds tighter)
const PRECEDENCE := {
	"<": 1, ">": 1, "<=": 1, ">=": 1, "<>": 1, "==": 1,
	"+": 2, "-": 2,
	"*": 3, "/": 3, "%": 3,
	"^": 4,
}


# ============================================================================
# TOKENIZER
# ============================================================================

var _formula: String = ""
var _pos: int = 0
var _tokens: Array = []
var _token_index: int = 0


## Tokenize a formula string
func tokenize(formula: String) -> Array:
	_formula = formula
	_pos = 0
	_tokens = []

	while _pos < _formula.length():
		var ch := _formula[_pos]

		# Skip whitespace
		if ch == " " or ch == "\t":
			_pos += 1
			continue

		# Number
		if ch.is_valid_int() or (ch == "." and _peek(1).is_valid_int()):
			_tokens.append(_read_number())
			continue

		# String literal
		if ch == '"':
			_tokens.append(_read_string())
			continue

		# Cell reference, range, or function
		if ch.is_valid_identifier() or ch == "$":
			_tokens.append(_read_identifier())
			continue

		# Operators and punctuation
		match ch:
			"=":
				if _peek(1) == "=":
					_tokens.append(Token.new(TokenType.COMPARISON, "==", _pos))
					_pos += 2
				else:
					_tokens.append(Token.new(TokenType.EQUALS, "=", _pos))
					_pos += 1
			"+", "-", "*", "/", "^", "%":
				_tokens.append(Token.new(TokenType.OPERATOR, ch, _pos))
				_pos += 1
			"<":
				if _peek(1) == "=":
					_tokens.append(Token.new(TokenType.COMPARISON, "<=", _pos))
					_pos += 2
				elif _peek(1) == ">":
					_tokens.append(Token.new(TokenType.COMPARISON, "<>", _pos))
					_pos += 2
				else:
					_tokens.append(Token.new(TokenType.COMPARISON, "<", _pos))
					_pos += 1
			">":
				if _peek(1) == "=":
					_tokens.append(Token.new(TokenType.COMPARISON, ">=", _pos))
					_pos += 2
				else:
					_tokens.append(Token.new(TokenType.COMPARISON, ">", _pos))
					_pos += 1
			"(":
				_tokens.append(Token.new(TokenType.LPAREN, "(", _pos))
				_pos += 1
			")":
				_tokens.append(Token.new(TokenType.RPAREN, ")", _pos))
				_pos += 1
			",":
				_tokens.append(Token.new(TokenType.COMMA, ",", _pos))
				_pos += 1
			":":
				_tokens.append(Token.new(TokenType.COLON, ":", _pos))
				_pos += 1
			_:
				_tokens.append(Token.new(TokenType.ERROR, "Unknown character: " + ch, _pos))
				_pos += 1

	_tokens.append(Token.new(TokenType.EOF, "", _pos))
	return _tokens


func _peek(offset: int = 0) -> String:
	var idx := _pos + offset
	if idx < _formula.length():
		return _formula[idx]
	return ""


func _read_number() -> Token:
	var start := _pos
	var has_dot := false

	while _pos < _formula.length():
		var ch := _formula[_pos]
		if ch.is_valid_int():
			_pos += 1
		elif ch == "." and not has_dot:
			has_dot = true
			_pos += 1
		else:
			break

	var num_str := _formula.substr(start, _pos - start)
	return Token.new(TokenType.NUMBER, float(num_str), start)


func _read_string() -> Token:
	var start := _pos
	_pos += 1  # Skip opening quote

	var result := ""
	while _pos < _formula.length():
		var ch := _formula[_pos]
		if ch == '"':
			_pos += 1
			# Check for escaped quote
			if _pos < _formula.length() and _formula[_pos] == '"':
				result += '"'
				_pos += 1
			else:
				break
		else:
			result += ch
			_pos += 1

	return Token.new(TokenType.STRING, result, start)


func _read_identifier() -> Token:
	var start := _pos
	var has_dollar := false

	# Check for $ prefix (absolute reference)
	if _formula[_pos] == "$":
		has_dollar = true
		_pos += 1

	# Read the identifier (letters, digits, underscores, and $ for absolute refs)
	var ident := ""
	while _pos < _formula.length():
		var ch := _formula[_pos]
		# Check if character can be part of identifier or cell reference
		if _is_identifier_char(ch) or ch == "$":
			ident += ch
			_pos += 1
		else:
			break

	var full_ident := ("$" if has_dollar else "") + ident

	# Check if it's a function
	if ident.to_upper() in FUNCTIONS:
		return Token.new(TokenType.FUNCTION, ident.to_upper(), start)

	# Check if it's a cell reference (e.g., A1, $A$1, AA123)
	if _is_cell_reference(full_ident):
		return Token.new(TokenType.CELL_REF, full_ident.to_upper(), start)

	# Unknown identifier - treat as error
	return Token.new(TokenType.ERROR, "Unknown identifier: " + full_ident, start)


func _is_identifier_char(ch: String) -> bool:
	# Check if a single character can be part of an identifier or cell reference
	if ch.length() != 1:
		return false
	var code := ch.unicode_at(0)
	# A-Z, a-z
	if (code >= 65 and code <= 90) or (code >= 97 and code <= 122):
		return true
	# 0-9
	if code >= 48 and code <= 57:
		return true
	# Underscore
	if code == 95:
		return true
	return false


func _is_cell_reference(text: String) -> bool:
	# Cell reference pattern: optional $, letters, optional $, digits
	# Examples: A1, $A1, A$1, $A$1, AA1, AAA123
	var regex := RegEx.new()
	regex.compile("^\\$?[A-Za-z]+\\$?[0-9]+$")
	return regex.search(text) != null


# ============================================================================
# PARSER
# ============================================================================

## Parse tokens into an AST
func parse(tokens: Array) -> ASTNode:
	_tokens = tokens
	_token_index = 0

	if _tokens.is_empty():
		return ASTNode.new(NodeType.ERROR, "Empty formula")

	# Skip leading equals sign if present
	if _current_token().type == TokenType.EQUALS:
		_advance()

	var result := _parse_expression()

	if _current_token().type != TokenType.EOF:
		var error_node := ASTNode.new(NodeType.ERROR)
		error_node.error_message = "Unexpected token: " + str(_current_token().value)
		return error_node

	return result


func _current_token() -> Token:
	if _token_index < _tokens.size():
		return _tokens[_token_index]
	return Token.new(TokenType.EOF, "", -1)


func _advance() -> Token:
	var token := _current_token()
	_token_index += 1
	return token


func _parse_expression() -> ASTNode:
	return _parse_comparison()


func _parse_comparison() -> ASTNode:
	var left := _parse_additive()

	while _current_token().type == TokenType.COMPARISON:
		var op: Variant = _advance().value
		var right := _parse_additive()
		var node := ASTNode.new(NodeType.BINARY_OP, op)
		node.children = [left, right]
		left = node

	return left


func _parse_additive() -> ASTNode:
	var left := _parse_multiplicative()

	while _current_token().type == TokenType.OPERATOR and _current_token().value in ["+", "-"]:
		var op: Variant = _advance().value
		var right := _parse_multiplicative()
		var node := ASTNode.new(NodeType.BINARY_OP, op)
		node.children = [left, right]
		left = node

	return left


func _parse_multiplicative() -> ASTNode:
	var left := _parse_power()

	while _current_token().type == TokenType.OPERATOR and _current_token().value in ["*", "/", "%"]:
		var op: Variant = _advance().value
		var right := _parse_power()
		var node := ASTNode.new(NodeType.BINARY_OP, op)
		node.children = [left, right]
		left = node

	return left


func _parse_power() -> ASTNode:
	var left := _parse_unary()

	if _current_token().type == TokenType.OPERATOR and _current_token().value == "^":
		var op: Variant = _advance().value
		var right := _parse_power()  # Right associative
		var node := ASTNode.new(NodeType.BINARY_OP, op)
		node.children = [left, right]
		return node

	return left


func _parse_unary() -> ASTNode:
	if _current_token().type == TokenType.OPERATOR and _current_token().value in ["+", "-"]:
		var op: Variant = _advance().value
		var operand := _parse_unary()
		var node := ASTNode.new(NodeType.UNARY_OP, op)
		node.children = [operand]
		return node

	return _parse_primary()


func _parse_primary() -> ASTNode:
	var token := _current_token()

	match token.type:
		TokenType.NUMBER:
			_advance()
			return ASTNode.new(NodeType.NUMBER, token.value)

		TokenType.STRING:
			_advance()
			return ASTNode.new(NodeType.STRING, token.value)

		TokenType.CELL_REF:
			_advance()
			# Check for range (A1:B10)
			if _current_token().type == TokenType.COLON:
				_advance()
				if _current_token().type == TokenType.CELL_REF:
					var end_ref: Variant = _advance().value
					return ASTNode.new(NodeType.RANGE_REF, [token.value, end_ref])
				else:
					var error_node := ASTNode.new(NodeType.ERROR)
					error_node.error_message = "Expected cell reference after ':'"
					return error_node
			return ASTNode.new(NodeType.CELL_REF, token.value)

		TokenType.FUNCTION:
			return _parse_function_call()

		TokenType.LPAREN:
			_advance()
			var expr := _parse_expression()
			if _current_token().type != TokenType.RPAREN:
				var error_node := ASTNode.new(NodeType.ERROR)
				error_node.error_message = "Expected ')'"
				return error_node
			_advance()
			return expr

		TokenType.ERROR:
			var error_node := ASTNode.new(NodeType.ERROR)
			error_node.error_message = str(token.value)
			_advance()
			return error_node

		_:
			var error_node := ASTNode.new(NodeType.ERROR)
			error_node.error_message = "Unexpected token: " + str(token.value)
			return error_node


func _parse_function_call() -> ASTNode:
	var func_name: Variant = _advance().value
	var node := ASTNode.new(NodeType.FUNCTION_CALL, func_name)

	if _current_token().type != TokenType.LPAREN:
		var error_node := ASTNode.new(NodeType.ERROR)
		error_node.error_message = "Expected '(' after function name"
		return error_node
	_advance()

	# Parse arguments
	if _current_token().type != TokenType.RPAREN:
		node.children.append(_parse_expression())

		while _current_token().type == TokenType.COMMA:
			_advance()
			node.children.append(_parse_expression())

	if _current_token().type != TokenType.RPAREN:
		var error_node := ASTNode.new(NodeType.ERROR)
		error_node.error_message = "Expected ')' after function arguments"
		return error_node
	_advance()

	return node


# ============================================================================
# EVALUATOR
# ============================================================================

## Evaluate an AST node against spreadsheet data
func evaluate(node: ASTNode, data: RefCounted, current_row: int = -1, current_col: int = -1) -> EvalResult:
	if node == null:
		return EvalResult.err("Null node")

	match node.type:
		NodeType.NUMBER:
			return EvalResult.ok(node.value)

		NodeType.STRING:
			return EvalResult.ok(node.value)

		NodeType.CELL_REF:
			return _eval_cell_ref(node.value, data, current_row, current_col)

		NodeType.RANGE_REF:
			return _eval_range_ref(node.value, data)

		NodeType.BINARY_OP:
			return _eval_binary_op(node, data, current_row, current_col)

		NodeType.UNARY_OP:
			return _eval_unary_op(node, data, current_row, current_col)

		NodeType.FUNCTION_CALL:
			return _eval_function(node, data, current_row, current_col)

		NodeType.ERROR:
			return EvalResult.err(node.error_message)

		_:
			return EvalResult.err("Unknown node type")


func _eval_cell_ref(ref: String, data: RefCounted, _current_row: int, _current_col: int) -> EvalResult:
	var parsed := parse_cell_reference(ref)
	if parsed.is_empty():
		return EvalResult.err("Invalid cell reference: " + ref)

	var row: int = parsed["row"]
	var col: int = parsed["col"]

	if row < 0 or row >= data.row_count or col < 0 or col >= data.column_count:
		return EvalResult.err("Cell out of range: " + ref)

	var cell = data.get_cell_if_exists(row, col)
	if cell == null or cell.is_empty():
		return EvalResult.ok(0)  # Empty cells are treated as 0

	# If the cell has a formula, return the computed value
	if cell.has_formula():
		return EvalResult.ok(cell.value)

	return EvalResult.ok(cell.value)


func _eval_range_ref(refs: Array, data: RefCounted) -> EvalResult:
	if refs.size() != 2:
		return EvalResult.err("Invalid range reference")

	var start := parse_cell_reference(refs[0])
	var end := parse_cell_reference(refs[1])

	if start.is_empty() or end.is_empty():
		return EvalResult.err("Invalid range reference")

	var values: Array = []
	var start_row: int = mini(start["row"], end["row"])
	var end_row: int = maxi(start["row"], end["row"])
	var start_col: int = mini(start["col"], end["col"])
	var end_col: int = maxi(start["col"], end["col"])

	for row in range(start_row, end_row + 1):
		for col in range(start_col, end_col + 1):
			var cell = data.get_cell_if_exists(row, col)
			if cell and not cell.is_empty():
				values.append(cell.value)

	return EvalResult.ok(values)


func _eval_binary_op(node: ASTNode, data: RefCounted, current_row: int, current_col: int) -> EvalResult:
	var left_result := evaluate(node.children[0], data, current_row, current_col)
	if left_result.is_error:
		return left_result

	var right_result := evaluate(node.children[1], data, current_row, current_col)
	if right_result.is_error:
		return right_result

	var left = left_result.value
	var right = right_result.value

	# Convert to numbers for arithmetic
	var left_num := _to_number(left)
	var right_num := _to_number(right)

	match node.value:
		"+":
			# String concatenation if either operand is a string
			if left is String or right is String:
				return EvalResult.ok(str(left) + str(right))
			return EvalResult.ok(left_num + right_num)
		"-":
			return EvalResult.ok(left_num - right_num)
		"*":
			return EvalResult.ok(left_num * right_num)
		"/":
			if right_num == 0:
				return EvalResult.err("#DIV/0!")
			return EvalResult.ok(left_num / right_num)
		"%":
			if right_num == 0:
				return EvalResult.err("#DIV/0!")
			return EvalResult.ok(fmod(left_num, right_num))
		"^":
			return EvalResult.ok(pow(left_num, right_num))
		"<":
			return EvalResult.ok(left_num < right_num)
		">":
			return EvalResult.ok(left_num > right_num)
		"<=":
			return EvalResult.ok(left_num <= right_num)
		">=":
			return EvalResult.ok(left_num >= right_num)
		"<>":
			return EvalResult.ok(left != right)
		"==":
			return EvalResult.ok(left == right)
		_:
			return EvalResult.err("Unknown operator: " + str(node.value))


func _eval_unary_op(node: ASTNode, data: RefCounted, current_row: int, current_col: int) -> EvalResult:
	var operand_result := evaluate(node.children[0], data, current_row, current_col)
	if operand_result.is_error:
		return operand_result

	var operand := _to_number(operand_result.value)

	match node.value:
		"+":
			return EvalResult.ok(operand)
		"-":
			return EvalResult.ok(-operand)
		_:
			return EvalResult.err("Unknown unary operator: " + str(node.value))


func _eval_function(node: ASTNode, data: RefCounted, current_row: int, current_col: int) -> EvalResult:
	var func_name: String = node.value
	var args: Array = []

	# Evaluate arguments
	for child in node.children:
		var result := evaluate(child, data, current_row, current_col)
		if result.is_error:
			return result
		args.append(result.value)

	# Call the appropriate function
	match func_name:
		"SUM":
			return _func_sum(args)
		"AVERAGE":
			return _func_average(args)
		"COUNT":
			return _func_count(args)
		"MIN":
			return _func_min(args)
		"MAX":
			return _func_max(args)
		"IF":
			return _func_if(args, node.children, data, current_row, current_col)
		"ABS":
			return _func_abs(args)
		"ROUND":
			return _func_round(args)
		"FLOOR":
			return _func_floor(args)
		"CEIL":
			return _func_ceil(args)
		"SQRT":
			return _func_sqrt(args)
		"POW":
			return _func_pow(args)
		"LEN":
			return _func_len(args)
		"UPPER":
			return _func_upper(args)
		"LOWER":
			return _func_lower(args)
		"TRIM":
			return _func_trim(args)
		"CONCATENATE":
			return _func_concatenate(args)
		"LEFT":
			return _func_left(args)
		"RIGHT":
			return _func_right(args)
		"MID":
			return _func_mid(args)
		"NOW":
			return _func_now()
		"TODAY":
			return _func_today()
		"YEAR":
			return _func_year(args)
		"MONTH":
			return _func_month(args)
		"DAY":
			return _func_day(args)
		_:
			return EvalResult.err("Unknown function: " + func_name)


# ============================================================================
# FUNCTION IMPLEMENTATIONS
# ============================================================================

func _flatten_args(args: Array) -> Array:
	var result: Array = []
	for arg in args:
		if arg is Array:
			result.append_array(_flatten_args(arg))
		else:
			result.append(arg)
	return result


func _func_sum(args: Array) -> EvalResult:
	var flat := _flatten_args(args)
	var total := 0.0
	for val in flat:
		total += _to_number(val)
	return EvalResult.ok(total)


func _func_average(args: Array) -> EvalResult:
	var flat := _flatten_args(args)
	if flat.is_empty():
		return EvalResult.err("#DIV/0!")
	var total := 0.0
	var count := 0
	for val in flat:
		if _is_numeric(val):
			total += _to_number(val)
			count += 1
	if count == 0:
		return EvalResult.err("#DIV/0!")
	return EvalResult.ok(total / count)


func _func_count(args: Array) -> EvalResult:
	var flat := _flatten_args(args)
	var count := 0
	for val in flat:
		if _is_numeric(val):
			count += 1
	return EvalResult.ok(count)


func _func_min(args: Array) -> EvalResult:
	var flat := _flatten_args(args)
	if flat.is_empty():
		return EvalResult.ok(0)
	var result: float = INF
	for val in flat:
		if _is_numeric(val):
			result = minf(result, _to_number(val))
	if result == INF:
		return EvalResult.ok(0)
	return EvalResult.ok(result)


func _func_max(args: Array) -> EvalResult:
	var flat := _flatten_args(args)
	if flat.is_empty():
		return EvalResult.ok(0)
	var result: float = -INF
	for val in flat:
		if _is_numeric(val):
			result = maxf(result, _to_number(val))
	if result == -INF:
		return EvalResult.ok(0)
	return EvalResult.ok(result)


func _func_if(args: Array, children: Array, data: RefCounted, current_row: int, current_col: int) -> EvalResult:
	if args.size() < 2:
		return EvalResult.err("IF requires at least 2 arguments")

	var condition = args[0]
	var is_true: bool

	if condition is bool:
		is_true = condition
	else:
		is_true = _to_number(condition) != 0

	if is_true:
		# Return second argument (true value)
		if children.size() > 1:
			return evaluate(children[1], data, current_row, current_col)
		return EvalResult.ok(0)
	else:
		# Return third argument (false value) or 0 if not provided
		if children.size() > 2:
			return evaluate(children[2], data, current_row, current_col)
		return EvalResult.ok(0)


func _func_abs(args: Array) -> EvalResult:
	if args.is_empty():
		return EvalResult.err("ABS requires 1 argument")
	return EvalResult.ok(absf(_to_number(args[0])))


func _func_round(args: Array) -> EvalResult:
	if args.is_empty():
		return EvalResult.err("ROUND requires at least 1 argument")
	var num := _to_number(args[0])
	var decimals := 0 if args.size() < 2 else int(_to_number(args[1]))
	var multiplier := pow(10, decimals)
	return EvalResult.ok(roundf(num * multiplier) / multiplier)


func _func_floor(args: Array) -> EvalResult:
	if args.is_empty():
		return EvalResult.err("FLOOR requires 1 argument")
	return EvalResult.ok(floorf(_to_number(args[0])))


func _func_ceil(args: Array) -> EvalResult:
	if args.is_empty():
		return EvalResult.err("CEIL requires 1 argument")
	return EvalResult.ok(ceilf(_to_number(args[0])))


func _func_sqrt(args: Array) -> EvalResult:
	if args.is_empty():
		return EvalResult.err("SQRT requires 1 argument")
	var num := _to_number(args[0])
	if num < 0:
		return EvalResult.err("#NUM!")
	return EvalResult.ok(sqrt(num))


func _func_pow(args: Array) -> EvalResult:
	if args.size() < 2:
		return EvalResult.err("POW requires 2 arguments")
	return EvalResult.ok(pow(_to_number(args[0]), _to_number(args[1])))


func _func_len(args: Array) -> EvalResult:
	if args.is_empty():
		return EvalResult.err("LEN requires 1 argument")
	return EvalResult.ok(str(args[0]).length())


func _func_upper(args: Array) -> EvalResult:
	if args.is_empty():
		return EvalResult.err("UPPER requires 1 argument")
	return EvalResult.ok(str(args[0]).to_upper())


func _func_lower(args: Array) -> EvalResult:
	if args.is_empty():
		return EvalResult.err("LOWER requires 1 argument")
	return EvalResult.ok(str(args[0]).to_lower())


func _func_trim(args: Array) -> EvalResult:
	if args.is_empty():
		return EvalResult.err("TRIM requires 1 argument")
	return EvalResult.ok(str(args[0]).strip_edges())


func _func_concatenate(args: Array) -> EvalResult:
	var result := ""
	for arg in args:
		result += str(arg)
	return EvalResult.ok(result)


func _func_left(args: Array) -> EvalResult:
	if args.is_empty():
		return EvalResult.err("LEFT requires at least 1 argument")
	var text := str(args[0])
	var count := 1 if args.size() < 2 else int(_to_number(args[1]))
	return EvalResult.ok(text.left(count))


func _func_right(args: Array) -> EvalResult:
	if args.is_empty():
		return EvalResult.err("RIGHT requires at least 1 argument")
	var text := str(args[0])
	var count := 1 if args.size() < 2 else int(_to_number(args[1]))
	return EvalResult.ok(text.right(count))


func _func_mid(args: Array) -> EvalResult:
	if args.size() < 3:
		return EvalResult.err("MID requires 3 arguments")
	var text := str(args[0])
	var start := int(_to_number(args[1])) - 1  # 1-based index
	var count := int(_to_number(args[2]))
	if start < 0:
		start = 0
	return EvalResult.ok(text.substr(start, count))


func _func_now() -> EvalResult:
	var datetime := Time.get_datetime_dict_from_system()
	return EvalResult.ok("%04d-%02d-%02d %02d:%02d:%02d" % [
		datetime["year"], datetime["month"], datetime["day"],
		datetime["hour"], datetime["minute"], datetime["second"]
	])


func _func_today() -> EvalResult:
	var date := Time.get_date_dict_from_system()
	return EvalResult.ok("%04d-%02d-%02d" % [date["year"], date["month"], date["day"]])


func _func_year(args: Array) -> EvalResult:
	if args.is_empty():
		return EvalResult.err("YEAR requires 1 argument")
	var date_str := str(args[0])
	var parts := date_str.split("-")
	if parts.size() >= 1:
		return EvalResult.ok(int(parts[0]))
	return EvalResult.err("#VALUE!")


func _func_month(args: Array) -> EvalResult:
	if args.is_empty():
		return EvalResult.err("MONTH requires 1 argument")
	var date_str := str(args[0])
	var parts := date_str.split("-")
	if parts.size() >= 2:
		return EvalResult.ok(int(parts[1]))
	return EvalResult.err("#VALUE!")


func _func_day(args: Array) -> EvalResult:
	if args.is_empty():
		return EvalResult.err("DAY requires 1 argument")
	var date_str := str(args[0])
	var parts := date_str.split("-")
	if parts.size() >= 3:
		# Handle date with time
		var day_part := parts[2].split(" ")[0]
		return EvalResult.ok(int(day_part))
	return EvalResult.err("#VALUE!")


# ============================================================================
# UTILITIES
# ============================================================================

func _to_number(value: Variant) -> float:
	if value is float or value is int:
		return float(value)
	if value is bool:
		return 1.0 if value else 0.0
	if value is String:
		if value.is_valid_float():
			return float(value)
		if value.is_valid_int():
			return float(value)
	return 0.0


func _is_numeric(value: Variant) -> bool:
	if value is float or value is int:
		return true
	if value is String:
		return value.is_valid_float() or value.is_valid_int()
	return false


## Parse a cell reference string (e.g., "A1", "$A$1") into row and column indices
static func parse_cell_reference(ref: String) -> Dictionary:
	var regex := RegEx.new()
	regex.compile("^(\\$?)([A-Za-z]+)(\\$?)([0-9]+)$")

	var match_result := regex.search(ref)
	if match_result == null:
		return {}

	var col_abs := match_result.get_string(1) == "$"
	var col_str := match_result.get_string(2).to_upper()
	var row_abs := match_result.get_string(3) == "$"
	var row_num := int(match_result.get_string(4))

	# Convert column letters to index (A=0, B=1, ..., Z=25, AA=26, etc.)
	var col := 0
	for i in range(col_str.length()):
		col = col * 26 + (col_str.unicode_at(i) - 65 + 1)
	col -= 1  # 0-based index

	var row := row_num - 1  # 0-based index

	return {
		"row": row,
		"col": col,
		"row_abs": row_abs,
		"col_abs": col_abs,
	}


## Get cell references from a formula (for dependency tracking)
func get_references(formula: String) -> Array:
	var refs: Array = []
	var tokens := tokenize(formula)

	for token in tokens:
		if token.type == TokenType.CELL_REF:
			var parsed := parse_cell_reference(token.value)
			if not parsed.is_empty():
				refs.append(Vector2i(parsed["col"], parsed["row"]))

	return refs


## Get all cell references including those in ranges
func get_all_references(formula: String) -> Array:
	var refs: Array = []
	var tokens := tokenize(formula)

	var i := 0
	while i < tokens.size():
		var token = tokens[i]
		if token.type == TokenType.CELL_REF:
			# Check if it's a range
			if i + 2 < tokens.size() and tokens[i + 1].type == TokenType.COLON and tokens[i + 2].type == TokenType.CELL_REF:
				var start := parse_cell_reference(token.value)
				var end := parse_cell_reference(tokens[i + 2].value)
				if not start.is_empty() and not end.is_empty():
					var start_row: int = mini(start["row"], end["row"])
					var end_row: int = maxi(start["row"], end["row"])
					var start_col: int = mini(start["col"], end["col"])
					var end_col: int = maxi(start["col"], end["col"])
					for row in range(start_row, end_row + 1):
						for col in range(start_col, end_col + 1):
							refs.append(Vector2i(col, row))
				i += 3
				continue
			else:
				var parsed := parse_cell_reference(token.value)
				if not parsed.is_empty():
					refs.append(Vector2i(parsed["col"], parsed["row"]))
		i += 1

	return refs


# ============================================================================
# HIGH-LEVEL API
# ============================================================================

## Parse and evaluate a formula, returning the result
func evaluate_formula(formula: String, data: RefCounted, current_row: int = -1, current_col: int = -1) -> EvalResult:
	if formula.is_empty():
		return EvalResult.ok("")

	# Skip the leading = if present
	var formula_text := formula
	if formula_text.begins_with("="):
		formula_text = formula_text.substr(1)

	var tokens := tokenize(formula_text)

	# Check for tokenizer errors
	for token in tokens:
		if token.type == TokenType.ERROR:
			return EvalResult.err(str(token.value))

	var ast := parse(tokens)

	if ast.type == NodeType.ERROR:
		return EvalResult.err(ast.error_message)

	return evaluate(ast, data, current_row, current_col)
