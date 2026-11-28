part of 'fake_engine_gateway.dart';

/// Agent runs, steering, and power state of [FakeEngineGateway] (split by responsibility).
mixin _FakeRunsAndPower implements BistreEngineGateway {
  abstract int _clock;
  StreamController<BistreEvent> get _events;
  Future<void> _record(String method, Map<String, Object?> args);

  final List<EngineAgentRun> _runs = <EngineAgentRun>[];

  /// Records a run in core's run list (as `listAgentRuns` returns it).
  void seedAgentRun({
    required String threadId,
    required String status,
    String? errorKey,
  }) {
    _clock++;
    _runs.insert(
      0,
      EngineAgentRun(
        id: 'run-seed-$_clock',
        threadId: threadId,
        mode: 'chat',
        status: status,
        stepIndex: 0,
        maxSteps: 24,
        unattendedPolicy: 'pause_and_notify',
        lastHeartbeatMs: _clock,
        costMicros: 0,
        errorKey: errorKey,
        createdAtMs: _clock,
        updatedAtMs: _clock,
      ),
    );
  }

  final List<EngineSteeringMessage> _steering = <EngineSteeringMessage>[];
  EnginePowerGuardStatus _powerStatus = const EnginePowerGuardStatus();

  @override
  Future<List<EngineAgentRun>> listAgentRuns({
    String? threadId,
    bool onlyActive = false,
    int limit = 50,
  }) async => _runs
      .where(
        (r) =>
            (threadId == null || r.threadId == threadId) &&
            (!onlyActive || r.isActive),
      )
      .take(limit)
      .toList(growable: false);

  @override
  Future<EngineSteeringMessage> enqueueSteering({
    required String threadId,
    required String content,
  }) async {
    final msg = EngineSteeringMessage(
      id: 'steer-${_steering.length + 1}',
      threadId: threadId,
      content: content,
      status: 'pending',
      createdAtMs: ++_clock,
    );
    _steering.add(msg);
    _events.add(
      SteeringQueueChangedEvent(
        threadId: threadId,
        pendingCount: _steering.where((s) => s.threadId == threadId).length,
      ),
    );
    return msg;
  }

  @override
  Future<List<EngineSteeringMessage>> listPendingSteering(
    String threadId,
  ) async => _steering
      .where((s) => s.threadId == threadId && s.status == 'pending')
      .toList(growable: false);

  @override
  Future<void> deleteSteering(String steeringId) async {
    _steering.removeWhere((s) => s.id == steeringId);
  }

  /// Sets what `powerGuardStatus` reports (for example a connected desktop daemon).
  void seedPowerStatus(EnginePowerGuardStatus status) => _powerStatus = status;

  @override
  Future<EnginePowerGuardStatus> powerGuardStatus() async => _powerStatus;

  @override
  Future<int> notifyPowerEvent(String eventKind, {bool? onAc}) async {
    await _record('notifyPowerEvent', <String, Object?>{
      'eventKind': eventKind,
    });
    return 0;
  }

  @override
  Future<EnginePowerGuardStatus> setAndroidPowerState({
    required bool fgsActive,
    required bool batteryUnrestricted,
  }) async {
    _powerStatus = EnginePowerGuardStatus(
      platform: 'android',
      androidFgsActive: fgsActive,
      androidBatteryUnrestricted: batteryUnrestricted,
    );
    return _powerStatus;
  }

  @override
  Future<EngineAgentRun> resolveIndeterminateRun({
    required String runId,
    required bool confirmCompleted,
  }) async {
    final idx = _runs.indexWhere((r) => r.id == runId);
    final old = _runs[idx];
    final next = EngineAgentRun(
      id: old.id,
      threadId: old.threadId,
      mode: old.mode,
      status: 'running',
      stepIndex: old.stepIndex,
      maxSteps: old.maxSteps,
      unattendedPolicy: old.unattendedPolicy,
      lastHeartbeatMs: ++_clock,
      costMicros: old.costMicros,
      createdAtMs: old.createdAtMs,
      updatedAtMs: _clock,
    );
    _runs[idx] = next;
    return next;
  }

  /// When set, checking for updates fails with this diagnostic.
  String? updateCheckFailure;

  /// When set, staging the update fails with this diagnostic.
  String? stageUpdateFailure;

  /// Optional override for [checkForUpdates] (defaults to available update `0.2.0`).
  EngineUpdateCheck? updateCheckOverride;

  @override
  Future<EngineUpdateCheck> checkForUpdates({String? feedUrlOverride}) async {
    await _record('checkForUpdates', <String, Object?>{
      'feedUrlOverride': feedUrlOverride,
    });
    final failure = updateCheckFailure;
    if (failure != null) throw Exception(failure);
    return updateCheckOverride ?? _availableUpdateFixture;
  }

  static const EngineUpdateCheck _availableUpdateFixture = EngineUpdateCheck(
    currentVersion: '0.1.0',
    latestVersion: '0.2.0',
    updateAvailable: true,
    track: 'track_b',
    ownershipMode: 'self_managed',
    signatureVerified: true,
    activeRunsBlocking: false,
    releaseNotes: 'Silent Track-B update ready.',
    downloadUrl: 'https://example.invalid/bistre-0.2.0.zip',
    sha256Hex: '0000',
    downloadSizeBytes: 12400000,
    checkedAtMs: 1700000000000,
  );

  @override
  Future<String> stageUpdate(EngineUpdateCheck check) async {
    await _record('stageUpdate', <String, Object?>{
      'version': check.latestVersion,
    });
    final failure = stageUpdateFailure;
    if (failure != null) throw Exception(failure);
    return '.bistre-dev/updates/bistre-${check.latestVersion}.zip';
  }

  @override
  Future<String> reinstallUpdate(EngineUpdateCheck check) async {
    await _record('reinstallUpdate', <String, Object?>{
      'version': check.latestVersion,
    });
    final failure = stageUpdateFailure;
    if (failure != null) throw Exception(failure);
    return '.bistre-dev/updates/bistre-${check.latestVersion}.zip';
  }

  String? pendingUpdate;
  String? installFailure;

  @override
  Future<String?> pendingUpdateVersion() async {
    await _record('pendingUpdateVersion', const <String, Object?>{});
    return pendingUpdate;
  }

  @override
  Future<String> installStagedUpdate() async {
    await _record('installStagedUpdate', const <String, Object?>{});
    final failure = installFailure;
    if (failure != null) throw Exception(failure);
    return '';
  }

  @override
  Future<bool> respondHostAction({
    required String requestId,
    required bool ok,
    required String outputText,
    String? imageBase64,
  }) async {
    await _record('respondHostAction', <String, Object?>{
      'requestId': requestId,
      'ok': ok,
      'outputText': outputText,
      'hasImage': imageBase64 != null && imageBase64.isNotEmpty,
    });
    return true;
  }
}
