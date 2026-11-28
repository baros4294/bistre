import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

/// Mechanically enforces design.md Section 7 / AGENTS.md Section 4:
/// All directional padding and alignment must use RTL-safe `EdgeInsetsDirectional` and `AlignmentDirectional`.
class ForbidNonDirectionalGeometryRule extends AnalysisRule {
  static const LintCode code = LintCode(
    'bistre_forbid_non_directional_geometry',
    'Non-directional EdgeInsets/Alignment breaks RTL locales (Arabic).',
    correctionMessage: 'Use EdgeInsetsDirectional (start/end) and AlignmentDirectional instead of left/right.',
    severity: DiagnosticSeverity.ERROR,
  );

  static const Set<String> forbiddenAlignmentConstants = <String>{
    'topLeft',
    'topRight',
    'centerLeft',
    'centerRight',
    'bottomLeft',
    'bottomRight',
  };

  ForbidNonDirectionalGeometryRule()
    : super(
        name: 'bistre_forbid_non_directional_geometry',
        description: 'Forbids physical left/right EdgeInsets and Alignment constants in apps/bistre_app/lib.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final visitor = _DirectionalGeometryVisitor(this, context);
    registry.addInstanceCreationExpression(this, visitor);
    registry.addMethodInvocation(this, visitor);
    registry.addPrefixedIdentifier(this, visitor);
    registry.addPropertyAccess(this, visitor);
  }

  /// Pure helper for checking `EdgeInsets` calls in both plugin and unit tests.
  static bool isForbiddenEdgeInsetsCall(
    String typeName,
    String? constructorName,
    ArgumentList args,
  ) {
    // `Positioned(left:/right:)` pins physical sides; use `PositionedDirectional`.
    if (typeName == 'Positioned' && constructorName == null) {
      return args.arguments.any(
        (arg) =>
            arg is NamedArgument &&
            (arg.name.lexeme == 'left' || arg.name.lexeme == 'right'),
      );
    }
    if (typeName != 'EdgeInsets') return false;
    if (constructorName == 'fromLTRB') return true;
    if (constructorName == 'only') {
      for (final arg in args.arguments) {
        if (arg is NamedArgument &&
            (arg.name.lexeme == 'left' || arg.name.lexeme == 'right')) {
          return true;
        }
      }
    }
    return false;
  }

  /// Pure helper for checking `Alignment.<constant>` in both plugin and unit tests.
  static bool isForbiddenAlignmentMember(String targetName, String memberName) {
    if (targetName == 'TextAlign') {
      // `start`/`end` follow the text direction; `left`/`right` do not.
      return memberName == 'left' || memberName == 'right';
    }
    return targetName == 'Alignment' &&
        forbiddenAlignmentConstants.contains(memberName);
  }
}

class _DirectionalGeometryVisitor extends SimpleAstVisitor<void> {
  _DirectionalGeometryVisitor(this.rule, this.context);

  final AnalysisRule rule;
  final RuleContext context;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (!_shouldCheck()) return;
    final typeName = node.constructorName.type.name.lexeme;
    final ctorName = node.constructorName.name?.name;
    if (ForbidNonDirectionalGeometryRule.isForbiddenEdgeInsetsCall(
      typeName,
      ctorName,
      node.argumentList,
    )) {
      rule.reportAtNode(node);
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (!_shouldCheck()) return;
    final target = node.target;
    // `Positioned(left: …)` parses as a method call when the type is not resolved yet.
    final forbidden = target == null
        ? ForbidNonDirectionalGeometryRule.isForbiddenEdgeInsetsCall(
            node.methodName.name,
            null,
            node.argumentList,
          )
        : target is SimpleIdentifier &&
              ForbidNonDirectionalGeometryRule.isForbiddenEdgeInsetsCall(
                target.name,
                node.methodName.name,
                node.argumentList,
              );
    if (forbidden) {
      rule.reportAtNode(node);
    }
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (!_shouldCheck()) return;
    if (ForbidNonDirectionalGeometryRule.isForbiddenAlignmentMember(
      node.prefix.name,
      node.identifier.name,
    )) {
      rule.reportAtNode(node);
    }
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (!_shouldCheck()) return;
    final target = node.target;
    if (target is SimpleIdentifier &&
        ForbidNonDirectionalGeometryRule.isForbiddenAlignmentMember(
          target.name,
          node.propertyName.name,
        )) {
      rule.reportAtNode(node);
    }
  }

  bool _shouldCheck() {
    if (!context.isInLibDir) return false;
    final path = context.definingUnit.file.path.replaceAll('\\', '/');
    return path.contains('/apps/bistre_app/lib/') && !path.endsWith('.g.dart');
  }
}
