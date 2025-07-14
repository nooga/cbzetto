# CBZ Viewer

A simple desktop application to view CBZ files (comic book archives) on Mac. It features smooth scrolling with touchpad, pages scaled to full width preserving aspect ratio, a page number and progress indicator in the bottom left, and efficient loading/unloading of pages to minimize RAM usage.

## Requirements

- Python 3.x
- PyQt6
- Pillow

## Installation

1. Create and activate a virtual environment (recommended):

   ```
   python3 -m venv venv
   source venv/bin/activate  # On Mac/Linux; use venv\Scripts\activate on Windows
   ```

2. Install dependencies:
   ```
   pip install -r requirements.txt
   ```

## Usage

Make sure the virtual environment is activated, then run:

```
python main.py [optional_path_to_cbz_file_or_folder]
```

If a folder path is provided, it will load all CBZ files in alphanumeric order and allow scrolling through them as a single document. If a file path is provided, it loads that single file. Otherwise, a file dialog prompts for selection.

A '.cbzviewer_state.json' file will be created in the folder to remember the scroll position for next time.

## Features

- Smooth touchpad scrolling
- Automatic page scaling to window width (preserving aspect ratio)
- Page number and percentage read indicator
- Lazy loading of images for memory efficiency
- Multi-file support: Load a folder of CBZ files and scroll through all as one.
- Updated indicator: Shows current file, local page, global page, and global percentage.
- State persistence: Remembers scroll position in folders.

This project is built using PyQt6 for the GUI and Pillow for image handling. CBZ files are handled via Python's built-in zipfile module.
