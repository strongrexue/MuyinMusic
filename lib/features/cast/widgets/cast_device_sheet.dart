import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cast_session.dart';

/// Device picker for DLNA casting: 本机 pinned first (tapping it while
/// casting disconnects), then the renderers found on the LAN.
class CastDeviceSheet extends ConsumerStatefulWidget {
  const CastDeviceSheet({super.key});

  @override
  ConsumerState<CastDeviceSheet> createState() => _CastDeviceSheetState();
}

class _CastDeviceSheetState extends ConsumerState<CastDeviceSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(castControllerProvider.notifier).startSearch();
    });
  }

  @override
  void dispose() {
    ref.read(castControllerProvider.notifier).stopSearch();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cast = ref.watch(castControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final controller = ref.read(castControllerProvider.notifier);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
              child: Row(
                children: [
                  Text(
                    '投播到设备',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  if (cast.searching)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.refresh_rounded, size: 20),
                      tooltip: '重新搜索',
                      onPressed: controller.startSearch,
                    ),
                ],
              ),
            ),
            if (cast.phase == CastPhase.failed && cast.errorMessage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  cast.errorMessage!,
                  style: TextStyle(color: scheme.error, fontSize: 13),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.smartphone_rounded),
              title: const Text('本机'),
              subtitle: Text(cast.isCasting ? '将播放切回本机' : '正在本机播放'),
              trailing: cast.isCasting
                  ? null
                  : Icon(Icons.check_rounded, color: scheme.primary),
              onTap: () {
                if (cast.isCasting) {
                  controller.disconnect();
                }
                Navigator.of(context).pop();
              },
            ),
            const Divider(height: 1),
            if (cast.devices.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                child: Text(
                  cast.searching
                      ? '正在搜索局域网内的投播设备…'
                      : '未发现设备，请确认设备与手机连接在同一局域网后重试。',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              )
            else
              ...cast.devices.map((device) {
                final connected =
                    cast.isCasting && cast.device?.udn == device.udn;
                final connecting =
                    cast.phase == CastPhase.connecting &&
                    cast.device?.udn == device.udn;
                return ListTile(
                  leading: const Icon(Icons.speaker_rounded),
                  title: Text(device.friendlyName),
                  subtitle: Text(device.subtitle),
                  trailing: connecting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : connected
                      ? Icon(Icons.check_rounded, color: scheme.primary)
                      : null,
                  onTap: () {
                    controller.connect(device);
                    Navigator.of(context).pop();
                  },
                );
              }),
          ],
        ),
      ),
    );
  }
}
