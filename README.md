<p align="center">
  <img src="Design/icon_1024.png" width="128" alt="Soon-Cut icon">
</p>

<h1 align="center">Soon-Cut</h1>

<p align="center">
  A floating macOS tool for turning what you're watching into a subtitled short video — record a region, trim, caption, drag to upload.<br>
  macOS 浮動小工具：邊看邊錄、剪頭尾、自動上繁中字幕，做完直接拖去上傳。
</p>

---

## English

Soon-Cut stays on top of your screen while you watch, review or demo something. Frame a region, record a few clips, trim them, add captions, and export a short video sized for Threads, Reels, Shorts or TikTok. Everything runs on your Mac — no account, no cloud, no data collected.

### Features

- **Always-on-top floating panel** that doesn't steal focus from your browser or video player
- **Region capture** — drag to frame any part of the screen; one click to lock 9:16
- **System audio recording** via ScreenCaptureKit
- **Clip editing** — trim with a filmstrip like iPhone Photos, drag to reorder, park clips in a staging area
- **On-device captions** — Traditional Chinese transcription with [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift), edit line by line
- **Multi-ratio export** — original / 9:16 / 4:5 / 1:1 / 16:9 with blurred background fill, platform hints and length warnings
- **Drag to upload** — drag the exported video straight into a web upload box or Finder

### Requirements

- macOS 15 or later, Apple Silicon
- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- About 1.6 GB of disk space for the speech model (downloaded on first use)

### Build from source

```bash
git clone <this repo>
cd Soon-Cut
xcodegen                     # generates SoonCut.xcodeproj from project.yml
open SoonCut.xcodeproj
```

1. In `project.yml`, set `DEVELOPMENT_TEAM` to your own Apple team ID (a stable signature keeps the Screen Recording permission from being asked on every build), then run `xcodegen` again.
2. Choose **My Mac** as the destination and press ⌘R.
3. On first recording, allow **Screen & System Audio Recording** for SoonCut in System Settings, then relaunch.

Builds from source have no watermark. The Mac App Store version is free to download with a small watermark, removed by a one-time purchase — buying it is a way to support the project.

### Responsible use

Soon-Cut is a screen recorder for commentary, tutorials, demos and your own content. Only share recordings of other people's work when you have the right to do so.

### License

Soon-Cut is free software, licensed under the [GNU General Public License v3.0 or later](LICENSE).

The **Soon-Cut name and icon are not covered by the license**. If you distribute a modified version, please give it a different name and icon.

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

---

## 繁體中文

Soon-Cut 是一個常駐在螢幕最上層的浮動視窗。看影片、做評論或示範時，框選畫面錄幾段、剪掉頭尾、自動上繁中字幕，再輸出成適合 Threads、Reels、Shorts、TikTok 的短影音。全部在你的 Mac 上處理，不用帳號、不上雲端、不收集資料。

### 功能

- **永遠在最上層的浮動視窗**，不會搶走瀏覽器或播放器的焦點
- **框選錄影**：直接在畫面上拖曳框選，一鍵鎖定 9:16
- **錄系統聲音**（ScreenCaptureKit）
- **片段剪輯**：像 iPhone 相簿一樣拖膠卷條剪頭尾、拖曳排序、暫存區放這次不用的片段
- **本機字幕**：用 [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) 轉寫繁體中文，可以逐句修改
- **多比例輸出**：原始／9:16／4:5／1:1／16:9，自動補模糊背景，標示適合的平台與長度上限
- **拖去上傳**：把輸出的影片直接拖進網頁上傳框或 Finder

### 需求

- macOS 15 以上、Apple Silicon
- Xcode 16 以上
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- 語音模型約 1.6 GB（第一次產生字幕時下載）

### 從原始碼編譯

```bash
git clone <這個 repo>
cd Soon-Cut
xcodegen                     # 從 project.yml 產生 SoonCut.xcodeproj
open SoonCut.xcodeproj
```

1. 把 `project.yml` 裡的 `DEVELOPMENT_TEAM` 改成你自己的 Apple 開發者 Team ID，再跑一次 `xcodegen`。簽章固定，螢幕錄影權限才不會每次編譯都重問。
2. 執行目的地選 **My Mac**，按 ⌘R。
3. 第一次錄影時，到系統設定允許 SoonCut 使用「螢幕與系統錄音」，然後重新開啟 App。

自己編譯的版本沒有浮水印。Mac App Store 版免費下載，右下角有小浮水印，一次買斷即可移除；購買也是支持這個專案的方式。

### 使用提醒

Soon-Cut 是用來評論、教學、示範與剪輯自己內容的螢幕錄影工具。轉發他人的作品前，請先確認你有權利這麼做。

### 授權

Soon-Cut 是自由軟體，採用 [GNU 通用公共授權條款 第 3 版或更新版本](LICENSE)（GPL-3.0-or-later）。

**「Soon-Cut」名稱與圖示不在授權範圍內。** 如果你發布修改後的版本，請使用不同的名稱與圖示。

歡迎貢獻，請先閱讀 [CONTRIBUTING.md](CONTRIBUTING.md)。

開發測試清單見 [docs/TESTING.md](docs/TESTING.md)。
