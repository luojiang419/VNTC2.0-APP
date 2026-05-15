# VNTC 2.0 APP

![VNTC 2.0 APP Cover](docs/screenshots/homepage-cover.png)

English | [简体中文](README.md)

VNTC 2.0 APP is a graphical VNT client focused on practical private networking for real users. On top of the original VNT networking capability, this project integrates room lobby management, chat, direct messaging, remote assistance, diagnostics, and configuration backup/restore into a single desktop experience.

This directory mainly contains source code for customization, development, packaging, and troubleshooting.

## Highlights

- Graphical VNT configuration management instead of long-term command-line usage.
- Dashboard, device status, room lobby, chat, and remote assistance in one client.
- Built-in VNT virtual-IP based remote assistance workflow.
- System tray, auto-start, close behavior, log export, and diagnostics for desktop use.
- Config import/export, default config selection, backup, and restore.
- Simplified Chinese and English interface switching from the Settings page.

## Core Features

### Virtual Networking

- Create and edit VNT configs with a graphical form.
- Default config support and auto-connect on startup.
- Multi-config management and drag-to-reorder.
- Import/export for single configs and full backup/restore support.

### Dashboard

- Connection status, online/offline device count, traffic, latency, and encryption overview.
- Virtual IP, device name, server, NAT type, and protocol related status display.

### Rooms, Lobby, and Direct Messages

- Default public lobby created automatically after joining a network.
- Room creation and room-based collaboration.
- Direct messages with online peers.

### Chat and Remote Assistance

- Text, image, file, and voice-related collaboration entry points.
- Built-in RustDesk runtime for remote assistance.
- Remote assistance based on VNT virtual IP and per-session password workflow.

### Operations and Diagnostics

- System tray integration.
- Close-button behavior control.
- Log viewing, copying, exporting, and cleanup.
- Diagnostic tools for chat and remote assistance scenarios.

## UI Preview

<table>
  <tr>
    <td width="50%" align="center">
      <img src="docs/screenshots/detail-01-dashboard.png" alt="Dashboard" />
      <br />
      <sub>Dashboard</sub>
    </td>
    <td width="50%" align="center">
      <img src="docs/screenshots/detail-02-room.png" alt="Rooms" />
      <br />
      <sub>Rooms, lobby, and chat</sub>
    </td>
  </tr>
  <tr>
    <td width="50%" align="center">
      <img src="docs/screenshots/detail-03-link-status.png" alt="Link Status" />
      <br />
      <sub>Link status and route inspection</sub>
    </td>
    <td width="50%" align="center">
      <img src="docs/screenshots/detail-04-config.png" alt="Config Management" />
      <br />
      <sub>Config management</sub>
    </td>
  </tr>
  <tr>
    <td width="50%" align="center">
      <img src="docs/screenshots/detail-05-settings.png" alt="Settings" />
      <br />
      <sub>Settings and language switch</sub>
    </td>
    <td width="50%" align="center"></td>
  </tr>
</table>

## Build

Install:

- [Flutter](https://docs.flutter.dev/get-started/install)
- [Rust](https://www.rust-lang.org/tools/install)
- `flutter_rust_bridge_codegen` when bridge regeneration is required

Run:

```bash
flutter pub get
flutter run
```

Windows packaging scripts:

- `scripts/build_windows.bat`
- `scripts/build_windows_installer.bat`

## Android Note

The public source tree does not include prebuilt Android `jniLibs` binaries. If you want to build Android packages yourself, regenerate or restore the corresponding Rust `.so` artifacts first.
