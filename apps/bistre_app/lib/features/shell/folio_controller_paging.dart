part of 'folio_controller.dart';

/// How many messages a chat opens with; longer chats load older pages on request.
const int kFeedPage = 400;

/// Windowed history of the open chat: it opens on its newest [kFeedPage] messages and older
/// pages load on request (Show earlier messages), or when something needs a message that is
/// not loaded yet (a search hit, a pin, the session tree).
extension FolioControllerPaging on FolioController {
  /// Whether the open chat has messages older than the loaded ones.
  bool get hasEarlierNodes => _hasEarlierNodes;

  /// Loads [threadId]'s newest messages: one page, or at least [keep] (what is already shown)
  /// while the chat has them.
  Future<({List<EngineNode> nodes, bool earlier})> _loadNodes(
    String threadId, {
    int keep = 0,
  }) async {
    final nodes = <EngineNode>[];
    String? before;
    // Every page holds kFeedPage messages or ends the chat, so this stops.
    while (true) {
      final page = await _gateway.listNodesWindow(
        threadId: threadId,
        beforeNodeId: before,
        limit: kFeedPage + 1,
      );
      // One extra row says whether anything older exists.
      final more = page.length > kFeedPage;
      nodes.insertAll(0, more ? page.sublist(1) : page);
      if (!more) return (nodes: nodes, earlier: false);
      if (nodes.length >= keep) return (nodes: nodes, earlier: true);
      before = nodes.first.id;
    }
  }

  /// Reloads the open chat after a change, keeping as many messages as are shown. Writes
  /// only into the chat that is still open.
  Future<void> _reloadActiveNodes(String threadId) async {
    final page = await _loadNodes(threadId, keep: _nodes.length);
    final spend = page.earlier
        ? await _gateway.getThreadSpendMicros(threadId)
        : null;
    if (_activeThread?.id != threadId) return;
    _nodes = page.nodes;
    _hasEarlierNodes = page.earlier;
    _partialThreadSpendMicros = spend;
  }

  /// Loads the page before the oldest loaded message. Returns whether it added any.
  Future<bool> loadEarlierNodes() async {
    final thread = _activeThread?.id;
    final anchor = _nodes.firstOrNull?.id;
    if (thread == null || anchor == null || !_hasEarlierNodes) return false;
    if (_loadingEarlierNodes) return false;
    _loadingEarlierNodes = true;
    try {
      final page = await _gateway.listNodesWindow(
        threadId: thread,
        beforeNodeId: anchor,
        limit: kFeedPage + 1,
      );
      // A reload or a chat switch while this page loaded makes it stale.
      if (_activeThread?.id != thread || _nodes.firstOrNull?.id != anchor) {
        return false;
      }
      final more = page.length > kFeedPage;
      _nodes = <EngineNode>[...(more ? page.sublist(1) : page), ..._nodes];
      _hasEarlierNodes = more;
      // The first loaded messages now have their parents: their old grouping is gone.
      _selectedChildIndex.remove('__root__');
      if (!more) _partialThreadSpendMicros = null;
      _notify();
      return page.isNotEmpty;
    } catch (e) {
      _fail(e);
      return false;
    } finally {
      _loadingEarlierNodes = false;
    }
  }

  /// Loads older pages until [found] holds or the chat has none left.
  Future<void> _loadEarlierUntil(bool Function() found) async {
    while (!found() && _hasEarlierNodes) {
      if (!await loadEarlierNodes()) return;
    }
  }

  /// Loads every older page (the session tree shows the whole chat).
  Future<void> loadAllEarlierNodes() => _loadEarlierUntil(() => false);

  /// The child shown at a fork the user did not choose: the newest one. In a partly
  /// loaded chat the first loaded messages have their parents unloaded; there the one on
  /// the way to the newest message is shown.
  int _defaultChildIndex(String parentKey) {
    final siblings = _childrenByParent[parentKey] ?? const <EngineNode>[];
    if (parentKey != '__root__' || !_hasEarlierNodes)
      return siblings.length - 1;
    final top = _newestBranchTop;
    final at = siblings.indexWhere((n) => n.id == top);
    return at < 0 ? siblings.length - 1 : at;
  }

  String? get _newestBranchTop {
    _childrenByParent;
    return _newestBranchTopId;
  }

  /// A message whose parent is not loaded (an earlier page) groups with the roots.
  String _parentKeyOf(EngineNode node) {
    _childrenByParent;
    final parent = node.parentId;
    return parent != null && _loadedIds.contains(parent) ? parent : '__root__';
  }

  String? _topLoadedAncestor(EngineNode? node) {
    if (node == null) return null;
    final byId = <String, EngineNode>{for (final n in _nodes) n.id: n};
    var current = node;
    // Bounded by the loaded messages, so a parent loop cannot spin.
    for (var i = 0; i < _nodes.length; i++) {
      final parent = byId[current.parentId];
      if (parent == null) break;
      current = parent;
    }
    return current.id;
  }
}

/// Groups messages by parent; a message whose parent is not loaded groups with the roots.
Map<String, List<EngineNode>> _groupChildrenByParent(
  List<EngineNode> allNodes,
  Set<String> loaded,
) {
  final map = <String, List<EngineNode>>{};
  for (final node in allNodes) {
    final parent = node.parentId;
    final key = parent != null && loaded.contains(parent) ? parent : '__root__';
    map.putIfAbsent(key, () => <EngineNode>[]).add(node);
  }
  return map;
}
