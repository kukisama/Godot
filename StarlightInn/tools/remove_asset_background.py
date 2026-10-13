from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image
from rembg import new_session, remove


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="birefnet-general")
    parser.add_argument("--input", nargs="+", type=Path, required=True)
    parser.add_argument("--output", nargs="+", type=Path, required=True)
    parser.add_argument("--grid", nargs="+", required=True)
    args = parser.parse_args()
    if len(args.input) != len(args.output) or len(args.input) != len(args.grid):
        parser.error("--input, --output and --grid must contain the same number of values")

    session = new_session(args.model)
    for source, destination, grid in zip(args.input, args.output, args.grid, strict=True):
        rows, columns = (int(value) for value in grid.lower().split("x", maxsplit=1))
        destination.parent.mkdir(parents=True, exist_ok=True)
        with Image.open(source) as image:
            image = image.convert("RGBA")
            sheet = Image.new("RGBA", image.size, (0, 0, 0, 0))
            for row in range(rows):
                for column in range(columns):
                    left = image.width * column // columns
                    top = image.height * row // rows
                    right = image.width * (column + 1) // columns
                    bottom = image.height * (row + 1) // rows
                    cell = image.crop((left, top, right, bottom))
                    cutout = remove(cell, session=session, decontaminate=True)
                    sheet.alpha_composite(cutout, (left, top))
            sheet.save(destination)
        print(f"BACKGROUND_REMOVED {source.name} grid={rows}x{columns} -> {destination}")


if __name__ == "__main__":
    main()