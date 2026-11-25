import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'mina_auth.dart';
import 'mina_client.dart';
import 'mina_http.dart';
import 'xiaomi_token_store.dart';

final xiaomiSecretStoreProvider = Provider<XiaomiSecretStore>((ref) {
  return const FlutterXiaomiSecretStore(FlutterSecureStorage());
});

final xiaomiTokenStoreProvider = Provider<XiaomiTokenStore>((ref) {
  return XiaomiTokenStore(ref.watch(xiaomiSecretStoreProvider));
});

final minaHttpTransportProvider = Provider<MinaHttpTransport>((ref) {
  return DioMinaHttpTransport();
});

final minaAuthProvider = Provider<MinaAuth>((ref) {
  return MinaAuth(
    http: ref.watch(minaHttpTransportProvider),
    tokenStore: ref.watch(xiaomiTokenStoreProvider),
  );
});

final minaClientProvider = Provider<MinaClient>((ref) {
  return MinaClient(
    http: ref.watch(minaHttpTransportProvider),
    auth: ref.watch(minaAuthProvider),
    tokenStore: ref.watch(xiaomiTokenStoreProvider),
  );
});
