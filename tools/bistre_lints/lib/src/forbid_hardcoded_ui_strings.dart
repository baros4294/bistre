import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

/// Mechanically enforces Spec 09 / ADR-0007: zero hardcoded UI strings in Bistre widgets.
/// Recursively inspects conditional (`?:`) and binary (`+`, `??`) expressions so ternary or
/// concatenation tricks cannot bypass localization enforcement.
class ForbidHardcodedUiStringsRule extends AnalysisRule {
  static const LintCode code = LintCode(
    'bistre_forbid_hardcoded_ui_strings',
    'Hardcoded user-facing string literal detected in UI widget.',
    correctionMessage:
        'Resolve UI strings via BistreLocalizations (l10n.t(L10nKey...)).',
    severity: DiagnosticSeverity.ERROR,
  );

  static const Set<String> positionalTextTargets = <String>{'Text', 'InkText'};

  static const Map<String, Set<String>> namedStringArgs = <String, Set<String>>{
    'TextSpan': <String>{'text'},
    'Semantics': <String>{
      'label',
      'hint',
      'value',
      'tooltip',
      'increasedValue',
      'decreasedValue',
    },
    'RawTooltip': <String>{'message'},
    'Tooltip': <String>{'message'},
    'WidgetsApp': <String>{'title'},
    'EngravedButton': <String>{'label'},
    'WaxSealBadge': <String>{'label'},
    'InkChip': <String>{'label', 'semanticsLabel'},
    'QuillInput': <String>{'placeholder'},
    'EngravedIcon': <String>{'semanticsLabel'},
  };

  ForbidHardcodedUiStringsRule()
    : super(
        name: 'bistre_forbid_hardcoded_ui_strings',
        description: 'Forbids raw StringLiteral arguments in user-facing UI widget constructors.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final visitor = _HardcodedStringVisitor(this, context);
    registry.addInstanceCreationExpression(this, visitor);
    registry.addMethodInvocation(this, visitor);
  }

  /// Inspects an AST argument list for forbidden raw string literals (used by both plugin and unit tests).
  static List<AstNode> findViolations(
    String constructorName,
    ArgumentList args,
  ) {
    final violations = <AstNode>[];
    if (positionalTextTargets.contains(constructorName)) {
      if (args.arguments.isNotEmpty) {
        final first = args.arguments.first;
        if (first is Expression) {
          _collectStringViolations(first, violations);
        }
      }
    }

    final forbiddenNamed = namedStringArgs[constructorName];
    if (forbiddenNamed != null) {
      for (final arg in args.arguments) {
        if (arg is NamedArgument && forbiddenNamed.contains(arg.name.lexeme)) {
          _collectStringViolations(arg.argumentExpression, violations);
        }
      }
    }
    return violations;
  }

  static void _collectStringViolations(
    Expression expr,
    List<AstNode> violations,
  ) {
    if (expr is StringLiteral) {
      if (!_isExemptLiteral(expr)) {
        violations.add(expr);
      }
      return;
    }
    if (expr is ParenthesizedExpression) {
      _collectStringViolations(expr.expression, violations);
      return;
    }
    if (expr is ConditionalExpression) {
      _collectStringViolations(expr.thenExpression, violations);
      _collectStringViolations(expr.elseExpression, violations);
      return;
    }
    if (expr is BinaryExpression) {
      final op = expr.operator.type;
      if (op == TokenType.PLUS || op == TokenType.QUESTION_QUESTION) {
        _collectStringViolations(expr.leftOperand, violations);
        _collectStringViolations(expr.rightOperand, violations);
      }
    }
  }

  static bool _isExemptLiteral(StringLiteral literal) {
    final val = literal.stringValue;
    if (val == null) return false;
    final trimmed = val.trim();
    // Allow empty/punctuation/whitespace-only separators (e.g. '', ' · ').
    return trimmed.isEmpty ||
        RegExp(r'^[\s·•—–\-:/|()\[\]]+$').hasMatch(trimmed);
  }
}

class _HardcodedStringVisitor extends SimpleAstVisitor<void> {
  _HardcodedStringVisitor(this.rule, this.context);

  final AnalysisRule rule;
  final RuleContext context;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (!_shouldCheck()) return;
    final name = node.constructorName.type.name.lexeme;
    for (final v in ForbidHardcodedUiStringsRule.findViolations(
      name,
      node.argumentList,
    )) {
      rule.reportAtNode(v);
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (!_shouldCheck()) return;
    if (node.target != null) return;
    final name = node.methodName.name;
    for (final v in ForbidHardcodedUiStringsRule.findViolations(
      name,
      node.argumentList,
    )) {
      rule.reportAtNode(v);
    }
  }

  bool _shouldCheck() {
    if (!context.isInLibDir) return false;
    final path = context.definingUnit.file.path.replaceAll('\\', '/');
    if (!path.contains('/apps/bistre_app/lib/')) return false;
    if (path.endsWith('.g.dart')) return false;
    return true;
  }
}
