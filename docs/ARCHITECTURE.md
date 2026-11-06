# ARCHITECTURE

## 全体像
```
 [BLEキーボード/DAW] --BLE MIDI--> [ESP32ブリッジ(最終)] --\
 [USB/DIN MIDI機器] ------------> [マイコン(まず有線)] -----+--リンクケーブル--> Chromatic(カート: ChromaSynth ROM)
```
ROM は MIDI のトランスポートに依存しない。「リンクポートで届くMIDIバイト列」だけを扱う。
BLE は後付けでブリッジ側(ESP32)に実装する。

## ROM 内部
- `main.asm`: ベクタ/ヘッダ/初期化/メインループ/ISR/MIDI解析/ジョイパッド/発音(M0)
- 割り込み: VBlank(フレームフラグ), Serial(受信バイトをリングバッファへ)
- メインループ: `halt` → MIDI drain(毎回) → VBlank時のみ ジョイパッド + UI + シーケンサ tick
- ボイス: 4ch(パルス×2、ウェーブ、ノイズ)。当面は CH1 のモノ発音。

## 今後のモジュール分割(予定)
| ファイル | 内容 |
|----------|------|
| `apu.asm` | チャンネル抽象化、パッチ適用、エンベロープ/ビブラート/アルペジオのフレーム更新 |
| `midi.asm` | 受信パーサ、チャンネル→ボイスのアロケート、MIDI OUT キュー |
| `seq.asm` | パターン/ソング、再生位置、テンポ(VBlank 基準 or Timer)、MIDI clock 同期 |
| `ui.asm` | 画面描画(BG タイルのテキスト)、画面遷移(Patch / Sequencer / Song) |
| `sram.asm` | パッチ・パターンの保存(MBC5+SRAM) |

## データ構造(案)
- Patch(16B 程度): ch種別, duty, 初期音量, エンベロープ, sweep, ビブラート深さ/速度, アルペジオ, wave番号, noise設定
- Pattern: 64 step × (note, patch, vol/cmd) × 4ch
- Song: パターン番号の並び

## 操作系(案)
D-pad/A/B/Start/Select のみ。Patch画面: 項目選択+値増減。Sequencer画面: LSDj/ tracker 風グリッド。

## 未確認事項(ハード仕様は要確認)
- Chromatic のリンクポート仕様(コネクタ形状、電圧、クロック供給方式・速度)。
- Chromatic が選ぶ動作モード(DMG/CGB)。現在は `-c`(両対応)で作っている。
- 使用フラッシュカート: **GB USB Smart Card 64M**(64Mbit=8MB)。複数ROM+起動メニュー対応か、対応MBC、SRAM有無/容量(バッテリーバックアップ可否)は未確認。M5(保存)までに確認する。
- GB のシリアル外部クロック最大速度に対し、ブリッジがバイト間隔をどれだけ空ける必要があるか(ISR処理時間を考慮)。
