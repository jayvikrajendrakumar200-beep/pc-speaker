# PC Speaker - Stream PC Audio to iPhone 🎵

Use your iPhone 11 as a wireless speaker for your Windows PC. Stream system audio over WiFi **or USB**, and optionally use your iPhone's microphone as a PC input device.

## ✨ Features

- 🎵 **High-quality audio streaming** (Opus 96kbps, ~200ms latency)
- 📶 **WiFi mode** - Connect over local network
- 🔌 **USB mode** - No WiFi needed, works over Lightning cable
- 🎤 **Microphone pass-through** - Use iPhone mic on PC (Discord, Zoom, etc.)
- 📱 **Background playback** - Audio continues when app is backgrounded
- 🔒 **Free sideloading** - Install with free Apple ID (7-day refresh via AltStore)

---

## 📋 Requirements

### PC (Windows 10/11)
- Python 3.9+
- **Stereo Mix** enabled in Windows Sound settings (see setup below)

### iPhone
- iPhone 11 or newer (iOS 15+)
- Free Apple ID for sideloading

### For USB Mode
- `usbmuxd` Python package (auto-installed)

---

## 🚀 Quick Start

### 1. Get the iPhone App (IPA)

**Option A: Build yourself (recommended)**
```bash
# Fork this repo on GitHub, then:
# 1. Go to Actions tab → "Build iOS App" → Run workflow
# 2. Download `pc-speaker-ipa` artifact
# 3. Or create a tag (v1.0.0) to trigger automatic release
```

**Option B: Download from Releases**
- Check the [Releases page](../../releases) for pre-built IPAs

### 2. Install on iPhone (Windows + AltStore)

1. **Install AltStore on PC:**
   - Download from [altstore.io](https://altstore.io/windows)
   - Install AltStore + iTunes + iCloud (not Microsoft Store versions)

2. **Connect iPhone via USB** → Trust computer on iPhone

3. **In AltStore:** `My Apps` → `+` → Select the `.ipa` file
   - Enter your Apple ID credentials (used only for signing)
   - App installs to iPhone

4. **On iPhone:** Settings → General → VPN & Device Management → Trust your Apple ID

5. **Refresh weekly:** Open AltStore on PC with iPhone connected → "Refresh All"

### 3. Enable "Stereo Mix" on Windows (Required!)

This lets the server capture your PC's system audio.

1. Right-click speaker icon → **Sound settings**
2. Scroll down → **More sound settings** (or Control Panel → Sound)
3. **Recording** tab → Right-click empty space → **Show Disabled Devices**
4. Right-click **Stereo Mix** → **Enable**
5. Right-click **Stereo Mix** → **Set as Default Device**
6. Properties → **Listen** tab → Uncheck "Listen to this device"
7. **Advanced** tab → Set to **24 bit, 48000 Hz (Studio Quality)**

> ⚠️ **No Stereo Mix?** Install [Voicemeeter Banana](https://vb-audio.com/Voicemeeter/) (free). Set Voicemeeter Output as default playback device, then select "Voicemeeter Out B1" as input in the server.

### 4. Run PC Server

```bash
# Install dependencies
pip install sounddevice soundfile websockets numpy opuslib usbmuxd

# Run server (HTTP:8080, WS:8081)
python pc_audio_server.py
```

You should see:
```
HTTP Stream: http://<YOUR_PC_IP>:8080/stream
WebSocket:   ws://<YOUR_PC_IP>:8081/ws
```

### 5. Connect from iPhone

**WiFi Mode (default):**
1. Open **PC Speaker** app on iPhone
2. Enter your PC's IP address (run `ipconfig` in CMD to find it, e.g., `192.168.1.42`)
3. Tap **Connect**

**USB Mode (no WiFi needed):**
1. On PC, run tunnel in separate terminal:
   ```bash
   python usbmuxd_tunnel.py 8080 8080
   python usbmuxd_tunnel.py 8081 8081
   ```
2. In app, switch to **USB** mode
3. Tap **Connect** (IP is auto-filled)

---

## 🎤 Using iPhone Microphone on PC

1. In app, tap **"Stream Mic to PC"** after connecting
2. On PC, a new input device **"PC Speaker Mic"** appears
3. In Discord/Zoom/OBS: Set Input Device to **"PC Speaker Mic"**

> Note: Mic audio plays through PC speakers for monitoring. Use headphones to avoid feedback.

---

## 🔧 Troubleshooting

| Issue | Solution |
|-------|----------|
| "No loopback device" | Enable Stereo Mix (see step 3) or install Voicemeeter |
| "Connection failed" | Check Windows Firewall: Allow Python on Private networks |
| Can't find PC IP | Run `ipconfig` in CMD, look for IPv4 Address under WiFi/Ethernet |
| USB not working | Trust computer on iPhone; reinstall usbmuxd: `pip install --upgrade usbmuxd` |
| Audio stutters | Lower bitrate in `pc_audio_server.py` (OPUS_BITRATE = 64000) |
| App crashes on launch | Re-sign with AltStore (7-day expiry) |

---

## 🏗️ Building from Source

### Prerequisites
- macOS (for iOS build) OR GitHub Actions (free)
- Flutter 3.22+

### Local Build (requires Mac)
```bash
flutter pub get
flutter build ipa --export-options-plist=export_options.plist
# Output: build/ios/ipa/pc_speaker.ipa
```

### GitHub Actions (free, no Mac needed)
1. Fork this repo
2. Enable Actions in fork settings
3. Go to Actions → "Build iOS App" → Run workflow
4. Download IPA from artifacts

### Update Team ID for signing
Edit `export_options.plist`:
```xml
<key>teamID</key>
<string>YOUR_10_CHAR_TEAM_ID</string>
```
Find your Team ID: [developer.apple.com/account](https://developer.apple.com/account) → Membership

---

## 📁 Project Structure

```
pc_speaker_app/
├── lib/
│   └── main.dart              # Flutter app (UI, audio, WebSocket)
├── ios/                       # iOS project (auto-generated)
├── pc_audio_server.py         # Windows audio capture + HTTP/WS server
├── usbmuxd_tunnel.py          # USB tunnel script
├── export_options.plist       # iOS build config for sideloading
├── .github/workflows/
│   └── build-ios.yml          # GitHub Actions CI
├── pubspec.yaml               # Flutter dependencies
└── README.md
```

---

## 🔒 Privacy & Security

- **No data leaves your local network**
- Audio streams directly PC ↔ iPhone
- No cloud servers, no accounts, no tracking
- Microphone only activates when you tap "Stream Mic"

---

## 🤝 Contributing

PRs welcome! Areas for improvement:
- Lower latency (WebRTC)
- Better virtual mic driver (VB-Cable integration)
- Equalizer/audio effects
- Auto-discovery (mDNS/Bonjour)

---

## 📄 License

MIT License - Use freely for personal or commercial projects.

---

## ⭐ Star this repo if it works for you!

Built with ❤️ using Flutter + Python + WebRTC concepts