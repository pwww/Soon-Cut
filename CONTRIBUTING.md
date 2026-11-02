# Contributing to Soon-Cut / 貢獻指南

Thanks for helping! / 感謝你的協助！

## Contributor License Agreement / 貢獻者授權協議

Soon-Cut is published under GPL-3.0-or-later and is also distributed on the Mac App Store by Aicolab LLC. To keep both possible, every contribution needs this agreement.

By submitting a pull request, you agree that:

1. You wrote the contribution, or have the right to submit it.
2. Your contribution is licensed to the public under GPL-3.0-or-later.
3. You also grant Aicolab LLC a perpetual, worldwide, non-exclusive, royalty-free license to use, modify and distribute your contribution under other terms, including in the Mac App Store version.

Please add this line to your pull request description:

> I agree to the Soon-Cut Contributor License Agreement in CONTRIBUTING.md.

Soon-Cut 以 GPL-3.0-or-later 開源，同時由 Aicolab LLC 在 Mac App Store 發行。為了兩者都能成立，送出 pull request 即表示你同意：

1. 這份貢獻是你寫的，或你有權提交。
2. 你的貢獻以 GPL-3.0-or-later 授權給大眾。
3. 你同時授予 Aicolab LLC 永久、全球、非專屬、免權利金的授權，可以用其他條款使用、修改與發行你的貢獻，包括 Mac App Store 版本。

請在 pull request 說明加上：

> I agree to the Soon-Cut Contributor License Agreement in CONTRIBUTING.md.

## Development / 開發

- Generate the project with `xcodegen`; don't commit `SoonCut.xcodeproj`. / 用 `xcodegen` 產生專案，不要提交 `SoonCut.xcodeproj`。
- Keep everything on-device: no analytics, no network calls except downloading the speech model. / 維持全本機處理：不加分析追蹤，除了下載語音模型不連網。
- UI text is Traditional Chinese for now. / 介面文字目前以繁體中文為主。
