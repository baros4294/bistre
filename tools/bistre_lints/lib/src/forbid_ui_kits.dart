import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

/// Mechanically enforces ADR-0001 and AGENTS.md Section 3:
/// - Zero Material/Cupertino UI libraries or `flutter_localizations` / `google_fonts`
/// - Zero third-party state management frameworks (built-in ChangeNotifier/ValueNotifier only)
/// - Zero direct HTTP/SQL packages in the thin Flutter presentation shell
class ForbidUiKitsRule extends AnalysisRule {
  static const LintCode code = LintCode(
    'bistre_forbid_ui_kits',
    'Importing Material, Cupertino, third-party state/UI kits, or HTTP/SQL libraries is forbidden in Bistre.',
    correctionMessage: 'Import package:flutter/widgets.dart, compose from Bistre Ink Primitives, and delegate HTTP/SQL to Rust via BistreEngineGateway.',
    severity: DiagnosticSeverity.ERROR,
  );

  static const List<String> forbiddenPrefixes = <String>[
    // Material / Cupertino UI kits & runtime font fetchers
    'package:flutter/material',
    'package:flutter/src/material',
    'package:flutter/cupertino',
    'package:flutter/src/cupertino',
    'package:material_ui',
    'package:cupertino_ui',
    'package:flutter_localizations',
    'package:google_fonts',
    // Third-party state management (ADR-0001: built-in ChangeNotifier/InheritedNotifier only)
    'package:provider',
    'package:riverpod',
    'package:flutter_riverpod',
    'package:bloc',
    'package:flutter_bloc',
    'package:get',
    'package:mobx',
    // Direct HTTP/SQL clients (AGENTS.md: zero HTTP/SQL in apps/bistre_app)
    'package:http',
    'package:dio',
    'package:sqflite',
    'package:sqlite3',
    'package:drift',
  ];

  ForbidUiKitsRule()
    : super(
        name: 'bistre_forbid_ui_kits',
        description: 'Forbids importing Material/Cupertino UI kits, third-party state frameworks, or HTTP/SQL libraries in apps/bistre_app.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final visitor = _UiKitVisitor(this, context);
    registry.addImportDirective(this, visitor);
    registry.addExportDirective(this, visitor);
  }

  /// Pure AST helper exposed for deterministic unit tests.
  static bool isForbiddenUri(String? uri) {
    if (uri == null) return false;
    for (final prefix in forbiddenPrefixes) {
      if (uri == prefix ||
          uri.startsWith('$prefix/') ||
          uri.startsWith('$prefix.')) {
        return true;
      }
    }
    return false;
  }
}

class _UiKitVisitor extends SimpleAstVisitor<void> {
  _UiKitVisitor(this.rule, this.context);

  final AnalysisRule rule;
  final RuleContext context;

  @override
  void visitImportDirective(ImportDirective node) {
    _checkUri(node, node.uri.stringValue);
  }

  @override
  void visitExportDirective(ExportDirective node) {
    _checkUri(node, node.uri.stringValue);
  }

  void _checkUri(UriBasedDirective node, String? uri) {
    final path = context.definingUnit.file.path.replaceAll('\\', '/');
    if (!path.contains('/apps/bistre_app/')) return;
    if (ForbidUiKitsRule.isForbiddenUri(uri)) {
      rule.reportAtNode(node);
    }
  }
}
