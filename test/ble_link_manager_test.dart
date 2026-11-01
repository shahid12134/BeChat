import 'package:bechat/core/ble/ble_link_phase.dart';
import 'package:bechat/services/ble/ble_link_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  BlePeerLink link(String linkId, {String? peerId, BleLinkRole? role}) {
    return BlePeerLink(
      linkId: linkId,
      role: role ?? BleLinkRole.central,
      peerId: peerId,
      createdAt: DateTime.utc(2026, 3, 1),
    );
  }

  group('capacity and duplicates', () {
    test('accepts links up to the configured limit and refuses the next', () {
      final manager = BleLinkManager(maxLinks: 2);
      expect(manager.add(link('a')), isTrue);
      expect(manager.add(link('b')), isTrue);
      expect(manager.isFull, isTrue);

      final overflow = link('c');
      expect(manager.add(overflow), isFalse);
      // The refused link is registered nowhere and its resources are not
      // silently adopted; the caller owns cleanup for the rejected link.
      expect(manager.byLinkId('c'), isNull);
      expect(manager.length, 2);
      expect(overflow.isClosed, isFalse);
    });

    test('the default limit matches the native Noise session capacity', () {
      // bleMaxLinkCount must agree with MAX_SESSIONS in
      // native/crypto_core/src/session.rs so the runtime never accepts a link
      // it could not secure. Both are raised together.
      expect(bleMaxLinkCount, 8);
      expect(BleLinkManager().maxLinks, bleMaxLinkCount);
    });

    test('refuses a second link with the same BLE device address', () {
      final manager = BleLinkManager(maxLinks: 4);
      expect(manager.add(link('aa:bb', peerId: 'peer-1')), isTrue);
      expect(manager.add(link('aa:bb', peerId: 'peer-2')), isFalse);
      expect(manager.length, 1);
      expect(manager.byPeerId('peer-2'), isNull);
    });

    test('refuses a second link that already names a bound peer', () {
      final manager = BleLinkManager(maxLinks: 4);
      expect(manager.add(link('a', peerId: 'peer-1')), isTrue);
      expect(manager.add(link('b', peerId: 'peer-1')), isFalse);
      expect(manager.byPeerId('peer-1')!.linkId, 'a');
    });
  });

  group('peer binding', () {
    test('bindPeer indexes the link for lookup once the identity is known', () {
      final manager = BleLinkManager(maxLinks: 4);
      final incoming = link('central-1');
      expect(manager.add(incoming), isTrue);
      expect(manager.byPeerId('peer-1'), isNull);

      expect(manager.bindPeer(incoming, 'peer-1'), isTrue);
      expect(manager.byPeerId('peer-1'), same(incoming));
      expect(manager.hasPeer('peer-1'), isTrue);
    });

    test('bindPeer refuses to steal a peer already bound to another link', () {
      final manager = BleLinkManager(maxLinks: 4);
      final first = link('a', peerId: 'peer-1');
      final second = link('b');
      expect(manager.add(first), isTrue);
      expect(manager.add(second), isTrue);

      expect(manager.bindPeer(second, 'peer-1'), isFalse);
      // The first link keeps the peer; the second stays unbound.
      expect(manager.byPeerId('peer-1'), same(first));
      expect(second.peerId, isNull);
    });

    test('bindPeer refuses a link that was removed or closed', () {
      final manager = BleLinkManager(maxLinks: 4);
      final incoming = link('central-1');
      expect(manager.add(incoming), isTrue);
      manager.remove(incoming);

      expect(manager.bindPeer(incoming, 'peer-1'), isFalse);
      expect(manager.byPeerId('peer-1'), isNull);
    });
  });

  group('independent teardown', () {
    test('removing one link leaves the others fully intact', () {
      final manager = BleLinkManager(maxLinks: 4);
      final a = link('a', peerId: 'peer-a');
      final b = link('b', peerId: 'peer-b');
      final c = link('c', peerId: 'peer-c');
      manager
        ..add(a)
        ..add(b)
        ..add(c);

      manager.remove(b);

      expect(manager.length, 2);
      expect(manager.byLinkId('b'), isNull);
      expect(manager.byPeerId('peer-b'), isNull);
      // The removed link is released; the survivors are untouched.
      expect(b.isClosed, isTrue);
      expect(a.isClosed, isFalse);
      expect(c.isClosed, isFalse);
      expect(manager.byPeerId('peer-a'), same(a));
      expect(manager.byPeerId('peer-c'), same(c));
    });

    test('removing an unknown link is a no-op', () {
      final manager = BleLinkManager(maxLinks: 4);
      final a = link('a', peerId: 'peer-a');
      manager.add(a);

      // A link id that was never registered changes nothing.
      expect(manager.remove(link('ghost')), isNull);
      expect(manager.length, 1);
      expect(a.isClosed, isFalse);
    });

    test('a removed link frees its slot for a new connection', () {
      final manager = BleLinkManager(maxLinks: 2);
      final a = link('a', peerId: 'peer-a');
      final b = link('b', peerId: 'peer-b');
      manager
        ..add(a)
        ..add(b);
      expect(manager.isFull, isTrue);

      manager.remove(a);
      expect(manager.isFull, isFalse);
      expect(manager.add(link('c', peerId: 'peer-c')), isTrue);
      expect(manager.length, 2);
    });

    test('removeAll releases every link and empties the registry', () {
      final manager = BleLinkManager(maxLinks: 4);
      final links = [link('a', peerId: 'peer-a'), link('b', peerId: 'peer-b')];
      for (final l in links) {
        manager.add(l);
      }

      final removed = manager.removeAll();

      expect(removed, hasLength(2));
      expect(manager.isEmpty, isTrue);
      expect(manager.byPeerId('peer-a'), isNull);
      for (final l in links) {
        expect(l.isClosed, isTrue);
      }
    });
  });

  group('link snapshots', () {
    test('states only includes links with a known peer identity', () {
      final manager = BleLinkManager(maxLinks: 4);
      manager
        ..add(link('a', peerId: 'peer-a'))
        ..add(link('connecting-central')); // no peerId yet: not published

      final states = manager.states(now: DateTime.utc(2026, 3, 2));

      expect(states, hasLength(1));
      expect(states.single.peerId, 'peer-a');
    });
  });
}
