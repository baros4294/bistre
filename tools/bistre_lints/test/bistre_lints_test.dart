import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:bistre_lints/src/forbid_hardcoded_ui_strings.dart';
import 'package:bistre_lints/src/forbid_layout_animations.dart';
import 'package:bistre_lints/src/forbid_non_directional_geometry.dart';
import 'package:bistre_lints/src/forbid_raw_colors.dart';
import 'package:bistre_lints/src/forbid_ui_kits.dart';
import 'package:test/test.dart';

class _TestAstCollector extends RecursiveAstVisitor<void> {
  final List<String> forbiddenImports = <String>[];
  final List<AstNode> hardcodedStrings = <AstNode>[];
  final List<String> layoutAnimations = <String>[];
  final List<AstNode> rawColors = <AstNode>[];
  final List<AstNode> nonDirectionalGeometry = <AstNode>[];

  @override
  void visitImportDirective(ImportDirective node) {
    final uri = node.uri.stringValue;
    if (ForbidUiKitsRule.isForbiddenUri(uri)) {
      forbiddenImports.add(uri!);
    }
    super.visitImportDirective(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (target == null) {
      final name = node.methodName.name;
      hardcodedStrings.addAll(
        ForbidHardcodedUiStringsRule.findViolations(name, node.argumentList),
      );
      if (ForbidLayoutAnimationsRule.isForbiddenWidget(name)) {
        layoutAnimations.add(name);
      }
      if (ForbidRawColorsRule.isRawColorCall(name)) {
        rawColors.add(node);
      }
      if (ForbidNonDirectionalGeometryRule.isForbiddenEdgeInsetsCall(
        name,
        null,
        node.argumentList,
      )) {
        nonDirectionalGeometry.add(node);
      }
    } else if (target is SimpleIdentifier) {
      if (ForbidRawColorsRule.isRawColorCall(target.name)) {
        rawColors.add(node);
      }
      if (ForbidNonDirectionalGeometryRule.isForbiddenEdgeInsetsCall(
        target.name,
        node.methodName.name,
        node.argumentList,
      )) {
        nonDirectionalGeometry.add(node);
      }
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final typeName = node.constructorName.type.name.lexeme;
    hardcodedStrings.addAll(
      ForbidHardcodedUiStringsRule.findViolations(typeName, node.argumentList),
    );
    if (ForbidLayoutAnimationsRule.isForbiddenWidget(typeName)) {
      layoutAnimations.add(typeName);
    }
    if (ForbidRawColorsRule.isRawColorCall(typeName)) {
      rawColors.add(node);
    }
    if (ForbidNonDirectionalGeometryRule.isForbiddenEdgeInsetsCall(
      typeName,
      node.constructorName.name?.name,
      node.argumentList,
    )) {
      nonDirectionalGeometry.add(node);
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (ForbidNonDirectionalGeometryRule.isForbiddenAlignmentMember(
      node.prefix.name,
      node.identifier.name,
    )) {
      nonDirectionalGeometry.add(node);
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final target = node.target;
    if (target is SimpleIdentifier &&
        ForbidNonDirectionalGeometryRule.isForbiddenAlignmentMember(
          target.name,
          node.propertyName.name,
        )) {
      nonDirectionalGeometry.add(node);
    }
    super.visitPropertyAccess(node);
  }
}

void main() {
  test('forbids Material, Cupertino, state frameworks, and HTTP/SQL imports while allowing widgets.dart', () {
    const source = '''
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:sqflite/sqflite.dart';
''';
    final parsed = parseString(content: source);
    final collector = _TestAstCollector();
    parsed.unit.visitChildren(collector);

    expect(collector.forbiddenImports, <String>[
      'package:flutter/material.dart',
      'package:flutter/cupertino.dart',
      'package:material_ui/material_ui.dart',
      'package:flutter_localizations/flutter_localizations.dart',
      'package:flutter_riverpod/flutter_riverpod.dart',
      'package:dio/dio.dart',
      'package:sqflite/sqflite.dart',
    ]);
  });

  test('forbids hardcoded UI strings including ternaries, concatenations, and Ink Primitives while allowing l10n lookups', () {
    const source = '''
Widget buildBad(bool flag, String? maybe) {
  return Semantics(
    label: 'Hardcoded Label',
    child: Column(
      children: [
        Text(flag ? 'Dark' : 'Light'),
        InkText(maybe ?? 'Fallback'),
        QuillInput(placeholder: 'Type here'),
        EngravedIcon(semanticsLabel: 'Logo'),
      ],
    ),
  );
}

Widget buildGood(dynamic l10n) {
  return Semantics(
    label: l10n.t('app.title'),
    child: Column(
      children: [
        Text(l10n.t('shell.composer.send')),
        Text(' · '),
        QuillInput(placeholder: l10n.t('shell.composer.placeholder')),
      ],
    ),
  );
}
''';
    final parsed = parseString(content: source);
    final collector = _TestAstCollector();
    parsed.unit.visitChildren(collector);

    // label + 'Dark' + 'Light' + 'Fallback' + placeholder + semanticsLabel = 6
    expect(collector.hardcodedStrings.length, 6);
  });

  test('forbids implicit layout-mutating animation widgets', () {
    const source = '''
Widget buildBad() => AnimatedContainer(duration: Duration.zero, child: AnimatedPadding(padding: EdgeInsetsDirectional.zero, duration: Duration.zero));
Widget buildGood() => AnimatedOpacity(opacity: 1, duration: Duration.zero);
''';
    final parsed = parseString(content: source);
    final collector = _TestAstCollector();
    parsed.unit.visitChildren(collector);

    expect(collector.layoutAnimations, <String>[
      'AnimatedContainer',
      'AnimatedPadding',
    ]);
  });

  test('forbids raw Color literals outside bistre_theme.dart', () {
    const source = '''
const a = Color(0xFF19120D);
final b = Color.fromARGB(255, 10, 20, 30);
''';
    final parsed = parseString(content: source);
    final collector = _TestAstCollector();
    parsed.unit.visitChildren(collector);

    expect(collector.rawColors.length, 2);
  });

  test('forbids physical left/right EdgeInsets and Alignment constants', () {
    const source = '''
const bad1 = EdgeInsets.fromLTRB(1, 2, 3, 4);
const bad2 = EdgeInsets.only(left: 8);
const bad3 = Alignment.centerLeft;
const good1 = EdgeInsetsDirectional.only(start: 8, end: 8);
const good2 = EdgeInsets.symmetric(horizontal: 8);
const good3 = AlignmentDirectional.centerStart;
''';
    final parsed = parseString(content: source);
    final collector = _TestAstCollector();
    parsed.unit.visitChildren(collector);

    expect(collector.nonDirectionalGeometry.length, 3);
  });

  test(
    'flags Positioned left/right, TextAlign left/right, and size transitions',
    () {
      const source = '''
import 'package:flutter/widgets.dart';
Widget a() => Positioned(left: 4, child: SizedBox());
Widget b() => PositionedDirectional(start: 4, child: SizedBox());
Widget c() => Text('x', textAlign: TextAlign.left);
Widget d() => Text('x', textAlign: TextAlign.start);
Widget e(Animation<double> t) => SizeTransition(sizeFactor: t, child: SizedBox());
Widget f() => AnimatedCrossFade(firstChild: SizedBox(), secondChild: SizedBox());
''';
      final unit = parseString(content: source).unit;
      final collector = _TestAstCollector();
      unit.accept(collector);
      expect(collector.nonDirectionalGeometry, hasLength(2));
      expect(collector.layoutAnimations, <String>[
        'SizeTransition',
        'AnimatedCrossFade',
      ]);
    },
  );
}
