# Usage: start the worker (cd worker && npx wrangler dev), then
#   python3 scripts/latency_benchmark.py "question one" "question two"
# Needs Pillow (pip install pillow). Each question costs about 1 cent.
# Measures how soon Clicky starts talking: old way (whole answer, then audio
# for all of it) vs new way (first sentence, then its audio). Same requests
# Clicky sends, through the local worker.
import base64, json, os, re, sys, time, urllib.request, glob, io
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
from PIL import Image

swift = open(os.path.join(REPO, 'leanring-buddy/') + 'CompanionManager.swift').read()
system_prompt = re.search(r'companionVoiceResponseSystemPrompt = """\n(.*?)\n\s*"""', swift, re.S).group(1)
system_prompt = "\n".join(line[4:] if line.startswith("    ") else line for line in system_prompt.split("\n"))

image_path = glob.glob(os.path.join(REPO, 'leanring-buddy/') + 'Assets.xcassets/codex-app-screenshot.imageset/*.jpg')[0]
image = Image.open(image_path).convert("RGB")
image.thumbnail((1280, 1280))
buffer = io.BytesIO(); image.save(buffer, "JPEG", quality=80)
image_b64 = base64.b64encode(buffer.getvalue()).decode()
label = f"user's screen (cursor is here) (image dimensions: {image.width}x{image.height} pixels)"

def first_segment_end(text):
    speakable = text.split("[", 1)[0]
    for m in re.finditer(r'[.!?](?=\s)|\n', speakable):
        candidate = " ".join(speakable[:m.end()].split())
        if len(candidate) >= 20:
            return candidate
    return None

def tts_seconds(text):
    body = json.dumps({"text": text, "model_id": "eleven_flash_v2_5",
                       "voice_settings": {"stability": 0.5, "similarity_boost": 0.75}}).encode()
    start = time.time()
    request = urllib.request.Request("http://localhost:8787/tts-with-timestamps", body, {"content-type": "application/json"})
    urllib.request.urlopen(request).read()
    return time.time() - start

questions = sys.argv[1:]
for question in questions:
    body = json.dumps({"model": "claude-sonnet-4-6", "max_tokens": 1024, "stream": True, "system": system_prompt,
        "messages": [{"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": image_b64}},
            {"type": "text", "text": label}, {"type": "text", "text": question}]}]}).encode()
    start = time.time()
    request = urllib.request.Request("http://localhost:8787/chat", body, {"content-type": "application/json"})
    text = ""; first_segment = None; first_segment_time = None
    with urllib.request.urlopen(request) as response:
        for raw_line in response:
            line = raw_line.decode().strip()
            if not line.startswith("data: "): continue
            event = json.loads(line[6:])
            if event.get("type") == "content_block_delta" and event["delta"].get("type") == "text_delta":
                text += event["delta"]["text"]
                if first_segment is None:
                    first_segment = first_segment_end(text)
                    if first_segment: first_segment_time = time.time() - start
    full_time = time.time() - start
    spoken = " ".join(re.sub(r'\[POINT:[^\]]*\]\s*$', '', text).split())
    old_latency = full_time + tts_seconds(spoken)
    if first_segment and first_segment != spoken:
        new_latency = first_segment_time + tts_seconds(first_segment)
    else:
        new_latency = old_latency  # one-sentence answer: same either way
    print(json.dumps({"question": question, "answer_chars": len(spoken), "first_piece": first_segment,
                      "claude_full_s": round(full_time, 2), "first_sentence_s": first_segment_time and round(first_segment_time, 2),
                      "old_start_talking_s": round(old_latency, 2), "new_start_talking_s": round(new_latency, 2)}))
