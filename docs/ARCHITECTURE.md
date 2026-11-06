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
| `ui.asm` | 画面描画(BG タイルのテキスト)、画面遷移(Play / Patch / Sequencer。Song は将来) |
| `sram.asm` | パッチ・パターンの保存(MBC5+SRAM) |

## データ構造
- Patch(実装済み, `wPatch`): 1chあたり8バイト×4ch。レイアウトは `inc/synth.inc` と `src/ui.asm` のパラメータ表(`PT_*`)が定義元。
  - CH1: duty vol env swt swd sws vibd vibs / CH2: duty vol env - - - vibd vibs / CH3: wave level - - - - vibd vibs / CH4: width vol env - - - - -
  - `wPatch` は32バイト境界に置き、オフセット加算が桁上げしない前提でコードを書いている。
- ビブラート: 毎フレーム(VoiceTick)、発音中の CH1-3 の period を三角波で ±off。off は (2048-period) に比例させて音程に依存せず一定のセント幅になるよう近似。
- 画面: Play/Edit の2画面。画面切替は VBlank 直後に LCD を一瞬オフにして BG マップを作り直す。
- Pattern(実装済み, `wPattern`): 16ステップ × 4ch の1バイトセル。0=空, $FF=ノートオフ, それ以外=MIDIノート。`wPattern[ch*16+step]`(64バイト境界)。
- シーケンサのタイミング: 毎フレーム 8.8固定小数のアキュムレータに +1.0。BPMごとの「16分音符=何フレーム」を `TempoTable`(`tools/gen_tempo.py` 生成)から引き、超えたら1ステップ進める。GBのフレーム周波数は59.7275Hz。最短でも3.7フレームなので1フレームに複数ステップは来ない。
- 将来 MIDI clock 同期(M6)をする時は、このアキュムレータの代わりに 24ppqn のクロック数でステップを進める。
- Song: パターン番号の並び

## 操作系(案)
D-pad/A/B/Start/Select のみ。Patch画面: 項目選択+値増減。Sequencer画面: LSDj/ tracker 風グリッド。

## 未確認事項(ハード仕様は要確認)
- Chromatic のリンクポート仕様(コネクタ形状、電圧、クロック供給方式・速度)。
- Chromatic が選ぶ動作モード(DMG/CGB)。現在は `-c`(両対応)で作っている。
- 使用フラッシュカート: **GB USB Smart Card 64M**(64Mbit=8MB)。EMS系。ユーザーは LSDj を書き込み済み。古い情報(2010-2013)では、複数ROM可・内蔵メニューはLSDj併用で不具合・コミュニティ製メニュー+複数ROM対応flasherあり・SRAMスロット数に上限(セーブは実質1つとの報告)。最新状況・対応MBCは未確認。M5(保存)までに実機で確認する。書き込み前に LSDj のセーブをバックアップすること。
- GB のシリアル外部クロック最大速度に対し、ブリッジがバイト間隔をどれだけ空ける必要があるか(ISR処理時間を考慮)。
