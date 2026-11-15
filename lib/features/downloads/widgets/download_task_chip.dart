import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/services/download_service.dart';
import '../../../core/ui/app_toast.dart';
import '../../../core/ui/music_action_glyphs.dart';
import '../download_progress.dart';

/// Pauses a running transfer started from a list row.
void pauseDownload(BuildContext context, WidgetRef ref, String taskId) {
  final service = ref.read(downloadServiceProvider);
  if (!service.pauseTask(taskId)) {
    showAppToast(context, '该任务已经结束', type: AppToastType.info);
  }
}

/// Restarts a paused transfer from the beginning.
void resumeDownload(BuildContext context, WidgetRef ref, String taskId) {
  final service = ref.read(downloadServiceProvider);
  if (!service.resumeTask(taskId)) {
    showAppToast(context, '该任务已经结束', type: AppToastType.info);
  }
}

/// Drops the transfer and its row from the downloads page.
void cancelDownload(BuildContext context, WidgetRef ref, String taskId) {
  final service = ref.read(downloadServiceProvider);
  if (!service.cancelTask(taskId)) {
    showAppToast(context, '该任务已经结束', type: AppToastType.info);
  }
}

/// Stands in for a row's download button while that song is downloading: the
/// ring (or a pause glyph) opens a tiny menu so the transfer can be paused,
/// resumed or cancelled without leaving the list.
class DownloadTaskChip extends ConsumerWidget {
  const DownloadTaskChip({
    super.key,
    required this.task,
    required this.dimension,
    required this.progressSize,
    this.strokeWidth = 2.2,
    this.color,
  });

  final DownloadTask task;
  final double dimension;
  final double progressSize;
  final double strokeWidth;
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.primary;
    final paused = task.isPaused;
    final progress = task.fraction;
    final service = ref.read(downloadServiceProvider);

    return prism.PopupAnchor(
      targetBuilder: (open) => Semantics(
        button: true,
        label: paused ? '继续下载' : '暂停下载',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: open,
          child: SizedBox.square(
            dimension: dimension,
            child: Center(
              child: SizedBox.square(
                dimension: progressSize,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (paused)
                      Icon(
                        Icons.play_arrow_rounded,
                        size: progressSize,
                        color: tint,
                      )
                    else
                      CircularProgressIndicator(
                        value: progress,
                        strokeWidth: strokeWidth,
                        color: tint,
                      ),
                    if (!paused)
                      Icon(
                        Icons.pause_rounded,
                        size: progressSize * 0.55,
                        color: tint,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      popupBuilder: (_) => prism.PopupMenu(
        items: [
          if (paused)
            prism.PopupMenuItem(
              label: '继续下载',
              leading: const Icon(Icons.play_arrow_rounded),
              executeImmediately: true,
              onPressed: () {
                if (!service.resumeTask(task.id)) {
                  showAppToast(context, '该任务已经结束', type: AppToastType.info);
                }
              },
            )
          else
            prism.PopupMenuItem(
              label: '暂停下载',
              leading: const Icon(Icons.pause_rounded),
              executeImmediately: true,
              onPressed: () {
                if (!service.pauseTask(task.id)) {
                  showAppToast(context, '该任务已经结束', type: AppToastType.info);
                }
              },
            ),
          prism.PopupMenuItem(
            label: '取消下载',
            glyph: MusicActionGlyphs.trash,
            executeImmediately: true,
            danger: true,
            onPressed: () => service.cancelTask(task.id),
          ),
        ],
      ),
    );
  }
}
