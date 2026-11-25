import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/mina_http.dart';

void main() {
  group('MinaCookieJar Domain 属性解析', () {
    final origin = Uri.parse('https://account.xiaomi.com/identity/list');
    final accountUri = Uri.parse(
      'https://account.xiaomi.com/identity/auth/verifyPhone',
    );

    test('Domain=xiaomi.com（无前导点）→ 子域可携带', () {
      final jar = MinaCookieJar();
      jar.absorb(['identity_session=s1; Domain=xiaomi.com; Path=/'], origin);
      expect(
        jar.cookieHeaderFor(accountUri),
        contains('identity_session=s1'),
      );
    });

    test('Domain=.xiaomi.com（带前导点）→ 子域可携带', () {
      final jar = MinaCookieJar();
      jar.absorb(['identity_session=s2; Domain=.xiaomi.com; Path=/'], origin);
      expect(
        jar.cookieHeaderFor(accountUri),
        contains('identity_session=s2'),
      );
    });

    test('无 Domain（host-only）→ 只回原主机，不发他域', () {
      final jar = MinaCookieJar();
      jar.absorb(['hostonly=h1; Path=/'], origin);
      expect(jar.cookieHeaderFor(accountUri), contains('hostonly=h1'));
      expect(
        jar.cookieHeaderFor(Uri.parse('https://api.mina.mi.com/x')),
        isNot(contains('hostonly')),
      );
    });

    test('Domain=xiaomi.com 的 cookie 不发往无关域', () {
      final jar = MinaCookieJar();
      jar.absorb(['identity_session=s3; Domain=xiaomi.com; Path=/'], origin);
      expect(
        jar.cookieHeaderFor(Uri.parse('https://example.com/')),
        isNot(contains('identity_session')),
      );
    });

    test('passToken=EXPIRED 是删除标记：不入罐、不回放', () {
      final jar = MinaCookieJar();
      jar.absorb(['passToken=EXPIRED; Domain=.xiaomi.com; Path=/'], origin);
      expect(jar.value('passToken'), isNull);
      expect(
        jar.cookieHeaderFor(accountUri),
        isNot(contains('passToken')),
      );
    });

    test('先存真值再收到 EXPIRED → 真值被删除', () {
      final jar = MinaCookieJar();
      jar.absorb(['passToken=pt-old; Domain=.xiaomi.com; Path=/'], origin);
      jar.absorb(['passToken=EXPIRED; Domain=.xiaomi.com; Path=/'], origin);
      expect(jar.value('passToken'), isNull);
    });

    test('setCookieValue 跳过 EXPIRED，取后续真值', () {
      expect(
        setCookieValue(
          ['passToken=EXPIRED; Path=/', 'passToken=pt-new; Path=/'],
          'passToken',
        ),
        'pt-new',
      );
      expect(
        setCookieValue(['serviceToken=EXPIRED; Path=/'], 'serviceToken'),
        isNull,
      );
    });
  });
}
