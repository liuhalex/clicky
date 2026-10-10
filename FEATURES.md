# Feature Log

Notes on what I'm building on top of the open-source Clicky repo
(github.com/farzaa/clicky). Some features recreate things the newest
HeyClicky has that aren't in this repo; others are new ideas.

The short version for reviewers is [PITCH.md](PITCH.md).

*Last updated: 2026-10-08 (branch `feature/live-session`).*

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
| [Starts talking 2.3× sooner](#starts-talking-sooner) | Improvement | Built, measured (not yet tried by voice) |
| [Talk over Clicky to interrupt it](#talk-over-clicky) | New | Built, tried, simplified after testing |
| [Captions, transcript, and "say that again"](#captions-and-say-that-again) | New | Built |
| [Hands-free mode (fn + control)](#hands-free-mode) | New | Built, tried (Mac-audio filter not yet confirmed) |
| [Hands-free ring](#hands-free-ring) | New | Built |
| [Cost compared to the original Clicky](#cost-compared-to-the-original-clicky) | Analysis | Done |
| [Token-anxiety design](#token-anxiety-design) | New | Built |
| [Point and draw while talking](#point-and-draw-while-talking) | ❓ | Planned |
| [Repo fixes: working tests, local setup](#repo-fixes) | Fixes to existing repo | Built |
| [Pointing accuracy investigation](#pointing-accuracy-investigation) | Improvement | In progress |
| [User research: what people ask for](#user-research-what-people-ask-for) | Research | Done |
| [Tried and dropped: "click it for me"](#tried-and-dropped-click-it-for-me) | New | Built, then removed |
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
  - **Elements that don't scroll:** if, while you scroll, the element is found exactly where it was and has never moved with the scroll, it's fixed on screen (X's Post button in its sidebar while the feed scrolls). Scroll events stop moving the buddy, and it stays on the button. If you later scroll the panel it's in, it's followed again.
  - **Pinned copies:** if the element *did* move with the scroll and then a match suddenly stops moving, it's a pinned copy (GitHub keeps a copy of a repo's Watch / Fork / Star buttons at the top). That match is ignored and the buddy follows the scrolling, and once that carries the element past an edge or under the browser toolbar, Clicky says where it went.
  - **Big jumps** (220pt+, e.g. page down) use the normal curved flight.
- **Limits:**
  - A classic line-based mouse wheel falls back to frame-only following.
  - The first frame after you start scrolling decides whether the element is fixed, so on a fixed button the buddy can drift for about a tenth of a second before snapping back.
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
- **Direction:** comes from the scroll-driven position estimate first, then from which way you were scrolling it (content disappears under the browser's tab and address bar or a site's sticky header well before the screen edge), then from the tracker's last position and motion.
- It waits for Clicky to finish its answer instead of talking over it.
- **Files:** `LostTrackedElementAnnouncement.swift`

## Re-find When Scrolled Back
**Origin:** New · **Status:** Built

- After an element is lost, the tracker keeps looking for it for 20s. If you scroll it back into view, the announcement stops mid-sentence and the buddy flies back saying **"there it is!"**
- Only an unmistakable match counts, so a look-alike can't trigger it.

## Starts Talking Sooner
**Origin:** Improvement to existing Clicky · **Status:** Built, measured (not yet tried by voice)

- **Before:** Clicky waited for Claude to write the whole answer, then asked ElevenLabs for audio of the whole answer, and only then started talking. Long explanations meant 6+ seconds of spinner.
- **Now:** as soon as Claude has written the first sentence, it goes to ElevenLabs and starts playing while Claude is still writing the rest. The rest follows as one or more longer pieces, requested right away and played back to back.
- **Where the time went:** the wait was three steps in a row: Claude writing the *whole* answer, then ElevenLabs making audio for the *whole* answer, then playback. Both of the first two grow with answer length, which is why long explanations were the slowest. Claude already streams its answer word by word; the original app just ignored the stream until it ended.
- **How it works now, step by step:**
  1. Claude's answer streams in. Each time new text arrives, `StreamingSpeechSegmenter` checks whether a complete sentence is ready.
  2. The first complete sentence (20+ characters) is sent to ElevenLabs immediately, while Claude keeps writing.
  3. `ElevenLabsTTSClient` is now a queue: each piece's audio request starts the moment its text is known, so several can be in flight at once, and a playback loop plays them in order as they arrive.
  4. When Claude finishes, whatever hasn't been spoken yet (minus the `[POINT]` tag) goes in as the last piece.
  5. The spinner stays until the first audio actually plays, then captions start. The cursor flies to its target as soon as the answer is complete, which is often while Clicky is still speaking (not measured).
- **How it was measured:** `scripts/latency_benchmark.py` sends the exact request Clicky sends (same system prompt, a real app screenshot at 1280px, Sonnet 4.6) through the local worker and times both paths. "Before" = time for Claude's full answer + time to get audio for all of it. "After" = time until the first sentence is written + time to get audio for that sentence. Screenshot capture and audio start-up are the same in both, so they're left out. The app also logs `⏱️ Clicky started talking Xs after the question was sent` on every real question.
- **Measured** (same screenshot and questions through the local worker, `scripts/latency_benchmark.py`, rerunnable):

  | Question | Before | After |
  |---|---|---|
  | what is this app and how do I start a new thread? | 3.07s | 2.04s |
  | how do I add a project here? | 3.15s | 1.65s |
  | explain what I'm looking at on this screen (long answer) | 6.65s | 1.59s |
  | where do I change settings? | 4.15s | 2.19s |
  | **Average** | **4.3s** | **1.9s** |

  The longer the answer, the bigger the win, because "after" no longer depends on answer length.
- **Details that matter:**
  - The first piece is the first sentence of at least 20 characters, so a lone "Sure." doesn't play by itself. Later pieces are at least 60 characters, since they're ready long before they're needed and longer pieces sound smoother.
  - ElevenLabs gets the previous text with each piece (`previous_text`), so the voice flows across pieces instead of restarting.
  - Nothing after a `[` is spoken until the answer is complete, so the `[POINT:...]` tag and a hands-free `[SILENT]` reply are never read aloud.
  - "3.5" or "e.g" doesn't end a sentence (a sentence end needs a space after it).
  - Captions are laid out per piece and stay exactly timed to the voice.
  - "Say that again" replays all the pieces from saved audio.
- **Cost:** the same. The same characters are sent to ElevenLabs, just split up.
- **Files:** `StreamingSpeechSegmenter.swift` (where to split), `ElevenLabsTTSClient.swift` (queue of pieces), `CompanionManager.swift` (`speakAnswerSegment`)

## Talk Over Clicky
**Origin:** New · **Status:** Built, tried, simplified after testing

- **What it does:** in hands-free mode, say "wait", "stop", "hold up", "one sec", "pause", "Clicky" or "Hey Clicky" while Clicky is talking, and it stops right away and listens. If that's all you said, nothing is sent. If you go on to ask something, it answers that instead. (Push-to-talk already stopped Clicky when pressed, so this is hands-free only.)
- **While Clicky is still thinking** (no voice playing yet), anything you say of 2+ words interrupts it. If you're adding to your question ("...and make it bold too"), Clicky drops the half-finished answer and sends your first question and the new words together.
- **Why only stop words while it talks:** the first version reacted to *any* speech (fade at the first word, stop at the second). In testing through laptop speakers, Clicky kept fading and stopping itself in a quiet room. The mic's transcript of its own voice is too unreliable: "gi" or "get" for "github", "clicking" for "clicky", "seven" for "7.7k", "far" for "farza". Three rounds of better echo matching each caught the last batch and missed the next. A short list of rare words Clicky almost never says is reliable, so that's what stops it.
- **Removing Clicky's own voice:** Clicky knows exactly what it's saying, so it lines the mic transcript up against that text. Words that match in runs of 2+, in order, are its own voice, and so is any word that looks like one of its words (same start, same stem, one letter off, or a number read out as words). A stop word only counts if Clicky didn't just say it, and only once it has lasted 0.3s, since recognition often corrects itself a moment later.
- **What gets sent:** only your words, with Clicky's voice removed from the start of the transcript.
- **How it works:**
  1. Before, hands-free paused the mic whenever Clicky was thinking or talking. Now the mic keeps listening the whole time.
  2. On every transcript update, Clicky's own words are subtracted, leaving only yours.
  3. A stop word (or 2+ words while it's only thinking) stops the speech queue, cancels the answer if Claude is still writing it, and clears the caption.
  4. When you finish talking (1.2s of silence, as before), the rest is sent, or nothing if it was only "wait".
  5. If Clicky finishes an answer and you never spoke, the mic restarts fresh so Clicky's words aren't stuck at the front of your next question.
- **The real fix, not built:** acoustic echo cancellation (Apple's voice processing) would remove Clicky's audio from the mic signal before recognition, so any word could interrupt. It needs Clicky's voice to play through the same audio engine as the mic, a bigger change to both the playback and recording paths.
- **With headphones:** the mic hears no echo at all.
- **Files:** `ClickySpeechInterruptionDetector.swift`, `CompanionManager.swift` (Live Session Supervisor, `reactToUserTalkingOverClickyIfSure`, `interruptClickyForHandsFreeSpeech`)

## Captions and "Say That Again"
**Origin:** New · **Status:** Built

- **Problem:** spoken instructions are easy to miss, especially for older users or in a noisy room. Asking again cost another Claude call and could get a different answer.
- **Why one line at a time:** the newest HeyClicky writes out what it says as one long transcript in the notch that keeps growing and takes up more and more of the screen. It makes more sense to show only the line Clicky is saying right now, where you're already looking, and the full transcript only when you ask for it.
- **Captions in Clicky's own bubble:** while Clicky talks, the same blue bubble it already uses when pointing ("click this!") shows what it's actually saying, one line at a time, timed to the voice. No second widget: when captions are off, the bubble goes back to its short pointing phrases. Captions are up to two lines (about 260pt wide), like TV subtitles. The answer is split into the fewest chunks that fit, then the words are spread evenly so **every caption fills the box**, with no short leftover that leaves it half empty. Chunks follow the text continuously, even across sentence ends. The box hugs its widest line, and text is measured in pixels, not characters. The last line stays 4 seconds after Clicky finishes.
- **Exact timing:** speech comes from ElevenLabs' `with-timestamps` endpoint (same cost), which returns when each character starts being spoken. Each caption switches when its first word starts, 0.1s early like subtitles. If timings aren't available, captions fall back to estimating from how much of the text has been spoken. The estimate lagged, because pauses at periods and commas take time without any characters.
- **Follows Clicky's cursor, with the bubble's animation:** the bubble moves with the blue cursor wherever it goes, including when it flies to point at something. The first line of each answer types out letter by letter while the bubble grows to fit (the same entrance as the "click this!" bubble), and later lines swap in place.
- **Switching lines:** the text crossfades (0.18s) inside the same bubble. The bubble keeps its width for the whole answer and only widens, never shrinks, when a later line needs more room, with a gentle ease and no bounce. Its size and position are computed from the text rather than measured after drawing, so it never wobbles sideways. (A first version slid the text and resized the bubble on every line, which felt jerky.)
- **Transcript:** a **Transcript** button in the menu bar panel opens a scrollable window with your questions and Clicky's answers (last 100 lines). Click outside it or press × to close. (A bubble that follows the cursor moves away as you reach for it, so it can't be the thing you click.)
- **On/off switch:** a **Captions** switch in the menu bar panel. On by default, remembered between launches.
- **Shortcut and voice:** press **ctrl + shift + c** anywhere, or say "captions on" / "captions off" (also "hide captions", "turn on captions"). A small bubble confirms "captions on" or "captions off". Both are handled on the Mac with **no Claude call**. Voice commands only count when they're 5 words or fewer, so a real question like "how do I turn on captions in YouTube" still goes to Claude. The shortcut avoids option (ctrl + option is push-to-talk) and command (app shortcuts), and holding it down doesn't flip captions back and forth. The panel shows the hint ⌃⇧C next to the switch.
- **How the design got here:**
  1. A caption under the cursor that moved with your mouse, which made it impossible to click.
  2. A tall strip under the notch, which blocked browser tabs with empty black space.
  3. A thin band under the notch, which wasn't liked either.
  4. Back under the cursor, held still while Clicky talks, in a separate dark box.
  5. Reusing Clicky's existing blue pointing bubble instead of adding a new box.
  6. Letting that bubble follow the cursor with its typing animation, and moving the transcript to a menu bar button.
- **"Say that again":** "say that again," "repeat that," "what did you say?", "come again," "one more time" (7 words or fewer) replay the last thing Clicky said from the saved audio, with captions. **No Claude call, no new voice request, $0**, and you hear exactly the same words. Works in push-to-talk and hands-free.
- **Careful with real questions:** "what was that error that just popped up?" and "how do I repeat a calendar event" still go to Claude (tested).
- **Files:** `CaptionsToggleCommands.swift` (shortcut and voice command), `OverlayWindow.swift` (caption bubble and animations), `worker/src/index.ts` (`/tts-with-timestamps` route), `ConversationTranscriptPanelManager.swift` (transcript window), `SpokenCaptionTimeline.swift`, `RepeatLastAnswerRequest.swift`, `ElevenLabsTTSClient.swift` (replay and playback progress)

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
  - The mic keeps listening while Clicky thinks and talks, so you can [talk over it](#talk-over-clicky). Clicky's own voice is recognized and removed, so it never answers itself.
  - Anything under 2 words ("hm", "okay") is ignored.
  - Push-to-talk always takes over the mic.
- **Limits:** a loud room can trigger questions.
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
| Speaking an answer | 1 ElevenLabs request for the whole answer | same characters, split into 2–3 requests (same price) |
| "Say that again", "captions on/off", "wait" / "hold up" | n/a | $0: handled on the Mac, no Claude or ElevenLabs call |

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
**Origin:** ❓ · **Status:** Planned (note: HeyClicky's site says it already "draws right on your screen to point the way")

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
- **Now:** 87 tests across 13 suites, run with Cmd+U.
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

## User Research: What People Ask For
**Origin:** Research · **Status:** Done (2026-10-08)

- **Sources:** Clicky's GitHub issues (~40), Clicky's Product Hunt launch (9 comments), OpenAI community forum threads, Hacker News comments, and reviews of Copilot Vision (The Verge, PCWorld, Yahoo). Reddit couldn't be loaded, so there are no Reddit counts.
- **Strongest demand: control over when it listens, and being able to cut it off.** For example: "Every time I pause for a second, it interrupts" (OpenAI forum), and Copilot Vision's reviewer wanted "a button to silence it". Clicky now has push-to-talk, hands-free, and [talking over it](#talk-over-clicky).
- **Speed:** people call 5s+ broken and quote 1.5–3.5s as the bar. Clicky now starts talking in [1.9s on average](#starts-talking-sooner).
- **Asked for in Clicky's own issues that this fork now has:** a transcript, a way to stop speech, a one-hand / no-hands way to talk (the ctrl + option shortcut "requires 3 fingers"), and following what's on screen.
- **Asked for, not built:** Windows/Linux (the top Clicky request by far), bring-your-own API key, memory across sessions, privacy controls (a capture indicator, "a timed context window, not always-on capture"), and clicking/typing for the user (see below).
- **Caveat:** written feedback is thin compared with the launch's reach (millions of views, 7.7k GitHub stars), so these are patterns, not counts.

## Tried and Dropped: "Click It for Me"
**Origin:** New · **Status:** Built, then removed (2026-10-08)

- **Idea:** after Clicky points, say "click it" and Clicky clicks that exact element (wherever the tracker says it is now), refusing password fields, with a ripple where it clicked. Asked for in Clicky issue [#38](https://github.com/farzaa/clicky/issues/38) ("If it can't type on my behalf what's the USP ?"), though by one user with no comments.
- **Why it was dropped:** the newest HeyClicky already has agents that do things for you. The cursor's job is to *show* you how, so you learn it. Having the cursor click for you blurs that line and overlaps with their agents.

## Improvements and Bug Fixes

Things found and fixed while building, newest first. These make a good story for the pitch: each one was caught by testing, a test harness, or real use.

| Problem | How it was found | Fix |
|---|---|---|
| On X, pointing at the Post button and scrolling the feed made the pointer drift off it | User testing; the log showed the tracker correctly finding the button in place, and every match being rejected | The GitHub fix assumed any match that stays put while scrolling is a pinned copy. A fixed sidebar button stays put too. Now: never moved with the scroll + found where it was = fixed on screen, so scroll events stop moving the buddy; moved with the scroll first, then stopped dead = pinned copy, ignored (3 tests) |
| Clicky still stopped itself mid-answer, after three rounds of echo fixes | User testing | While Clicky's voice plays, only stop words stop it ("wait", "hold up", "one sec", "pause", "stop", "Clicky"); fading removed. Through laptop speakers, its own voice can't be reliably told apart from the user's by transcript alone |
| Clicky said "[SILENT]" out loud | User testing (log) | Claude repeated its hands-free "stay quiet" reply to a push-to-talk question, and Clicky only checked for it in hands-free mode. Now it's never spoken in either mode |
| Still fading after that fix | User testing; new log cases: "get" (github), "clicking" (clicky), "seven" (7.7k) | Two changes. Clicky now waits until a word has lasted 0.3s before reacting, because speech recognition revises its guesses ("gi" → "get" → "github"); clear stop words still act instantly. And echo matching now covers sound-alike starts, shared stems, and numbers read out as words |
| In a quiet room, Clicky kept fading out and back in during answers | User testing; the log showed the "user words" were bits of Clicky's own voice: "gi" (github), "far" (farza), "click" (clicky), "source" (sourced), and an answer's first word "yeah" | The echo filter only removed exact runs of 2+ matching words. Now, when deciding whether you're interrupting, any heard word that looks like one of Clicky's words (same word, the start of one, or one letter off) is ignored too; stop words still count unless Clicky said them (2 tests from the real log) |
| Still silent after that fix: pointing at GitHub's Fork button and scrolling it away said nothing | User testing; the log showed frame matches 150–430pt from where scrolling put the button, and the learned scroll scale collapsing from 1.00 to -0.03 | GitHub pins a copy of the repo buttons at the top, and the tracker latched onto it. Now a match that doesn't move with scrolling is ignored, the scroll scale can't drop below 0.5 (content always moves with the scroll), and Clicky declares the element lost once scrolling carries it out of view (4 tests) |
| Scrolling an element off the top of a webpage made Clicky go silent instead of saying where it went | User testing (GitHub page; log said "disappeared while on screen, top right") | Web content vanishes under the browser toolbar and GitHub's sticky header ~100–150pt below the screen edge, so it looked like a page change. Now, if you were scrolling it toward an edge in the last second and it was in that half of the screen, it counts as scrolled off (5 tests) |
| Built "click it for me", then realized HeyClicky's agents already act for you and the cursor is for teaching | Product review | Removed completely; documented above |
| Hands-free's "ignore the Mac's own audio" check compared the whole transcript, which now includes Clicky's voice | Code review while building talk-over | The check runs on the user's own words only, after Clicky's voice is removed |
| Captions assumed one audio clip per answer | Building faster responses | Captions are laid out per piece as each starts playing, still timed by ElevenLabs' character timings; "say that again" replays all pieces |
| No way to stop Clicky in hands-free mode; the mic was off while it talked | User research (the top complaint about voice assistants) | Talk over Clicky: the mic stays on, Clicky's own voice is subtracted, and speaking stops it |
| Clicky waited for the whole answer, then audio for the whole answer, before saying anything (4.3s average, 6.65s on a long answer) | Measured with a benchmark | Speak each sentence as soon as Claude writes it (1.9s average, 1.59s on the long answer) |
| Talking over Clicky needed 3 words, so "um" or "okay" did nothing | User feedback | Fade, then stop: the first word lowers Clicky's voice instantly, a second word or a stop word ("wait", "hold up", "one sec", "Clicky") stops it, and a stray word restores the volume after 1.5s |
| First streamed chunk sometimes had two sentences, and both became the first piece (slower start) | Unit test | The first piece ends at the earliest sentence long enough; later pieces take everything available |
| Hands-free listening restarting during Clicky's answer would have hidden the thinking spinner | Code review while building talk-over | Background listening keeps the spinner while an answer is in progress |
| A cancelled answer could play the "out of credits" voice, since a cancelled request can surface as a network error | Code review while building talk-over | Error voice only plays if the answer wasn't cancelled |
| Turning captions off and back on while Clicky was still talking left them off until the next answer | User testing | Turning captions on mid-answer restarts them at the line being spoken right now |
| Captions could only be turned off by opening the menu bar panel | User feedback | ctrl + shift + c shortcut and "captions on/off" voice command, both free (no Claude call), with a confirmation bubble |
| Caption box sometimes looked half empty, sometimes full | User feedback | Split the answer into evenly sized chunks that each fill the two-line box (measured in pixels), and size the box to its widest line |
| Captions too short, showing too little at once (52-character limit left over from the notch band) | User feedback | Two-line captions like TV subtitles (~42 characters per line, 84 per caption) in a ~260pt bubble; height also only grows within an answer |
| Captions switched after Clicky had already moved on to the next line | User testing | Exact per-character timings from ElevenLabs (`/tts-with-timestamps`, same cost) instead of estimating from text length |
| Caption bubble sometimes got taller for the same length of text | User testing | Claude's answers can contain line breaks; captions kept them, rendering an empty extra line. All whitespace is normalized to single spaces (test added) |
| Line-switch animation felt jerky and stressful; the bubble resized on every line | User feedback | Soft 0.18s crossfade only; the bubble keeps its width per answer and only widens when needed |
| Line switches were abrupt | User feedback | First tried a slide-and-fade (replaced, see above) |
| Caption bubble stood still instead of following Clicky, and appeared without the typing animation | User feedback | Bubble follows the blue cursor; first line types out as the bubble grows, later lines swap in; transcript moved to a menu bar button |
| A separate caption box next to Clicky's existing blue "click this!" bubble was redundant | User feedback | Captions use the same blue bubble; the pointing phrase hides while a caption shows |
| Notch captions (thin band) didn't feel right | User feedback | Captions back under Clicky's cursor, held still while it talks so they can be clicked |
| Notch caption hung far below the notch and blocked browser tabs, with empty black space above the text | User testing (screenshot) | Thin 20pt band under the notch, black only over the notch itself, one-line captions split into short phrases |
| Some people won't want captions | User feedback | Captions switch in the menu bar panel (on by default) |
| A caption under the cursor can't be clicked (it moves away with your mouse) | Design review | Moved captions to the notch, which never moves; clicking opens the transcript |
| Missed what Clicky said? Asking again cost a Claude call and could change the answer | Product review (accessibility for older users) | Captions, plus "say that again" replays the saved audio for free |
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
| Hands-free mic would hear Clicky's own voice | Design review | Mic pauses whenever Clicky is thinking or talking (later replaced by talk-over, which keeps the mic on and subtracts Clicky's voice) |
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
