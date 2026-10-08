"""Render Hollow Bell's original score and Foley, then measure the actual files.

Python 3.12 + NumPy. FFmpeg is resolved from imageio_ffmpeg or PATH; no downloads,
services, credentials, scipy, or soundfile. Run this file to regenerate everything;
--validate-only re-decodes existing assets; --verify-determinism re-renders in
memory and compares every WAV/OGG byte against the existing deliverables.

All pitches, rhythms, synthesis, room impulses and random seeds are authored here.
There are no sampled recordings. WAVs are stereo 16-bit PCM, music is also Vorbis.
Looping mixes fold BOTH note releases and room tails over the exact bar boundary.
Only assets/audio/** and qa/audio-analysis.json are written by this program.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib
import io
import json
import math
import re
import shutil
import subprocess
import sys
import wave
from collections import Counter
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

import numpy as np
from numpy.typing import NDArray


SR = 44100
SEED = 8102026
ROOT = Path(__file__).resolve().parents[1]
AUDIO = ROOT / "assets" / "audio"
REPORT = ROOT / "qa" / "audio-analysis.json"
FloatAudio = NDArray[np.float32]
MUSIC_LENGTHS = {"explore": 96.0, "boss": 80.0, "victory": 10.0}
SFX_LENGTHS = {
    "step": 0.19, "jump": 0.34, "land": 0.43, "sword": 0.39,
    "heavy": 0.76, "hit": 0.29, "parry": 0.83, "roll": 0.48,
    "heal": 1.55, "bow": 0.42, "magic": 1.10, "wing": 0.57,
    "slam": 1.05, "bell": 3.20, "checkpoint": 2.25, "death": 2.05,
    "ui": 0.15,
}
SFX_DESCRIPTIONS = {
    "step": "leather sole, gritty stone and a small heel resonance",
    "jump": "leather lift and a short moving air envelope",
    "land": "two-stage boot impact with low wooden-body resonance",
    "sword": "shaped air cut with a quiet steel edge ring",
    "heavy": "anticipation, broad blade swish and low impact",
    "hit": "non-graphic cloth/armor impact, no vocal or injury sounds",
    "parry": "inharmonic shield/steel transient and bright short ring",
    "roll": "three overlapping cloth/leather brushes",
    "heal": "cork pop, liquid-like resonances and ascending warm plucks",
    "bow": "taut string release, wooden body and bolt air",
    "magic": "rising airy resonance with a modal bell/pluck answer",
    "wing": "two broad, asymmetric feather/cloth air pulses",
    "slam": "low frame-drum body, stone resonances and debris tail",
    "bell": "low bronze toll with hum, prime, minor third and nominal",
    "checkpoint": "the score's D-A-C-D motif in warm bell/plucked tones",
    "death": "descending bowed phrase and a fading low bronze hum",
    "ui": "short rounded wooden pluck, not a square-wave bleep",
}
# Eight bars in D Aeolian: Dm(add9), C, Bb, Asus, Dm/F, Gm, C(add9), Am(sus).
CHORDS = (
    (50, 57, 62, 65, 69), (48, 55, 60, 64, 67),
    (46, 53, 58, 62, 65), (45, 52, 57, 62, 67),
    (53, 57, 62, 65, 69), (43, 50, 55, 58, 62),
    (48, 55, 60, 62, 67), (45, 52, 57, 60, 62),
)
MELODY = (
    (74, 69, 72, 74, 77, 76, 74, 69),
    (67, 70, 69, 65, 64, 67, 69, 72),
    (74, 76, 77, 81, 79, 77, 76, 74),
    (72, 70, 69, 67, 76, 74, 72, 69),
)
RHYTHM = (1.5, 0.5, 1.0, 1.0, 1.5, 0.5, 1.0, 1.0)


@dataclass(frozen=True, slots=True)
class Note:
    instrument: str
    time: float
    midi: float
    length: float
    gain: float
    pan: float = 0.0
    variant: int = 0


def db(amplitude: float) -> float:
    return 20.0 * math.log10(max(float(amplitude), 1e-12))


def rms(samples: FloatAudio) -> float:
    return math.sqrt(float(np.sum(samples * samples, dtype=np.float64)) / samples.size)


def hz(midi: float) -> float:
    return 440.0 * 2.0 ** ((midi - 69.0) / 12.0)


def smooth_noise(rng: np.random.Generator, frames: int, width: int) -> FloatAudio:
    noise = rng.standard_normal(frames + width - 1).astype(np.float32)
    kernel = np.full(width, 1.0 / math.sqrt(width), dtype=np.float32)
    return np.convolve(noise, kernel, mode="valid").astype(np.float32)


def envelope(t: NDArray[Any], length: float, attack: float, release: float) -> NDArray[Any]:
    front = np.sin(np.clip(t / attack, 0.0, 1.0) * math.pi * 0.5) ** 2
    back = np.sin(np.clip((length - t) / release, 0.0, 1.0) * math.pi * 0.5) ** 2
    return front * back


def synth_voice(kind: str, midi: float, length: float, variant: int = 0) -> FloatAudio:
    """Small acoustic-inspired modal models, not chip oscillators or recordings."""
    frames = max(8, round(length * SR))
    t = np.arange(frames, dtype=np.float64) / SR
    f = hz(midi)
    salt = sum((index + 1) * ord(letter) for index, letter in enumerate(kind))
    rng = np.random.default_rng(SEED + frames * 17 + round(midi * 100) * 31 + variant * 7919 + salt)
    result = np.zeros(frames, dtype=np.float64)
    if kind == "lute":
        # Two slightly detuned courses; pluck position rejects selected harmonics.
        # Higher modes decay more quickly, with slight string stiffness.
        for cents in (-3.1 - variant * 0.35, 3.8 + variant * 0.27):
            course = f * 2.0 ** (cents / 1200.0)
            for partial in range(1, 15):
                frequency = course * partial * math.sqrt(1.0 + 0.000045 * partial * partial)
                if frequency > SR * 0.43:
                    continue
                weight = math.sin(math.pi * partial * 0.217) / partial ** 1.12
                decay = (0.70 + 75.0 / f) / partial ** 0.62
                result += weight * np.sin(2.0 * math.pi * frequency * t) * np.exp(-t / decay)
        body = smooth_noise(rng, frames, 31)
        result += 0.11 * body * np.exp(-t * 65.0)
        result += 0.075 * np.sin(2.0 * math.pi * 196.0 * t) * np.exp(-t * 16.0)
        result *= envelope(t, length, 0.0035, min(0.085, length * 0.25)) / 1.9
    elif kind == "flute":
        vibrato = 0.0035 * np.sin(2.0 * math.pi * (4.85 + variant * 0.17) * t)
        vibrato *= 1.0 - np.exp(-t * 4.0)
        breath_drift = 0.0008 * np.sin(2.0 * math.pi * 1.2 * t + variant)
        phase = np.cumsum(2.0 * math.pi * f * (1.0 + vibrato + breath_drift) / SR)
        for partial, weight in ((1, 0.86), (2, 0.16), (3, 0.065), (4, 0.026), (6, 0.009)):
            result += weight * np.sin(partial * phase + partial * 0.09)
        breath = smooth_noise(rng, frames, 5)
        breath -= np.convolve(breath, np.full(31, 1.0 / 31.0), mode="same")
        result += breath * (0.024 + 0.047 * np.exp(-t * 24.0))
        result *= 0.80 + 0.08 * np.sin(math.pi * t / length)
        result *= envelope(t, length, min(0.055, length * 0.15), min(0.16, length * 0.32))
    elif kind == "bowed":
        for musician, cents in enumerate((-5.0, 4.2)):
            vibrato = 0.0025 * np.sin(2.0 * math.pi * (4.3 + musician * 0.71) * t + variant)
            phase = np.cumsum(2.0 * math.pi * f * 2.0 ** (cents / 1200.0) * (1.0 + vibrato) / SR)
            for partial in range(1, 13):
                if partial * f > SR * 0.43:
                    continue
                formant = 0.7 + 0.55 * math.exp(-((partial * f - 900.0) / 660.0) ** 2)
                result += formant * np.sin(partial * phase) / partial ** 1.48
        result += 0.019 * smooth_noise(rng, frames, 9)
        result *= (0.88 + 0.055 * np.sin(2.0 * math.pi * 0.8 * t + variant)) / 2.5
        result *= envelope(t, length, min(0.19, length * 0.25), min(0.42, length * 0.35))
    elif kind == "drum":
        phase = 2.0 * math.pi * (f * t + f * 0.48 * (1.0 - np.exp(-t * 62.0)) / 62.0)
        result = 0.75 * np.sin(phase) * np.exp(-t * 7.2)
        result += 0.23 * np.sin(phase * 1.59) * np.exp(-t * 13.5)
        result += 0.15 * np.sin(phase * 2.14) * np.exp(-t * 21.0)
        result += 0.12 * smooth_noise(rng, frames, 7) * np.exp(-t * 41.0)
        result *= envelope(t, length, 0.002, min(0.07, length * 0.3))
    elif kind == "bell":
        for ratio, weight, decay in (
            (0.5, 0.46, 2.6), (1.0, 0.60, 2.1), (1.189, 0.21, 1.4),
            (1.503, 0.16, 1.1), (2.003, 0.31, 1.75), (2.756, 0.09, 0.7),
            (4.071, 0.045, 0.42),
        ):
            result += weight * np.sin(2.0 * math.pi * f * ratio * t) * np.exp(-t / decay)
        result += 0.022 * smooth_noise(rng, frames, 3) * np.exp(-t * 90.0)
        result *= envelope(t, length, 0.004, min(0.5, length * 0.3)) / 1.35
    else:
        raise ValueError(f"Unknown voice: {kind}")
    return result.astype(np.float32)


@lru_cache(maxsize=384)
def voice(kind: str, midi: float, length: float, variant: int) -> FloatAudio:
    # Three performances per note keep repeated arpeggios from sounding stamped.
    return synth_voice(kind, midi, length, variant)


def add_audio(dest: FloatAudio, mono: FloatAudio, at: float, gain: float, pan: float, loop: bool) -> None:
    position = round(at * SR)
    pan = max(-1.0, min(1.0, pan))
    levels = (gain * math.cos((pan + 1.0) * math.pi / 4.0),
              gain * math.sin((pan + 1.0) * math.pi / 4.0))
    offset = 0
    if loop:
        position %= len(dest)
    elif position < 0:
        offset = -position
        position = 0
    while offset < len(mono) and position < len(dest):
        count = min(len(mono) - offset, len(dest) - position)
        for channel in range(2):
            dest[position:position + count, channel] += mono[offset:offset + count] * levels[channel]
        offset += count
        position += count
        if loop and position == len(dest):
            position = 0


def room(dry: FloatAudio, loop: bool, seconds: float, wet: float, salt: int) -> FloatAudio:
    """Early stone-room reflections plus decorrelated, low-passed diffuse decay."""
    size = round(seconds * SR)
    full_length = len(dry) + size - 1
    fft_size = 1 << (full_length - 1).bit_length()
    result = dry.copy()
    for channel in range(2):
        rng = np.random.default_rng(SEED + salt + channel * 313)
        impulse = np.zeros(size, dtype=np.float32)
        for index, delay in enumerate((0.019, 0.031, 0.047, 0.063, 0.089, 0.113, 0.157, 0.211, 0.293)):
            position = round((delay + channel * (0.0017 + index * 0.0009)) * SR)
            if position < size:
                impulse[position] = 0.40 * math.exp(-delay * 5.0) * (-1.0 if index % 4 == 3 else 1.0)
        t = np.arange(size, dtype=np.float64) / SR
        diffuse = smooth_noise(rng, size, 13)
        diffuse *= (0.0014 * np.exp(-t * 5.0 / seconds) * np.clip((t - 0.065) / 0.09, 0, 1)).astype(np.float32)
        impulse += diffuse
        impulse *= np.clip((seconds - t) / 0.09, 0.0, 1.0).astype(np.float32)
        impulse = np.convolve(impulse, np.array([0.12, 0.23, 0.30, 0.23, 0.12], dtype=np.float32), mode="same")
        source = dry[:, channel] * 0.83 + dry[:, 1 - channel] * 0.17
        reflected = np.fft.irfft(np.fft.rfft(source, fft_size) * np.fft.rfft(impulse, fft_size), fft_size)
        result[:, channel] += reflected[:len(dry)].astype(np.float32) * wet
        if loop:
            tail = reflected[len(dry):full_length].astype(np.float32)
            for offset in range(0, len(tail), len(dry)):
                part = tail[offset:offset + len(dry)]
                result[:len(part), channel] += part * wet
    return result


def music_score(name: str) -> tuple[list[Note], dict[str, Any]]:
    notes: list[Note] = []
    if name == "victory":
        for index, (at, pitch) in enumerate(zip((0.0, 0.55, 1.1, 1.65, 2.3, 3.0, 3.7), MELODY[0][:7])):
            notes.append(Note("flute", at, pitch, 0.82 if index < 6 else 1.5, 0.18, -0.12, index % 3))
            notes.append(Note("lute", at, pitch - 12, 1.65, 0.19, 0.40, index % 3))
        # A restrained Picardy third brightens the final D chord, not a fanfare.
        for bar, chord in enumerate(((50, 57, 62, 65), (43, 55, 58, 62), (50, 57, 62, 66))):
            for index, pitch in enumerate(chord):
                notes.append(Note("bowed", bar * 2.0, pitch, 3.35, 0.080, -0.55 + index * 0.35, index % 3))
            for index in range(8):
                notes.append(Note("lute", bar * 2.0 + index * 0.24, chord[index % 4] + 12, 1.35, 0.10, (-1) ** index * 0.4, index % 3))
        notes.extend((Note("bell", 0.0, 62, 4.0, 0.09, -0.32),
                      Note("bell", 5.8, 74, 4.1, 0.12, 0.25),
                      Note("flute", 5.0, 78, 1.0, 0.09, 0.15),
                      Note("flute", 5.85, 74, 2.25, 0.13, -0.12)))
        return notes, {"bpm": 109.090909, "loop": False, "form": "motif, answer, Picardy-third release", "mode": "D Aeolian; final D major"}

    boss = name == "boss"
    beat = 0.625 if boss else 0.75
    bar_length = beat * 4.0
    section_gains = (0.90, 1.04, 1.17, 1.00) if boss else (0.80, 0.96, 1.13, 0.85)
    rng = np.random.default_rng(SEED + (200 if boss else 100))
    for bar in range(32):
        section = bar // 8
        shape = section_gains[section]
        chord = CHORDS[bar % 8]
        if section == 1 and bar % 8 == 2:
            chord = (41, 53, 57, 60, 65)  # Relative-major answer on the second phrase.
        at = bar * bar_length
        pattern = tuple(index / 3.0 for index in range(12)) if boss else (0.0, 0.75, 1.5, 2.0, 2.75, 3.5)
        order = (0, 2, 3, 1, 4, 2, 1, 3, 4, 2, 3, 1)
        for index, pulse in enumerate(pattern):
            pitch = chord[order[index]] + (12 if section == 2 and index % 3 == 2 else 0)
            human_time = float(rng.uniform(-0.005, 0.005)) if pulse > 0 else 0.0
            strength = (0.145 if boss else 0.155) * shape * (1.12 if index == 0 else float(rng.uniform(0.83, 1.02)))
            notes.append(Note("lute", at + pulse * beat + human_time, pitch, 1.40, strength,
                              -0.42 if index % 2 == 0 else 0.38, (index + section) % 3))
        # Slow bows cross the barline, including the final bar -> first bar.
        for index, pitch in enumerate(chord[1:4]):
            notes.append(Note("bowed", at - 0.08, pitch + (12 if boss and index == 2 else 0),
                              round(bar_length + 0.42, 3), (0.079 if boss else 0.059) * shape,
                              -0.58 + index * 0.55, (bar + index) % 3))
        notes.append(Note("bowed", at, chord[0] - 12, round(bar_length + 0.30, 3),
                          (0.071 if boss else 0.047) * shape, -0.08, bar % 3))
        if boss:
            for index, pulse in enumerate((0.0, 0.75, 1.5, 2.0, 2.5, 3.25, 3.75)):
                strength = (0.21, 0.068, 0.12, 0.16, 0.070, 0.105, 0.061)[index]
                notes.append(Note("drum", at + pulse * beat, 33 if index in (0, 3) else 40,
                                  0.66, strength * shape, -0.12 if index % 2 else 0.13, index % 3))
        else:
            notes.append(Note("drum", at, 38, 0.66, 0.082 * shape, -0.12, bar % 3))
            if bar % 2 or section == 2:
                notes.append(Note("drum", at + 2.5 * beat, 45, 0.45, 0.040 * shape, 0.21, bar % 3))
        if bar % 8 == 0:
            notes.append(Note("bell", at, 50 if boss else 62, 4.6, (0.11 if boss else 0.050) * shape, 0.30, section % 3))
        if boss and bar % 8 == 6:
            notes.append(Note("bell", at + 2.0 * beat, 57, 3.8, 0.068, -0.25, section % 3))

    for section in range(4):
        shape = section_gains[section]
        for phrase, pitches in enumerate(MELODY):
            elapsed = 0.0
            for index, (pitch, beats) in enumerate(zip(pitches, RHYTHM)):
                # A lower-register response and selective grace notes, not copy/paste bars.
                octave = -12 if section == 1 and phrase in (1, 3) else 0
                at = section * 8.0 * bar_length + phrase * 2.0 * bar_length + elapsed * beat
                length = round(beats * beat * 0.84 + 0.06, 3)
                notes.append(Note("flute", at + 0.026, pitch + octave, length,
                                  (0.169 if boss else 0.177) * shape, -0.13, (section + index) % 3))
                if boss or (section == 2 and phrase == 2):
                    notes.append(Note("bowed", at, pitch - 12, round(length + 0.15, 3),
                                      (0.126 if boss else 0.056) * shape, 0.28, index % 3))
                if section == 2 and index in (2, 6):
                    notes.append(Note("lute", at - 0.13, pitch + 2, 0.55, 0.078, 0.36, 2))
                elapsed += beats
    notes.append(Note("bell", MUSIC_LENGTHS[name] - beat, 57, 4.2, 0.041 if boss else 0.025, -0.29))
    return notes, {
        "bpm": 96 if boss else 80, "meter": "4/4", "bars": 32, "loop": True,
        "mode": "D Aeolian", "motif_midi": list(MELODY[0]), "motif_beats": list(RHYTHM),
        "form": [
            {"start_bar": 1, "character": "statement", "orchestration_gain": section_gains[0]},
            {"start_bar": 9, "character": "lower-register answer, relative-major reharmonization", "orchestration_gain": section_gains[1]},
            {"start_bar": 17, "character": "upper plucks, bowed doubling and grace notes", "orchestration_gain": section_gains[2]},
            {"start_bar": 25, "character": "restrained return, suspended A into the opening D", "orchestration_gain": section_gains[3]},
        ],
    }


def master(samples: FloatAudio, target_db: float, loop: bool) -> tuple[FloatAudio, dict[str, float]]:
    samples -= np.mean(samples, axis=0, dtype=np.float64).astype(np.float32)
    if not loop:
        fade_in = min(round(0.003 * SR), len(samples))
        fade_out = min(round((0.65 if len(samples) > 5 * SR else 0.055) * SR), len(samples) // 3)
        samples[:fade_in] *= np.linspace(0, 1, fade_in, dtype=np.float32)[:, None] ** 2
        samples[-fade_out:] *= np.linspace(1, 0, fade_out, dtype=np.float32)[:, None] ** 2
    before_rms = rms(samples)
    before_peak = float(np.max(np.abs(samples)))
    # Fixed gain ONLY: preserve phrase dynamics, no automatic makeup or loudnorm compression.
    gain = min(10.0 ** (target_db / 20.0) / max(before_rms, 1e-9), 0.76 / max(before_peak, 1e-9))
    samples *= gain
    return samples, {"fixed_gain_db": db(gain), "target_rms_dbfs": target_db, "input_rms_dbfs": db(before_rms)}


def render_music(name: str) -> tuple[FloatAudio, dict[str, Any]]:
    notes, score = music_score(name)
    loop = name != "victory"
    mix = np.zeros((round(MUSIC_LENGTHS[name] * SR), 2), dtype=np.float32)
    for note in notes:
        mono = voice(note.instrument, note.midi, note.length, note.variant)
        add_audio(mix, mono, note.time, note.gain, note.pan, loop)
    mix = room(mix, loop, 1.35, 0.28, 101 if name == "explore" else 202)
    mix, mastering = master(mix, -18.5 if name == "boss" else -21.0, loop)
    score.update({"note_events": len(notes), "events_by_instrument": dict(Counter(note.instrument for note in notes)),
                  "mastering": mastering, "release_and_room_tail_wrap": loop})
    return mix, score


def render_sfx(name: str) -> FloatAudio:
    length = SFX_LENGTHS[name]
    frames = round(length * SR)
    mix = np.zeros((frames, 2), dtype=np.float32)
    rng = np.random.default_rng(SEED + sum(ord(letter) * (index + 1) for index, letter in enumerate(name)))

    def note(kind: str, at: float, midi: float, duration: float, gain: float, pan: float = 0.0) -> None:
        add_audio(mix, voice(kind, midi, duration, 1), at, gain, pan, False)

    def brush(at: float, duration: float, gain: float, width: int, pan: float, attack: float = 0.01) -> None:
        count = round(duration * SR)
        t = np.arange(count, dtype=np.float64) / SR
        noise = smooth_noise(rng, count, width)
        shape = envelope(t, duration, attack, max(0.02, duration * 0.6))
        add_audio(mix, (noise * shape * np.exp(-t * 2.0 / duration)).astype(np.float32), at, gain, pan, False)

    def resonance(at: float, frequency: float, duration: float, gain: float, pan: float, decay: float = 9.0) -> None:
        count = round(duration * SR)
        t = np.arange(count, dtype=np.float64) / SR
        body = np.sin(2.0 * math.pi * frequency * t) * np.exp(-t * decay)
        body *= envelope(t, duration, 0.002, min(0.09, duration * 0.4))
        add_audio(mix, body.astype(np.float32), at, gain, pan, False)

    if name == "step":
        brush(0.0, 0.105, 0.42, 14, -0.18, 0.003)
        brush(0.045, 0.09, 0.21, 4, 0.22, 0.004)
        resonance(0.005, 158, 0.15, 0.42, 0.0, 29.0)
    elif name == "jump":
        brush(0.0, 0.12, 0.36, 19, -0.20)
        brush(0.05, 0.26, 0.32, 6, 0.28, 0.06)
        resonance(0.0, 118, 0.16, 0.23, -0.1, 24.0)
    elif name == "land":
        note("drum", 0.0, 40, 0.38, 0.68, -0.10)
        brush(0.01, 0.20, 0.45, 21, 0.15, 0.002)
        resonance(0.027, 176, 0.27, 0.25, 0.32, 18.0)
    elif name == "sword":
        brush(0.0, 0.31, 0.65, 3, -0.30, 0.065)
        brush(0.065, 0.26, 0.34, 11, 0.35, 0.025)
        resonance(0.07, 1360, 0.24, 0.08, 0.20, 14.0)
    elif name == "heavy":
        brush(0.0, 0.26, 0.22, 18, -0.34, 0.085)
        brush(0.17, 0.47, 0.65, 8, 0.32, 0.06)
        note("drum", 0.30, 33, 0.44, 0.64, -0.05)
        resonance(0.29, 296, 0.42, 0.20, 0.15, 9.0)
    elif name == "hit":
        brush(0.0, 0.12, 0.57, 8, -0.1, 0.002)
        resonance(0.0, 187, 0.25, 0.59, 0.05, 20.0)
        resonance(0.01, 431, 0.19, 0.19, 0.35, 27.0)
    elif name == "parry":
        brush(0.0, 0.075, 0.22, 2, 0.0, 0.001)
        for index, frequency in enumerate((733, 1177, 1841, 2773, 4013)):
            resonance(0.0, frequency, 0.76, 0.38 / (1 + index * 0.5), (-1) ** index * 0.27, 5.5 + index * 2.0)
    elif name == "roll":
        for at, pan, strength in ((0.0, -0.35, 0.36), (0.105, 0.05, 0.49), (0.235, 0.37, 0.29)):
            brush(at, 0.22, strength, 17, pan, 0.025)
        resonance(0.23, 121, 0.19, 0.22, 0.18, 19.0)
    elif name == "heal":
        resonance(0.0, 510, 0.07, 0.19, -0.2, 45.0)
        for index, pitch in enumerate((62, 65, 69, 74)):
            note("lute", 0.12 + index * 0.16, pitch, 0.90, 0.27, -0.34 + index * 0.22)
        for index in range(5):
            resonance(0.10 + index * 0.057, 380 + index * 109, 0.12, 0.067, 0.2, 26.0)
        note("bell", 0.65, 74, 0.87, 0.14, 0.2)
    elif name == "bow":
        note("lute", 0.0, 50, 0.36, 0.47, -0.2)
        brush(0.008, 0.27, 0.41, 3, 0.30, 0.014)
        resonance(0.0, 312, 0.22, 0.23, -0.1, 17.0)
    elif name == "magic":
        brush(0.0, 0.68, 0.22, 7, -0.22, 0.20)
        for index, pitch in enumerate((69, 72, 74, 77)):
            note("bell", index * 0.11, pitch, 0.70, 0.21, -0.35 + index * 0.24)
        note("flute", 0.24, 74, 0.64, 0.10, 0.18)
    elif name == "wing":
        brush(0.0, 0.32, 0.58, 27, -0.35, 0.045)
        brush(0.19, 0.31, 0.42, 11, 0.35, 0.08)
        resonance(0.0, 94, 0.24, 0.17, -0.2, 17.0)
    elif name == "slam":
        note("drum", 0.0, 28, 0.9, 0.80, -0.05)
        note("drum", 0.026, 40, 0.64, 0.39, 0.16)
        brush(0.008, 0.63, 0.40, 25, -0.23, 0.002)
        for index, frequency in enumerate((117, 193, 319, 521)):
            resonance(0.018 * index, frequency, 0.72, 0.20 / (index + 1), (-1) ** index * 0.35, 7.5 + index)
    elif name == "bell":
        note("bell", 0.0, 50, 3.2, 0.72, -0.08)
    elif name == "checkpoint":
        for index, pitch in enumerate((62, 69, 72, 74)):
            note("bell", index * 0.23, pitch, 1.55, 0.24, -0.36 + index * 0.24)
            note("lute", index * 0.23, pitch - 12, 1.35, 0.18, 0.24 - index * 0.15)
    elif name == "death":
        for index, pitch in enumerate((65, 64, 62, 57)):
            note("bowed", index * 0.27, pitch - 12, 1.10, 0.24, -0.30 + index * 0.20)
        note("bell", 0.24, 38, 1.80, 0.19, 0.0)
    elif name == "ui":
        note("lute", 0.0, 74, 0.14, 0.47, -0.15)
        resonance(0.0, 587.33, 0.12, 0.22, 0.15, 35.0)
    else:
        raise ValueError(name)
    mix = room(mix, False, min(0.55, length * 0.9), 0.25, 777)
    mix, _ = master(mix, -20.0 if name in ("step", "roll", "ui") else -17.0, False)
    return mix


def pcm_bytes(samples: FloatAudio, salt: int, loop: bool) -> bytes:
    rng = np.random.default_rng(SEED + salt)
    dither = rng.random(samples.shape, dtype=np.float32) - rng.random(samples.shape, dtype=np.float32)
    scaled = np.rint(samples * 32768.0 + dither)
    if not np.all(np.isfinite(scaled)) or np.max(np.abs(scaled)) >= 32767:
        raise ValueError("Nonfinite samples or PCM clipping before export")
    pcm = scaled.astype("<i2")
    if not loop:
        pcm[0] = 0
        pcm[-1] = 0
    return pcm.tobytes()


def wav_bytes(pcm: bytes) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(SR)
        wav.writeframes(pcm)
    return output.getvalue()


def ffmpeg_path() -> str:
    try:
        module = importlib.import_module("imageio_ffmpeg")
        executable = str(module.get_ffmpeg_exe())
    except ImportError:
        executable = shutil.which("ffmpeg") or ""
    if not executable or not Path(executable).is_file():
        raise RuntimeError("FFmpeg not found locally; provide imageio_ffmpeg or FFmpeg on PATH. Nothing is downloaded.")
    return executable


def encode_ogg(ffmpeg: str, pcm: bytes, name: str) -> bytes:
    command = [ffmpeg, "-nostdin", "-v", "error", "-f", "s16le", "-ar", str(SR), "-ac", "2",
               "-i", "pipe:0", "-map_metadata", "-1", "-c:a", "libvorbis", "-q:a", "6",
               "-fflags", "+bitexact", "-flags:a", "+bitexact", "-serial_offset", "0",
               "-metadata", f"title=Hollow Bell - {name}",
               "-metadata", "artist=Hollow Bell original procedural score"]
    if name != "victory":
        command += ["-metadata", "LOOPSTART=0", "-metadata", f"LOOPEND={len(pcm) // 4}",
                    "-metadata", f"LOOPLENGTH={len(pcm) // 4}"]
    command += ["-f", "ogg", "pipe:1"]
    result = subprocess.run(command, input=pcm, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    if not result.stdout.startswith(b"OggS"):
        raise RuntimeError(f"No Ogg bitstream for {name}: {result.stderr.decode(errors='replace')}")
    return result.stdout


def decode(path: Path, ffmpeg: str) -> FloatAudio:
    if path.suffix == ".wav":
        with wave.open(str(path), "rb") as wav:
            if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getcomptype()) != (2, 2, SR, "NONE"):
                raise ValueError(f"Wrong PCM format: {path}")
            return np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2").reshape(-1, 2).astype(np.float32) / 32768.0
    result = subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-i", str(path), "-f", "f32le",
                             "-acodec", "pcm_f32le", "-ar", str(SR), "-ac", "2", "pipe:1"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    return np.frombuffer(result.stdout, dtype="<f4").reshape(-1, 2).copy()


def r128(path: Path, ffmpeg: str) -> dict[str, float]:
    result = subprocess.run([ffmpeg, "-nostdin", "-hide_banner", "-nostats", "-i", str(path),
                             "-af", "ebur128=peak=true:framelog=verbose", "-f", "null", "-"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, encoding="utf-8", check=True)
    summary = result.stderr.rsplit("Summary:", 1)[-1]
    values: dict[str, float] = {}
    for key, pattern in (("integrated_lufs", r"I:\s+(-?\d+(?:\.\d+)?) LUFS"),
                         ("loudness_range_lu", r"LRA:\s+(-?\d+(?:\.\d+)?) LU"),
                         ("true_peak_dbtp", r"Peak:\s+(-?\d+(?:\.\d+)?) dBFS")):
        found = re.search(pattern, summary)
        if found is None:
            raise RuntimeError(f"Missing R128 measurement {key}: {summary[-1800:]}")
        values[key] = float(found.group(1))
    return values


def measurements(samples: FloatAudio, loop: bool, phrase_seconds: float | None = None) -> dict[str, Any]:
    mid = (samples[:, 0] + samples[:, 1]) * 0.5
    side = (samples[:, 0] - samples[:, 1]) * 0.5
    # Float64 accumulation without promoting entire long stereo buffers.
    channels = [db(rms(samples[:, channel])) for channel in range(2)]
    correlation = float(np.corrcoef(samples[::4, 0], samples[::4, 1])[0, 1])
    result: dict[str, Any] = {
        "sample_rate": SR, "channels": 2, "frames": len(samples), "duration_seconds": len(samples) / SR,
        "sample_peak_dbfs": db(float(np.max(np.abs(samples)))), "rms_dbfs": db(rms(samples)),
        "channel_rms_dbfs": channels, "stereo_correlation": correlation,
        "side_to_mid_db": db(rms(side) / max(rms(mid), 1e-12)),
        "dc_offset": [float(value) for value in np.mean(samples, axis=0, dtype=np.float64)],
        "clipped_samples": int(np.count_nonzero(np.abs(samples) >= 1.0)),
        "all_samples_finite": bool(np.all(np.isfinite(samples))),
    }
    if loop:
        window = round(SR * 0.05)
        seam = np.concatenate((samples[-window:], samples[:window]))
        derivative = np.abs(np.diff(seam, axis=0))
        jump = float(np.max(np.abs(samples[0] - samples[-1])))
        reference = float(np.quantile(derivative, 0.999))
        result["loop_boundary"] = {
            "jump_amplitude": jump, "jump_dbfs": db(jump), "local_derivative_p999": reference,
            "jump_to_local_p999": jump / max(reference, 1e-12),
            "first_50ms_rms_dbfs": db(rms(samples[:window])),
            "last_50ms_rms_dbfs": db(rms(samples[-window:])),
            "rms_difference_db": abs(db(rms(samples[:window])) - db(rms(samples[-window:]))),
        }
    else:
        result["endpoint_peak"] = float(np.max(np.abs(samples[[0, -1]])))
    if phrase_seconds is not None:
        frames = round(phrase_seconds * SR)
        phrases = [samples[start:start + frames] for start in range(0, len(samples), frames)]
        result["phrase_rms_dbfs"] = [db(rms(phrase)) for phrase in phrases]
        result["adjacent_phrase_correlations"] = [
            float(np.corrcoef(phrases[index - 1][::8].reshape(-1), phrases[index][::8].reshape(-1))[0, 1])
            for index in range(1, len(phrases))
        ]
    return result


def self_checks() -> dict[str, bool]:
    # Test the actual overlap routine with a tail crossing an exact loop boundary.
    target = np.zeros((8, 2), dtype=np.float32)
    add_audio(target, np.array([1.0, 2.0, 3.0, 4.0], dtype=np.float32), 6 / SR, 1.0, -1.0, True)
    expected = np.array([3, 4, 0, 0, 0, 0, 1, 2], dtype=np.float32)
    wrap = bool(np.array_equal(target[:, 0], expected))
    a = synth_voice("lute", 57, 0.9, 2)
    b = synth_voice("lute", 57, 0.9, 2)
    spectrum = np.abs(np.fft.rfft(a * np.hanning(len(a))))
    frequencies = np.fft.rfftfreq(len(a), 1 / SR)
    band = (frequencies > 180) & (frequencies < 270)
    measured = float(frequencies[band][np.argmax(spectrum[band])])
    checks = {"tail_wrap_uses_real_samples": wrap, "fresh_voice_deterministic": bool(np.array_equal(a, b)),
              "lute_A3_fundamental_within_1_percent": abs(measured - 220.0) < 2.2,
              "all_17_required_sfx_distinct_names": len(SFX_LENGTHS) == 17}
    if not all(checks.values()):
        raise AssertionError(f"DSP self-checks failed: {checks}, measured lute fundamental={measured}")
    return checks


def publish(path: Path, content: bytes, verify: bool) -> None:
    if verify:
        if not path.is_file() or path.read_bytes() != content:
            raise AssertionError(f"Determinism mismatch: {path.relative_to(ROOT)}")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)


def validate(ffmpeg: str, compositions: dict[str, Any], deterministic: bool, checks: dict[str, bool]) -> dict[str, Any]:
    assets: dict[str, Any] = {}
    errors: list[str] = []

    def expect(condition: bool, description: str) -> None:
        if not condition:
            errors.append(description)

    specs: list[tuple[str, Path, float, bool, bool]] = []
    for name, seconds in MUSIC_LENGTHS.items():
        specs.append((f"music/{name}", AUDIO / "music" / f"{name}.ogg", seconds, name != "victory", True))
        specs.append((f"masters/{name}", AUDIO / "masters" / f"{name}.wav", seconds, name != "victory", True))
    specs.extend((f"sfx/{name}", AUDIO / "sfx" / f"{name}.wav", seconds, False, False)
                 for name, seconds in SFX_LENGTHS.items())
    pcm_references: dict[str, FloatAudio] = {}
    for key, path, seconds, loop, music in specs:
        samples = decode(path, ffmpeg)
        phrase_seconds = seconds / 4 if loop else None
        info = measurements(samples, loop, phrase_seconds)
        info.update({"path": path.relative_to(ROOT).as_posix(), "bytes": path.stat().st_size,
                     "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "loop": loop})
        if key.startswith("music/"):
            info.update(r128(path, ffmpeg))
            expect(info["true_peak_dbtp"] <= -1.0, f"{key}: true peak {info['true_peak_dbtp']} dBTP exceeds -1.0")
            pcm_references[key.split("/")[1]] = samples
        elif key.startswith("masters/"):
            reference = pcm_references.pop(key.split("/")[1])
            expect(len(reference) == len(samples), f"{key}: Vorbis decoded length differs from PCM")
            if len(reference) == len(samples):
                error_rms = rms(reference - samples)
                info["ogg_roundtrip_snr_db"] = db(rms(samples) / max(error_rms, 1e-12))
                expect(info["ogg_roundtrip_snr_db"] >= 24.0,
                       f"{key}: roundtrip SNR={info['ogg_roundtrip_snr_db']:.3f} dB <24")
        else:
            info["design"] = SFX_DESCRIPTIONS[key.split("/")[1]]
        expect(abs(info["duration_seconds"] - seconds) <= 1 / SR,
               f"{key}: duration={info['duration_seconds']}, expected {seconds}")
        expect(info["all_samples_finite"] and info["clipped_samples"] == 0,
               f"{key}: finite={info['all_samples_finite']}, clipped={info['clipped_samples']}")
        expect(info["sample_peak_dbfs"] <= -1.0, f"{key}: sample peak={info['sample_peak_dbfs']} dBFS")
        low, high = (-30.0, -13.0) if music else (-38.0, -10.0)
        expect(low <= info["rms_dbfs"] <= high, f"{key}: RMS={info['rms_dbfs']} outside {low}..{high}")
        expect(-0.25 < info["stereo_correlation"] < 0.9999,
               f"{key}: stereo correlation={info['stereo_correlation']}")
        expect(info["side_to_mid_db"] > -38.0, f"{key}: side/mid={info['side_to_mid_db']} dB")
        expect(max(abs(value) for value in info["dc_offset"]) < 0.003,
               f"{key}: DC offset={info['dc_offset']}")
        if loop:
            boundary = info["loop_boundary"]
            expect(boundary["jump_amplitude"] < 0.035,
                   f"{key}: loop jump={boundary['jump_amplitude']} >=0.035")
            expect(boundary["jump_to_local_p999"] < 2.0,
                   f"{key}: loop jump/local derivative={boundary['jump_to_local_p999']} >=2")
            expect(boundary["rms_difference_db"] < 9.0,
                   f"{key}: boundary RMS difference={boundary['rms_difference_db']} dB >=9")
            expect(max(abs(value) for value in info["adjacent_phrase_correlations"]) < 0.98,
                   f"{key}: insufficient phrase variation: {info['adjacent_phrase_correlations']}")
        elif not key.startswith("music/"):
            expect(info["endpoint_peak"] == 0.0, f"{key}: PCM one-shot endpoints are not zero")
        assets[key] = info
        print(f"  {key:20s} {info['duration_seconds']:6.2f}s  peak {info['sample_peak_dbfs']:6.2f}  "
              f"RMS {info['rms_dbfs']:6.2f}  stereo {info['stereo_correlation']:.4f}", flush=True)
    expect(assets["music/boss"]["rms_dbfs"] >= assets["music/explore"]["rms_dbfs"] + 0.5,
           f"Boss must intensify: boss RMS={assets['music/boss']['rms_dbfs']}, explore={assets['music/explore']['rms_dbfs']}")
    sfx_hashes = {value["sha256"] for key, value in assets.items() if key.startswith("sfx/")}
    expect(len(sfx_hashes) == 17, f"Expected 17 distinct SFX waveforms, got {len(sfx_hashes)}")
    return {
        "schema": "hollow-bell-audio-analysis/v1", "passed": not errors, "errors": errors,
        "provenance": "Original scores and acoustic-inspired DSP. No downloaded or sampled music/audio.",
        "sample_rate": SR, "seed": SEED, "python": sys.version.split()[0], "numpy": np.__version__,
        "generator_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "ffmpeg": ffmpeg, "dsp_self_checks": checks,
        "full_asset_byte_determinism_verified": deterministic,
        "music_files": 3, "pcm_masters": 3, "distinct_sfx_files": len(sfx_hashes),
        "composition": compositions, "assets": assets,
        "validation_scope": "Decoded PCM/Vorbis, R128 true peak, waveform/loop/phrase checks; not a listening review or full-game test.",
        "runtime_contract": {"master_default": 0.65, "music_players": 2, "sfx_pool": 16,
                             "crossfade_seconds": 1.15, "paused_music_gain": 0.24,
                             "victory_loops": False, "pause_allows_only_ui_sfx": True},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--validate-only", action="store_true", help="measure existing assets without synthesis")
    mode.add_argument("--verify-determinism", action="store_true", help="re-render without overwriting assets; compare every byte")
    args = parser.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    ffmpeg = ffmpeg_path()
    checks = self_checks()
    compositions: dict[str, Any] = {}
    if args.validate_only and REPORT.is_file():
        previous = json.loads(REPORT.read_text(encoding="utf-8"))
        compositions = previous.get("composition", {})
    if not args.validate_only:
        for index, name in enumerate(MUSIC_LENGTHS):
            print(f"Rendering original {name} ({MUSIC_LENGTHS[name]:.0f}s)...", flush=True)
            samples, score = render_music(name)
            compositions[name] = score
            pcm = pcm_bytes(samples, 1000 + index, name != "victory")
            publish(AUDIO / "masters" / f"{name}.wav", wav_bytes(pcm), args.verify_determinism)
            publish(AUDIO / "music" / f"{name}.ogg", encode_ogg(ffmpeg, pcm, name), args.verify_determinism)
            del samples, pcm
        for index, name in enumerate(SFX_LENGTHS):
            print(f"Rendering Foley {name}...", flush=True)
            pcm = pcm_bytes(render_sfx(name), 2000 + index, False)
            publish(AUDIO / "sfx" / f"{name}.wav", wav_bytes(pcm), args.verify_determinism)
        voice.cache_clear()
    print("Measuring actual decoded files (dBFS; 0 dBFS is full scale)...", flush=True)
    report = validate(ffmpeg, compositions, args.verify_determinism, checks)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(f"Report: {REPORT}", flush=True)
    if report["errors"]:
        for error in report["errors"]:
            print(f"FAIL: {error}", flush=True)
        return 1
    print(f"PASS: 3 music + 3 PCM masters + 17 distinct SFX; byte-determinism={args.verify_determinism}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())