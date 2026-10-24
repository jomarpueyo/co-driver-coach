# Security

Co-Driver Coach is a single-player BeamNG.drive mod plus a few local helper tools. This page describes what it
touches, what it sends where, and the state of the last security review.

## What runs where

| Part | Runs as | Talks to |
|---|---|---|
| The mod (`co_driver_coach/`: Lua extensions and UI apps) | inside BeamNG.drive | files under the game's user folder (`settings/coDriverCoach/`, `replays/codriver/`) |
| Race engineer bridge (`tools/engineer.py`, `engineer.bat`) | your Windows account | the game, through request and reply files in `settings/coDriverCoach/engineer/`; the microphone; `https://api.anthropic.com` (only with an API key) |
| Voice review page (`tools/voice_review.py`) | your Windows account | `http://127.0.0.1:8766` on this computer only |
| Development tools (`tools/bmcp.py`, `deploy.sh`, `harness.py`, `tools/offline/`) | your Windows account | the game's own local MCP server (`127.0.0.1:29292`), for development only |

## Data that leaves your computer

Only the race engineer sends data off the machine, and only when an Anthropic API key is set:
- your question, as text;
- the car and drive data the answer needs: temperatures, damage, laps, recent corners;
- after a drive, the drive's analysis.

The bridge sends no audio. Speech-to-text (Whisper) and the voice (Kokoro) run locally. Without a key, the
engineer answers from the car's data and nothing is sent.

## Data kept on your computer

- **Drive recordings:** telemetry, laps and replays, under the game's user folder. Nothing is deleted automatically.
- **The engineer's voice log** (`settings/coDriverCoach/engineer/voicelog/`): each push-to-talk clip as a WAV file, what was
  heard, and the answer. The newest 300 clips are kept. Set `"voice_log_keep": 0` in `tools/engineer_config.json` to
  keep the text only.
- **The API key:** in `tools/.anthropic_key` (git-ignored) or the `ANTHROPIC_API_KEY` environment variable. It is
  sent only to `api.anthropic.com` over HTTPS, in a request header, and is never logged. Keep the file readable by
  your account only:

  ```
  icacls tools\.anthropic_key /inheritance:r /grant:r "%USERNAME%:F"
  ```

## Things to know

- **The game's MCP server** (Options → enable MCP, the setting `enableMcp`) lets local programs run any Lua in
  the game. It has no login and doesn't check where requests come from. Turn it off when you're not
  developing. The mod works without it; only the development tools here use it.
- **Other mods run unsandboxed Lua**, with file and process access. That is how BeamNG's mod system works. Only
  install mods you trust: malicious mods were distributed in 2024 and 2025.
- **The voice review page** only answers requests addressed to `127.0.0.1` or `localhost` on its own port. It
  accepts changes only from its own page, which carries a per-run token. Only run it while you use it.

## Review status (2026-10-23)

The project's own code was reviewed. Fuzzing covered:
- the bridge's functions;
- the voice review server;
- the Lua loaders, with corrupted save files;
- the UI-to-Lua string escaping, checked with a real Lua parser.

There were no injection paths and no secret leaks. The key is not in git history.

| Finding | Status |
|---|---|
| Voice review page reachable from other websites (cross-site writes, DNS rebinding) | Fixed: Host, Origin and token checks |
| Bridge request id used in a file name (could write outside its folder) | Fixed: plain ids only |
| Corrupted routes or session files could stop lap timing or the analysis | Fixed: checked on load |
| Panel strings with control characters produced Lua that wouldn't compile | Fixed: stripped |
| PowerShell started by name | Fixed: full system path |
| API key file readable by other local accounts | Fixed on the author's machine; see the `icacls` line above |
| `setuptools` 65.5.0 in the bridge environment (4 advisories) | Fixed: 84.2.1 |
| Python packages not pinned with hashes; models downloaded with no checksum | Open |
| Bridge environment on Python 3.11.4 with OpenSSL 1.1.1u (end of life) | Open |

## Reporting a problem

Please open a GitHub issue. For anything sensitive, ask in an issue for a private contact first.
