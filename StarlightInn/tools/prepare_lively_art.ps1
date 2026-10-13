[CmdletBinding()]
param([string]$SourceDirectory = (Join-Path $PSScriptRoot '..\assets\source\lively'))

# Converts saved Image 2.5 masters only; never submits, reschedules or reviews images.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not ('StarlightLivelyArtV2' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

public static class StarlightLivelyArtV2 {
    sealed class Component {
        public int Id;
        public Rectangle Bounds;
        public List<int> Pixels = new List<int>();
        public double CenterX { get { return Bounds.Left + Bounds.Width / 2.0; } }
        public double CenterY { get { return Bounds.Top + Bounds.Height / 2.0; } }
    }

    static bool Foreground(Color color) {
        return color.A >= 16 && !(color.R > 180 && color.B > 180 && color.G < 110
            && Math.Min(color.R, color.B) - color.G > 100);
    }

    static List<Bitmap> ReadAtlas(string path, int rows) {
        List<Bitmap> cells = new List<Bitmap>();
        try {
            using (Bitmap source = new Bitmap(path)) {
                int width = source.Width, height = source.Height, count = width * height;
                bool[] foreground = new bool[count];
                int[] labels = new int[count], queue = new int[count];
                for (int y = 0; y < height; y++)
                    for (int x = 0; x < width; x++)
                        foreground[y * width + x] = Foreground(source.GetPixel(x, y));
                List<Component> components = new List<Component>();
                // Detect bodies on the whole master BEFORE cutting. Generated rows
                // are not guaranteed to land on the mathematical cell boundaries.
                for (int pixel = 0; pixel < count; pixel++) {
                    if (!foreground[pixel] || labels[pixel] != 0) continue;
                    Component part = new Component { Id = components.Count + 1 };
                    int head = 0, tail = 1, left = width, top = height, right = -1, bottom = -1;
                    queue[0] = pixel; labels[pixel] = part.Id;
                    while (head < tail) {
                        int current = queue[head++], x = current % width, y = current / width;
                        part.Pixels.Add(current);
                        left = Math.Min(left, x); right = Math.Max(right, x);
                        top = Math.Min(top, y); bottom = Math.Max(bottom, y);
                        for (int dy = -1; dy <= 1; dy++)
                            for (int dx = -1; dx <= 1; dx++) {
                                int nx = x + dx, ny = y + dy;
                                if ((dx == 0 && dy == 0) || nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
                                int next = ny * width + nx;
                                if (!foreground[next] || labels[next] != 0) continue;
                                labels[next] = part.Id; queue[tail++] = next;
                            }
                    }
                    part.Bounds = Rectangle.FromLTRB(left, top, right + 1, bottom + 1);
                    components.Add(part);
                }
                List<Component> bodies = components.FindAll(part => part.Pixels.Count >= 1500
                    && part.Bounds.Width >= width / 8.0 * 0.22 && part.Bounds.Height >= height / (double)rows * 0.45);
                if (bodies.Count != rows * 8)
                    throw new InvalidDataException("Expected " + rows * 8 + " independent complete bodies, found " + bodies.Count + ": " + path);
                bodies.Sort((a, b) => a.CenterY.CompareTo(b.CenterY));
                HashSet<int> bodyIds = new HashSet<int>();
                foreach (Component body in bodies) bodyIds.Add(body.Id);
                List<Component> ordered = new List<Component>();
                for (int row = 0; row < rows; row++) {
                    List<Component> strip = bodies.GetRange(row * 8, 8);
                    strip.Sort((a, b) => a.CenterX.CompareTo(b.CenterX));
                    ordered.AddRange(strip);
                }
                int extras = 0;
                foreach (Component body in ordered) {
                    Rectangle bounds = body.Bounds;
                    if (bounds.Left < 2 || bounds.Top < 2 || bounds.Right > width - 2 || bounds.Bottom > height - 2)
                        throw new InvalidDataException("The source master itself clips a character: " + path);
                    List<Component> owned = new List<Component> { body };
                    Rectangle nearby = Rectangle.Inflate(bounds, 10, 10);
                    // Preserve nearby disconnected highlights/accessories, not the
                    // foot/hair shards that a neighboring grid row used to donate.
                    foreach (Component part in components) {
                        if (bodyIds.Contains(part.Id) || !nearby.Contains(part.Bounds)) continue;
                        owned.Add(part); bounds = Rectangle.Union(bounds, part.Bounds); extras++;
                    }
                    Bitmap crop = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
                    foreach (Component part in owned)
                        foreach (int pixel in part.Pixels) {
                            int x = pixel % width, y = pixel / width;
                            crop.SetPixel(x - bounds.Left, y - bounds.Top, source.GetPixel(x, y));
                        }
                    cells.Add(crop);
                }
                Console.WriteLine("LIVELY_SEGMENT " + Path.GetFileName(path) + " complete_bodies=" + bodies.Count + " nearby_details=" + extras);
            }
            return cells;
        } catch {
            foreach (Bitmap cell in cells) cell.Dispose();
            throw;
        }
    }

    static Bitmap Fit(Bitmap source, int width, int height, int baseline, double scale) {
        Bitmap image = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        int w = Math.Max(1, (int)Math.Round(source.Width * scale));
        int h = Math.Max(1, (int)Math.Round(source.Height * scale));
        using (Graphics graphics = Graphics.FromImage(image)) {
            graphics.Clear(Color.Transparent);
            graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
            graphics.PixelOffsetMode = PixelOffsetMode.Half;
            graphics.CompositingMode = CompositingMode.SourceCopy;
            graphics.DrawImage(source, new Rectangle((width - w) / 2, baseline - h, w, h),
                new Rectangle(0, 0, source.Width, source.Height), GraphicsUnit.Pixel);
        }
        return image;
    }

    static void Save(Bitmap image, string path) {
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        image.Save(path, ImageFormat.Png);
    }

    public static void Prepare(string root, string source) {
        string sprites = Path.Combine(root, "assets", "sprites");
        string[] people = { "mira", "oren", "eve", "finn", "traveler" };
        foreach (string person in people) {
            bool player = person == "traveler";
            // Visually verified: Mira and Finn masters have right, then left.
            string[] directions = person == "mira" || person == "finn"
                ? new[] { "down", "right", "left", "up" } : new[] { "down", "left", "right", "up" };
            List<Bitmap> cells = ReadAtlas(Path.Combine(source, person + "_animation.png"), player ? 4 : 5);
            try {
                int tallest = 1, widest = 1;
                foreach (Bitmap cell in cells) {
                    tallest = Math.Max(tallest, cell.Height);
                    widest = Math.Max(widest, cell.Width);
                }
                // One scale for the complete character: never resize each stride separately.
                double scale = Math.Min((player ? 108.0 : 132.0) / tallest, (player ? 84.0 : 112.0) / widest);
                for (int index = 0; index < cells.Count; index++) {
                    string name = index < 32 ? person + "_" + directions[index / 8] + "_" + index % 8
                        : person + "_" + (index - 32);
                    using (Bitmap frame = Fit(cells[index], player ? 96 : 128, player ? 128 : 160, player ? 120 : 148, scale))
                        Save(frame, Path.Combine(sprites, name + ".png"));
                }
                if (!player) {
                    Bitmap smile = cells[34];
                    using (Bitmap bust = smile.Clone(new Rectangle(0, 0, smile.Width, (int)(smile.Height * 0.72)), PixelFormat.Format32bppArgb)) {
                        double portraitScale = Math.Min(216.0 / bust.Height, 184.0 / bust.Width);
                        using (Bitmap portrait = Fit(bust, 208, 240, 234, portraitScale))
                            Save(portrait, Path.Combine(root, "assets", "ui", "portrait_" + person + ".png"));
                    }
                }
                Console.WriteLine("LIVELY_CHARACTER_READY " + person + " frames=" + cells.Count);
            } finally { foreach (Bitmap cell in cells) cell.Dispose(); }
        }
        foreach (string phase in new[] { "dawn", "day", "sunset", "night" })
            using (Bitmap hall = new Bitmap(Path.Combine(source, "hall_" + phase + ".png")))
                Save(hall, Path.Combine(root, "assets", "world", "inn_hall_" + phase + ".png"));
        Console.WriteLine("LIVELY_ART_READY: 192 animation frames, 4 happy portraits, 4 time-of-day backgrounds.");
    }
}
'@ -ReferencedAssemblies @('System.Drawing.Common', 'System.Drawing.Primitives', 'System.Runtime', 'System.Collections', 'System.Console', 'System.Private.Windows.Core', 'System.Private.Windows.GdiPlus', 'System.Runtime.InteropServices')
}

[StarlightLivelyArtV2]::Prepare([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')), [IO.Path]::GetFullPath($SourceDirectory))