---
name: gb-synth-dev
description: Game Boy (DMG/CGB) APU・RGBDSアセンブリ・リンクポートMIDI・シーケンサ設計の作業メモ。ChromaSynth ROM の音源/MIDI/UI/パッチ保存を実装・デバッグするときに使う。
---

# gb-synth-dev

## APU 早見表
| ch | 種類 | 周波数式 | 備考 |
|----|------|----------|------|
| 1 | Pulse + sweep | 131072/(2048-x) Hz | NR10-14 |
| 2 | Pulse | 同上 | NR21-24 |
| 3 | Wave (32x4bit) | 65536/(2048-x) Hz | NR30-34, 波形RAM $FF30-3F |
| 4 | Noise | NR43 で分周/LFSR幅 | NR41-44 |

- 11bit period `x` は NRx3(下位8) + NRx4 下位3bit。NRx4 bit7 = トリガ。
- NRx2: 上位4bit=初期音量, bit3=エンベロープ方向, 下位3bit=速度。**上位5bitが0でDAC OFF**。
- 音量/エンベロープを変えたいときはトリガし直す(ここでクリックが出やすい)。
- CH3 の波形RAMは CH3 を一旦止め(NR30 bit7=0)てから書く。
- ビブラート/ピッチベンドは NRx3/NRx4 の period 値を毎フレーム更新(トリガしない)。
- 音階テーブルは `tools/gen_notetable.py`。MIDI 36..107 を対象(最低音は約64Hz)。

## RGBDS 注意
- v1.0 構文: `DEF X EQU ...`、`ldh a, [rXXX]`、`ld a, [hl+]`。
- `-Weverything` を通す。`ds` パディングやセクション配置は `-m`(map) で確認。
- ヘッダは `rgbfix -v -p 0xFF -c -t TITLE -m ROM`。MBC/SRAM が必要になったら `-m MBC5+RAM+BATTERY -r <size>` に変更。
- 割り込みベクタ: VBlank $40, STAT $48, Timer $50, Serial $58, Joypad $60。
- 16ビット比較/ループは `ld a,b / or c` パターン。

## MIDI(有線)設計メモ
- GB側はリンクポートを**外部クロック(スレーブ)**にして受信: `SC=$80`。1バイト完了で Serial 割り込み。
- クロックは外部マイコン(RP2040/ESP32/Arduino等)が供給する(Arduinoboy 方式)。USB-MIDI/DIN ⇄ マイコン ⇄ リンクケーブル。
- ISR は SB をリングバッファへ積み SC を再アーム。パースはメインループ(`DrainMidi`/`MidiByte`)。
- ランニングステータス対応済み。リアルタイム(F8 clock, FA start, FC stop)は現状無視 → DAW同期で実装。
- MIDI OUT(DAW同期): マイコンがクロックを刻むたびに GB が SB に載せた送信バイトが返る。送信キューを SB にロードしておく。
- BLE MIDI: GBカート側からは無線を扱えないため、**ESP32 等のブリッジ**が BLE MIDI ⇄ リンクポートを変換する。最後に実装。

## パッチ/UI メモ
- パッチ値は NR12 などにほぼ直接対応(env は bit3=方向, 下位3bit=ペース)。CH3 の level は 0/1/2 → NR32 $20/$40/$60。
- 非トリガで NRx4 を書くとき bit7 を立てない(再トリガすると音が頭から鳴り直す)。
- `jr` が届かないとアセンブルエラーになる。遠い分岐は `jp`。
- 新しい文字を画面に出すときは `tools/gen_font.py` にグリフを足して `make gen`。

## シーケンサ/入力メモ
- 1ステップ=16分音符。frames = 15*59.7275/BPM。8.8固定小数で積算(`SeqTick`)。
- SELECT は「単押し=ch切替」「押しながら=修飾キー」の二役。`wSelUsed` で修飾に使われたかを覚え、離した時に判定する。
- 画面ごとの入力ハンドラ(`EditInput`/`SeqInput`)は d=今フレームの新規押下ビット、`wJoy`=押下中、`wJoyPrev`=前フレーム を使う。

## 検証
- `tools/headless_test.py`(PyBoy): パッド操作、`wRing` へのMIDI直接注入、RAM状態assert、スクリーンショット保存。PyBoy は最初に本物のブートROMを走らせるので PC>=0x100 まで待つ。
- VRAM は VBlank 中のみ書ける。UI は VBlank 直後に1フレーム1行まで更新する設計(`UpdateUI`)。
- CH3 は同じ period で パルスより1オクターブ低い。ノートを+12 してから period テーブルを引く。
- `make` 警告ゼロ + `rgbfix -v` 成功は最低条件。
- 音は SameBoy で聴感確認。MIDI は実機ブリッジが無いうちはエミュレータのリンク入力が無いので、`wRing` にバイトを直接積むテストモードを用意して確認する(予定)。
