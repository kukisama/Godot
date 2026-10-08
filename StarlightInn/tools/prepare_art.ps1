param()

# Production conversion of the Image 2.5 masters; no generation requests here.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not ('StarlightArt' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Collections.Generic;

public static class StarlightArt {
    static Bitmap Key(Bitmap source, Rectangle region) {
        Bitmap result = new Bitmap(region.Width, region.Height, PixelFormat.Format32bppArgb);
        for (int y = 0; y < region.Height; y++) {
            for (int x = 0; x < region.Width; x++) {
                Color c = source.GetPixel(region.X + x, region.Y + y);
                int spill = Math.Min(c.R, c.B) - c.G;
                bool key = c.R > 140 && c.B > 140 && c.G < 145 && spill > 65;
                result.SetPixel(x, y, key ? Color.Transparent : c);
            }
        }
        return result;
    }

    static Rectangle Bounds(Bitmap image) {
        int left = image.Width, top = image.Height, right = -1, bottom = -1;
        for (int y = 0; y < image.Height; y++) {
            for (int x = 0; x < image.Width; x++) {
                if (image.GetPixel(x, y).A < 16) continue;
                left = Math.Min(left, x); top = Math.Min(top, y);
                right = Math.Max(right, x); bottom = Math.Max(bottom, y);
            }
        }
        if (right < left || bottom < top) throw new InvalidDataException("Empty artwork cell.");
        return Rectangle.FromLTRB(left, top, right + 1, bottom + 1);
    }

    static void Save(Bitmap image, string path) {
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        image.Save(path, ImageFormat.Png);
        Console.WriteLine("PREPARED " + path);
    }

    static Bitmap Fit(Bitmap source, int width, int height, int baseline, double scale) {
        Bitmap result = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        int w = Math.Max(1, (int)Math.Round(source.Width * scale));
        int h = Math.Max(1, (int)Math.Round(source.Height * scale));
        if (w > width || h > baseline) throw new InvalidDataException("Sprite exceeds its canvas.");
        using (Graphics g = Graphics.FromImage(result)) {
            g.Clear(Color.Transparent);
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.CompositingMode = CompositingMode.SourceCopy;
            g.DrawImage(source, new Rectangle((width - w) / 2, baseline - h, w, h),
                new Rectangle(0, 0, source.Width, source.Height), GraphicsUnit.Pixel);
        }
        return result;
    }

    static List<Bitmap> Cells(string path, int columns, int rows) {
        List<Bitmap> cells = new List<Bitmap>();
        using (Bitmap source = new Bitmap(path)) {
            if (source.Width % columns != 0 || source.Height % rows != 0)
                throw new InvalidDataException("Atlas dimensions do not match the grid: " + path);
            int w = source.Width / columns, h = source.Height / rows;
            for (int row = 0; row < rows; row++) {
                for (int col = 0; col < columns; col++) {
                    using (Bitmap keyed = Key(source, new Rectangle(col * w, row * h, w, h))) {
                        Rectangle bounds = Bounds(keyed);
                        if (bounds.Width < 24 || bounds.Height < 24)
                            throw new InvalidDataException("Unexpectedly small artwork cell.");
                        cells.Add(keyed.Clone(bounds, PixelFormat.Format32bppArgb));
                    }
                }
            }
        }
        return cells;
    }

    public static void Prepare(string root) {
        string source = Path.Combine(root, "assets", "source");
        string sprites = Path.Combine(root, "assets", "sprites");
        string ui = Path.Combine(root, "assets", "ui");
        string[] directions = { "down", "left", "right", "up" };
        string[] names = { "mira", "oren", "eve", "finn" };
        List<Bitmap> hero = Cells(Path.Combine(source, "traveler_sheet.png"), 4, 4);
        try {
            int tallest = 1, widest = 1;
            foreach (Bitmap cell in hero) { tallest = Math.Max(tallest, cell.Height); widest = Math.Max(widest, cell.Width); }
            double scale = Math.Min(108.0 / tallest, 84.0 / widest);
            for (int i = 0; i < hero.Count; i++) {
                using (Bitmap frame = Fit(hero[i], 96, 128, 120, scale))
                    Save(frame, Path.Combine(sprites, "traveler_" + directions[i / 4] + "_" + (i % 4) + ".png"));
            }
        } finally { foreach (Bitmap cell in hero) cell.Dispose(); }

        List<Bitmap> npcs = Cells(Path.Combine(source, "npc_sheet.png"), 4, 2);
        try {
            int tallest = 1, widest = 1;
            foreach (Bitmap cell in npcs) { tallest = Math.Max(tallest, cell.Height); widest = Math.Max(widest, cell.Width); }
            double scale = Math.Min(132.0 / tallest, 112.0 / widest);
            for (int i = 0; i < npcs.Count; i++) {
                using (Bitmap frame = Fit(npcs[i], 128, 160, 148, scale))
                    Save(frame, Path.Combine(sprites, names[i % 4] + "_" + (i / 4) + ".png"));
                if (i < 4) {
                    Rectangle bust = new Rectangle(0, 0, npcs[i].Width, (int)(npcs[i].Height * 0.72));
                    using (Bitmap crop = npcs[i].Clone(bust, PixelFormat.Format32bppArgb)) {
                        double portraitScale = Math.Min(216.0 / crop.Height, 184.0 / crop.Width);
                        using (Bitmap portrait = Fit(crop, 208, 240, 234, portraitScale))
                            Save(portrait, Path.Combine(ui, "portrait_" + names[i] + ".png"));
                    }
                }
            }
        } finally { foreach (Bitmap cell in npcs) cell.Dispose(); }

        string[] props = { "lantern", "crystal", "noticeboard", "ivy", "crest", "candles", "books", "sparkle" };
        List<Bitmap> objects = Cells(Path.Combine(source, "prop_sheet.png"), 4, 2);
        try {
            for (int i = 0; i < objects.Count; i++) {
                Save(objects[i], Path.Combine(sprites, props[i] + ".png"));
            }
        } finally { foreach (Bitmap cell in objects) cell.Dispose(); }

        using (Bitmap frame = new Bitmap(Path.Combine(source, "dialogue_frame.png")))
        using (Bitmap keyed = Key(frame, new Rectangle(0, 0, frame.Width, frame.Height)))
        using (Bitmap cropped = keyed.Clone(Bounds(keyed), PixelFormat.Format32bppArgb))
            Save(cropped, Path.Combine(ui, "dialogue_frame.png"));
        using (Bitmap hall = new Bitmap(Path.Combine(source, "inn_hall.png")))
            Save(hall, Path.Combine(root, "assets", "world", "inn_hall.png"));
        Console.WriteLine("ART_READY: 5 Image 2.5 masters -> 38 production PNGs; portraits derived from the NPC master.");
    }
}
'@ -ReferencedAssemblies @('System.Drawing.Common', 'System.Drawing.Primitives', 'System.Runtime', 'System.Collections', 'System.Console', 'System.Private.Windows.Core', 'System.Private.Windows.GdiPlus', 'System.Runtime.InteropServices')
}

[StarlightArt]::Prepare([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))