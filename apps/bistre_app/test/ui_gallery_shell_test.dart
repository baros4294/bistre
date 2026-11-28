import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';
import 'support/gallery_scenes.dart';

/// `just ui-gallery`, main shell: first run, empty and dense chats, live replies, approvals,
/// recovery notices, sidebar states, and the side panels (desktop, light, English).
void main() {
  testWidgets('gallery: main shell', (tester) async {
    await loadBundledFonts();
    resetGalleryView(tester);
    final g = GalleryShooter(tester);
    final now = galleryClock().millisecondsSinceEpoch;

    await g.shoot('shell-first-run', connected: false);
    await g.shoot('shell-empty-ready', seed: false);
    await g.shoot('shell-chat-dense');
    await g.shoot(
      'shell-chat-thinking-open',
      prepare: (s) async {
        s.ctrl.focusBranchNode('n-2b');
        await s.tester.pumpAndSettle();
        await s.tap(find.textContaining('Thinking'));
      },
    );
    await g.shoot(
      'shell-chat-first-version',
      prepare: (s) async {
        s.ctrl.focusBranchNode('n-2a');
        await s.tester.pumpAndSettle();
      },
    );
    await g.shoot(
      'shell-chat-rich-table-math-mermaid',
      prepare: (s) => s.ctrl.selectThread('t-rich'),
    );
    await g.shoot(
      'shell-chat-sources-and-attachments',
      prepare: (s) async {
        s.gw
          ..grounding['t-1'] = const <EngineGroundingSource>[
            EngineGroundingSource(
              nodeId: 'n-2b',
              url: 'https://sqlite.org/wal.html',
              title: 'Write-Ahead Logging',
              citedText: 'A checkpoint can run concurrently with readers.',
            ),
            EngineGroundingSource(
              nodeId: 'n-2b',
              url: 'https://sqlite.org/pragma.html#pragma_wal_checkpoint',
              title: 'PRAGMA wal_checkpoint',
            ),
          ]
          ..seedNode(
            EngineNode(
              id: 'n-3',
              threadId: 't-1',
              parentId: 'n-2b',
              role: 'user',
              content:
                  'Here is our current schema and the trace from last night.',
              createdAtMs: now - 50000,
              attachments: const <EngineNodeAttachment>[
                EngineNodeAttachment(
                  name: 'schema.sql',
                  mimeType: 'text/plain',
                  sizeBytes: 4120,
                  blobRelPath: 'blobs/schema.sql',
                ),
                EngineNodeAttachment(
                  name: 'checkpoint-trace.png',
                  mimeType: 'image/png',
                  sizeBytes: 182334,
                  blobRelPath: 'blobs/trace.png',
                ),
              ],
            ),
          );
        await s.ctrl.selectThread('t-2');
        await s.ctrl.selectThread('t-1');
        await s.tester.pumpAndSettle();
      },
    );
    await g.shoot(
      'shell-streaming-with-queue',
      settle: false,
      prepare: (s) async {
        s.ctrl.addAttachment(
          const ComposerAttachment(
            id: 'a1',
            name: 'wal-bench.csv',
            mimeType: 'text/csv',
            path: '/tmp/wal-bench.csv',
            sizeBytes: 20480,
          ),
        );
        await s.emit(<BistreEvent>[
          const RunStartedEvent(threadId: 't-1', nodeId: 'live'),
          const ThinkingDeltaEvent(
            threadId: 't-1',
            nodeId: 'live',
            delta: 'Compare checkpoint modes under 8 concurrent readers.',
          ),
          const ToolExecutionUpdatedEvent(
            threadId: 't-1',
            runId: 'run-1',
            callId: 'c1',
            toolName: 'read',
            riskTier: 'tier0_read_only',
            status: 'completed',
            summary: 'read crates/bistre-storage/src/wal.rs',
            outputText: '212 lines',
          ),
          const ToolExecutionUpdatedEvent(
            threadId: 't-1',
            runId: 'run-1',
            callId: 'c2',
            toolName: 'shell',
            riskTier: 'tier2_side_effect',
            status: 'running',
            summary: 'cargo bench -p bistre-storage wal_checkpoint',
            outputText: '',
          ),
          const DeltaBatchEvent(
            threadId: 't-1',
            nodeId: 'live',
            textDelta:
                'Running the checkpoint benchmark now. Early numbers show',
          ),
          const SteeringQueueChangedEvent(threadId: 't-1', pendingCount: 2),
        ]);
      },
    );
    await g.shoot(
      'shell-tool-approval',
      settle: false,
      prepare: (s) => s.emit(<BistreEvent>[
        const RunStartedEvent(threadId: 't-1', nodeId: 'live'),
        const ToolApprovalRequestedEvent(
          threadId: 't-1',
          runId: 'run-7',
          callId: 'call_0',
          toolName: 'edit',
          argumentsJson: '{"path":"crates/bistre-storage/src/wal.rs","old":"synchronous = FULL","new":"synchronous = NORMAL"}',
          riskTier: 'tier1_reversible_edit',
        ),
      ]),
    );
    await g.shoot(
      'shell-retry-backoff',
      prepare: (s) => s.emit(<BistreEvent>[
        const DiagnosticRaisedEvent(
          key: 'diag.run.backoff_waiting',
          detailCode:
              'retry_in_ms=12000;attempt=2;reason=diag.provider.rate_limited',
        ),
      ]),
    );
    for (final (name, key) in const <(String, String)>[
      ('shell-error-key-rejected', 'diag.provider.auth_failed'),
      ('shell-error-conversation-full', 'diag.provider.context_overflow'),
      ('shell-error-spending-limit', 'diag.wallet.ceiling_exceeded'),
      ('shell-error-reply-cut-off', 'diag.provider.reply_truncated'),
    ]) {
      await g.shoot(
        name,
        prepare: (s) => s.emit(<BistreEvent>[DiagnosticRaisedEvent(key: key)]),
      );
    }
    await g.shoot(
      'shell-sidebar-closed',
      prepare: (s) async => s.ctrl.toggleSidebar(),
    );
    await g.shoot(
      'shell-sidebar-searching',
      prepare: (s) async => s.ctrl.setSidebarFilter('review'),
    );
    await g.shoot(
      'shell-sidebar-projects',
      fixtures: (gw) => gw.seedProject(),
      prepare: (s) => s.ctrl.selectThread('t-write'),
    );
    await g.shoot(
      'shell-sidebar-projects-phone-ar-200',
      size: GallerySize.phone,
      textScale: 2.0,
      locale: 'ar',
      fixtures: (gw) => gw.seedProject(),
      prepare: (s) => s.openPhoneDrawer(),
    );
    await g.shoot(
      'shell-sidebar-assistants',
      prepare: (s) async => s.ctrl.setSidebarTab(SidebarTab.assistant),
    );
    await g.shoot(
      'shell-sidebar-pinned',
      prepare: (s) async => s.ctrl.setSidebarTab(SidebarTab.pinned),
    );
    await g.shoot(
      'shell-sidebar-background-runs',
      settle: false,
      prepare: (s) => s.emit(const <BistreEvent>[
        RunStartedEvent(threadId: 't-2', nodeId: 'live-2'),
        RunStartedEvent(threadId: 't-3', nodeId: 'live-3'),
      ]),
    );
    await g.shoot(
      'shell-tabs-open',
      size: GallerySize.wide,
      prepare: (s) async {
        await s.ctrl.selectThread('t-2');
        await s.ctrl.selectThread('t-rich');
        await s.ctrl.selectThread('t-1');
        await s.tester.pumpAndSettle();
      },
    );
    await g.shoot(
      'shell-inspector',
      prepare: (s) async => s.ctrl.toggleInspector(),
    );
    for (final tab in StudioTab.values) {
      await g.shoot(
        'shell-studio-${tab.name}',
        size: GallerySize.wide,
        prepare: (s) async {
          if (tab == StudioTab.story || tab == StudioTab.prompt) {
            await s.ctrl.selectThread('t-write');
            await s.ctrl.refreshStoryStudio();
          }
          s.ctrl.setStudioTab(tab);
          await s.tester.pumpAndSettle();
        },
      );
    }
    await g.shoot(
      'shell-search-panel',
      prepare: (s) async => s.ctrl.toggleSearchPanel(),
    );
    await g.shoot(
      'shell-session-tree',
      prepare: (s) async => s.ctrl.openSessionTree(),
    );
    await g.shoot(
      'shell-turn-details',
      prepare: (s) async => s.ctrl.openTurnDetails(
        s.ctrl.visibleBranchNodes.firstWhere((n) => n.id == 'n-2b'),
      ),
    );
    await g.shoot(
      'shell-write-mode',
      prepare: (s) => s.ctrl.selectThread('t-write'),
    );
    await g.shoot(
      'shell-write-manuscript',
      prepare: (s) async {
        await s.ctrl.selectThread('t-write');
        s.ctrl.toggleManuscriptView(true);
        await s.tester.pumpAndSettle();
      },
    );
    g.verify();
  });
}
