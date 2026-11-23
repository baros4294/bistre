import 'dart:io';

import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:bistre_app/main.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';

void main() {
  testWidgets(
    'UIGalleryTest captures all 28 redesigned Studio Atelier screens (Waves A-E) with real bundled fonts and color lab icons',
    (WidgetTester tester) async {
      await loadBundledFonts();
      final outDir = Directory('build/ui_gallery')..createSync(recursive: true);

      tester.view.physicalSize = const Size(1320, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 01. Unconfigured Welcome Desk (SINGLE Add API Key card, zero duplicate CTAs!).
      final l10n1 = loadDiskCatalogs();
      final gw1 = GalleryGateway(connected: false);
      final ctrl1 = FolioController(
        gateway: gw1,
        defaultThreadTitle: l10n1.t(L10nKey.shellThreadDefaultTitle),
        onLocaleSynced: l10n1.setLocale,
        isDevEnvironment: true,
      );
      await ctrl1.bootstrap('memory');
      final key1 = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key1,
          child: BistreApp(l10nController: l10n1, folioController: ctrl1),
        ),
      );
      await capturePng(tester, key1, outDir, '01_welcome_unconfigured_day.png');
      ctrl1.dispose();
      await gw1.shutdown();

      // 02. Configured Ready Welcome Desk (active color lab badge + vertical starters).
      final l10nReady = loadDiskCatalogs();
      final gwReady = GalleryGateway(connected: true, seedConversation: false);
      final ctrlReady = FolioController(
        gateway: gwReady,
        defaultThreadTitle: l10nReady.t(L10nKey.shellThreadDefaultTitle),
        onLocaleSynced: l10nReady.setLocale,
        isDevEnvironment: true,
      );
      await ctrlReady.bootstrap('memory');
      final keyReady = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: keyReady,
          child: BistreApp(
            l10nController: l10nReady,
            folioController: ctrlReady,
          ),
        ),
      );
      await capturePng(
        tester,
        keyReady,
        outDir,
        '02_welcome_configured_day.png',
      );
      ctrlReady.dispose();
      await gwReady.shutdown();

      // 03. Active Conversation (Light Document mode, Markdown/code, branch switcher, token/cost footer, quote).
      final l10n2 = loadDiskCatalogs();
      final gw2 = GalleryGateway(connected: true);
      final ctrl2 = FolioController(
        gateway: gw2,
        defaultThreadTitle: l10n2.t(L10nKey.shellThreadDefaultTitle),
        onLocaleSynced: l10n2.setLocale,
        isDevEnvironment: true,
      );
      await ctrl2.bootstrap('memory');
      ctrl2.replyToPassage(
        'Isolating writes on one actor thread eliminates write-write SQLITE_BUSY.',
      );
      final key2 = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key2,
          child: BistreApp(l10nController: l10n2, folioController: ctrl2),
        ),
      );
      await capturePng(
        tester,
        key2,
        outDir,
        '03_chat_markdown_code_branches_day.png',
      );

      // 04. Active Conversation + Docked Right Chat Parameters Inspector Drawer.
      ctrl2.clearQuote();
      ctrl2.toggleInspector();
      await capturePng(
        tester,
        key2,
        outDir,
        '04_chat_inspector_drawer_day.png',
      );

      // 05. Dark Theme + Bubbles Layout.
      ctrl2.toggleInspector();
      ctrl2.toggleTheme();
      ctrl2.toggleLayoutMode();
      await capturePng(tester, key2, outDir, '05_chat_night_bubbles.png');

      // 06. Full-Window Settings -> Providers & Keys (color lab icons, loaded models, delete button).
      ctrl2.toggleTheme();
      ctrl2.toggleLayoutMode();
      await ctrl2.fetchModelsForProvider('openai');
      ctrl2.openSettings();
      await capturePng(tester, key2, outDir, '06_settings_providers_keys.png');

      // 07. Full-Window Settings -> Add Provider Template Gallery.
      await tester.tap(find.text('Add provider').first);
      await capturePng(tester, key2, outDir, '07_settings_add_provider.png');

      // 08. Full-Window Settings -> Assistants (ZERO hardcoded mode pills).
      ctrl2.setSettingsTab(SettingsTab.assistants);
      await capturePng(tester, key2, outDir, '08_settings_assistants.png');

      // 09. Full-Window Settings -> Appearance & Custom Fonts Studio.
      ctrl2.setSettingsTab(SettingsTab.appearance);
      await capturePng(
        tester,
        key2,
        outDir,
        '09_settings_appearance_fonts.png',
      );

      // 10. Full-Window Settings -> Safety & Budget (Unlimited active).
      ctrl2.setSettingsTab(SettingsTab.trust);
      await capturePng(
        tester,
        key2,
        outDir,
        '10_settings_budget_unlimited.png',
      );

      // 11. Full-Window Settings -> Safety & Budget (Custom USD cap active).
      await ctrl2.updateSettings(
        ctrl2.settings.copyWith(walletDailyCeilingMicros: 5000000),
        quiet: true,
      );
      await capturePng(tester, key2, outDir, '11_settings_budget_capped.png');

      // 12. Full-Window Settings -> Updates & Storage (OTA available + Ed25519 verified + Dev badge).
      ctrl2.setSettingsTab(SettingsTab.updates);
      await ctrl2.checkForUpdates();
      await capturePng(tester, key2, outDir, '12_settings_updates_storage.png');

      // 13. Full-Window Settings -> Language Selector.
      ctrl2.setSettingsTab(SettingsTab.language);
      await capturePng(tester, key2, outDir, '13_settings_language.png');

      // 14. Full-Window Dark Settings -> Interactive Keyboard Shortcuts.
      ctrl2.toggleTheme();
      ctrl2.setSettingsTab(SettingsTab.shortcuts);
      await capturePng(tester, key2, outDir, '14_settings_shortcuts_night.png');

      // 15. Sidebar Assistants Tab (Light theme).
      ctrl2.closeSettings();
      ctrl2.toggleTheme();
      ctrl2.setSidebarTab(SidebarTab.assistant);
      await capturePng(tester, key2, outDir, '15_sidebar_assistants_tab.png');

      // 16. Command Palette (Ctrl+K).
      ctrl2.setSidebarTab(SidebarTab.chat);
      ctrl2.toggleCommandPalette();
      await capturePng(tester, key2, outDir, '16_command_palette.png');

      // 17. Arabic RTL Desktop Workspace.
      ctrl2.closeCommandPalette();
      l10n2.setLocale('ar');
      await capturePng(tester, key2, outDir, '17_arabic_rtl_desktop.png');

      // 18. Narrow Mobile Viewport (412x892) with Slide-Over Sidebar Drawer.
      l10n2.setLocale('en');
      tester.view.physicalSize = const Size(412, 892);
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Toggle sidebar'));
      await capturePng(tester, key2, outDir, '18_mobile_drawer.png');

      // --- Wave A-E High-DPI Gallery Screens (19..28) ---
      tester.view.physicalSize = const Size(1360, 860);
      await tester.pumpAndSettle();
      // Close narrow drawer if open and ensure clean desktop layout.
      final l10n3 = loadDiskCatalogs();
      final gw3 = GalleryGateway(connected: true);
      final ctrl3 = FolioController(
        gateway: gw3,
        defaultThreadTitle: l10n3.t(L10nKey.shellThreadDefaultTitle),
        onLocaleSynced: l10n3.setLocale,
        isDevEnvironment: true,
      );
      await ctrl3.bootstrap('memory');
      final key3 = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key3,
          child: BistreApp(l10nController: l10n3, folioController: ctrl3),
        ),
      );
      await tester.pumpAndSettle();

      // 19. Wave A: Docked Studio Pane [Runs] with OS Sleep Guard active + durable run.
      ctrl3.setStudioTab(StudioTab.runs);
      await capturePng(
        tester,
        key3,
        outDir,
        '19_studio_runs_and_sleep_guard.png',
      );

      // 20. Wave B: Expanded Thinking / Reasoning Block on assistant passage.
      ctrl3.toggleStudioPane();
      ctrl3.focusBranchNode('n-2b');
      await tester.pumpAndSettle();
      final thoughtFinder = find.textContaining('Thinking');
      if (thoughtFinder.evaluate().isNotEmpty) {
        await tester.tap(thoughtFinder.first);
      }
      await capturePng(
        tester,
        key3,
        outDir,
        '20_chat_thinking_and_tool_timeline.png',
      );

      // 21. Wave C: Rich Studio Canvas (GFM Table + NotoSansMath LaTeX + Mermaid Flowchart).
      await ctrl3.selectThread('t-rich');
      await capturePng(
        tester,
        key3,
        outDir,
        '21_chat_rich_table_math_mermaid.png',
      );

      // 22. Wave C: Visual DAG Session Tree Overlay.
      await ctrl3.selectThread('t-1');
      ctrl3.openSessionTree();
      await capturePng(tester, key3, outDir, '22_session_tree_overlay.png');

      // 23. Wave A/B: Full-Window Settings -> Agent, Tools & Sleep (Workspace, MCP, Sleep Guard, Termux).
      ctrl3.closeSessionTree();
      ctrl3.openSettings(SettingsTab.agent);
      await capturePng(tester, key3, outDir, '23_settings_agent_tools_mcp.png');

      // 24. Wave D: Full-Window Settings -> Memory & Skills (Saved Memory, Cron Schedules, SKILL.md).
      await ctrl3.setWorkspaceRootPath('C:/baros4294/bistre');
      await ctrl3.refreshMemorySkillsAndCron();
      ctrl3.setSettingsTab(SettingsTab.memory);
      await tester.pump(const Duration(seconds: 3));
      await capturePng(
        tester,
        key3,
        outDir,
        '24_settings_memory_skills_cron.png',
      );

      // 25. Wave E: Write Mode + Studio Pane [Story Bible] (CCv3 Cards, Persona, Lorebook V3 + Progressions, Regex).
      ctrl3.closeSettings();
      await ctrl3.selectThread('t-write');
      await ctrl3.refreshStoryStudio();
      ctrl3.setStudioTab(StudioTab.story);
      await capturePng(tester, key3, outDir, '25_studio_story_bible_panel.png');

      // 26. Wave E: Write Mode + Studio Pane [Prompt Inspector] (Token Bar, Prompt Cache Boundary, Lorebook Trace).
      ctrl3.setStudioTab(StudioTab.prompt);
      await capturePng(tester, key3, outDir, '26_studio_prompt_inspector.png');

      // 27. Wave E: Write Mode Roleplay Controls + Editorial Pure-TextSpan Dialogue Highlighting.
      ctrl3.toggleStudioPane();
      await capturePng(
        tester,
        key3,
        outDir,
        '27_write_roleplay_controls_dialogue.png',
      );

      // 28. Wave E: Write Mode Long-Form Manuscript Canvas (Chapters/Scenes, Beats -> Prose, Inline Rewrite Laser Tools).
      ctrl3.toggleManuscriptView(true);
      await capturePng(
        tester,
        key3,
        outDir,
        '28_write_manuscript_beats_laser_tools.png',
      );

      await tester.pump(const Duration(seconds: 3));
      ctrl3.dispose();
      await gw3.shutdown();

      ctrl2.dispose();
      await gw2.shutdown();

      const expectedFiles = <String>[
        '01_welcome_unconfigured_day.png',
        '02_welcome_configured_day.png',
        '03_chat_markdown_code_branches_day.png',
        '04_chat_inspector_drawer_day.png',
        '05_chat_night_bubbles.png',
        '06_settings_providers_keys.png',
        '07_settings_add_provider.png',
        '08_settings_assistants.png',
        '09_settings_appearance_fonts.png',
        '10_settings_budget_unlimited.png',
        '11_settings_budget_capped.png',
        '12_settings_updates_storage.png',
        '13_settings_language.png',
        '14_settings_shortcuts_night.png',
        '15_sidebar_assistants_tab.png',
        '16_command_palette.png',
        '17_arabic_rtl_desktop.png',
        '18_mobile_drawer.png',
        '19_studio_runs_and_sleep_guard.png',
        '20_chat_thinking_and_tool_timeline.png',
        '21_chat_rich_table_math_mermaid.png',
        '22_session_tree_overlay.png',
        '23_settings_agent_tools_mcp.png',
        '24_settings_memory_skills_cron.png',
        '25_studio_story_bible_panel.png',
        '26_studio_prompt_inspector.png',
        '27_write_roleplay_controls_dialogue.png',
        '28_write_manuscript_beats_laser_tools.png',
      ];
      for (final file in expectedFiles) {
        final f = File('${outDir.path}/$file');
        expect(f.existsSync(), isTrue, reason: 'Missing gallery image $file');
        expect(f.lengthSync(), greaterThan(5000));
      }
    },
  );
}
