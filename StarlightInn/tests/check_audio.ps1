[CmdletBinding()]
param()

# Read-only QA: independently parse the actual RIFF/PCM bytes. Never load the
# generator, its metrics, Godot, an audio device, or external sample libraries.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:Assertions = 0
$script:Failures = [Collections.Generic.List[string]]::new()
$culture = [Globalization.CultureInfo]::InvariantCulture

function Assert-Audio {
    param([bool]$Condition, [string]$Label, [string]$Actual)
    $script:Assertions++
    if (-not $Condition) {
        $message = 'FAIL: ' + $Label + ' | actual: ' + $Actual
        $script:Failures.Add($message)
        Write-Output $message
    }
}

$source = @'
using System;
using System.IO;
using System.Text;
using System.Security.Cryptography;

public static class __AUDIO_QA__
{
    public sealed class Metrics
    {
        public string Name, Hash;
        public int Format, Rate, Bits, Channels, Align, ByteRate, Frames;
        public long Bytes, Clipped;
        public double Seconds, Peak, Rms, RmsL, RmsR, DcL, DcR, MidRms, SideRms, Correlation;
        public double First, Last, MaxStep, EdgeStep, JoinStep, JoinSlopeChange;
        public double SeamRms, WindowMin, WindowMax, HighBandRatio;
        public int LeadingZeroFrames, TrailingZeroFrames;
        internal double[] L, R;
    }

    static void Need(bool value, string message)
    {
        if (!value) throw new InvalidDataException(message);
    }

    static string FourCC(BinaryReader reader)
    {
        byte[] bytes = reader.ReadBytes(4);
        Need(bytes.Length == 4, "Truncated FourCC");
        return Encoding.ASCII.GetString(bytes);
    }

    public static Metrics Read(string path)
    {
        using (FileStream stream = File.OpenRead(path))
        {
            Metrics result = Parse(stream, Path.GetFileName(path));
            stream.Position = 0;
            using (SHA256 sha = SHA256.Create())
                result.Hash = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
            return result;
        }
    }

    static Metrics Parse(Stream stream, string name)
    {
        Metrics m = new Metrics();
        m.Name = name; m.Bytes = stream.Length;
        Need(stream.Length >= 44, "Too short for PCM WAV: " + stream.Length + " bytes");
        // Leave the stream open for a separate hash of all original file bytes.
        using (BinaryReader reader = new BinaryReader(stream, Encoding.ASCII, true))
        {
            Need(FourCC(reader) == "RIFF", "Expected little-endian RIFF");
            long declared = reader.ReadUInt32() + 8L;
            Need(declared == stream.Length, "RIFF length " + declared + " != actual " + stream.Length);
            Need(FourCC(reader) == "WAVE", "Missing WAVE signature");
            bool fmt = false, data = false;
            byte[] pcm = null;
            while (stream.Position < declared)
            {
                Need(declared - stream.Position >= 8, "Truncated chunk header");
                string id = FourCC(reader);
                uint size = reader.ReadUInt32();
                long end = stream.Position + size;
                long paddedEnd = end + (size & 1u);
                Need(end <= declared && paddedEnd <= declared, "Chunk " + id + " exceeds RIFF bounds");
                if (id == "fmt ")
                {
                    Need(!fmt && size >= 16, "Duplicate or short fmt chunk");
                    fmt = true;
                    m.Format = reader.ReadUInt16(); m.Channels = reader.ReadUInt16();
                    m.Rate = reader.ReadInt32(); m.ByteRate = reader.ReadInt32();
                    m.Align = reader.ReadUInt16(); m.Bits = reader.ReadUInt16();
                }
                else if (id == "data")
                {
                    Need(!data && size > 0 && size <= 16 * 1024 * 1024, "Duplicate, empty, or oversized data chunk");
                    data = true;
                    pcm = reader.ReadBytes((int)size);
                    Need(pcm.Length == size, "Truncated PCM data");
                }
                stream.Position = paddedEnd;
            }
            Need(fmt && data && pcm != null, "Missing fmt/data chunk");
            Need(m.Format == 1 && m.Channels == 2 && m.Bits == 16 && m.Rate == 44100,
                String.Format("Expected PCM/44100/16/2, got format={0}, rate={1}, bits={2}, channels={3}",
                    m.Format, m.Rate, m.Bits, m.Channels));
            Need(m.Align == 4 && m.ByteRate == 176400, "Invalid PCM block alignment or byte rate");
            Need(pcm.Length % m.Align == 0, "Partial PCM frame at end of data chunk");
            m.Frames = pcm.Length / m.Align;
            Need(m.Frames > 1, "Not enough frames");
            m.Seconds = m.Frames / (double)m.Rate;
            m.L = new double[m.Frames]; m.R = new double[m.Frames];
            double sumL = 0.0, sumR = 0.0, sqL = 0.0, sqR = 0.0, cross = 0.0;
            double midSquare = 0.0, sideSquare = 0.0, highSquare = 0.0;
            double smoothL = 0.0, smoothR = 0.0, smooth2L = 0.0, smooth2R = 0.0;
            // Independent two-stage 3 kHz low-pass residual: a conservative
            // brightness proxy, not a claim of perceptual/listening verification.
            double a = 1.0 - Math.Exp(-2.0 * Math.PI * 3000.0 / m.Rate);
            int edge = (int)(m.Rate * 0.012);
            for (int i = 0; i < m.Frames; i++)
            {
                int at = i * 4;
                short left = unchecked((short)(pcm[at] | (pcm[at + 1] << 8)));
                short right = unchecked((short)(pcm[at + 2] | (pcm[at + 3] << 8)));
                if (left == short.MinValue || left == short.MaxValue) m.Clipped++;
                if (right == short.MinValue || right == short.MaxValue) m.Clipped++;
                double l = left / 32768.0, r = right / 32768.0;
                m.L[i] = l; m.R[i] = r;
                sumL += l; sumR += r; sqL += l * l; sqR += r * r; cross += l * r;
                midSquare += (l + r) * (l + r) * 0.25;
                sideSquare += (l - r) * (l - r) * 0.25;
                m.Peak = Math.Max(m.Peak, Math.Max(Math.Abs(l), Math.Abs(r)));
                if (i > 0)
                {
                    double step = Math.Max(Math.Abs(l - m.L[i - 1]), Math.Abs(r - m.R[i - 1]));
                    m.MaxStep = Math.Max(m.MaxStep, step);
                    if (i < edge || i >= m.Frames - edge) m.EdgeStep = Math.Max(m.EdgeStep, step);
                }
                smoothL += a * (l - smoothL); smoothR += a * (r - smoothR);
                smooth2L += a * (smoothL - smooth2L); smooth2R += a * (smoothR - smooth2R);
                double highL = l - smooth2L, highR = r - smooth2R;
                highSquare += highL * highL + highR * highR;
            }
            m.RmsL = Math.Sqrt(sqL / m.Frames); m.RmsR = Math.Sqrt(sqR / m.Frames);
            m.Rms = Math.Sqrt((sqL + sqR) / (2.0 * m.Frames));
            m.DcL = sumL / m.Frames; m.DcR = sumR / m.Frames;
            m.MidRms = Math.Sqrt(midSquare / m.Frames); m.SideRms = Math.Sqrt(sideSquare / m.Frames);
            double variance = (sqL - sumL * sumL / m.Frames) * (sqR - sumR * sumR / m.Frames);
            m.Correlation = variance > 0.0 ? (cross - sumL * sumR / m.Frames) / Math.Sqrt(variance) : 0.0;
            m.HighBandRatio = sqL + sqR > 0.0 ? highSquare / (sqL + sqR) : 0.0;
            m.First = Math.Max(Math.Abs(m.L[0]), Math.Abs(m.R[0]));
            m.Last = Math.Max(Math.Abs(m.L[m.Frames - 1]), Math.Abs(m.R[m.Frames - 1]));
            m.JoinStep = Math.Max(Math.Abs(m.L[0] - m.L[m.Frames - 1]),
                Math.Abs(m.R[0] - m.R[m.Frames - 1]));
            m.JoinSlopeChange = Math.Max(
                Math.Abs((m.L[1] - m.L[0]) - (m.L[m.Frames - 1] - m.L[m.Frames - 2])),
                Math.Abs((m.R[1] - m.R[0]) - (m.R[m.Frames - 1] - m.R[m.Frames - 2])));
            while (m.LeadingZeroFrames < m.Frames
                && Math.Abs(m.L[m.LeadingZeroFrames]) <= 1.0 / 32768.0
                && Math.Abs(m.R[m.LeadingZeroFrames]) <= 1.0 / 32768.0) m.LeadingZeroFrames++;
            while (m.TrailingZeroFrames < m.Frames
                && Math.Abs(m.L[m.Frames - 1 - m.TrailingZeroFrames]) <= 1.0 / 32768.0
                && Math.Abs(m.R[m.Frames - 1 - m.TrailingZeroFrames]) <= 1.0 / 32768.0) m.TrailingZeroFrames++;
            int seam = Math.Min((int)(m.Rate * 0.1), m.Frames / 2);
            double head = WindowRms(m, 0, seam), tail = WindowRms(m, m.Frames - seam, seam);
            m.SeamRms = Math.Sqrt((head * head + tail * tail) * 0.5);
            m.WindowMin = double.MaxValue;
            for (int i = 0; i < m.Frames; i += m.Rate)
            {
                double rms = WindowRms(m, i, Math.Min(m.Rate, m.Frames - i));
                m.WindowMin = Math.Min(m.WindowMin, rms); m.WindowMax = Math.Max(m.WindowMax, rms);
            }
            return m;
        }
    }

    static double WindowRms(Metrics m, int start, int count)
    {
        double sum = 0.0;
        for (int i = start; i < start + count; i++) sum += m.L[i] * m.L[i] + m.R[i] * m.R[i];
        return Math.Sqrt(sum / (2.0 * count));
    }

    public static double PanWindow(Metrics m, double start, double seconds)
    {
        int first = (int)(start * m.Rate), end = Math.Min(m.Frames, first + (int)(seconds * m.Rate));
        double l = 0.0, r = 0.0;
        for (int i = first; i < end; i++) { l += m.L[i] * m.L[i]; r += m.R[i] * m.R[i]; }
        return l + r > 0.0 ? (r - l) / (r + l) : 0.0;
    }

    public static double MaxFootstepCorrelation(Metrics a, Metrics b)
    {
        double best = 0.0;
        // Search +/-10 ms, so a mere time shift does not count as a new footstep.
        for (int lag = -441; lag <= 441; lag += 21)
        {
            double sumX = 0.0, sumY = 0.0, xx = 0.0, yy = 0.0, xy = 0.0;
            int start = Math.Max(0, -lag), end = Math.Min(a.Frames, b.Frames - lag);
            for (int i = start; i < end; i++)
            {
                double x = (a.L[i] + a.R[i]) * 0.5, y = (b.L[i + lag] + b.R[i + lag]) * 0.5;
                sumX += x; sumY += y; xx += x * x; yy += y * y; xy += x * y;
            }
            int count = end - start;
            double denom = (xx - sumX * sumX / count) * (yy - sumY * sumY / count);
            if (denom > 0.0) best = Math.Max(best, Math.Abs((xy - sumX * sumY / count) / Math.Sqrt(denom)));
        }
        return best;
    }

    public static double JoinedEdgeStep(Metrics m)
    {
        // Examine an actual tail -> head -> head-neighbour sequence, not just the
        // last-to-first jump. Both channels and every adjacent sample are checked.
        int span = Math.Min(m.Rate / 20, m.Frames / 2);
        double previousL = m.L[m.Frames - span], previousR = m.R[m.Frames - span], max = 0.0;
        for (int i = 1; i < span * 2; i++)
        {
            int frame = (m.Frames - span + i) % m.Frames;
            max = Math.Max(max, Math.Max(Math.Abs(m.L[frame] - previousL), Math.Abs(m.R[frame] - previousR)));
            previousL = m.L[frame]; previousR = m.R[frame];
        }
        return max;
    }

    public static bool RejectCorruptHeader(string path, int offset, byte value)
    {
        // In-memory negative tests: no extra files or changes to production WAVs.
        byte[] bytes = File.ReadAllBytes(path);
        bytes[offset] = value;
        try
        {
            using (MemoryStream stream = new MemoryStream(bytes, false)) Parse(stream, "in-memory invalid WAV");
            return false;
        }
        catch (InvalidDataException) { return true; }
    }
}
'@

$sha = [Security.Cryptography.SHA256]::Create()
try {
    $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($source))).Replace('-', '')
} finally {
    $sha.Dispose()
}
$typeName = 'StarlightInnAudioQa_' + $digest.Substring(0, 16)
$qaType = $typeName -as [type]
if ($null -eq $qaType) {
    Add-Type -TypeDefinition $source.Replace('__AUDIO_QA__', $typeName)
    $qaType = $typeName -as [type]
}

$directory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\assets\audio'))
$specs = @(
    @{ Name = 'footstep_0.wav'; Min = 0.17; Max = 0.24 },
    @{ Name = 'footstep_1.wav'; Min = 0.17; Max = 0.24 },
    @{ Name = 'footstep_2.wav'; Min = 0.17; Max = 0.24 },
    @{ Name = 'dialogue_open.wav'; Min = 0.60; Max = 0.80 },
    @{ Name = 'dialogue_close.wav'; Min = 0.20; Max = 0.30 },
    @{ Name = 'select.wav'; Min = 0.10; Max = 0.18 },
    @{ Name = 'reply.wav'; Min = 0.80; Max = 1.05 },
    @{ Name = 'lute.wav'; Min = 3.50; Max = 4.10 },
    @{ Name = 'fireplace.wav'; Min = 15.999; Max = 16.001 }
)
$files = @()
if (Test-Path -LiteralPath $directory -PathType Container) {
    $files = @(Get-ChildItem -LiteralPath $directory -Filter '*.wav' -File)
}
Assert-Audio ($files.Count -eq 9) 'Exactly nine WAV files' ('count=' + $files.Count)
$expectedNames = @($specs | ForEach-Object { $_.Name })
$unexpected = @($files | Where-Object { $expectedNames -cnotcontains $_.Name })
Assert-Audio ($unexpected.Count -eq 0) 'No unexpected or incorrectly cased WAV names' (($unexpected | ForEach-Object { $_.Name }) -join ', ')
$reports = @{}

foreach ($spec in $specs) {
    $name = $spec.Name
    $path = Join-Path $directory $name
    Assert-Audio (Test-Path -LiteralPath $path -PathType Leaf) ($name + ' exists') $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    try {
        $m = $qaType::Read($path)
        Assert-Audio $true ($name + ' independent RIFF parser') 'valid chunks, sizes, PCM format and full frames'
    } catch {
        Assert-Audio $false ($name + ' independent RIFF parser') $_.Exception.ToString()
        continue
    }
    $reports[$name] = $m
    Write-Output ([string]::Format($culture,
        'FILE {0} | {1} Hz / {2}-bit / {3}ch PCM | frames={4} | seconds={5:F6} | bytes={6}',
        $name, $m.Rate, $m.Bits, $m.Channels, $m.Frames, $m.Seconds, $m.Bytes))
    Write-Output ([string]::Format($culture,
        '  peak={0:F6} RMS={1:F6} RMS_L/R={2:F6}/{3:F6} DC_L/R={4:F8}/{5:F8} clipped={6}',
        $m.Peak, $m.Rms, $m.RmsL, $m.RmsR, $m.DcL, $m.DcR, $m.Clipped))
    Write-Output ([string]::Format($culture,
        '  first/last={0:F6}/{1:F6} max/edge_step={2:F6}/{3:F6} correlation={4:F6} mid/side_RMS={5:F6}/{6:F6} brightness_proxy={7:F6}',
        $m.First, $m.Last, $m.MaxStep, $m.EdgeStep, $m.Correlation, $m.MidRms, $m.SideRms, $m.HighBandRatio))
    Write-Output ('  SHA256=' + $m.Hash)

    $isFire = $name -eq 'fireplace.wav'
    $minRms = if ($isFire) { 0.04 } else { 0.015 }
    Assert-Audio ($m.Format -eq 1) ($name + ' linear PCM') ([string]$m.Format)
    Assert-Audio ($m.Rate -eq 44100) ($name + ' sample rate') ([string]$m.Rate)
    Assert-Audio ($m.Bits -eq 16) ($name + ' bit depth') ([string]$m.Bits)
    Assert-Audio ($m.Channels -eq 2) ($name + ' stereo channels') ([string]$m.Channels)
    Assert-Audio ($m.Align -eq 4 -and $m.ByteRate -eq 176400) ($name + ' frame layout') ('align=' + $m.Align + ', byteRate=' + $m.ByteRate)
    Assert-Audio ($m.Seconds -ge $spec.Min -and $m.Seconds -le $spec.Max) ($name + ' duration') ($m.Seconds.ToString('F6', $culture))
    Assert-Audio ($m.Rms -ge $minRms) ($name + ' audible RMS >= ' + $minRms) ($m.Rms.ToString('F8', $culture))
    Assert-Audio ($m.Rms -le 0.20) ($name + ' restrained overall RMS <= 0.20') ($m.Rms.ToString('F8', $culture))
    Assert-Audio ($m.RmsL -ge $minRms * 0.85 -and $m.RmsR -ge $minRms * 0.85) ($name + ' both channels audible') ($m.RmsL.ToString('F8', $culture) + '/' + $m.RmsR.ToString('F8', $culture))
    Assert-Audio ($m.Peak -ge 0.20 -and $m.Peak -le 0.65) ($name + ' design sample peak in 0.20..0.65 FS') ($m.Peak.ToString('F8', $culture))
    Assert-Audio ($m.Peak -le 0.70) ($name + ' hard peak ceiling <= 0.70 FS') ($m.Peak.ToString('F8', $culture))
    Assert-Audio ($m.Clipped -eq 0) ($name + ' no clipped PCM samples') ([string]$m.Clipped)
    Assert-Audio ([Math]::Abs($m.DcL) -lt 0.015 -and [Math]::Abs($m.DcR) -lt 0.015) ($name + ' per-channel abs DC < 0.015') ($m.DcL.ToString('F8', $culture) + '/' + $m.DcR.ToString('F8', $culture))
    Assert-Audio ($m.First -le 1.0 / 32768) ($name + ' start at zero within 1 LSB') ($m.First.ToString('F8', $culture))
    Assert-Audio ($m.Last -le 1.0 / 32768) ($name + ' end at zero within 1 LSB') ($m.Last.ToString('F8', $culture))
    Assert-Audio ($m.EdgeStep -le 0.12) ($name + ' no hard cut near either edge') ($m.EdgeStep.ToString('F8', $culture))
    Assert-Audio ($m.MaxStep -le 0.20) ($name + ' no impulsive single-sample jump') ($m.MaxStep.ToString('F8', $culture))
    Assert-Audio ($m.JoinSlopeChange -le 0.002) ($name + ' smooth limiting endpoint slopes') ($m.JoinSlopeChange.ToString('F8', $culture))
    Assert-Audio ($m.Correlation -gt 0.25) ($name + ' mono-compatible stereo') ($m.Correlation.ToString('F8', $culture))
    Assert-Audio ($m.MidRms -ge $minRms * 0.85) ($name + ' audible mono fold-down') ($m.MidRms.ToString('F8', $culture))
    Assert-Audio ([Math]::Max($m.RmsL, $m.RmsR) -le [Math]::Min($m.RmsL, $m.RmsR) * 1.35) ($name + ' channel level balance') ($m.RmsL.ToString('F8', $culture) + '/' + $m.RmsR.ToString('F8', $culture))
    Assert-Audio ($m.HighBandRatio -le 0.30) ($name + ' restrained high-frequency residual') ($m.HighBandRatio.ToString('F8', $culture))
}

for ($a = 0; $a -lt 3; $a++) {
    for ($b = $a + 1; $b -lt 3; $b++) {
        $left = 'footstep_' + $a + '.wav'
        $right = 'footstep_' + $b + '.wav'
        if ($reports.ContainsKey($left) -and $reports.ContainsKey($right)) {
            Assert-Audio ($reports[$left].Hash -ne $reports[$right].Hash) ($left + ' vs ' + $right + ' different SHA256') ($reports[$left].Hash + ' / ' + $reports[$right].Hash)
            $corr = $qaType::MaxFootstepCorrelation($reports[$left], $reports[$right])
            Assert-Audio ($corr -lt 0.97) ($left + ' vs ' + $right + ' not a scaled/time-shifted duplicate') ($corr.ToString('F8', $culture))
            Write-Output ('FOOTSTEP_PAIR ' + $a + '/' + $b + ' | max_abs_lag_correlation=' + $corr.ToString('F6', $culture))
        }
    }
}

if ($reports.ContainsKey('lute.wav')) {
    $lute = $reports['lute.wav']
    Assert-Audio ($lute.SideRms -ge $lute.MidRms * 0.02 -and $lute.SideRms -le $lute.MidRms * 0.50) 'Lute restrained non-mono stereo width' ($lute.SideRms.ToString('F8', $culture) + ' / mid=' + $lute.MidRms.ToString('F8', $culture))
    $pans = @(0.06, 0.80, 1.53, 2.34 | ForEach-Object { $qaType::PanWindow($lute, $_, 0.29) })
    $range = ($pans | Measure-Object -Maximum).Maximum - ($pans | Measure-Object -Minimum).Minimum
    Assert-Audio ($range -ge 0.04) 'Lute spatial position varies with the four plucks' ($range.ToString('F8', $culture))
    Write-Output ('LUTE_PAN_WINDOWS=' + (($pans | ForEach-Object { $_.ToString('F6', $culture) }) -join ', '))
}

if ($reports.ContainsKey('fireplace.wav')) {
    $fire = $reports['fireplace.wav']
    $join = $qaType::JoinedEdgeStep($fire)
    Assert-Audio ($fire.Frames -eq 705600) 'Fire exactly 16 seconds' ([string]$fire.Frames)
    Assert-Audio ($fire.Rms -le 0.12) 'Fire quiet sustained bed, RMS <= 0.12' ($fire.Rms.ToString('F8', $culture))
    Assert-Audio ($fire.JoinStep -le 2.0 / 32768) 'Fire tail-to-head continuity' ($fire.JoinStep.ToString('F8', $culture))
    Assert-Audio ($fire.JoinSlopeChange -le 0.001) 'Fire tail-to-head first-difference continuity' ($fire.JoinSlopeChange.ToString('F8', $culture))
    Assert-Audio ($join -le 0.04) 'Fire every step across joined 100 ms boundary' ($join.ToString('F8', $culture))
    Assert-Audio ($fire.MaxStep -le 0.08) 'Fire no large abrupt crackle' ($fire.MaxStep.ToString('F8', $culture))
    Assert-Audio ($fire.SeamRms -ge $fire.Rms * 0.35 -and $fire.SeamRms -le $fire.Rms * 1.8) 'Fire no long silent seam or seam swell' ($fire.SeamRms.ToString('F8', $culture) + ' / overall=' + $fire.Rms.ToString('F8', $culture))
    Assert-Audio ($fire.LeadingZeroFrames -le 44 -and $fire.TrailingZeroFrames -le 44) 'Fire no silent padding beyond 1 ms on either edge' ('head=' + $fire.LeadingZeroFrames + ', tail=' + $fire.TrailingZeroFrames)
    Assert-Audio ($fire.WindowMin -ge 0.035 -and $fire.WindowMax -le $fire.WindowMin * 2.5) 'Fire continuous 1-second energy, no large explosion' ('min=' + $fire.WindowMin.ToString('F8', $culture) + ', max=' + $fire.WindowMax.ToString('F8', $culture))
    Assert-Audio ($fire.Correlation -ge 0.85 -and $fire.Correlation -lt 0.995) 'Fire stable centre with real stereo texture' ($fire.Correlation.ToString('F8', $culture))
    Assert-Audio ($fire.SideRms -ge $fire.MidRms * 0.05 -and $fire.SideRms -le $fire.MidRms * 0.30) 'Fire restrained stereo side energy' ($fire.SideRms.ToString('F8', $culture) + ' / mid=' + $fire.MidRms.ToString('F8', $culture))
    Assert-Audio ($fire.HighBandRatio -le 0.10) 'Fire low-frequency air, not white hiss' ($fire.HighBandRatio.ToString('F8', $culture))
    Write-Output ([string]::Format($culture,
        'FIRE_LOOP | join_step={0:F8} join_slope={1:F8} joined_edge_step={2:F8} seam_RMS={3:F6} 1s_RMS_min/max={4:F6}/{5:F6} zero_frames_head/tail={6}/{7}',
        $fire.JoinStep, $fire.JoinSlopeChange, $join, $fire.SeamRms, $fire.WindowMin, $fire.WindowMax, $fire.LeadingZeroFrames, $fire.TrailingZeroFrames))
}

if ($reports.ContainsKey('select.wav')) {
    $fixture = Join-Path $directory 'select.wav'
    $corruptions = @(
        @{ Offset = 0; Value = 0; Label = 'bad RIFF signature' },
        @{ Offset = 7; Value = 127; Label = 'inconsistent RIFF length' },
        @{ Offset = 8; Value = 0; Label = 'bad WAVE signature' },
        @{ Offset = 20; Value = 3; Label = 'float instead of PCM' },
        @{ Offset = 22; Value = 1; Label = 'mono instead of stereo' },
        @{ Offset = 24; Value = 0; Label = 'wrong sample rate' },
        @{ Offset = 28; Value = 0; Label = 'wrong byte rate' },
        @{ Offset = 32; Value = 2; Label = 'wrong frame alignment' },
        @{ Offset = 34; Value = 8; Label = 'wrong bit depth' },
        @{ Offset = 43; Value = 127; Label = 'data extends beyond file' }
    )
    foreach ($case in $corruptions) {
        Assert-Audio ($qaType::RejectCorruptHeader($fixture, $case.Offset, [byte]$case.Value)) ('Parser rejects ' + $case.Label) ('in-memory byte offset=' + $case.Offset)
    }
}

$ffmpeg = Get-Command -Name ffmpeg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -ne $ffmpeg) {
    foreach ($spec in $specs) {
        $path = Join-Path $directory $spec.Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $decodeOutput = (& $ffmpeg.Source -nostdin -hide_banner -v error -xerror -i $path -f null - 2>&1 | Out-String)
        $decodeExit = $LASTEXITCODE
        Assert-Audio ($decodeExit -eq 0) ($spec.Name + ' optional FFmpeg decode to null') ('exit=' + $decodeExit + '; ' + $decodeOutput.Trim())
    }
    Write-Output 'FFMPEG_DECODE=executed (null output, no playback)'
} else {
    Write-Output 'FFMPEG_DECODE=skipped (not on PATH; independent PCM validation completed)'
}

if ($script:Failures.Count -gt 0) {
    Write-Output ('AUDIO_CHECK FAIL | files=' + $reports.Count + ' | assertions=' + $script:Assertions + ' | failures=' + $script:Failures.Count)
    exit 1
}
Write-Output ('AUDIO_CHECK PASS | files=' + $reports.Count + ' | assertions=' + $script:Assertions + ' | failures=0 | no playback')
exit 0