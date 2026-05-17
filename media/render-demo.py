#!/usr/bin/env python3
"""
Render synthetic whispertype demo frames as PNGs.

Storyboard (15 fps):
  0.0-1.0s : idle editor + status chip "idle"
  1.0-1.3s : Caps Lock press flash; status -> "recording"
  1.3-4.5s : waveform pulses; status "recording"; mic dot pulses
  4.5-4.8s : Caps Lock press flash; status -> "transcribing"
  4.8-6.0s : "transcribing..." with spinner
  6.0-9.5s : text streams word-by-word into editor
  9.5-11.0s: hold final frame; status fades back to "idle"
  11.0s    : loop point (frame matches first frame visually)

Frames are written to /tmp/wt-frames/f%04d.png; ffmpeg composes the GIF.
Re-run any time: python3 media/render-demo.py
"""

import math
import os
import random
import shutil
from PIL import Image, ImageDraw, ImageFont

# ---------------------------------------------------------------------------
# Canvas + palette
# ---------------------------------------------------------------------------

W, H = 800, 500
FPS = 15
OUT_DIR = "/tmp/wt-frames"

BG = (24, 27, 33)              # dark slate
PANEL = (32, 36, 44)            # editor panel
PANEL_EDGE = (52, 58, 68)
TEXT = (220, 224, 230)
DIM = (130, 138, 150)
MUTED = (90, 96, 108)
ACCENT = (95, 207, 215)         # cyan
ACCENT_DIM = (50, 110, 116)
RECORD = (235, 102, 102)        # red
RECORD_DIM = (110, 60, 60)

FONT_MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
FONT_MONO_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"

f_chip = ImageFont.truetype(FONT_MONO_BOLD, 14)
f_title = ImageFont.truetype(FONT_MONO_BOLD, 13)
f_body = ImageFont.truetype(FONT_MONO, 18)
f_small = ImageFont.truetype(FONT_MONO, 12)

random.seed(7)

FINAL_TEXT = "Hello world. This is whispertype - push-to-talk dictation for Linux."

# ---------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------

def new_frame():
    img = Image.new("RGB", (W, H), BG)
    return img, ImageDraw.Draw(img)


def rounded_rect(d, box, radius, fill=None, outline=None, width=1):
    d.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def draw_editor_chrome(d):
    # Top bar with traffic lights + title
    rounded_rect(d, (40, 40, W - 40, H - 60), 10, fill=PANEL, outline=PANEL_EDGE, width=1)
    # Title bar fill
    d.rectangle((41, 41, W - 41, 75), fill=(40, 44, 52))
    d.line((41, 75, W - 41, 75), fill=PANEL_EDGE, width=1)
    # Traffic lights
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = 62 + i * 22
        d.ellipse((cx - 6, 52, cx + 6, 64), fill=c)
    # Title
    d.text((W // 2 - 50, 54), "notes.txt", font=f_title, fill=DIM)


def draw_status_chip(d, label, color, accent_color, pulse=0.0):
    # Chip in top-right of editor title bar
    x1 = W - 230
    y1 = 48
    x2 = W - 60
    y2 = 70
    rounded_rect(d, (x1, y1, x2, y2), 11, fill=(50, 56, 66), outline=PANEL_EDGE)
    # Dot
    dot_r = 5 + pulse * 1.5
    cx, cy = x1 + 16, (y1 + y2) // 2
    d.ellipse((cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r), fill=color)
    d.text((x1 + 30, y1 + 3), f"whispertype - {label}", font=f_chip, fill=accent_color)


def draw_caps_lock(d, pressed=False):
    # Tiny keyboard glyph bottom-center
    kx, ky = W // 2 - 70, H - 90
    kw, kh = 140, 36
    bg = PANEL if not pressed else (60, 90, 96)
    edge = PANEL_EDGE if not pressed else ACCENT
    rounded_rect(d, (kx, ky, kx + kw, ky + kh), 6, fill=bg, outline=edge, width=2 if pressed else 1)
    label_color = ACCENT if pressed else DIM
    d.text((kx + 28, ky + 9), "Caps Lock", font=f_chip, fill=label_color)


def draw_waveform(d, t, active=True):
    # Centered waveform
    cx = W // 2
    cy = H // 2 + 10
    bars = 41
    spacing = 10
    base_w = 4
    total_w = bars * spacing
    left = cx - total_w // 2
    for i in range(bars):
        # Distance from center, normalized 0..1
        dist = abs(i - bars // 2) / (bars // 2)
        envelope = math.cos(dist * math.pi / 2)  # tall in middle
        # Time-varying with per-bar phase
        if active:
            phase = i * 0.4 + t * 6.0
            amp = 0.45 + 0.55 * (0.5 + 0.5 * math.sin(phase)) * (0.6 + 0.4 * math.sin(t * 3.1 + i * 0.2))
        else:
            amp = 0.08
        h = int(8 + 70 * envelope * amp)
        x = left + i * spacing
        color = ACCENT if active else MUTED
        rounded_rect(d, (x, cy - h, x + base_w, cy + h), 2, fill=color)


def draw_mic_glyph(d, cx, cy, color):
    # Stylized mic: rounded capsule + stand
    d.rounded_rectangle((cx - 8, cy - 14, cx + 8, cy + 6), radius=8, fill=color)
    d.arc((cx - 14, cy - 6, cx + 14, cy + 14), 0, 180, fill=color, width=2)
    d.line((cx, cy + 14, cx, cy + 22), fill=color, width=2)
    d.line((cx - 8, cy + 22, cx + 8, cy + 22), fill=color, width=2)


def draw_spinner(d, cx, cy, t, color=ACCENT):
    # 8-tick spinner
    ticks = 8
    for i in range(ticks):
        ang = (i / ticks) * 2 * math.pi + t * 6.0
        x1 = cx + math.cos(ang) * 8
        y1 = cy + math.sin(ang) * 8
        x2 = cx + math.cos(ang) * 14
        y2 = cy + math.sin(ang) * 14
        # fade based on position relative to head
        head = (t * 6.0) % (2 * math.pi)
        delta = (ang - head) % (2 * math.pi)
        alpha = max(0.15, 1.0 - delta / (2 * math.pi))
        c = tuple(int(color[k] * alpha + BG[k] * (1 - alpha)) for k in range(3))
        d.line((x1, y1, x2, y2), fill=c, width=3)


def draw_typed_text(d, text, cursor_visible=True):
    # Editor body: wrap simple, render with monospace
    x0, y0 = 70, 110
    line_h = 28
    max_w = W - 140
    lines = wrap_mono(text, f_body, max_w)
    for i, line in enumerate(lines):
        d.text((x0, y0 + i * line_h), line, font=f_body, fill=TEXT)
    # Cursor at end of last line
    last = lines[-1] if lines else ""
    bbox = d.textbbox((0, 0), last, font=f_body)
    cx = x0 + (bbox[2] - bbox[0])
    cy = y0 + (len(lines) - 1 if lines else 0) * line_h
    if cursor_visible:
        d.rectangle((cx + 2, cy + 2, cx + 12, cy + 24), fill=ACCENT)


def wrap_mono(text, font, max_w):
    # Simple monospace word-wrap
    words = text.split(" ")
    lines = []
    cur = ""
    for w in words:
        candidate = w if not cur else cur + " " + w
        bbox = font.getbbox(candidate)
        if bbox[2] - bbox[0] <= max_w:
            cur = candidate
        else:
            if cur:
                lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    if not lines:
        lines = [""]
    return lines


def draw_hint(d, text, color=MUTED):
    # bottom-right tiny hint
    d.text((60, H - 35), text, font=f_small, fill=color)


# ---------------------------------------------------------------------------
# Frame composer
# ---------------------------------------------------------------------------

def compose_frame(frame_idx, total_frames):
    t = frame_idx / FPS  # seconds
    img, d = new_frame()
    draw_editor_chrome(d)

    # Phase boundaries (seconds)
    T_IDLE_END = 1.0
    T_CAPS1 = 1.3
    T_REC_END = 4.5
    T_CAPS2 = 4.8
    T_TRANS_END = 6.0
    T_TYPE_END = 9.5
    T_HOLD_END = 11.0

    blink = (frame_idx // 7) % 2 == 0  # cursor blink ~2Hz

    if t < T_IDLE_END:
        # Idle
        draw_status_chip(d, "idle", MUTED, DIM)
        draw_caps_lock(d, pressed=False)
        draw_hint(d, "press Caps Lock to dictate")
        # Empty editor with a faint placeholder cursor
        d.rectangle((72, 112, 82, 134), fill=(60, 66, 76))

    elif t < T_CAPS1:
        # Caps press flash; transitioning to recording
        draw_status_chip(d, "recording", RECORD, RECORD)
        draw_caps_lock(d, pressed=True)
        draw_hint(d, "Caps Lock pressed", color=ACCENT)
        d.rectangle((72, 112, 82, 134), fill=(60, 66, 76))

    elif t < T_REC_END:
        # Recording: waveform + pulsing mic dot
        pulse = 0.5 + 0.5 * math.sin(t * 6.0)
        draw_status_chip(d, "recording", RECORD, RECORD, pulse=pulse)
        # Mic glyph next to waveform on the left
        draw_mic_glyph(d, 100, H // 2 + 10, RECORD)
        draw_waveform(d, t, active=True)
        draw_caps_lock(d, pressed=False)
        draw_hint(d, "listening...", color=DIM)

    elif t < T_CAPS2:
        # Second Caps press
        draw_status_chip(d, "transcribing", ACCENT, ACCENT)
        draw_caps_lock(d, pressed=True)
        draw_hint(d, "Caps Lock pressed", color=ACCENT)

    elif t < T_TRANS_END:
        # Transcribing with spinner
        draw_status_chip(d, "transcribing", ACCENT, ACCENT)
        draw_spinner(d, W // 2, H // 2 + 10, t - T_CAPS2)
        d.text((W // 2 - 70, H // 2 + 40), "transcribing...", font=f_body, fill=DIM)
        draw_caps_lock(d, pressed=False)
        draw_hint(d, "whisper.cpp large-v3", color=MUTED)

    elif t < T_TYPE_END:
        # Type text word by word
        draw_status_chip(d, "typing", ACCENT, ACCENT)
        progress = (t - T_TRANS_END) / (T_TYPE_END - T_TRANS_END)
        words = FINAL_TEXT.split(" ")
        # Slight ease-in then steady
        n = int(progress * len(words) + 0.0001)
        n = max(1, min(n, len(words)))
        partial = " ".join(words[:n])
        draw_typed_text(d, partial, cursor_visible=blink)
        draw_caps_lock(d, pressed=False)
        draw_hint(d, "typed via ydotool", color=MUTED)

    elif t < T_HOLD_END:
        # Hold final
        # Fade chip from typing -> idle near the end so loop is clean
        fade_t = (t - T_TYPE_END) / (T_HOLD_END - T_TYPE_END)
        if fade_t < 0.6:
            draw_status_chip(d, "typing", ACCENT, ACCENT)
        else:
            draw_status_chip(d, "idle", MUTED, DIM)
        draw_typed_text(d, FINAL_TEXT, cursor_visible=blink)
        draw_caps_lock(d, pressed=False)
        draw_hint(d, "press Caps Lock to dictate", color=MUTED)
    else:
        draw_status_chip(d, "idle", MUTED, DIM)
        d.rectangle((72, 112, 82, 134), fill=(60, 66, 76))
        draw_caps_lock(d, pressed=False)
        draw_hint(d, "press Caps Lock to dictate")

    return img


def main():
    if os.path.isdir(OUT_DIR):
        shutil.rmtree(OUT_DIR)
    os.makedirs(OUT_DIR, exist_ok=True)
    duration = 11.0  # seconds
    total = int(duration * FPS)
    for i in range(total):
        img = compose_frame(i, total)
        img.save(os.path.join(OUT_DIR, f"f{i:04d}.png"))
    print(f"Wrote {total} frames to {OUT_DIR}")


if __name__ == "__main__":
    main()
