import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

/// Mechanically enforces DESIGN.md Section 6: animate `transform` and `opacity`; the only height
/// animation is a disclosure, and it goes through `DisclosureReveal` (`lib/design/disclosure_reveal.dart`).
class ForbidLayoutAnimationsRule extends AnalysisRule {
  static const LintCode code = LintCode(
    'bistre_forbid_layout_animations',
    'Implicit layout-mutating animation widget is forbidden in Bistre.',
    correctionMessage: 'Animate transform/opacity honoring BistreMotion, or use DisclosureReveal for a disclosure height.',
    severity: DiagnosticSeverity.ERROR,
  );

  static const Set<String> forbiddenWidgets = <String>{
    'AnimatedContainer',
    'AnimatedPadding',
    'AnimatedSize',
    'AnimatedPositioned',
    'AnimatedPositionedDirectional',
    'AnimatedAlign',
    'AnimatedPhysicalModel',
    // Size and layout tweens in other clothes.
    'SizeTransition',
    'AnimatedCrossFade',
    'AnimatedDefaultTextStyle',
    'AnimatedFractionallySizedBox',
  };

  ForbidLayoutAnimationsRule()
    : super(
        name: 'bistre_forbid_layout_animations',
        description: 'Forbids layout-mutating implicit animation widgets in apps/bistre_app/lib.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final visitor = _LayoutAnimationVisitor(this, context);
    registry.addInstanceCreationExpression(this, visitor);
    registry.addMethodInvocation(this, visitor);
  }

  /// Pure helper exposed for unit tests.
  static bool isForbiddenWidget(String name) => forbiddenWidgets.contains(name);
}

class _LayoutAnimationVisitor extends SimpleAstVisitor<void> {
  _LayoutAnimationVisitor(this.rule, this.context);

  final AnalysisRule rule;
  final RuleContext context;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (!_shouldCheck()) return;
    final name = node.constructorName.type.name.lexeme;
    if (ForbidLayoutAnimationsRule.isForbiddenWidget(name)) {
      rule.reportAtNode(node);
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (!_shouldCheck()) return;
    if (node.target != null) return;
    if (ForbidLayoutAnimationsRule.isForbiddenWidget(node.methodName.name)) {
      rule.reportAtNode(node);
    }
  }

  bool _shouldCheck() {
    if (!context.isInLibDir) return false;
    final path = context.definingUnit.file.path.replaceAll('\\', '/');
    return path.contains('/apps/bistre_app/lib/') && !path.endsWith('.g.dart');
  }
}
