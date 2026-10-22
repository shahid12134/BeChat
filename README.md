# BeChat

**An offline peer-to-peer messaging framework using direct BLE, with future
Wi-Fi Direct and adaptive cloud switching.**

## Current Status

**Phase 2: Direct Offline BLE Text Messaging.** BeChat can advertise, scan,
connect, exchange application identities over a GATT link, and send text
messages of up to 4096 UTF-8 bytes between two Android phones.
Unknown inbound devices must be approved before a link is usable, and the
Nearby screen includes a persistent **Allow New Connections** switch. Delivery
is acknowledged end-to-end with an application ACK; messages remain queued
until the intended peer is connected and acknowledges them.

A persistent **BeChat availability** control is available from the Chats and
Nearby app bars. Turning it on verifies Android Bluetooth and permissions before
BeChat advertises; turning it off stops scanning and advertising, closes active
links, and clears runtime state without deleting chats or peers. The Nearby
screen uses a manual scan with a 15-second timeout, retains candidates across a
refresh, and expires stale discovery hints after about 10 seconds.

An optional Android **Background messaging** setting keeps BeChat available for
nearby messages while the app is minimized, using a visible foreground-service
notification. It requires notification permission and does not guarantee
delivery if Android stops the app process. This phase does **not** provide
message encryption, cryptographic peer authentication, delivery after
force-stop or process death, multi-hop mesh routing, store-and-forward relay, or
cloud fallback.

---

## Project Overview

BeChat is a Flutter Android application designed for offline-first
peer-to-peer messaging. The architecture supports future phases where:

- **Phase 2:** Direct BLE discovery, GATT connection, and acknowledged text
  messaging (current)
- **Phase 3:** Peer authentication and encrypted messaging
- **Phase 4:** Wi-Fi Direct transfer
- **Phase 5:** Store-and-forward relay and multi-hop routing
- **Phase 6:** Firebase cloud fallback and hybrid routing

---

## Architecture

```
lib/
  main.dart                          # App entry point
  app/
    app.dart                         # MaterialApp widget
    app_messenger.dart               # Global scaffold messenger for service errors
    bootstrap_host.dart              # Database/identity bootstrap and retry UI
    theme/
      app_theme.dart                 # Light/dark themes, colors
    routes/
      app_router.dart                # GoRouter navigation
  core/
    ble/
      ble_protocol.dart              # Frame/transfer codecs, HELLO, payloads
      ble_transport.dart             # Bidirectional byte transport interface
      ble_link_session.dart          # Handshake, framing, ACK, send/receive
    constants/
      app_constants.dart             # App-wide constants
    utils/
      date_utils.dart                # Date formatting utilities
    widgets/
      ble_availability_button.dart   # Shared BeChat on/off app-bar control
      empty_state.dart               # Empty state widget
      avatar_widget.dart             # Peer avatar with initials
      status_indicator.dart          # Transport status indicator
  data/
    database/
      database_helper.dart           # SQLite database initialization
    models/
      app_settings.dart              # Persistent application preferences
      peer.dart                      # Peer data model
      chat.dart                      # Chat data model
      message.dart                   # Message data model
      attachment.dart                # Attachment data model
      identity.dart                  # Device identity model
      message_route.dart             # Future routing model
      ble_candidate.dart             # Nearby BLE discovery hint
    repositories/
      app_data_repository.dart       # Transactional user-data clearing
      app_settings_repository.dart   # Persistent application preferences
      peer_repository.dart           # Peer CRUD operations
      chat_repository.dart           # Chat CRUD operations
      message_repository.dart        # Message CRUD + BLE delivery states
      identity_repository.dart       # Identity bootstrap and legacy repair
      peer_discovery_repository.dart # Phase 1 demo discovery interface
      mock_peer_discovery_repository.dart # Demo-only simulated discovery
      unavailable_peer_discovery_repository.dart # Non-demo demo state
    mock/
      mock_data.dart                 # Demo data seeder
  services/
    background/
      background_ble_service.dart    # Dart bridge to Android background service
      background_action_coordinator.dart # Notification action routing
    ble/
      ble_runtime.dart               # Android permissions, GATT, links, UI state
      ble_message_store.dart         # Atomic incoming message persistence
      ble_outbox.dart                # Queued delivery and bounded retries
      incoming_connection_policy.dart # Inbound peer approval decisions
      incoming_connection_request.dart # Pending approval request model
  providers/
    app_settings_providers.dart      # Persistent application settings state
    background_service_provider.dart # Android background bridge provider
    ble_providers.dart               # BLE runtime state provider
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
      widgets/incoming_request_dialog.dart # Incoming connection prompt
      widgets/peer_list_item.dart    # Peer list item widget
    settings/
      screens/settings_screen.dart   # App settings/info
android/app/src/main/kotlin/com/bechat/bechat/
  MainActivity.kt                    # Flutter host, BLE status, intent routing
  BackgroundBleBridge.kt             # Channel, permissions, queued events
  BeChatForegroundService.kt         # Visible Android foreground service
  BackgroundNotifications.kt         # Service/message/request notifications
  BackgroundActionReceiver.kt        # Accept/decline/block notification actions
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
| `app_settings` | Persistent application preferences |

### Key Features

- Foreign key constraints enabled
- Indexes on frequently queried columns (chat_id, timestamp, peer_id, route status)
- Versioned schema with migration support (current version: 3)
- Repository pattern for clean data access

### Persistent Application Settings

Database version 3 adds an `app_settings` key/value table. Settings are read
through typed repository methods and survive application restarts.

| Setting | Default | Purpose |
|---------|---------|---------|
| `ble_enabled` | `false` | Intended BeChat BLE availability preference |
| `allow_new_connections` | `true` | Permit requests from previously unknown peers |
| `background_ble_enabled` | `false` | Opt-in preference for Android background messaging |
| `message_previews_enabled` | `false` | Whether message notifications include message text |

`ble_enabled` is the user's intended BeChat availability preference. On startup,
BeChat reconciles it with the actual Android adapter and permission state before
advertising; the preference alone never proves that BLE is operational.
`allow_new_connections` is enforced for unknown inbound peers.
`background_ble_enabled` is saved only after Android notification permission and
background-service checks succeed. It never enables BeChat availability by
itself, and a saved preference does not prove the foreground service is running.
Sender names are always shown in message notifications; message text is shown
only when `message_previews_enabled` is on.

---

## Dependencies

| Package | Purpose |
|---------|---------|
| `flutter_riverpod` | State management |
| `go_router` | Navigation/routing |
| `sqflite` | Local SQLite database |
| `uuid` | Unique ID generation |
| `intl` | Date formatting |
| `bluetooth_low_energy` `6.2.1` | Android BLE central and peripheral roles |

---

## How to Run on a Physical Android Device

### Prerequisites

1. **Flutter SDK** installed (3.35.4+)
2. **Android SDK** installed with:
   - Android SDK Platform 36
   - Android SDK Build-Tools
   - Android NDK 27.1.12297006
   - Android SDK Platform-Tools
3. **Two physical Android phones** with:
   - Android 7.0+ (API 24+)
   - BLE hardware
    - USB Debugging enabled
    - Bluetooth turned on
    - BeChat turned on; background messaging is optional after enabling it on
      each phone

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
cd C:\Projects\BeChat
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

## Direct BLE Text Messaging

BeChat is off by default. Once turned on, both phones advertise the BeChat GATT
service and can scan for it. The app uses the standard BLE central and
peripheral roles at the same time, so either phone can initiate a connection.

1. Install the same build on both phones and open BeChat on both.
2. Tap the Bluetooth availability icon in the Chats or Nearby app bar to turn
   BeChat on. This does not change the system Bluetooth radio.
3. Grant the Android **Nearby devices** permission when prompted. Android 11
   and earlier also require location permission for BLE scanning. If Bluetooth
   is off, enable it in Android settings as prompted, then retry.
4. Open **Nearby** and tap **Scan** on both phones. Scanning stops automatically
   after 15 seconds; tap **Scan** again to refresh. Recently seen devices remain
   visible for about 10 seconds.
5. Tap a discovered BeChat device on one phone.
6. Wait for the GATT connection and application HELLO handshake. A saved peer
   reconnects directly; an unknown peer triggers a connection request dialog on
   the receiving phone.
7. On the receiving phone, choose **Accept**, **Decline**, or **Block**. The
   peer is saved only after acceptance and is then shown in **Saved Peers**.
8. Open the peer's chat and send text.

### Incoming Connection Approval

- **Allow New Connections** in Nearby defaults to on and persists across
  restarts. Turning it off rejects unknown inbound peers but still allows
  saved, unblocked peers to reconnect. Turning BeChat itself off overrides this
  setting and closes all links.
- A request expires after 30 seconds. Declining rejects the link and suppresses
  new prompts from that device for about 60 seconds. The cooldown is in memory
  only.
- Blocking an unknown requester saves a blocked peer record, so later HELLO
  attempts are rejected and the existing block/unblock flow still applies.
- Messages received before approval receive a transient rejected ACK and are
  not stored. The sender keeps the message queued and retries during the
  30-second approval window instead of marking it permanently failed.
- Request dialogs are disabled for barrier/back dismissal, but the request can
  expire or be cancelled by turning new connections off.
- The pending request is not persisted, marked online, or shown as an approved
  peer before acceptance.
- Device names and IDs come from the other phone. They are not
  cryptographically authenticated, and a device can present a different ID.
  Blocking is an application-level control, not a cryptographic ban.

Delivery behavior:

- Outgoing messages are saved locally as `queued` before transmission.
- `sent` means every BLE frame was written; it is not proof of receipt.
- `delivered` requires an application ACK from the peer.
- If the link drops or an ACK times out, the message is returned to the outbox.
  Ordinary retries are bounded; connection-approval retries continue only
  until the pending request expires.
- Messages for another peer remain queued while a different peer is connected.
- Incoming messages are stored atomically. Duplicate message IDs are
  acknowledged as duplicates without creating a second message or unread count.
- Blocked peers are rejected during HELLO and incoming-message validation.

BLE IDs from advertisements are discovery hints. The stable BeChat application
device ID is exchanged in HELLO. Neither the BLE address nor the application ID
is cryptographically authenticated in this phase.

### Fixed GATT Profile

| Item | UUID |
|------|------|
| BeChat service | `6f1b8e30-6c4a-4f4f-9f4c-424543484100` |
| RX (central writes) | `6f1b8e30-6c4a-4f4f-9f4c-424543484101` |
| TX (peripheral notifies) | `6f1b8e30-6c4a-4f4f-9f4c-424543484102` |

The protocol uses a 10-byte big-endian frame header, start/data/end framing,
and an FNV-1a checksum. The checksum detects accidental corruption only; it is
not a cryptographic integrity mechanism.

---

## Background Messaging

Background messaging is opt-in and Android-only. Open **Settings > Background**
and turn on **Background messaging**. BeChat explains the Android battery
limits, requests notification permission, and starts an Android foreground
service only after BeChat availability, Bluetooth, and notification checks
succeed. The persistent service notification is required by Android.

While background mode is active and BeChat is minimized:

- Existing links and advertising remain available, but manual nearby discovery
  stops. BeChat does not continuously scan in the background.
- New messages are stored before an ACK or notification is produced. Message
  notifications show the sender name, but show only `New message` unless
  **Message previews** is enabled. Duplicate message IDs do not create duplicate
  notifications.
- Unknown connection requests appear as high-priority notifications with
  **Accept**, **Decline**, and **Block** actions. The action carries the exact
  request ID and is processed by the Dart runtime; stale or expired actions fail
  safely. Tapping the notification opens BeChat rather than launching a dialog
  over another app.
- Tapping a message notification opens the corresponding chat.

Turning background mode off stops the service and cancels its connection-request
notification. Turning BeChat availability off also stops background operation.
Restarting BeChat reconciles the saved preference with the actual notification
permission and service state.

A foreground service does **not** keep Flutter or Dart alive forever. Android may
stop the process for battery, memory, or user force-stop reasons. BeChat does not
restart itself after process death and does not claim guaranteed background
delivery. On some device vendors, additional battery settings may be required.

The native implementation only hosts the foreground service and notifications;
the Dart BLE runtime remains the single owner of scanning, advertising, and GATT.
No second Kotlin BLE stack is used.

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

These are not real Bluetooth devices. Demo mode remains separate from the
real BLE runtime: it never starts scanning or advertising and does not produce
fake entries in the real BLE nearby list. With demo mode disabled, the Nearby
screen uses real BLE discovery only.

Demo seeding does not create or replace the real local identity. It runs only when demo mode is enabled and the peers table is empty, so repeated startup does not duplicate records.

To remove demo data, open **Settings > Debug Information > Clear Database**. This deletes peers, chats, messages, attachments, and routing records while keeping the local identity and application settings. If demo mode remains enabled, sample data may be seeded again on a later startup when the peers table is empty.

---

## What is NOT Implemented

The following belong to future phases:

- Message encryption or cryptographic peer authentication
- Key generation, verification, or out-of-band identity comparison
- Guaranteed background delivery after process death or force-stop
- More than one simultaneous BLE link
- Wi-Fi Direct
- Store-and-forward relay
- Multi-hop or TTL routing
- Firebase authentication or Cloud Messaging
- Cloud synchronization or automatic P2P/cloud switching
- Media/file transfer
- Production security hardening

### Phase 2 Limitations

- Text only, with a maximum of 4096 UTF-8 bytes per message.
- BeChat must be explicitly turned on. Without background messaging, BLE pauses
  when the app leaves the foreground. With background messaging enabled, Android
  may still stop the app process, so delivery is best-effort rather than
  guaranteed.
- A scan is manual and stops after 15 seconds. Nearby candidates are ephemeral
  discovery hints that expire after about 10 seconds. Background mode never
  performs continuous scanning.
- BLE range, discovery time, and connection reliability depend on the phones
  and radio environment.
- The link is not encrypted and the exchanged identity is not authenticated.
  Anyone nearby with a compatible implementation could attempt to connect.
- Discovery advertises only the display name `BeChat`; the stable application
  ID is revealed after connecting.
- Only one active link is supported. Concurrent connection attempts are
  rejected rather than arbitrated by a cryptographic identity comparison.
- The BLE runtime is enabled for Android only. iOS is not configured in this
  phase.
- The app has not been validated through an automated physical-phone BLE test;
  manual two-device testing is required.

---

## Android Permissions

Declared in `AndroidManifest.xml`:

- `INTERNET` and `ACCESS_NETWORK_STATE` (foundation only)
- Android 11 and below: `BLUETOOTH`, `BLUETOOTH_ADMIN`,
  `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`
- Android 12 and above: `BLUETOOTH_SCAN` (with `neverForLocation`),
  `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE`
- Android 13 and above: `POST_NOTIFICATIONS`, requested only when enabling
  background messaging
- `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_CONNECTED_DEVICE` for the visible
  background service
- `android.hardware.bluetooth_le` is optional so the app can install on devices
  without BLE; runtime BLE use then reports that it is unsupported.

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
- BLE frame codec, transfer framing, reassembly, checksums, and size limits
- HELLO validation, message payload UTF-8 boundaries, and ACKs
- Session handshake, ACK timeout, disconnect handling, and transfer limits
- Outbox transitions, ACK outcomes, requeue behavior, bounded retries, and
  connection-approval retry handling
- Atomic incoming-message persistence, duplicate handling, blocked peers, and
  notification callbacks only for newly stored messages
- Background enable/disable, notification-permission denial, service retention
  while paused, service-failure state, and notification-action routing
- Message notification privacy defaults and preview opt-in
- Persistent BeChat availability reconciliation, serialized toggles, shutdown,
  scan gating, candidate expiration, and app-bar availability states
- Nearby scan prompting, retained candidates, progress, and stop controls
- Bootstrap failure recovery and key widget interactions

Manual BLE validation still requires two physical Android phones; emulator and
unit tests cannot verify radio behavior, GATT interoperability, real throughput,
foreground-service behavior, notification delivery, OEM battery restrictions, or
process-death recovery.

---

## License

University cybersecurity project - academic use only.
