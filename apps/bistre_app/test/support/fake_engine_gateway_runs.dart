part of 'fake_engine_gateway.dart';

/// Agent runs, steering, and power state of [FakeEngineGateway] (split by responsibility to
/// keep each file under 1,500 lines).
mixin _FakeRunsAndPower implements BistreEngineGateway {
  abstract int _clock;
  StreamController<BistreEvent> get _events;
  Future<void> _record(String method, Map<String, Object?> args);

  final List<EngineAgentRun> _runs = <EngineAgentRun>[];

  /// Records a run in core's run list (as `listAgentRuns` returns it).
  void seedAgentRun({required String threadId, required String status}) {
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
}
