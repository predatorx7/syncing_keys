import 'package:flutter/material.dart';

/// Light-weight modal "fetching from cloud..." indicator shown while
/// [SyncingKeys.getKey] is reaching out to iCloud / Google Drive.
///
/// Use [show] to push and capture the dismissal callback; call the returned
/// callback when the work is complete so the dialog is torn down. Wrapping
/// in a small class keeps the call-site of the CRUD engine readable.
class LoadingOverlay {
  LoadingOverlay._();

  static VoidCallback show(BuildContext context, {String message = 'Fetching from cloud…'}) {
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      useRootNavigator: true,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
                const SizedBox(width: 16),
                Text(message,
                    style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ),
      ),
    );
    return () {
      if (navigator.canPop()) navigator.pop();
    };
  }
}
