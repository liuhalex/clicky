# Feature Log

Notes on what I'm building on top of the open-source Clicky repo
(github.com/farzaa/clicky). Some features recreate things the newest
HeyClicky has that aren't in this repo; others are new ideas.

The short version for reviewers is [PITCH.md](PITCH.md).

*Last updated: 2026-10-07 (branch `feature/live-session`).*

**Origin key**
- **New**: my own idea, not in Clicky or HeyClicky as far as I know
- **From HeyClicky**: recreating something the newest (private) HeyClicky does
- **❓**: origin not labeled yet

**Status key**
- **Built**: code done and unit tests pass
- **Tried**: tested by hand in the running app
- **Planned**: designed, not built yet

## Summary

| Feature | Origin | Status |
|---|---|---|
| [The pointer follows what it points at](#the-pointer-follows-what-it-points-at) | New | Built, tried |
| [On-device element tracking](#on-device-element-tracking) | New | Built, tried |
| [Anchored scroll following](#anchored-scroll-following) | New | Built, tried (shake fix not yet re-tried) |
| [Flight steering toward moving targets](#flight-steering) | New | Built, tried |
| [Point while explaining, then let go](#point-while-explaining-then-let-go) | ❓ | Built |
| ["It scrolled off the top" voice announcement](#lost-element-announcement) | New | Built, tried |
| [Re-find when scrolled back ("there it is!")](#re-find-when-scrolled-back) | New | Built |
| [Hands-free mode (fn + control)](#hands-free-mode) | New | Built, tried (Mac-audio filter not yet confirmed) |
| [Hands-free ring](#hands-free-ring) | New | Built |
| [Cost compared to the original Clicky](#cost-compared-to-the-original-clicky) | Analysis | Done |
| [Token-anxiety design](#token-anxiety-design) | New | Built |
| [Point and draw while talking](#point-and-draw-while-talking) | ❓ | Planned |
| [Repo fixes: working tests, local setup](#repo-fixes) | Fixes to existing repo | Built |
| [Pointing accuracy investigation](#pointing-accuracy-investigation) | Improvement | In progress |
| [Tutor mode with a whiteboard](#future-ideas-not-built) | New | Idea, on hold (API cost) |

Also see [Improvements and Bug Fixes](#improvements-and-bug-fixes) for everything found and fixed along the way.

---

## The Pointer Follows What It Points At
**Origin:** New (confirmed: HeyClicky has no continuous screen watching) · **Status:** Built, tried

- **Problem:** Clicky takes one screenshot when you release the push-to-talk keys. If you scroll afterward, it points at where the element *used* to be.
- **What it does:** whenever Clicky points at something, on any question, the cursor stays on that element while you scroll, flick, or drag the window.
- **How it works:**
  - When Clicky points, it starts watching the screen with one ScreenCaptureKit stream per display at 12 fps. The stream only delivers frames when something changes, so a still screen costs almost nothing.
  - Tracking starts from the exact screenshot Claude saw, so it locks onto the right element even if you scrolled while Claude was answering.
  - Watching stops once the buddy is back at your cursor (see [Point While Explaining](#point-while-explaining-then-let-go)).
  - The whole Clicky app is excluded from capture, so the tracker never sees the buddy itself.
- **Privacy:** frames stay on the Mac. Only the screenshot attached to a question is sent, same as before. macOS shows its screen-recording indicator only for those few seconds.
- **Two kinds of "seeing":** the Mac watching the screen (local frames and plain math for tracking) is free. Claude seeing the screen happens only when you ask a question, with one fresh screenshot, exactly like the original Clicky.
- **Switching screens:** each question takes a fresh screenshot when you let go of the keys, so Claude always sees the current screen. If you switch screens while Clicky is pointing, the tracker notices the element is gone and quietly lets go.
- **Files:** `LiveSessionScreenWatcher.swift`, `CompanionManager.swift` (Screen Watching section)

## On-Device Element Tracking
**Origin:** New · **Status:** Built, tried

- **What it does:** finds the element Claude pointed at again in every new frame.
- **Key decision: Claude finds it once, the Mac tracks it.** Streaming the screen to Claude would be seconds behind and cost roughly $10+/hour per user. Tracking runs locally, for free, in ~15ms per frame.
- **How it works:**
  1. Save a small grayscale image (164×68px) around Claude's point.
  2. On every new frame, search the whole frame for the best match. This uses normalized cross-correlation with Accelerate's `vDSP_imgfir`, run at ¼ resolution with a light blur.
  3. Prefer matches near where the motion predicts the element should be. A match far away, or one while the element is leaving the screen, must be near-perfect and clearly unique.
- **Approaches tried and rejected:**
  - **Apple Vision `VNTrackObjectRequest`:** lost the element above ~30px of scroll per frame while still reporting ~65% confidence.
  - **Comparing only the top 2 matches:** jumped between identical list rows. Half-pixel offsets let a look-alike outscore the real element.
  - **No blur:** failed on identical rows. Blur fixed that, but Accelerate's filter zeroes the border pixels, which broke tracking at the screen edge, so border pixels are now kept as-is.
- **Tuning:** the distance penalty (0.0004 per pixel) works in a 2× window. Halving it breaks identical rows; doubling it breaks fast flicks.
- **Tests:** smooth scroll, fast flick (150px/frame), window drag, target scrolled off-screen (must not jump to a look-alike), identical rows, blank area, screen edge.
- **Files:** `ScreenElementTemplateTracker.swift`, `LiveSessionTests.swift`

## Anchored Scroll Following
**Origin:** New · **Status:** Built, tried (shake fix not yet re-tried)

- **Problem:** following frames alone felt like "scroll away, snap back." Frames arrive ~12×/s and slightly late, while content scrolls at 60–120 fps.
- **What it does:** trackpad scroll events move the buddy *instantly*, and frame matches only correct the drift. The buddy follows every 16ms, covering half the remaining distance each frame, so it stays ~25ms behind, about as long as the app takes to redraw.
- **Details:**
  - **Late frames:** each correction adds any scrolling that happened after the frame was captured.
  - **Self-calibrating:** it learns how far content moves per point of scroll (it measured 0.91 in Safari), which handles apps that scroll faster or slower than the scroll events say.
  - **Corrections are blended in** over a few frames (35% each) rather than applied at once, which fixed a shake. Mismatches over 60pt are applied in full.
  - **Big jumps** (220pt+, e.g. page down) use the normal curved flight.
- **Limits:**
  - A classic line-based mouse wheel falls back to frame-only following.
  - Scrolling a different panel on the same screen moves the buddy briefly until the next frame corrects it.
- **Files:** `TrackedElementPositionEstimator.swift`, `OverlayWindow.swift`

## Flight Steering
**Origin:** New · **Status:** Built, tried

- If the element moves while the buddy is flying to it, the curve bends toward the new position on every animation frame, instead of landing on the old spot and jumping.
- **Files:** `OverlayWindow.swift` (`animateBezierFlightArc`)

## Point While Explaining, Then Let Go
**Origin:** ❓ · **Status:** Built

- The buddy points while Clicky explains, then lets go **4s after Clicky stops talking**. Scrolling restarts the countdown, so it stays while you're still looking.
- Clicking the element, asking something new, or losing the element also ends pointing.
- If the area around the point is too plain to track (e.g. empty background), the buddy points without following and flies back after 3s, like the original Clicky.

## Lost-Element Announcement
**Origin:** New · **Status:** Built, tried

- **Only when it was scrolled away:** if it vanished because you switched pages, tabs, or apps, Clicky quietly stops pointing and says nothing. Commenting on every page change felt creepy.
- When the element leaves the screen, Clicky **says** where it went, using Claude's label for it. For example: *"the save button scrolled off the top of your screen. scroll back up a little and it'll be right there."*
- **Direction:** comes from the scroll-driven position estimate first, then from the tracker's last position and motion.
- It waits for Clicky to finish its answer instead of talking over it.
- **Files:** `LostTrackedElementAnnouncement.swift`

## Re-find When Scrolled Back
**Origin:** New · **Status:** Built

- After an element is lost, the tracker keeps looking for it for 20s. If you scroll it back into view, the announcement stops mid-sentence and the buddy flies back saying **"there it is!"**
- Only an unmistakable match counts, so a look-alike can't trigger it.

## Hands-Free Mode
**Origin:** New (confirmed: HeyClicky has no hands-free mode) · **Status:** Built, tried (Mac-audio filter not yet confirmed)

- **What it does:** hold **fn + control** (~0.6s) to turn hands-free on, and again to turn it off. While it's on, you just talk, with no keys needed. Clicky picks up your question when you speak and sends it once you've gone 1.2s without new words. Push-to-talk (ctrl + option) is the default and always works.
- **How it got here:** first built as a "live session" with two modes (push-to-talk and hands-free) switched by double-tapping a key, first option and then command. Once the pointer followed every point, a session's only remaining purpose was hands-free, so it became a single toggle with nothing to switch.
- **Why there's no "live push-to-talk" mode:** it would feel identical to normal push-to-talk (same following, same cost). Its only difference is answers about 0.1–0.3s faster, because there's no fresh screenshot to take, and it has two downsides: you'd have to remember to start it, and the screen-recording indicator would stay on. Continuous watching earns its own mode only if Clicky starts using screen *history* (e.g. "what was that error that just flashed?").
- **Only answers when you're talking to it:** with the mic open, Clicky overhears things that aren't for it (talking to someone else, a call, a video). For hands-free speech, Claude is told to reply exactly `[SILENT]` if it wasn't said to it, and then Clicky says nothing, points at nothing, and keeps it out of the conversation history. Push-to-talk always answers.
- **Privacy:** speech is transcribed on the Mac (Apple Speech with on-device recognition, which this Mac supports), so your voice never leaves it. Only a finished question of 2+ words goes to Claude.
- **Naming:** first called "always listening," which sounded like surveillance, so it was renamed "hands-free" and described as "just start talking."
- **Ignores the Mac's own speakers:** a video or podcast playing on the Mac would otherwise get picked up and sent as a question. While hands-free is on, Clicky also transcribes what the Mac is playing (captured through ScreenCaptureKit, Clicky's own voice excluded, recognized on-device). If the mic heard the same sentence, it's dropped silently: no waveform, nothing sent.
  - **Echo test:** the mic's words must line up, in order, with **one stretch** of the Mac's audio (3+ words, 60%+ of what was heard). A real question that shares common words with a long video doesn't count, because those words are scattered.
  - **Not used:** Apple's built-in echo cancellation (voice processing). On macOS it mainly cancels the app's own playback and turns down other audio while the mic is on, so your music would stay quiet the whole time.
  - Sound from *other* devices (a phone, a TV, another person) isn't filtered, by design.
- **Safeguards:**
  - The mic pauses while Clicky thinks and talks, so it never hears itself.
  - Anything under 2 words ("hm", "okay") is ignored.
  - Push-to-talk always takes over the mic.
- **Limits:** you can't interrupt Clicky mid-answer, and a loud room can trigger questions.
- **Files:** `LiveSessionToggleShortcut.swift`, `ComputerAudioEchoDetector.swift`, `ComputerAudioSpeechTranscriber.swift`, `CompanionManager.swift` (Live Session Supervisor)

## Hands-Free Ring
**Origin:** New · **Status:** Built

- An **orange ring breathes around the buddy while hands-free is on**. No ring means push-to-talk as usual.
- The orange matches the dot macOS shows when an app is using the microphone, so the meaning is already familiar.
- **Tried and dropped:**
  - A mic/keyboard badge, which looked cluttered on screen all the time.
  - Dashed vs solid, which was too subtle.
  - A blue ring for push-to-talk sessions, which stopped making sense once sessions became hands-free only.
  - A sonar ripple and a voice-reactive ring, which were also considered.

## Cost Compared to the Original Clicky

| | Original Clicky | Now |
|---|---|---|
| Claude calls per question | 1 | 1 |
| What's sent | 1 screenshot (1280px) + question + history | identical (hands-free questions add ~120 tokens of instructions) |
| Cost per question | ~2,400 input tokens + a short answer ≈ 1¢ (Sonnet 4.6) | same |
| Pointer following | n/a | local, $0 (a little CPU while pointing) |
| Hands-free listening | n/a | $0: speech and the Mac's audio are transcribed on-device |
| Extra API cost | n/a | overheard speech that reaches Claude costs one call (~1¢) even when it replies `[SILENT]` |

- **Why hands-free is affordable:** the original Clicky uses AssemblyAI, which bills per hour of streamed audio. An always-open mic on that would cost money the whole time it's on. On-device Apple Speech makes it free.
- **Possible saving:** check whether overheard speech was meant for Clicky with a cheap text-only call (e.g. Haiku, no screenshot) before the full call.

## Token-Anxiety Design
**Origin:** New · **Status:** Built

- **The worry:** "hands-free is on, so it must be burning tokens."
- **Reality:** watching, tracking, and transcription are local and free. Claude is only called per question, at the same cost as push-to-talk. Hands-free adds one real risk (stray speech sending a question), which the safeguards above reduce.
- **Design:**
  - Turning it on says *"hands-free on · just start talking."*
  - Turning it off shows a receipt: *"hands-free off · 3 questions sent."*
  - Forgotten hands-free **turns itself off after 10 quiet minutes**.
- **Ideas not built:** a live question counter in the menu bar panel, a flash on the ring at the moment something is sent, a question cap.

## Point and Draw While Talking
**Origin:** ❓ · **Status:** Planned

- **Goal:** while explaining, the buddy points at each thing *as it's mentioned* and can outline or draw. For example: "click **here**, then this panel **over here** opens."
- **Plan:**
  - Claude places markers throughout its answer: `[POINT]`, `[BOX:x1,y1,x2,y2]`, `[CIRCLE:x,y,r]`, and maybe `[OUTLINE:…]` and `[ARROW:…]`.
  - Markers are timed to the voice by their position in the text compared with the audio length. ElevenLabs' exact word timings are an upgrade path if that isn't close enough.
  - Shapes are drawn in the buddy's blue and follow scrolling using the same tracker.
- **Open decisions:**
  - Which shapes come first?
  - Loose hand-drawn style or clean geometric?

## Repo Fixes
**Origin:** Fixes to the existing repo · **Status:** Built

- **Tests were broken**, for four separate reasons:
  1. There was no shared Xcode scheme, so the command-line tools couldn't find the test target.
  2. `TEST_HOST` pointed at `leanring-buddy.app` instead of `Clicky.app`.
  3. The tests imported `leanring_buddy` instead of the actual module, `Clicky`.
  4. The original test struct was missing `@MainActor`.
- **Now:** 45 tests across 7 suites, run with Cmd+U.
- **Local development setup:**
  - Signing set to my personal team.
  - The Worker runs locally (`npx wrangler dev`) and the app points at `http://localhost:8787`.
  - Speech-to-text uses Apple Speech, which needs no key (macOS Dictation must be on).
  - Before merging back, these local-only changes should be reverted or put behind config.

## Pointing Accuracy Investigation
**Origin:** Improvement · **Status:** In progress

- **Report:** Clicky pointed a few inches away from what it was talking about.
- **Experiment:** I rendered a realistic store page at 1280px (the size Clicky sends) with 35 elements at known positions, then asked Claude to locate 12 of them three ways:

  | Setup | On target | Median error | Avg. input tokens |
  |---|---|---|---|
  | Sonnet 4.6 + `[POINT]` tag (current) | 12/12 | 1px | ~2,400 |
  | Sonnet 5.5 + `[POINT]` tag | 12/12 | 1px | ~2,800 |
  | Sonnet 5.5 + computer use tool | 12/12 | 1px | ~5,900 |

- **Finding:** Claude's coordinates are accurate on a clean page, so switching to the computer use tool would add cost (~2.4× tokens) without helping here. The error most likely comes from what happens *after* Claude points:
  - tracking drifting onto a look-alike,
  - a miscalibrated scroll estimate,
  - Clicky pointing at one thing while talking about several,
  - or real screens being much busier than the test page.
- **Also learned:**
  - Sonnet 4.6 rejects the new `computer_toolset_20260801` (it only takes the older beta `computer_20251124`). Sonnet 5.5 accepts it with no beta header.
  - The repo already had an unused `ElementLocationDetector.swift` that used the older computer use tool. The original team clearly hit accuracy problems too.
- **Next step:** debug builds now save every point Claude makes: the exact screenshot Claude saw with its point marked in red, plus the question, the answer, and the coordinates, in `.pointing-debug/` (git-ignored). Big tracking jumps are also logged. Reproducing a bad point once will show which cause it is.
- **Files:** `PointingDebugRecorder.swift`

## Improvements and Bug Fixes

Things found and fixed while building, newest first. These make a good story for the pitch: each one was caught by testing, a test harness, or real use.

| Problem | How it was found | Fix |
|---|---|---|
| Two shortcuts and two concepts (a "live session" plus a double-tap mode switch) for what was really just hands-free | Design review once pointer-following worked everywhere | fn + control now turns hands-free on and off. Removed the session concept, the double-tap toggle, and the blue ring |
| Pointer only followed scrolling inside a live session; a normal push-to-talk point stayed put | User testing (session was off, so the pointer didn't follow) | Watch the screen just while pointing, on every question |
| Clicky commented after switching pages ("I can't see it anymore…") | User feedback | Lost-element announcement only plays when the element was scrolled away; page/tab/app switches end pointing silently |
| Hands-free answered speech that wasn't meant for it (background conversation) | User testing + log | For hands-free speech, Claude replies `[SILENT]` when not addressed; Clicky stays quiet |
| Hands-free picked up audio playing on the Mac itself (videos, podcasts) | User testing | Transcribe the Mac's own audio on-device and drop mic speech that matches one stretch of it (6 tests) |
| "Always listening" sounded scary | User feedback | Renamed to **hands-free** ("just start talking"); confirmed speech is transcribed on-device, so voice never leaves the Mac |
| Couldn't tell why pointing was off | User report | Debug recorder plus an accuracy experiment (see above) |
| Mode badge (mic/keyboard icons) looked cluttered | User feedback | Ring color showed the mode instead (later simplified to an orange ring for hands-free only) |
| Double-tap option opens other apps (Claude) | User feedback | Switched to double-tap command (later removed entirely, see the first row) |
| After scrolling a lost element back, Clicky kept saying it was gone | User testing | Keep searching for 20s after losing it; stop the announcement and fly back ("there it is!") when re-found |
| Lost element announced as "disappeared on the left" when it was really scrolled off the top | Debug log | Use the scroll-driven estimate to pick the direction; the tracker loses elements a few frames before they leave |
| Buddy shook while scrolling | User testing | Blend frame corrections in (35% per frame) instead of snapping; only snap for jumps over 60pt |
| Buddy lagged then snapped back while scrolling | User testing | Anchor to trackpad scroll events (instant), with frames only correcting drift; self-calibrating scroll scale |
| Tracked element moves made the buddy snap instead of fly | User feedback | Flights steer toward the moving element every frame |
| Tracker drifted at the left screen edge | Unit test | Accelerate's 3×3 blur zeroes border pixels; the border now keeps its original pixels |
| Tracker jumped to an identical list row | Unit test | Half-pixel scroll offsets let look-alikes outscore the real row. Fixed with a light blur plus motion prediction with a distance penalty |
| Tracker jumped to a similar button 238px away | Unit test | Search everywhere near the motion prediction instead of comparing only the top 2 matches |
| Tracker "found" a look-alike after the target scrolled off-screen | Prototype | If the element is predicted to be leaving the screen, only an unmistakable match counts |
| Apple's Vision tracker lost elements on fast scrolls while reporting ~65% confidence | Prototype | Replaced with template matching (NCC via Accelerate), ~15ms per frame |
| Hands-free mic would hear Clicky's own voice | Design review | Mic pauses whenever Clicky is thinking or talking |
| Push-to-talk didn't work: Ctrl+Option only flickered the waveform | First run | No server for the speech-to-text token. Switched to Apple Speech (needs macOS Dictation on) |
| Tests couldn't run at all (4 separate issues) | First test run | Shared scheme, `TEST_HOST` → `Clicky.app`, module `Clicky`, `@MainActor` (see Repo Fixes) |

## Future Ideas (Not Built)

### Tutor mode with a whiteboard
**Status:** idea, on hold because each lesson would run on my own API credit.

- **What it is:** Clicky opens a whiteboard and teaches a topic. It writes equations and text as it explains, circles and underlines things, pauses to ask "does that make sense?", gives practice problems, and nudges you with hints when you're wrong.
- **What makes it different from other AI tutors:** "teach me *this thing on my screen*". Clicky pulls the equation, chart, or code you're looking at onto the board and works through it. Uploaded PDFs/images come second.
- **Plan:**
  - One "talk and draw" engine shared with point-and-draw: Claude returns steps that pair a spoken line with board actions.
  - The board is a web view: KaTeX for math, rough.js for hand-drawn shapes.
  - The app controls the lesson loop: explain → check understanding → practice → hint.
  - Hands-free mode for answering.
  - Prompt caching on the lesson context to keep long lessons cheap.
