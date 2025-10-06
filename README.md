# Manga Library Manager - KOReader Plugin


FEEL FREE TO FORK AND CHANGE, AND THEN OPEN A PULL REQUEST BACK HERE TO IMPLEMENT THE CHANGES!
A comprehensive manga library management plugin for KOReader that provides full-screen manga organization, reading progress tracking, and seamless chapter navigation.

![Manga Library Manager](https://img.shields.io/badge/KOReader-Plugin-blue) ![Version](https://img.shields.io/badge/version-1.0.0-green) ![Tested](https://img.shields.io/badge/tested-Kindle%20PW7-orange)

## Features

✅ **Full-Screen Library Interface** - Rakuyomi-style full-screen manga browser  
✅ **Reading Progress Tracking** - Visual indicators for read/unread chapters and series completion  
✅ **Series Management** - Organize manga by series with automatic chapter sorting  
✅ **Bulk Operations** - Mark entire series as read/unread with confirmation dialogs  
✅ **Individual Chapter Control** - Long-press chapters for individual read/unread toggle  
✅ **Multiple Format Support** - Supports .cbz, .cbr, .cb7, .zip, and .rar files  
✅ **Persistent Settings** - Reading progress saved across KOReader sessions  
✅ **Seamless Navigation** - Clean back-button navigation between library and chapters  


## Installation

### Prerequisites
- **Jailbroken Kindle** (or **Ubuntu** (required for custom plugins)
- **KOReader installed** on your device
- **Kindle Paperwhite Gen 7** or **Ubuntu** (tested device - probably will work on others as well)

### Step-by-Step Installation

1. **Download the Plugin Files**
   - Download `main.lua` and `_meta.lua` from this repository

2. **Create Plugin Folder**
Create folder: MangaLibrary.koplugin

3. **Add Plugin Files**
MangaLibrary.koplugin/
├── main.lua
└── _meta.lua


4. **Install on Device**
- Connect your Kindle via USB
- Copy the `MangaLibrary.koplugin` folder to:
  ```
  /mnt/us/koreader/plugins/
  ```

5. **Enable the Plugin**
- Open KOReader
- Go to: **Tools → Plugin Management**
- Enable **"Manga Library Manager"**
- Restart KOReader

6. **Access the Plugin**
- Go to: **Tools → Manga Library**

## Usage

### Setting Up Your Manga Collection

1. **Organize Your Files**
For example, do:

/mnt/us/manga/
├── One Piece/
│ ├── Chapter 001.cbz
│ ├── Chapter 002.cbz
│ └── Chapter 003.cbz
├── Naruto/
│ ├── Chapter 001.cbz
│ └── Chapter 002.cbz
└── Attack on Titan/
├── Chapter 001.cbz
└── Chapter 002.cbz

2. **Add Manga Folders**
- Open Manga Library
- Tap **⚙️ Settings** (top-left)
- Select **"Add Manga Folder"**
- Enter path: `/mnt/us/manga/`
- Plugin automatically scans for series and chapters

### Reading and Progress Tracking

- **View Library**: See all series with progress indicators `✓` (complete) `○` (in-progress)
- **Enter Series**: Tap any series to view chapters
- **Read Chapter**: Tap chapter to open (automatically marked as read)
- **Mark Progress**: Long-press chapters for read/unread options
- **Bulk Actions**: Use "Mark All Read/Unread" buttons within each series

### Navigation

- **Library View**: ⚙️ Settings, Series List, Close option
- **Chapter View**: ← Back to Library, Bulk controls, Chapter list
- **Back Key**: Smart navigation (Chapters → Library → Close)

## Supported File Formats

- **.cbz** (Comic Book ZIP)
- **.cbr** (Comic Book RAR) 
- **.cb7** (Comic Book 7z)
- **.zip** (ZIP archives)
- **.rar** (RAR archives)

## Compatibility

### Tested Devices
- ✅ **Kindle Paperwhite Gen 7** (Primary test device)

### Expected Compatibility
- 🟡 **Other Kindle Models** (may require path adjustments)
- 🟡 **Kobo eReaders** (change paths to `/mnt/onboard/manga/`)
- 🟡 **PocketBook** (change paths to `/mnt/ext1/manga/`)
- 🟡 **Android/Linux KOReader** (adjust paths accordingly)

> **Note**: This plugin has only been thoroughly tested on Kindle Paperwhite Gen 7. While it should work on other KOReader-supported devices, you may need to adjust manga folder paths for your specific device.

## Troubleshooting

### Common Issues

**Plugin doesn't appear in menu**
- Ensure folder is named exactly `MangaLibrary.koplugin`
- Check plugin is in correct directory: `/mnt/us/koreader/plugins/`
- Restart KOReader completely

**No manga series found**
- Verify manga folder path is correct for your device
- Ensure manga files are in series subdirectories
- Check file extensions are supported (.cbz, .cbr, etc.)
- Use "Refresh Library" in settings menu

**Chapters not sorting correctly**
- Ensure chapter files have numbers in their names
- Example: "Chapter 001.cbz", "Ch 01.cbz", "Volume 1 Chapter 5.cbz"

## Future Plans

🚀 **Planned Features for Future Releases:**

- ** Direct Manga Downloads** - Download manga directly into specified folders from within the plugin
- ** Enhanced Display Options** - Cover art display, grid view, reading statistics
- ** Library Management** - Series grouping, custom tags, search functionality
- ** Online Integration** - Popular manga source integration with automatic updates
- ** Multi-Device Sync** - Progress synchronization across multiple devices
- ** Performance Optimizations** - Faster library loading for large collections

## Contributing

This is an open-source project! Contributions, bug reports, and feature requests are welcome.

- **Bug Reports**: Please include your device model, KOReader version, and detailed steps to reproduce
- **Feature Requests**: Describe your use case and how the feature would improve your manga reading experience

**Made for manga lovers who want better organization on their e-readers! 📚✨**

*Tested and developed on Kindle Paperwhite Gen 7 with KOReader*
