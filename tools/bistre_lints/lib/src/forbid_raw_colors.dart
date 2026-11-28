import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

/// Mechanically enforces design.md Section 2 / ADR-0011:
/// All UI colors must derive from WCAG-verified `BistreThemeData` tokens in `bistre_theme.dart`.
class ForbidRawColorsRule extends AnalysisRule {
  static const LintCode code = LintCode(
    'bistre_forbid_raw_colors',
    'Raw Color literal is forbidden outside bistre_theme.dart.',
    correctionMessage: 'Use semantic Sepia Book tokens from BistreTheme.of(context) (design.md).',
    severity: DiagnosticSeverity.ERROR,
  );

  ForbidRawColorsRule()
    : super(
        name: 'bistre_forbid_raw_colors',
        description: 'Forbids raw Color(...) construction outside lib/design/bistre_theme.dart.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final visitor = _RawColorVisitor(this, context);
    registry.addInstanceCreationExpression(this, visitor);
    registry.addMethodInvocation(this, visitor);
  }

  /// Pure helper exposed for unit tests.
  static bool isRawColorCall(String typeName) => typeName == 'Color';
}

class _RawColorVisitor extends SimpleAstVisitor<void> {
  _RawColorVisitor(this.rule, this.context);

  final AnalysisRule rule;
  final RuleContext context;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (!_shouldCheck()) return;
    if (ForbidRawColorsRule.isRawColorCall(
      node.constructorName.type.name.lexeme,
    )) {
      rule.reportAtNode(node);
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (!_shouldCheck()) return;
    final target = node.target;
    if (target == null &&
        ForbidRawColorsRule.isRawColorCall(node.methodName.name)) {
      rule.reportAtNode(node);
      return;
    }
    if (target is SimpleIdentifier &&
        ForbidRawColorsRule.isRawColorCall(target.name)) {
      rule.reportAtNode(node);
    }
  }

  bool _shouldCheck() {
    if (!context.isInLibDir) return false;
    final path = context.definingUnit.file.path.replaceAll('\\', '/');
    if (!path.contains('/apps/bistre_app/lib/')) return false;
    if (path.endsWith('/lib/design/bistre_theme.dart')) return false;
    if (path.endsWith('.g.dart')) return false;
    return true;
  }
}
