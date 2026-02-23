# TeslaNav — Voice → Route → Tesla

iPhone app: speak a destination or multi-stop itinerary in plain English.
Claude parses it into structured stops, Google Maps optimizes the order,
route goes directly to your Tesla's navigation (one or multiple cars).

---

## Architecture

```
iPhone mic
  └─ SFSpeechRecognizer (on-device)
       └─ raw transcript
            └─ Claude API (claude-sonnet-4)
                 └─ structured JSON stops + time windows
                      └─ FastAPI backend
                           ├─ Google Maps Distance Matrix → greedy time-window optimizer
                           └─ Tesla Fleet API → navigation_request per vehicle
```

---

## Quick Start

### 1. Backend

```bash
cd backend
cp .env.example .env
# Add your Google Maps key to .env

pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

Test it:
```bash
curl http://localhost:8000/health
```

For remote access from iPhone on same network, use your Mac's local IP:
```
http://192.168.x.x:8000
```
Or deploy to Fly.io / Railway in 2 minutes for HTTPS.

### 2. iOS App

Open `TeslaNav.xcodeproj` in Xcode 15+.

Add to `Info.plist`:
```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>To convert your voice into navigation destinations</string>
<key>NSMicrophoneUsageDescription</key>
<string>To record your voice for route planning</string>
```

Build & run on device (speech recognition requires real device).

### 3. API Keys Needed

| Key | Where to get | Used for |
|-----|-------------|----------|
| Claude API | console.anthropic.com | Parse voice → stops |
| Google Maps | console.cloud.google.com → Distance Matrix API | Real drive times |
| Tesla Fleet API token | developer.tesla.com | Send nav to car |

Enter all three in the app's Settings tab.

---

## Tesla Fleet API Setup

1. Register at [developer.tesla.com](https://developer.tesla.com)
2. Create app, note `client_id`
3. OAuth 2.0 flow (Authorization Code):
   ```
   GET https://auth.tesla.com/oauth2/v3/authorize
     ?client_id=YOUR_CLIENT_ID
     &redirect_uri=YOUR_REDIRECT
     &scope=vehicle_device_data vehicle_cmds
     &response_type=code
   ```
4. Exchange code → `access_token`
5. Paste token in app Settings

Required scopes: `vehicle_device_data`, `vehicle_cmds`

The backend proxies all Tesla calls — your token never leaves your device/backend.

---

## Example Voice Prompts

- *"Take me to open houses at 123 Main St Palo Alto 10 to noon, then 456 Oak Ave Menlo Park 11 to 1, then 789 Pine Rd Redwood City 1 to 3"*
- *"Navigate to Tesla HQ, then Whole Foods on El Camino, then home"*
- *"I need to hit Costco, then pick up dry cleaning on University Ave, then get to my 3pm at 500 Hamilton Ave"*

Claude handles all the ambiguity — missing cities, relative times, implicit ordering.

---

## File Structure

```
TeslaNav/
├── TeslaNav/
│   ├── TeslaNavApp.swift       # App entry
│   ├── Models.swift            # Data models
│   ├── ContentView.swift       # Main UI + vehicle selector
│   ├── RouteViewModel.swift    # Orchestration logic
│   ├── SpeechService.swift     # SFSpeechRecognizer wrapper
│   ├── LLMService.swift        # Claude API client
│   ├── TeslaService.swift      # Tesla Fleet API client
│   └── SettingsView.swift      # API key config
└── backend/
    ├── main.py                 # FastAPI server
    ├── requirements.txt
    └── .env.example
```

---

## Deploy Backend to Fly.io (optional, for HTTPS)

```bash
brew install flyctl
fly launch --name tesla-nav-backend
fly secrets set GOOGLE_MAPS_API_KEY=your_key
fly deploy
```

Then set Backend URL in app to `https://tesla-nav-backend.fly.dev`.
