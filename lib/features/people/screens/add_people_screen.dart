import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import 'package:bechat/core/utils/error_formatter.dart';
import 'package:bechat/data/models/peer.dart';
import 'package:bechat/providers/chat_providers.dart';
import 'package:bechat/providers/online_providers.dart';
import 'package:bechat/providers/peer_providers.dart';
import 'package:bechat/services/online/people_service.dart';

/// Share your permanent BeChat ID, search someone else's, and manage
/// connection requests. All authorization is enforced by `firestore.rules`;
/// this screen only calls [PeopleService] and shows friendly failures.
class AddPeopleScreen extends ConsumerStatefulWidget {
  const AddPeopleScreen({super.key});

  @override
  ConsumerState<AddPeopleScreen> createState() => _AddPeopleScreenState();
}

class _AddPeopleScreenState extends ConsumerState<AddPeopleScreen> {
  final _searchController = TextEditingController();

  PeopleService get _service => ref.read(peopleServiceProvider);

  late Future<BeChatProfile> _me;
  late Future<List<ConnectionRequest>> _incoming;
  late Future<List<ConnectionRequest>> _sent;
  late Future<List<ConnectionRequest>> _contacts;

  /// My Firebase uid, resolved once from [_me]; only used to pick the
  /// other party's ID on a contact row (either direction).
  String? _myUid;

  BeChatProfile? _searchResult;
  bool _searching = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _me = _service.ensureMyProfile().then((profile) {
      _myUid = profile.uid;
      return profile;
    });
    _reloadLists();
  }

  void _reloadLists() {
    _incoming = _service.incomingRequests();
    // Filtered here, not inline in build(): FutureBuilder re-subscribes when
    // it sees a NEW future object, and an inline `.then` would loop forever.
    _sent = _service.sentRequests().then(
      (rows) => rows.where((r) => r.status != requestAccepted).toList(),
    );
    _contacts = _service.contacts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(_reloadLists);
    await Future.wait([_incoming, _sent, _contacts]);
  }

  Future<void> _search() async {
    final input = _searchController.text.trim();
    if (input.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _searchResult = null;
    });
    try {
      final profile = await _service.searchPublicId(input);
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchResult = profile;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchResult = null;
      });
      _snack(describeErrorForUser(error));
    }
  }

  Future<void> _sendRequest(BeChatProfile target) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await _service.sendRequest(target);
      if (!mounted) return;
      setState(() {
        _sending = false;
        _searchResult = null;
      });
      _searchController.clear();
      _snack('Request sent to ${target.displayName}.');
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _sending = false);
      _snack(describeErrorForUser(error));
    }
  }

  Future<void> _respond(ConnectionRequest request, String status) =>
      _guard(() => _service.respond(request, status));

  Future<void> _remove(ConnectionRequest request) =>
      _guard(() => _service.removeRequest(request));

  /// Opens the accepted contact's conversation in the existing chat UI,
  /// creating the local peer/chat rows on first use. Online messages are
  /// stored under that same chat by `TransportManager`.
  Future<void> _openChat(ConnectionRequest request) async {
    final myUid = _myUid;
    if (myUid == null) {
      _snack('Your BeChat ID is still loading. Try again in a moment.');
      return;
    }
    final other = request.otherParty(myUid);
    if (other.deviceId.isEmpty) {
      _snack('That contact has no registered device yet.');
      return;
    }
    try {
      final existing = await ref
          .read(peerRepositoryProvider)
          .getPeerByPeerId(other.deviceId);
      // Never rename a peer that already exists (e.g. from a BLE handshake).
      final peer =
          existing ??
          Peer(
            peerId: other.deviceId,
            displayName: other.publicId,
            deviceName: '',
          );
      if (existing == null) {
        await ref.read(peerListProvider.notifier).savePeer(peer);
      }
      final chat = await ref
          .read(chatRepositoryProvider)
          .getOrCreateChatForPeer(peer);
      await ref.read(chatListProvider.notifier).refreshChats();
      if (!mounted) return;
      context.push('/chat/${chat.chatId}');
    } catch (error) {
      _snack(describeErrorForUser(error));
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
      await _refresh();
    } catch (error) {
      _snack(describeErrorForUser(error));
    }
  }

  Future<void> _copyId(String publicId) async {
    await Clipboard.setData(ClipboardData(text: publicId));
    _snack('BeChat ID copied.');
  }

  Future<void> _shareId(String publicId) async {
    try {
      await SharePlus.instance.share(
        ShareParams(text: 'Add me on BeChat — my ID is $publicId'),
      );
    } catch (error) {
      _snack(describeErrorForUser(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Add People')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _myIdCard(theme),
            const SizedBox(height: 20),
            Text('Find someone', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _searchField(theme),
            if (_searchResult != null) ...[
              const SizedBox(height: 12),
              _searchResultCard(theme, _searchResult!),
            ],
            const SizedBox(height: 20),
            _section(
              'Incoming',
              _incoming,
              (request) => _requestRow(
                theme,
                label: request.requesterPublicId,
                subtitle: 'Wants to connect',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: _sending
                          ? null
                          : () => _respond(request, requestAccepted),
                      child: const Text('Accept'),
                    ),
                    TextButton(
                      onPressed: _sending
                          ? null
                          : () => _respond(request, requestDeclined),
                      child: const Text('Decline'),
                    ),
                  ],
                ),
              ),
            ),
            _section(
              'Sent',
              _sent,
              (request) => _requestRow(
                theme,
                label: request.recipientPublicId,
                subtitle: request.status == requestDeclined
                    ? 'Declined'
                    : 'Awaiting reply',
                trailing: TextButton(
                  onPressed: _sending
                      ? null
                      : () => _remove(request),
                  child: Text(
                    request.status == requestDeclined ? 'Remove' : 'Cancel',
                  ),
                ),
              ),
            ),
            _section(
              'Contacts',
              _contacts,
              (request) => _requestRow(
                theme,
                label: _otherPublicId(request),
                subtitle: 'Connected',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: _sending ? null : () => _openChat(request),
                      child: const Text('Message'),
                    ),
                    TextButton(
                      onPressed: _sending ? null : () => _remove(request),
                      child: const Text('Remove'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _otherPublicId(ConnectionRequest request) {
    final myUid = _myUid;
    if (myUid == null) return request.requesterPublicId;
    return request.otherParty(myUid).publicId;
  }

  Widget _myIdCard(ThemeData theme) {
    return FutureBuilder<BeChatProfile>(
      future: _me,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(describeErrorForUser(snapshot.error!)),
                  TextButton(
                    onPressed: () => setState(() {
                      _me = _service.ensureMyProfile().then((profile) {
                        _myUid = profile.uid;
                        return profile;
                      });
                    }),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        final profile = snapshot.data!;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your BeChat ID', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                SelectableText(
                  profile.publicId,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  profile.displayName,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.hintColor),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => _copyId(profile.publicId),
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => _shareId(profile.publicId),
                      icon: const Icon(Icons.share, size: 18),
                      label: const Text('Share'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _searchField(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchController,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.search,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: 'BC-7K9P-42MX',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _searching ? null : _search,
          child: _searching
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Find'),
        ),
      ],
    );
  }

  Widget _searchResultCard(ThemeData theme, BeChatProfile profile) {
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(profile.displayName, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              profile.publicId,
              style: theme.textTheme.bodyMedium?.copyWith(letterSpacing: 1),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _sending ? null : () => _sendRequest(profile),
              icon: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.person_add, size: 18),
              label: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(
    String title,
    Future<List<ConnectionRequest>> future,
    Widget Function(ConnectionRequest request) row,
  ) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        FutureBuilder<List<ConnectionRequest>>(
          future: future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  describeErrorForUser(snapshot.error!),
                  style: theme.textTheme.bodySmall,
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            final rows = snapshot.data!;
            if (rows.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'None right now.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
              );
            }
            return Column(children: rows.map(row).toList());
          },
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _requestRow(
    ThemeData theme, {
    required String label,
    required String subtitle,
    required Widget trailing,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        child: Icon(Icons.person, color: theme.colorScheme.onPrimary),
      ),
      title: Text(label, style: const TextStyle(letterSpacing: 1)),
      subtitle: Text(subtitle),
      trailing: trailing,
    );
  }
}
