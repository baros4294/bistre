import 'package:bistre_guard/perf_runner.dart';
import 'package:test/test.dart';

void main() {
  test('parses probe lines, adb output, medians, and budget verdicts', () {
    expect(
      parseProbe(
        '[BISTRE_PERF] stream_frames=180 stream_frame_p95_ms=6.25\nchat_ready_ms=512',
      ),
      <String, String>{
        'stream_frames': '180',
        'stream_frame_p95_ms': '6.25',
        'chat_ready_ms': '512',
      },
    );
    expect(
      parseAmStartTotalTime('Status: ok\nTotalTime: 612\nWaitTime: 640'),
      612,
    );
    expect(
      parseDumpsysTotalPssKb('  TOTAL PSS:   98304   TOTAL RSS: 150000'),
      98304,
    );
    expect(parseDumpsysTotalPssKb('        TOTAL    97000    80000'), 97000);
    expect(median(<num>[420, 380, 390]), 390);

    const ok = PerfMetric('first', 380, 'ms', budget: 400, hardFail: 600);
    const over = PerfMetric('first', 450, 'ms', budget: 400, hardFail: 600);
    const fail = PerfMetric('first', 650, 'ms', budget: 400, hardFail: 600);
    expect(ok.overBudget || ok.failed, isFalse);
    expect(over.overBudget && !over.failed, isTrue);
    expect(fail.failed, isTrue);
    expect(fail.describe(), startsWith('FAIL'));
  });
}
