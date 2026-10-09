[CmdletBinding()]
param()

# Original, deterministic DSP only. No recordings, network, playback or Godot import.
# Run from any working directory; only the nine named PCM WAVs are written.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$source = @'
using System;
using System.IO;
using System.Text;

public static class __AUDIO_DSP__
{
    const int Rate = 44100;
    const double Tau = 2.0 * Math.PI;
    const uint Seed = 0x51A71E29u;

    sealed class Noise
    {
        uint state;
        public Noise(uint seed) { state = seed == 0 ? 1u : seed; }
        public double Unit()
        {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            return (state + 0.5) / 4294967296.0;
        }
        public double White() { return 2.0 * Unit() - 1.0; }
    }

    sealed class Stereo
    {
        public readonly double[] L, R;
        public int Length { get { return L.Length; } }
        public Stereo(double seconds)
        {
            int frames = (int)Math.Round(seconds * Rate);
            L = new double[frames]; R = new double[frames];
        }
    }

    // Cookbook biquads, with band-pass unity gain at resonance.
    sealed class Filter
    {
        double b0, b1, b2, a1, a2, z1, z2;
        public Filter(string kind, double hz, double q)
        {
            double w = Tau * hz / Rate;
            double c = Math.Cos(w), alpha = Math.Sin(w) / (2.0 * q);
            double a0 = 1.0 + alpha;
            a1 = -2.0 * c / a0; a2 = (1.0 - alpha) / a0;
            if (kind == "low")
            {
                b0 = (1.0 - c) * 0.5 / a0;
                b1 = (1.0 - c) / a0; b2 = b0;
            }
            else if (kind == "high")
            {
                b0 = (1.0 + c) * 0.5 / a0;
                b1 = -(1.0 + c) / a0; b2 = b0;
            }
            else
            {
                b0 = alpha / a0; b1 = 0.0; b2 = -b0;
            }
        }
        public double Tick(double x)
        {
            double y = b0 * x + z1;
            z1 = b1 * x - a1 * y + z2;
            z2 = b2 * x - a2 * y;
            return y;
        }
    }

    static double Attack(double t, double seconds)
    {
        if (t <= 0.0) return 0.0;
        if (t >= seconds) return 1.0;
        return 0.5 - 0.5 * Math.Cos(Math.PI * t / seconds);
    }

    static double Tail(int index, int count, double seconds)
    {
        return Attack((count - 1 - index) / (double)Rate, seconds);
    }

    static void Pan(Stereo sound, int frame, double value, double pan)
    {
        // Small equal-power offsets, with unity gain at the centre.
        sound.L[frame] += value * Math.Sqrt(1.0 - pan);
        sound.R[frame] += value * Math.Sqrt(1.0 + pan);
    }

    static void Finish(Stereo sound, double gain, double high, double low,
        double fadeIn, double fadeOut)
    {
        Filter hl = high > 0.0 ? new Filter("high", high, 0.70710678) : null;
        Filter hr = high > 0.0 ? new Filter("high", high, 0.70710678) : null;
        Filter ll = low > 0.0 ? new Filter("low", low, 0.70710678) : null;
        Filter lr = low > 0.0 ? new Filter("low", low, 0.70710678) : null;
        double dcL = 0.0, dcR = 0.0;
        for (int i = 0; i < sound.Length; i++)
        {
            double l = sound.L[i], r = sound.R[i];
            if (hl != null) { l = hl.Tick(l); r = hr.Tick(r); }
            if (ll != null) { l = ll.Tick(l); r = lr.Tick(r); }
            // A fixed analogue-style transfer, NOT per-file peak normalization.
            // Leave 0.05 FS of additional headroom for the small DC correction.
            l = 0.60 * Math.Tanh(l * gain / 0.60);
            r = 0.60 * Math.Tanh(r * gain / 0.60);
            sound.L[i] = l; sound.R[i] = r;
            dcL += l; dcR += r;
        }
        dcL /= sound.Length; dcR /= sound.Length;
        for (int i = 0; i < sound.Length; i++)
        {
            double gate = Attack(i / (double)Rate, fadeIn) * Tail(i, sound.Length, fadeOut);
            sound.L[i] = (sound.L[i] - dcL) * gate;
            sound.R[i] = (sound.R[i] - dcR) * gate;
        }
    }

    static Stereo Footstep(int variant)
    {
        double[] lengths = { 0.200, 0.207, 0.216 };
        double[] floorHz = { 121.0, 134.0, 114.0 };
        Stereo sound = new Stereo(lengths[variant]);
        Noise noise = new Noise(unchecked(Seed + (uint)(variant + 1) * 0x9E3779B9u));
        Filter floor = new Filter("band", floorHz[variant], 1.7);
        Filter plank = new Filter("band", 292.0 + 21.0 * variant, 2.2);
        Filter grain = new Filter("band", 610.0 - 29.0 * variant, 1.4);
        Filter sole = new Filter("low", 190.0, 0.70710678);
        Filter brush = new Filter("low", 740.0, 0.70710678);
        for (int i = 0; i < sound.Length; i++)
        {
            double t = i / (double)Rate;
            // Rounded heel contact, then a weaker toe roll: no impulse/gunshot transient.
            double heel = Attack(t, 0.008 + variant * 0.0007) * Math.Exp(-t / 0.039);
            double tt = t - (0.030 + variant * 0.003);
            double toe = tt > 0.0 ? Attack(tt, 0.010) * Math.Exp(-tt / 0.025) : 0.0;
            double drive = noise.White() * (0.80 * heel + 0.42 * toe);
            double body = 2.4 * floor.Tick(drive) + 1.05 * plank.Tick(drive)
                + 0.35 * grain.Tick(drive) + 0.28 * sole.Tick(drive);
            double fibre = brush.Tick(noise.White()) * heel * 0.055;
            Pan(sound, i, body, (variant - 1) * 0.035);
            sound.L[i] += fibre; sound.R[i] += fibre * 0.85;
        }
        // Identical family gain; the three performances retain their dynamics.
        Finish(sound, 3.2, 38.0, 1550.0, 0.004, 0.021);
        return sound;
    }

    static void Bell(Stereo sound, double onset, double fundamental, double amplitude,
        double decay, double pan, uint seed)
    {
        Noise noise = new Noise(seed);
        // Slightly inharmonic brass modes with rapidly damped upper partials.
        double[] ratios = { 1.0, 2.013, 2.756, 3.897, 5.071 };
        double[] weights = { 1.0, 0.29, 0.13, 0.055, 0.018 };
        double[] damping = { 1.0, 0.69, 0.48, 0.32, 0.20 };
        double[] phases = new double[ratios.Length];
        for (int h = 0; h < phases.Length; h++) phases[h] = noise.White() * 0.12;
        Filter wood = new Filter("band", 215.0, 1.3);
        int start = (int)Math.Round(onset * Rate);
        for (int i = start; i < sound.Length; i++)
        {
            double t = (i - start) / (double)Rate;
            double value = 0.0;
            for (int h = 0; h < ratios.Length; h++)
                value += weights[h] * Math.Exp(-t / (decay * damping[h]))
                    * Math.Sin(Tau * fundamental * ratios[h] * t + phases[h]);
            value *= amplitude * Attack(t, 0.0065);
            double mallet = wood.Tick(noise.White() * Attack(t, 0.004) * Math.Exp(-t / 0.015));
            Pan(sound, i, value + 0.35 * mallet, pan);
        }
    }

    static void Reflections(Stereo sound, double amount)
    {
        double[] dryL = (double[])sound.L.Clone(), dryR = (double[])sound.R.Clone();
        int[] delays = { (int)(Rate * 0.061), (int)(Rate * 0.103), (int)(Rate * 0.157) };
        double[] levels = { 0.11, 0.075, 0.043 };
        for (int tap = 0; tap < delays.Length; tap++)
        {
            Filter l = new Filter("low", 1800.0 - tap * 250.0, 0.70710678);
            Filter r = new Filter("low", 1700.0 - tap * 230.0, 0.70710678);
            for (int i = delays[tap]; i < sound.Length; i++)
            {
                int from = i - delays[tap];
                sound.L[i] += amount * levels[tap] * l.Tick(dryR[from]);
                sound.R[i] += amount * levels[tap] * r.Tick(dryL[from]);
            }
        }
    }

    static Stereo DialogueOpen()
    {
        Stereo sound = new Stereo(0.700);
        Bell(sound, 0.012, 392.0, 0.34, 0.235, -0.035, Seed ^ 0x010A44u);
        Reflections(sound, 0.55);
        Finish(sound, 1.08, 65.0, 2450.0, 0.004, 0.072);
        return sound;
    }

    static Stereo DialogueClose()
    {
        Stereo sound = new Stereo(0.250);
        Noise noise = new Noise(Seed ^ 0xAC105Eu);
        Filter paper = new Filter("band", 820.0, 0.65);
        Filter cover = new Filter("band", 173.0, 1.3);
        Filter binding = new Filter("low", 420.0, 0.70710678);
        Filter side = new Filter("low", 1050.0, 0.70710678);
        for (int i = 0; i < sound.Length; i++)
        {
            double t = i / (double)Rate;
            double u = (t - 0.009) / 0.181;
            double page = u > 0.0 && u < 1.0 ? Math.Pow(Math.Sin(Math.PI * u), 1.6) : 0.0;
            double ct = t - 0.139;
            double landing = ct > 0.0 ? Attack(ct, 0.011) * Math.Exp(-ct / 0.026) : 0.0;
            double x = noise.White();
            double body = 0.64 * paper.Tick(x) * page
                + 1.15 * cover.Tick(x * landing) + 0.32 * binding.Tick(x * landing);
            double rustle = side.Tick(noise.White()) * page * 0.045;
            sound.L[i] = body + rustle; sound.R[i] = body - rustle;
        }
        Finish(sound, 1.9, 62.0, 1850.0, 0.007, 0.032);
        return sound;
    }

    static Stereo Select()
    {
        Stereo sound = new Stereo(0.140);
        Noise noise = new Noise(Seed ^ 0x5E1EC7u);
        Filter body = new Filter("band", 270.0, 1.5);
        Filter tick = new Filter("band", 690.0, 2.0);
        Filter finger = new Filter("low", 600.0, 0.70710678);
        for (int i = 0; i < sound.Length; i++)
        {
            double t = i / (double)Rate;
            double x = noise.White() * Attack(t, 0.0045) * Math.Exp(-t / 0.022);
            double value = 1.8 * body.Tick(x) + 1.3 * tick.Tick(x) + 0.35 * finger.Tick(x);
            Pan(sound, i, value, 0.0);
        }
        Finish(sound, 3.0, 85.0, 1900.0, 0.003, 0.023);
        return sound;
    }

    static Stereo Reply()
    {
        Stereo sound = new Stereo(0.900);
        Bell(sound, 0.013, 329.627557, 0.31, 0.267, -0.075, Seed ^ 0xAE9101u);
        Bell(sound, 0.327, 440.0, 0.335, 0.255, 0.075, Seed ^ 0xAE9102u);
        Reflections(sound, 0.62);
        Finish(sound, 1.04, 65.0, 2350.0, 0.004, 0.076);
        return sound;
    }

    static void PluckedCourse(Stereo sound, double onset, double hz, double amplitude,
        double pan, uint seed)
    {
        Noise noise = new Noise(seed);
        int start = (int)Math.Round(onset * Rate);
        // Two gently detuned strings, displaced near one fifth of their length.
        // Upper harmonics decay faster; this is a pluck, not a gated oscillator beep.
        for (int course = 0; course < 2; course++)
        {
            double detune = course == 0 ? 0.9991 : 1.0012;
            double coursePan = pan + (course == 0 ? -0.095 : 0.095);
            double[] phases = new double[11];
            for (int h = 0; h < phases.Length; h++) phases[h] = noise.White() * 0.055;
            Filter plectrum = new Filter("low", 1350.0, 0.70710678);
            for (int i = start; i < sound.Length; i++)
            {
                double t = (i - start) / (double)Rate;
                double value = 0.0;
                for (int h = 1; h <= phases.Length; h++)
                {
                    double weight = Math.Sin(Math.PI * h * 0.213) / Math.Pow(h, 1.27);
                    double partial = hz * detune * h * Math.Sqrt(1.0 + 0.00012 * h * h);
                    double decay = 1.13 / Math.Pow(h, 0.72);
                    value += weight * Math.Exp(-t / decay)
                        * Math.Sin(Tau * partial * t + phases[h - 1]);
                }
                double pick = plectrum.Tick(noise.White()) * Math.Exp(-t / 0.013) * 0.10;
                Pan(sound, i, (value + pick) * amplitude * 0.5 * Attack(t, 0.0048), coursePan);
            }
        }
    }

    static Stereo Lute()
    {
        Stereo sound = new Stereo(3.800);
        // An original four-note D-A-F-D phrase, unevenly spaced and softly voiced.
        // No transcription, soundfont, external recording or quoted melody.
        double[] onsets = { 0.022, 0.747, 1.487, 2.287 };
        double[] notes = { 146.832384, 220.0, 174.614116, 293.664768 };
        double[] levels = { 0.47, 0.40, 0.435, 0.48 };
        double[] pans = { -0.19, 0.16, -0.11, 0.20 };
        for (int note = 0; note < notes.Length; note++)
            PluckedCourse(sound, onsets[note], notes[note], levels[note], pans[note],
                unchecked(Seed + 0x107Eu + (uint)note * 977u));
        Filter bodyL = new Filter("band", 196.0, 1.15), bodyR = new Filter("band", 199.0, 1.15);
        Filter cavityL = new Filter("band", 485.0, 1.0), cavityR = new Filter("band", 492.0, 1.0);
        for (int i = 0; i < sound.Length; i++)
        {
            double l = sound.L[i], r = sound.R[i];
            sound.L[i] = 0.83 * l + 0.28 * bodyL.Tick(l) + 0.11 * cavityL.Tick(l);
            sound.R[i] = 0.83 * r + 0.28 * bodyR.Tick(r) + 0.11 * cavityR.Tick(r);
        }
        Reflections(sound, 0.92);
        Finish(sound, 1.18, 48.0, 2800.0, 0.004, 0.160);
        return sound;
    }

    static double[] PeriodicNoise(int frames, Noise noise, double high, double low)
    {
        double[] white = new double[frames], result = new double[frames];
        for (int i = 0; i < frames; i++) white[i] = noise.White();
        Filter hp = new Filter("high", high, 0.70710678);
        Filter lp = new Filter("low", low, 0.70710678);
        // A full period warms the recursive filters. The second pass starts from
        // the previous period's tail state rather than a zero-state discontinuity.
        for (int pass = 0; pass < 2; pass++)
            for (int i = 0; i < frames; i++)
            {
                double value = lp.Tick(hp.Tick(white[i]));
                if (pass == 1) result[i] = value;
            }
        return result;
    }

    static void Ember(Stereo sound, Noise noise, int start, double amplitude, double pan)
    {
        int length = (int)(Rate * (0.028 + 0.042 * noise.Unit()));
        Filter fibre = new Filter("low", 1000.0 + 280.0 * noise.Unit(), 0.70710678);
        Filter wood = new Filter("band", 360.0 + 410.0 * noise.Unit(), 1.6);
        for (int i = 0; i < length; i++)
        {
            double t = i / (double)Rate;
            double drive = noise.White() * Attack(t, 0.0032) * Math.Exp(-t / 0.012);
            double value = (0.68 * fibre.Tick(drive) + 0.9 * wood.Tick(drive))
                * amplitude * Tail(i, length, 0.010);
            // Embers crossing the wrap are not truncated or discarded.
            Pan(sound, (start + i) % sound.Length, value, pan);
        }
    }

    static void QuietSeam(Stereo sound)
    {
        int best = 0;
        double bestCost = double.MaxValue;
        for (int i = 0; i < sound.Length; i++)
        {
            int prev = (i + sound.Length - 1) % sound.Length;
            double cost = Math.Abs(sound.L[i]) + Math.Abs(sound.R[i])
                + Math.Abs(sound.L[prev]) + Math.Abs(sound.R[prev])
                + 2.0 * Math.Abs(sound.L[i] - sound.L[prev])
                + 2.0 * Math.Abs(sound.R[i] - sound.R[prev]);
            if (cost < bestCost) { bestCost = cost; best = i; }
        }
        double[] left = (double[])sound.L.Clone(), right = (double[])sound.R.Clone();
        for (int i = 0; i < sound.Length; i++)
        {
            int from = (best + i) % sound.Length;
            sound.L[i] = left[from]; sound.R[i] = right[from];
        }
    }

    static Stereo Fireplace()
    {
        Stereo sound = new Stereo(16.0);
        double[] hearth = PeriodicNoise(sound.Length, new Noise(Seed ^ 0xF1AE01u), 28.0, 240.0);
        double[] air = PeriodicNoise(sound.Length, new Noise(Seed ^ 0xF1AE02u), 180.0, 900.0);
        double[] sides = PeriodicNoise(sound.Length, new Noise(Seed ^ 0xF1AE03u), 65.0, 340.0);
        for (int i = 0; i < sound.Length; i++)
        {
            double phase = Tau * i / sound.Length;
            // Integer cycles make the slow breathing periodic as well.
            double breathe = 0.89 + 0.07 * Math.Cos(phase * 3.0 + 0.27)
                + 0.04 * Math.Cos(phase * 7.0 - 0.61);
            double mid = 0.98 * hearth[i] * breathe + 0.12 * air[i];
            double side = 0.14 * sides[i];
            sound.L[i] = mid + side; sound.R[i] = mid - side;
        }
        Noise embers = new Noise(Seed ^ 0xE8BEA5u);
        for (int eventIndex = 0; eventIndex < 61; eventIndex++)
        {
            int onset = (int)(embers.Unit() * sound.Length);
            double level = 0.22 + 0.23 * embers.Unit();
            double pan = embers.White() * 0.27;
            Ember(sound, embers, onset, level, pan);
        }
        QuietSeam(sound);
        // Already periodically filtered: do NOT restart a mastering IIR at frame 0.
        // The 6 ms raised-cosine edges meet at zero with zero limiting slope; there
        // is no long silence/fade at the loop boundary. QA measures the joined edges.
        Finish(sound, 1.15, 0.0, 0.0, 0.006, 0.006);
        return sound;
    }

    static void WriteWave(string directory, string name, Stereo sound)
    {
        // No automatic normalization, clipping or fallback gain if a design fails.
        for (int i = 0; i < sound.Length; i++)
        {
            if (Double.IsNaN(sound.L[i]) || Double.IsInfinity(sound.L[i])
                || Double.IsNaN(sound.R[i]) || Double.IsInfinity(sound.R[i])
                || Math.Abs(sound.L[i]) > 0.65 || Math.Abs(sound.R[i]) > 0.65)
                throw new InvalidDataException(name + ": unsafe DSP output at frame " + i);
        }
        string path = Path.Combine(directory, name);
        using (FileStream stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
        using (BinaryWriter writer = new BinaryWriter(stream, Encoding.ASCII))
        {
            writer.Write(Encoding.ASCII.GetBytes("RIFF"));
            writer.Write((uint)(36 + sound.Length * 4));
            writer.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
            writer.Write((uint)16); writer.Write((ushort)1); writer.Write((ushort)2);
            writer.Write((uint)Rate); writer.Write((uint)(Rate * 4));
            writer.Write((ushort)4); writer.Write((ushort)16);
            writer.Write(Encoding.ASCII.GetBytes("data"));
            writer.Write((uint)(sound.Length * 4));
            for (int i = 0; i < sound.Length; i++)
            {
                writer.Write((short)Math.Round(sound.L[i] * 32768.0, MidpointRounding.AwayFromZero));
                writer.Write((short)Math.Round(sound.R[i] * 32768.0, MidpointRounding.AwayFromZero));
            }
        }
        Console.WriteLine("WROTE {0} | frames={1} | PCM 44100 Hz / 16-bit / stereo", name, sound.Length);
    }

    public static void Generate(string project)
    {
        string output = Path.Combine(project, "assets", "audio");
        Directory.CreateDirectory(output);
        for (int variant = 0; variant < 3; variant++)
            WriteWave(output, "footstep_" + variant + ".wav", Footstep(variant));
        WriteWave(output, "dialogue_open.wav", DialogueOpen());
        WriteWave(output, "dialogue_close.wav", DialogueClose());
        WriteWave(output, "select.wav", Select());
        WriteWave(output, "reply.wav", Reply());
        WriteWave(output, "lute.wav", Lute());
        WriteWave(output, "fireplace.wav", Fireplace());
        Console.WriteLine("AUDIO_SYNTHESIS_OK | files=9 | seed=0x{0:X8} | fixed family gains | no playback", Seed);
    }
}
'@

# Content-addressed in-memory type names allow corrected scripts to be rerun in
# the same terminal without accidentally reusing an older Add-Type definition.
# Default framework references avoid PowerShell 7.6 System.Private.* ref conflicts.
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($source))).Replace('-', '')
} finally {
    $sha.Dispose()
}
$typeName = 'StarlightInnAudioDsp_' + $digest.Substring(0, 16)
$dspType = $typeName -as [type]
if ($null -eq $dspType) {
    Add-Type -TypeDefinition $source.Replace('__AUDIO_DSP__', $typeName)
    $dspType = $typeName -as [type]
}
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dspType::Generate($project)
exit 0