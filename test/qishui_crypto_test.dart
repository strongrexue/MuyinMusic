import 'package:cy_shine_music/core/sdk/qishui_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('x-gorgon matches the reference implementation', () {
    const stub = '3ECAA8B28B2DB2D40D2456CA3DAD152A';
    expect(
      QishuiSdk.gorgonVector(
        query: 'a=1&b=2',
        stub: stub,
        rticket: '1700000000123',
        pointer: 0x1230,
      ),
      '8404301204044c1b00bafdef9194b4f73bce38c460631fe0a3ec',
    );
    expect(
      QishuiSdk.gorgonVector(
        query: 'a=1&b=2',
        stub: stub,
        rticket: '1700000000123',
        pointer: 0,
      ),
      '840400000404ffdabd0951d2b5e08dbe93cc69fce41ef43c54cd',
    );
  });
}
