import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cast_session.dart';

/// Orange strip shown under the top chrome row while casting:
/// 「正在投播 · 设备名」 with a disconnect action.
class CastStatusStrip extends ConsumerWidget {
  const CastStatusStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cast = ref.watch(castControllerProvider);
    if (!cast.isCasting) return const SizedBox.shrink();
    final deviceName = cast.device?.friendlyName ?? '设备';
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 2, 16, 4),
      child: Container(
        key: const ValueKey('player-cast-strip'),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        decoration: BoxDecoration(
          color: Colors.orange.shade600,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.cast_connected_rounded,
              size: 18,
              color: Colors.white,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                cast.phase == CastPhase.connecting
                    ? '正在连接 · $deviceName'
                    : '正在投播 · $deviceName',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            TextButton(
              onPressed: () =>
                  ref.read(castControllerProvider.notifier).disconnect(),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('断开'),
            ),
          ],
        ),
      ),
    );
  }
}
