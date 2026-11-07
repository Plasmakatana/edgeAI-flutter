import 'package:flutter/material.dart';

/// Reports background-task progress into a modal dialog.
typedef ProgressReporter = void Function(String stage, [double? progress]);

class _Progress {
  const _Progress(this.stage, this.progress);
  final String stage;
  final double? progress;
}

/// Runs [task] behind a modal progress dialog.
///
/// The dialog updates via the [ProgressReporter] handed to [task] and closes
/// automatically when [task] completes. Exceptions propagate to the caller.
Future<T> runWithProgressDialog<T>(
  BuildContext context, {
  required String title,
  required Future<T> Function(ProgressReporter report) task,
}) async {
  final navigator = Navigator.of(context);
  final progress =
      ValueNotifier<_Progress>(const _Progress('Starting…', null));
  // ignore: unawaited_futures
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: ValueListenableBuilder<_Progress>(
        valueListenable: progress,
        builder: (_, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (value.progress == null)
              const LinearProgressIndicator()
            else
              LinearProgressIndicator(value: value.progress!.clamp(0.0, 1.0)),
            const SizedBox(height: 12),
            Text(value.stage),
          ],
        ),
      ),
    ),
  );
  try {
    return await task(
      (stage, [p]) => progress.value = _Progress(stage, p),
    );
  } finally {
    progress.dispose();
    navigator.pop();
  }
}
