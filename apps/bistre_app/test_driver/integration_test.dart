import 'package:flutter_driver/flutter_driver.dart' as driver;
import 'package:integration_test/integration_test_driver.dart';

/// Host side of `flutter drive --profile`: prints the benchmark's `reportData` and writes the
/// streaming timeline (`build/streaming.timeline.json` plus its summary) for attribution
/// (Spec 11 §1).
Future<void> main() => integrationDriver(
  responseDataCallback: (Map<String, dynamic>? data) async {
    final timeline = data?['timeline'];
    if (timeline is Map<String, dynamic>) {
      final summary = driver.TimelineSummary.summarize(
        driver.Timeline.fromJson(timeline),
      );
      await summary.writeTimelineToFile('streaming');
    }
    await writeResponseData(data);
  },
);
