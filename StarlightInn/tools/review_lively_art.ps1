[CmdletBinding()]
param()

# Explicit art review requested by the user: geometry evidence + real production previews.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not ('StarlightLivelyReview' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

public static class StarlightLivelyReview {
    static bool Foreground(Color color) {
        return color.A >= 16 && !(color.R > 180 && color.B > 180 && color.G < 110
            && Math.Min(color.R, color.B) - color.G > 100);
    }

    public static void Review(string root) {
        string output = Path.Combine(root, "qa", "art-review");
        Directory.CreateDirectory(output);
        List<string> report = new List<string>();
        string[] directions = { "down", "left", "right", "up" };
        int frameCount = 0, alphaFailures = 0;
        foreach (string person in new[] { "mira", "oren", "eve", "finn", "traveler" }) {
            int rows = person == "traveler" ? 4 : 5;
            using (Bitmap atlas = new Bitmap(Path.Combine(root, "assets", "source", "lively", person + "_animation.png"))) {
                int w = atlas.Width / 8, h = atlas.Height / rows;
                int badCells = 0;
                for (int row = 0; row < rows; row++)
                    for (int col = 0; col < 8; col++) {
                        int left = w, top = h, right = -1, bottom = -1, edge = 0;
                        for (int y = 0; y < h; y++)
                            for (int x = 0; x < w; x++) {
                                if (!Foreground(atlas.GetPixel(col * w + x, row * h + y))) continue;
                                left = Math.Min(left, x); right = Math.Max(right, x);
                                top = Math.Min(top, y); bottom = Math.Max(bottom, y);
                                if (x == 0 || x == w - 1 || y == 0 || y == h - 1) edge++;
                            }
                        if (edge > 0) {
                            badCells++;
                            report.Add("GRID_EDGE " + person + " row=" + row + " col=" + col + " pixels=" + edge
                                + " bounds=" + left + "," + top + "," + right + "," + bottom);
                        }
                    }
                report.Add("ATLAS " + person + " " + atlas.Width + "x" + atlas.Height + " grid_edge_cells=" + badCells);
            }
            const int cellWidth = 224, cellHeight = 260;
            using (Bitmap review = new Bitmap(cellWidth * 8, cellHeight * rows, PixelFormat.Format32bppArgb))
            using (Graphics graphics = Graphics.FromImage(review))
            using (Font font = new Font("Consolas", 11))
            using (Brush dark = new SolidBrush(Color.FromArgb(24, 33, 44)))
            using (Brush light = new SolidBrush(Color.FromArgb(34, 44, 56)))
            using (Brush label = new SolidBrush(Color.FromArgb(237, 222, 190))) {
                graphics.Clear(Color.FromArgb(15, 24, 33));
                graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
                graphics.PixelOffsetMode = PixelOffsetMode.Half;
                for (int index = 0; index < rows * 8; index++) {
                    string name = index < 32 ? person + "_" + directions[index / 8] + "_" + index % 8
                        : person + "_" + (index - 32);
                    int x0 = index % 8 * cellWidth, y0 = index / 8 * cellHeight;
                    for (int y = 0; y < 240; y += 12)
                        for (int x = 0; x < cellWidth; x += 12)
                            graphics.FillRectangle((x / 12 + y / 12) % 2 == 0 ? dark : light, x0 + x, y0 + y, 12, 12);
                    using (Bitmap frame = new Bitmap(Path.Combine(root, "assets", "sprites", name + ".png"))) {
                        int transparent = 0, edge = 0, magenta = 0;
                        for (int y = 0; y < frame.Height; y++)
                            for (int x = 0; x < frame.Width; x++) {
                                Color color = frame.GetPixel(x, y);
                                if (color.A == 0) transparent++;
                                if (color.A >= 16 && (x == 0 || x == frame.Width - 1 || y == 0 || y == frame.Height - 1)) edge++;
                                if (color.A >= 16 && !Foreground(color)) magenta++;
                            }
                        if (transparent == 0 || edge > 0 || magenta > 0) {
                            alphaFailures++;
                            report.Add("PRODUCTION_ERROR " + name + " transparent=" + transparent + " edge=" + edge + " matte=" + magenta);
                        }
                        int width = (int)Math.Round(frame.Width * 1.4), height = (int)Math.Round(frame.Height * 1.4);
                        graphics.DrawImage(frame, new Rectangle(x0 + (cellWidth - width) / 2, y0 + 8, width, height),
                            new Rectangle(0, 0, frame.Width, frame.Height), GraphicsUnit.Pixel);
                        graphics.DrawString(name, font, label, x0 + 8, y0 + 240);
                        frameCount++;
                    }
                }
                review.Save(Path.Combine(output, person + "-production.png"), ImageFormat.Png);
            }
        }
        report.Add("PRODUCTION_SUMMARY frames=" + frameCount + " alpha_or_canvas_failures=" + alphaFailures);
        File.WriteAllLines(Path.Combine(output, "geometry.txt"), report);
        foreach (string line in report) Console.WriteLine(line);
    }
}
'@ -ReferencedAssemblies @('System.Drawing.Common', 'System.Drawing.Primitives', 'System.Runtime', 'System.Collections', 'System.Console', 'System.Private.Windows.Core', 'System.Private.Windows.GdiPlus', 'System.Runtime.InteropServices')
}

[StarlightLivelyReview]::Review([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))