import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/state/node_health_provider.dart';

void main() {
  test('all-node progress is scoped to one profile', () {
    const state = NodeHealthState(
      testingAllProfiles: {'profile-a'},
      testing: {'profile-a\u0000node-a'},
    );

    expect(state.isTestingAll('profile-a'), isTrue);
    expect(state.isTestingAll('profile-b'), isFalse);
    expect(state.isTesting('profile-a', 'node-a'), isTrue);
    expect(state.isTesting('profile-b', 'node-a'), isFalse);
  });
}
