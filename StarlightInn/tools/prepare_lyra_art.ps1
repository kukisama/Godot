[CmdletBinding()]
param(
    [string]$MovementSource = (Join-Path $PSScriptRoot '..\assets\source\lively\lyra_movement.png'),
    [string]$ExpressionSource = (Join-Path $PSScriptRoot '..\assets\source\lively\lyra_expressions.png'),
    [string]$RembgPython = (Join-Path $env:LOCALAPPDATA 'StarlightInn\rembg-venv\Scripts\python.exe'),
    [switch]$ForceBackgroundRemoval
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$qa = Join-Path $root 'qa\lyra-cut'
[void][IO.Directory]::CreateDirectory($qa)

foreach ($path in @($MovementSource, $ExpressionSource)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing generated source: $path" }
}
if (-not (Test-Path -LiteralPath $RembgPython -PathType Leaf)) { throw "rembg Python was not found: $RembgPython" }

$movementCutout = Join-Path $qa 'lyra_movement_cutout.png'
$expressionCutout = Join-Path $qa 'lyra_expressions_cutout.png'
$remover = Join-Path $PSScriptRoot 'remove_asset_background.py'
$refreshCutouts = $ForceBackgroundRemoval -or -not (Test-Path -LiteralPath $movementCutout -PathType Leaf) `
    -or -not (Test-Path -LiteralPath $expressionCutout -PathType Leaf) `
    -or (Get-Item -LiteralPath $movementCutout).LastWriteTimeUtc -lt (Get-Item -LiteralPath $MovementSource).LastWriteTimeUtc `
    -or (Get-Item -LiteralPath $expressionCutout).LastWriteTimeUtc -lt (Get-Item -LiteralPath $ExpressionSource).LastWriteTimeUtc
if ($refreshCutouts) {
    & $RembgPython $remover --model birefnet-general --input $MovementSource $ExpressionSource --output $movementCutout $expressionCutout --grid 1x1 2x4
    if ($LASTEXITCODE -ne 0) { throw "Background removal failed: $LASTEXITCODE" }
}
else { Write-Output 'BACKGROUND_CUTOUTS_REUSED movement=1 expressions=8' }

Add-Type -AssemblyName System.Drawing
if (-not ('StarlightLyraArtV8' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

public static class StarlightLyraArtV8 {
    sealed class Component {
        public Rectangle Bounds;
        public List<int> Pixels = new List<int>();
        public double CenterX { get { return Bounds.Left + Bounds.Width / 2.0; } }
        public double CenterY { get { return Bounds.Top + Bounds.Height / 2.0; } }
    }

    static List<Bitmap> Extract(string path, int rows, int columns) {
        List<Bitmap> cells = new List<Bitmap>();
        using (Bitmap source = new Bitmap(path)) {
            int width = source.Width, height = source.Height, count = width * height;
            bool[] foreground = new bool[count];
            int[] labels = new int[count], queue = new int[count];
            for (int y = 0; y < height; y++)
                for (int x = 0; x < width; x++)
                    foreground[y * width + x] = source.GetPixel(x, y).A >= 24;

            List<Component> components = new List<Component>();
            for (int pixel = 0; pixel < count; pixel++) {
                if (!foreground[pixel] || labels[pixel] != 0) continue;
                Component part = new Component();
                int id = components.Count + 1, head = 0, tail = 1;
                int left = width, top = height, right = -1, bottom = -1;
                queue[0] = pixel; labels[pixel] = id;
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
                            labels[next] = id; queue[tail++] = next;
                        }
                }
                part.Bounds = Rectangle.FromLTRB(left, top, right + 1, bottom + 1);
                components.Add(part);
            }

            double cellWidth = width / (double)columns, cellHeight = height / (double)rows;
            List<Component> bodies = components.FindAll(part => part.Pixels.Count >= 500
                && part.Bounds.Width >= cellWidth * 0.22 && part.Bounds.Height >= cellHeight * 0.38);
            if (bodies.Count != rows * columns)
                throw new InvalidDataException("Expected " + (rows * columns) + " complete subjects, found " + bodies.Count + " in " + path);

            bodies.Sort((a, b) => a.CenterY.CompareTo(b.CenterY));
            List<Component> ordered = new List<Component>();
            for (int row = 0; row < rows; row++) {
                List<Component> strip = bodies.GetRange(row * columns, columns);
                strip.Sort((a, b) => a.CenterX.CompareTo(b.CenterX));
                ordered.AddRange(strip);
            }

            foreach (Component body in ordered) {
                Rectangle bounds = Rectangle.Inflate(body.Bounds, 3, 3);
                bounds.Intersect(new Rectangle(0, 0, width, height));
                Bitmap crop = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
                using (Graphics graphics = Graphics.FromImage(crop)) {
                    graphics.CompositingMode = CompositingMode.SourceCopy;
                    graphics.DrawImage(source, new Rectangle(0, 0, bounds.Width, bounds.Height), bounds, GraphicsUnit.Pixel);
                }
                cells.Add(crop);
            }
        }
        return cells;
    }

    static Bitmap Fit(Bitmap source, int width, int height, int baseline, double scale) {
        Bitmap image = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        int w = Math.Max(1, (int)Math.Round(source.Width * scale));
        int h = Math.Max(1, (int)Math.Round(source.Height * scale));
        using (Graphics graphics = Graphics.FromImage(image)) {
            graphics.Clear(Color.Transparent);
            graphics.CompositingMode = CompositingMode.SourceCopy;
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            graphics.DrawImage(source, new Rectangle((width - w) / 2, baseline - h, w, h),
                new Rectangle(0, 0, source.Width, source.Height), GraphicsUnit.Pixel);
        }
        return image;
    }

    static List<Bitmap> ExtractSafeGrid(string path, int rows, int columns) {
        List<Bitmap> cells = new List<Bitmap>();
        using (Bitmap source = new Bitmap(path)) {
            for (int row = 0; row < rows; row++)
                for (int column = 0; column < columns; column++) {
                    int cellLeft = source.Width * column / columns;
                    int cellTop = source.Height * row / rows;
                    int cellRight = source.Width * (column + 1) / columns;
                    int cellBottom = source.Height * (row + 1) / rows;
                    int left = cellRight, top = cellBottom, right = -1, bottom = -1, pixels = 0;
                    for (int y = cellTop; y < cellBottom; y++)
                        for (int x = cellLeft; x < cellRight; x++) {
                            if (source.GetPixel(x, y).A < 24) continue;
                            pixels++;
                            left = Math.Min(left, x); right = Math.Max(right, x);
                            top = Math.Min(top, y); bottom = Math.Max(bottom, y);
                        }
                    if (pixels < 500 || right < left || bottom < top)
                        throw new InvalidDataException("Missing subject at row=" + row + " column=" + column + " in " + path);
                    Rectangle bounds = Rectangle.FromLTRB(Math.Max(cellLeft, left - 3), Math.Max(cellTop, top - 3),
                        Math.Min(cellRight, right + 4), Math.Min(cellBottom, bottom + 4));
                    Bitmap crop = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
                    using (Graphics graphics = Graphics.FromImage(crop)) {
                        graphics.CompositingMode = CompositingMode.SourceCopy;
                        graphics.DrawImage(source, new Rectangle(0, 0, bounds.Width, bounds.Height), bounds, GraphicsUnit.Pixel);
                    }
                    cells.Add(crop);
                }
        }
        return cells;
    }

    static int FindVerticalGap(Bitmap source, int expected, int radius, int top, int bottom) {
        int best = expected, bestPixels = int.MaxValue;
        for (int x = Math.Max(1, expected - radius); x < Math.Min(source.Width - 1, expected + radius); x++) {
            int pixels = 0;
            for (int y = top; y < bottom; y++) if (source.GetPixel(x, y).A >= 24) pixels++;
            if (pixels < bestPixels) { best = x; bestPixels = pixels; }
        }
        if (bestPixels > 0) throw new InvalidDataException("No transparent vertical separator near x=" + expected + " pixels=" + bestPixels);
        return best;
    }

    static int FindHorizontalGap(Bitmap source, int expected, int radius) {
        int best = expected, bestPixels = int.MaxValue;
        for (int y = Math.Max(1, expected - radius); y < Math.Min(source.Height - 1, expected + radius); y++) {
            int pixels = 0;
            for (int x = 0; x < source.Width; x++) if (source.GetPixel(x, y).A >= 24) pixels++;
            if (pixels < bestPixels) { best = y; bestPixels = pixels; }
        }
        if (bestPixels > 0) throw new InvalidDataException("No transparent horizontal separator near y=" + expected + " pixels=" + bestPixels);
        return best;
    }

    static List<Bitmap> ExtractAdaptiveGrid(string path, int rows, int columns) {
        List<Bitmap> cells = new List<Bitmap>();
        using (Bitmap source = new Bitmap(path)) {
            int[] yCuts = new int[rows + 1];
            yCuts[0] = 0; yCuts[rows] = source.Height;
            for (int row = 1; row < rows; row++)
                yCuts[row] = FindHorizontalGap(source, source.Height * row / rows, source.Height / rows / 3);

            for (int row = 0; row < rows; row++) {
                int[] xCuts = new int[columns + 1];
                xCuts[0] = 0; xCuts[columns] = source.Width;
                for (int column = 1; column < columns; column++)
                    xCuts[column] = FindVerticalGap(source, source.Width * column / columns, source.Width / columns / 3,
                        yCuts[row], yCuts[row + 1]);
                for (int column = 0; column < columns; column++) {
                    int left = xCuts[column + 1], top = yCuts[row + 1], right = -1, bottom = -1, pixels = 0;
                    for (int y = yCuts[row]; y < yCuts[row + 1]; y++)
                        for (int x = xCuts[column]; x < xCuts[column + 1]; x++) {
                            if (source.GetPixel(x, y).A < 24) continue;
                            pixels++;
                            left = Math.Min(left, x); right = Math.Max(right, x);
                            top = Math.Min(top, y); bottom = Math.Max(bottom, y);
                        }
                    if (pixels < 500 || right < left || bottom < top)
                        throw new InvalidDataException("Missing subject at row=" + row + " column=" + column + " in " + path);
                    Rectangle bounds = Rectangle.FromLTRB(Math.Max(xCuts[column], left - 3), Math.Max(yCuts[row], top - 3),
                        Math.Min(xCuts[column + 1], right + 4), Math.Min(yCuts[row + 1], bottom + 4));
                    Bitmap crop = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
                    using (Graphics graphics = Graphics.FromImage(crop)) {
                        graphics.CompositingMode = CompositingMode.SourceCopy;
                        graphics.DrawImage(source, new Rectangle(0, 0, bounds.Width, bounds.Height), bounds, GraphicsUnit.Pixel);
                    }
                    cells.Add(crop);
                }
                    }
        }
        return cells;
    }

    static void Save(Bitmap image, string path) {
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        image.Save(path, ImageFormat.Png);
    }

    public static void Prepare(string root, string movementPath, string expressionPath) {
        string sprites = Path.Combine(root, "assets", "sprites");
        List<Bitmap> movement = Extract(movementPath, 4, 8);
        try {
            int tallest = 1, widest = 1;
            foreach (Bitmap frame in movement) {
                tallest = Math.Max(tallest, frame.Height);
                widest = Math.Max(widest, frame.Width);
            }
            double scale = Math.Min(132.0 / tallest, 112.0 / widest);
            string[] directions = { "down", "left", "right", "up" };
            for (int index = 0; index < movement.Count; index++)
                using (Bitmap frame = Fit(movement[index], 128, 160, 148, scale)) {
                    Save(frame, Path.Combine(sprites, "lyra_" + directions[index / 8] + "_" + (index % 8) + ".png"));
                    if (index < 8) Save(frame, Path.Combine(sprites, "lyra_" + index + ".png"));
                }
        } finally { foreach (Bitmap frame in movement) frame.Dispose(); }

        string[] expressions = { "neutral", "smile", "laugh", "concern", "surprise", "anger", "sad", "determined" };
        // Background removal already runs independently per 2x4 slot. Preserve
        // every surviving edge pixel from each isolated slot instead of seeking
        // a sheet-wide transparent separator that soft alpha may not provide.
        List<Bitmap> portraits = ExtractSafeGrid(expressionPath, 2, 4);
        try {
            int tallest = 1, widest = 1;
            foreach (Bitmap portrait in portraits) {
                tallest = Math.Max(tallest, portrait.Height);
                widest = Math.Max(widest, portrait.Width);
            }
            double scale = Math.Min(226.0 / tallest, 194.0 / widest);
            for (int index = 0; index < portraits.Count; index++)
                using (Bitmap portrait = Fit(portraits[index], 208, 240, 234, scale)) {
                    Save(portrait, Path.Combine(root, "assets", "ui", "lyra_" + expressions[index] + ".png"));
                    if (index == 1) Save(portrait, Path.Combine(root, "assets", "ui", "portrait_lyra.png"));
                }
        } finally { foreach (Bitmap portrait in portraits) portrait.Dispose(); }
        Console.WriteLine("LYRA_ART_READY movement=32 idle_gestures=8 expressions=8 portrait=1");
    }
}
'@ -ReferencedAssemblies @('System.Drawing.Common', 'System.Drawing.Primitives', 'System.Runtime', 'System.Collections', 'System.Console', 'System.Private.Windows.Core', 'System.Private.Windows.GdiPlus', 'System.Runtime.InteropServices')
}

[StarlightLyraArtV8]::Prepare($root, [IO.Path]::GetFullPath($movementCutout), [IO.Path]::GetFullPath($expressionCutout))