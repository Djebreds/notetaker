#!/usr/bin/env python3
"""Generates synthetic test meetings with macOS voices for the model bench.

For every clip it writes <name>.flac (16 kHz mono), <name>.txt (reference text) and
<name>.json (reference utterances with start times). File names ending in "-me"
are transcribed as the user's own mic; everything else as "others".

Usage: scripts/make-bench-audio.py [output-dir]   (default: bench/samples)
"""
import json
import os
import subprocess
import sys
import tempfile
import wave

RATE = 16000

CLIPS = {
    "en-team": [
        ("Daniel", "Morning everyone. Let's start with the release plan for the mobile app."),
        ("Karen", "Sure. The payment screen is finished, but the onboarding flow still needs another review."),
        ("Moira", "I can review onboarding this afternoon and send comments to the design channel."),
        ("Daniel", "Great. Karen, can you update the release notes before Thursday?"),
        ("Karen", "Yes, I will have them ready by Thursday morning."),
        ("Moira", "One open question is whether we still support older Android versions."),
        ("Daniel", "Let's decide that next week, after we check the analytics."),
    ],
    "id-standup": [
        ("Damayanti", "Selamat pagi semuanya. Kemarin saya sudah menyelesaikan integrasi pembayaran dengan bank."),
        ("Damayanti", "Hari ini saya akan memperbaiki bug di halaman login dan menulis dokumentasi."),
        ("Damayanti", "Tidak ada kendala, tapi saya butuh akses ke server staging."),
    ],
    "ms-update": [
        ("Amira", "Selamat pagi. Saya sudah siapkan laporan kewangan untuk suku ketiga."),
        ("Amira", "Minggu depan kita perlu berbincang tentang bajet pemasaran."),
        ("Amira", "Tolong hantar maklum balas sebelum hari Jumaat."),
    ],
    "mixed-codeswitch": [
        ("Damayanti", "Jadi untuk sprint ini kita fokus ke API integration dulu ya."),
        ("Daniel", "Okay, what about the dashboard redesign?"),
        ("Damayanti", "Dashboard-nya kita push ke next sprint, karena designer-nya masih cuti."),
        ("Daniel", "Makes sense. I will tell the client tomorrow."),
        ("Damayanti", "Oke, nanti saya share deadline-nya di Slack."),
    ],
    "silence-then-speech-me": [
        ("<silence>", "25"),
        ("Daniel", "Sorry, I was on mute. I agree with the plan, let's ship it on Friday."),
    ],
}

GAPS = [0.7, 1.1, 0.8, 1.3, 0.9, 1.0]


def synthesize(voice, text, tmp):
    aiff = os.path.join(tmp, "u.aiff")
    wav = os.path.join(tmp, "u.wav")
    subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", aiff, wav], check=True)
    with wave.open(wav, "rb") as w:
        return w.readframes(w.getnframes())


def silence(seconds):
    return b"\x00\x00" * int(seconds * RATE)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "bench", "samples")
    os.makedirs(out_dir, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, utterances in CLIPS.items():
            pcm = bytearray(silence(0.5))
            reference = []
            for i, (voice, text) in enumerate(utterances):
                if voice == "<silence>":
                    pcm += silence(float(text))
                    continue
                start = len(pcm) / 2 / RATE
                pcm += synthesize(voice, text, tmp)
                reference.append({"start": round(start, 2), "speaker": voice, "text": text})
                pcm += silence(GAPS[i % len(GAPS)])
            wav = os.path.join(tmp, f"{name}.wav")
            with wave.open(wav, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(RATE)
                w.writeframes(bytes(pcm))
            flac = os.path.join(out_dir, f"{name}.flac")
            subprocess.run(["afconvert", "-f", "flac", "-d", "flac", wav, flac], check=True)
            with open(os.path.join(out_dir, f"{name}.json"), "w") as f:
                json.dump(reference, f, ensure_ascii=False, indent=2)
            with open(os.path.join(out_dir, f"{name}.txt"), "w") as f:
                f.write(" ".join(u["text"] for u in reference) + "\n")
            print(f"{name}: {len(pcm) / 2 / RATE:.1f} s, {len(reference)} utterances")


if __name__ == "__main__":
    main()
