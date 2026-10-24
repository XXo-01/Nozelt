import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/routing_rule.dart';

void main() {
  test('normalizes suffix and emits IPv6 CIDR safely', () {
    const suffix = RoutingRule(
      id: 'suffix',
      type: RoutingRuleType.domainSuffix,
      value: '*.Example.COM',
      action: RoutingRuleAction.proxy,
    );
    const ipv6 = RoutingRule(
      id: 'ipv6',
      type: RoutingRuleType.ipCidr,
      value: '2001:db8::/32',
      action: RoutingRuleAction.direct,
    );

    expect(suffix.validate(), isNull);
    expect(suffix.toMihomoRule('PROXY'), 'DOMAIN-SUFFIX,example.com,PROXY');
    expect(ipv6.toMihomoRule('PROXY'), 'IP-CIDR6,2001:db8::/32,DIRECT');
  });

  test('accepts pasted URLs, international domains and single IPs', () {
    String normalize(RoutingRuleType type, String value) =>
        RoutingRule.normalizeRuleValue(type, value);

    expect(
      normalize(RoutingRuleType.domain, 'https://www.YouTube.com/watch?v=1'),
      'www.youtube.com',
    );
    expect(
      normalize(RoutingRuleType.domain, 'example.com:8443'),
      'example.com',
    );
    expect(
      normalize(RoutingRuleType.domainSuffix, '.example.com.'),
      'example.com',
    );
    expect(
      normalize(RoutingRuleType.domainSuffix, 'госуслуги.рф'),
      'xn--c1aapkosapc.xn--p1ai',
    );
    expect(
      normalize(RoutingRuleType.domain, 'Пример.РФ'),
      'xn--e1afmkfd.xn--p1ai',
    );
    expect(
      normalize(RoutingRuleType.domain, 'münchen.de'),
      'xn--mnchen-3ya.de',
    );
    expect(normalize(RoutingRuleType.ipCidr, '203.0.113.7'), '203.0.113.7/32');
    expect(normalize(RoutingRuleType.ipCidr, '2001:db8::1'), '2001:db8::1/128');
    expect(
      const RoutingRule(
        id: 'idn',
        type: RoutingRuleType.domainSuffix,
        value: 'https://яндекс.рф/',
        action: RoutingRuleAction.direct,
      ).validate(),
      isNull,
    );
  });

  test('rejects config injection and invalid CIDR prefixes', () {
    const injected = RoutingRule(
      id: 'bad',
      type: RoutingRuleType.domain,
      value: 'example.com,DIRECT\nMATCH',
      action: RoutingRuleAction.proxy,
    );
    const badCidr = RoutingRule(
      id: 'cidr',
      type: RoutingRuleType.ipCidr,
      value: '10.0.0.0/99',
      action: RoutingRuleAction.direct,
    );

    expect(injected.validate(), isNotNull);
    expect(badCidr.validate(), isNotNull);
  });

  test('emits Windows process rules and rejects path injection', () {
    const process = RoutingRule(
      id: 'process',
      type: RoutingRuleType.processName,
      value: 'Steam.exe',
      action: RoutingRuleAction.direct,
    );
    const path = RoutingRule(
      id: 'path',
      type: RoutingRuleType.processName,
      value: r'C:\Games\Steam.exe',
      action: RoutingRuleAction.direct,
    );

    expect(process.validate(), isNull);
    expect(process.toMihomoRule('PROXY'), 'PROCESS-NAME,steam.exe,DIRECT');
    expect(path.validate(), isNotNull);
  });
}
