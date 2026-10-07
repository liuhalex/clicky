# Clicky Live Sessions

Alex Liu · Demo video: [link] · Branch: `feature/live-session` · Full log: [FEATURES.md](FEATURES.md)

## The problem

Clicky takes one screenshot when you let go of push-to-talk. If you scroll, switch tabs, or move a window after asking, the blue cursor points at where the button used to be. Every question also needs a key press.

## What I built

**Live sessions.** Hold fn + control to start one. Clicky watches the screen on your Mac while the session is on. When it points at something, the cursor stays on it while you scroll, flick, or drag the window.

**Hands-free mode.** Double-tap command and just talk. Speech is transcribed on the Mac. Clicky ignores audio your Mac is playing (videos, podcasts) and stays quiet when you weren't talking to it.

**Smaller pieces:**
- If you scroll the element away, Clicky tells you where it went. Scroll it back and the cursor returns.
- The ring around the cursor shows the mode: blue for push-to-talk, orange for hands-free (the same orange as the macOS mic dot).
- Sessions end with a receipt ("3 questions sent") and turn themselves off after 10 quiet minutes.

## Three decisions, with data

**1. Track on the Mac instead of asking Claude again.**
Streaming frames to Claude would run seconds behind and cost roughly $10+ an hour per user. I tried Apple's Vision object tracker first. It lost the target once scrolling passed about 30px per frame and still reported ~65% confidence. I replaced it with template matching (normalized cross-correlation on Accelerate). It holds within 2px at 150px per frame (a fast flick), runs in about 15ms per frame, and costs nothing. Claude is still called once per question, same as before.

**2. Use scroll events to anchor the cursor.**
Frames arrive about 12 times a second and a little late, so following frames alone made the cursor lag and then snap. Trackpad scroll events arrive instantly, so they move the cursor right away, and frame matches only correct drift. The system learns each app's scroll speed by itself (it measured 0.91 in Safari).

**3. Measure before changing models.**
After seeing some bad points, I ran an accuracy test: 12 elements on a realistic page, three setups. All three, including today's setup, landed 12/12 within about 1px. Switching to the computer use tool would have cost 2.4x the tokens for no gain. The misses come from somewhere else, so I added a debug recorder that saves what Claude saw and where it pointed.

## Also fixed

- The test target couldn't run at all (4 separate setup bugs). There are now 53 tests.
- The tracker jumped between identical list rows, drifted at the screen edge, and grabbed look-alikes when the target scrolled away. Each was caught by a test and fixed.
- Early feedback made the design calmer: no comments when you change pages, "always listening" renamed to hands-free, and icons replaced with a color.

## Cost

Built on about $5 of Anthropic credit. Watching and tracking are free. Each question costs the same as it did before.

## What's next

- Find the remaining pointing misses on busy screens using the debug recorder.
- Point and draw while talking: circle or outline each thing as Clicky mentions it.
- Check whether hands-free speech was meant for Clicky with a cheap text-only call before sending the screenshot.
- A tutor mode with a whiteboard (designed, shelved for API cost).

## Code

| File | What it does |
|---|---|
| `ScreenElementTemplateTracker.swift` | Template matching and the rules for trusting a match |
| `TrackedElementPositionEstimator.swift` | Scroll anchoring and self-calibration |
| `LiveSessionScreenWatcher.swift` | Screen and system audio capture during a session |
| `ComputerAudioEchoDetector.swift` | Hands-free filter for the Mac's own audio |
| `CompanionManager.swift` | Session lifecycle, hands-free listening, announcements |
| `leanring-buddyTests/LiveSessionTests.swift` | Tests for tracking, anchoring, shortcuts, and echo detection |
