# BeChat

**An Encrypted Offline Peer-to-Peer Messaging Framework using BLE and Wi-Fi Direct with Adaptive Cloud Switching.**

## Current Status

**Phase 1: Local Foundation.** This release provides a unique local identity, safe local SQLite persistence, local chat creation, honest queued message states, and an opt-in simulated discovery mode.

Real BLE discovery, cryptography, pairing, Wi-Fi Direct, cloud messaging, and mesh routing are NOT implemented.

---

## Project Overview

BeChat is a Flutter Android application designed for secure, offline-first peer-to-peer messaging. The architecture supports future phases where:

- **Phase 3:** BLE peer discovery and encrypted messaging
- **Phase 4:** Wi-Fi Direct transfer
- **Phase 5:** Store-and-forward relay, multi-hop routing
- **Phase 6:** Firebase cloud fallback, hybrid routing

---

## Architecture

```
lib/
  main.dart                          # App entry point
  app/
    app.dart                         # MaterialApp widget
    bootstrap_host.dart              # Database/identity bootstrap and retry UI
    theme/
      app_theme.dart                 # Light/dark themes, colors
    routes/
      app_router.dart                # GoRouter navigation
  core/
    constants/
      app_constants.dart             # App-wide constants
    utils/
      date_utils.dart                # Date formatting utilities
    widgets/
      empty_state.dart               # Empty state widget
      avatar_widget.dart             # Peer avatar with initials
      status_indicator.dart          # Transport status indicator
  data/
    database/
      database_helper.dart           # SQLite database initialization
    models/
      peer.dart                      # Peer data model
      chat.dart                      # Chat data model
      message.dart                   # Message data model
      attachment.dart                # Attachment data model
      identity.dart                  # Device identity model
      message_route.dart             # Future routing model
    repositories/
      app_data_repository.dart       # Transactional user-data clearing
      peer_repository.dart           # Peer CRUD operations
      chat_repository.dart           # Chat CRUD operations
      message_repository.dart        # Message CRUD operations
      identity_repository.dart       # Identity bootstrap and legacy repair
      peer_discovery_repository.dart # Abstract discovery interface
      mock_peer_discovery_repository.dart # Demo-only simulated discovery
      unavailable_peer_discovery_repository.dart # Non-demo discovery state
    mock/
      mock_data.dart                 # Demo data seeder
  providers/
    chat_providers.dart              # Chat state management
    peer_providers.dart              # Peer state management
    message_providers.dart           # Message state management
    settings_providers.dart          # Settings/identity state management
  features/
    home/
      screens/home_screen.dart       # Main screen with bottom nav
    chats/
      screens/chat_list_screen.dart  # Conversation list
      screens/chat_screen.dart       # Individual chat/messaging
      widgets/chat_list_item.dart    # Chat list item widget
    peers/
      screens/peer_discovery_screen.dart # Nearby peers scan
      screens/peer_details_screen.dart   # Peer info/pairing UI
      widgets/peer_list_item.dart    # Peer list item widget
    settings/
      screens/settings_screen.dart   # App settings/info
```

---

## SQLite Database Schema

### Tables

| Table | Purpose |
|-------|---------|
| `identity` | Local device identity |
| `peers` | Known peers (discovered devices) |
| `chats` | Conversation threads |
| `messages` | Individual messages |
| `attachments` | File attachment metadata |
| `message_routes` | Future store-and-forward routing |

### Key Features

- Foreign key constraints enabled
- Indexes on frequently queried columns (chat_id, timestamp, peer_id, route status)
- Versioned schema with migration support
- Repository pattern for clean data access

---

## Dependencies

| Package | Purpose |
|---------|---------|
| `flutter_riverpod` | State management |
| `go_router` | Navigation/routing |
| `sqflite` | Local SQLite database |
| `uuid` | Unique ID generation |
| `intl` | Date formatting |

---

## How to Run on a Physical Android Device

### Prerequisites

1. **Flutter SDK** installed (3.35.4+)
2. **Android SDK** installed with:
   - Android SDK Platform 35
   - Android SDK Build-Tools
   - Android NDK 27.1.12297006
   - Android SDK Platform-Tools
3. **Physical Android phone** with:
   - Android 8.0+ (API 26+)
   - USB Debugging enabled

### Setup Steps

#### 1. Enable Developer Options on Your Phone

1. Go to **Settings > About Phone**
2. Tap **Build Number** 7 times until "You are now a developer" appears
3. Go back to **Settings > Developer Options**
4. Enable **USB Debugging**

#### 2. Connect Your Phone

1. Connect the phone via USB cable
2. On the phone, tap **Allow** when prompted for USB debugging
3. Verify the connection:

```bash
flutter devices
```

You should see your device listed.

#### 3. Build and Run

```bash
cd Bechat
flutter pub get
flutter run
```

Or build an APK:

```bash
flutter build apk --debug
# APK at: build/app/outputs/flutter-apk/app-debug.apk
```

Install manually:

```bash
adb install build/app/outputs/flutter-apk/app-debug.apk
```

---

## Demo Mode and Simulated Peers

Demo mode is disabled by default. Ordinary startup creates only the local identity and does not seed peers, chats, or messages.

Enable simulated discovery and sample data explicitly:

```bash
flutter run --dart-define=BECHAT_DEMO_DATA=true
flutter build apk --debug --dart-define=BECHAT_DEMO_DATA=true
```

With demo mode enabled, the Nearby screen is labeled as simulated and can discover:

- **Alice** - "Alice's Phone" (Online, -45 dBm)
- **Rahul** - "Rahul's Phone" (Online, -62 dBm)
- **BeChat Lab Device** - (Offline, -78 dBm)
- **Cyber Lab** - (Online, -55 dBm)
- **Maria** - "Maria's Phone" (Offline, -88 dBm)

These are not real Bluetooth devices. In Phase 2, a real `PeerDiscoveryRepository` implementation will replace the mock.

Demo seeding does not create or replace the real local identity. It runs only when demo mode is enabled and the peers table is empty, so repeated startup does not duplicate records.

To remove demo data, open **Settings > Debug Information > Clear Database**. This deletes peers, chats, messages, attachments, and routing records while keeping the local identity. If demo mode remains enabled, sample data may be seeded again on a later startup when the peers table is empty.

---

## What is NOT Implemented

The following belong to future phases:

- BLE scanning/advertising/messaging
- Public-key cryptography (RSA/ECC)
- AES message encryption
- Cryptographic key generation/exchange
- Wi-Fi Direct
- Socket communication
- Store-and-forward relay
- Multi-hop routing
- TTL routing logic
- Firebase authentication
- Firebase Cloud Messaging
- Cloud synchronization
- Automatic P2P/cloud switching
- Real media/file transfer
- Production security implementation

---

## Future Phase 3 Integration

To replace mock discovery with real BLE:

1. Create `BlePeerDiscoveryRepository` implementing `PeerDiscoveryRepository`
2. Register it as a Riverpod provider
3. Update `peerDiscoveryRepositoryProvider` in `peer_providers.dart`

```dart
// peer_providers.dart
final peerDiscoveryRepositoryProvider = Provider<PeerDiscoveryRepository>((ref) {
  // Replace with: return BlePeerDiscoveryRepository();
  return MockPeerDiscoveryRepository();
});
```

---

## Android Permissions

Currently configured:

- `INTERNET` (future use)
- `ACCESS_NETWORK_STATE` (connectivity checks)

Future BLE permissions are documented in `AndroidManifest.xml` but commented out.

---

## Testing

```bash
flutter test          # Run all tests
flutter analyze       # Check for issues
```

Tests cover:
- Identity creation, persistence, legacy placeholder repair, and rollback
- Peer/chat/message repository safety, ordering, transactions, and foreign keys
- User-data clearing while retaining identity
- Queued message behavior and sender detection
- Demo-mode gating and simulated peer persistence
- Bootstrap failure recovery and key widget interactions

---

## License

University cybersecurity project - academic use only.
