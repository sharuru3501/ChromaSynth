# AGENTS.md — ChromaSynth

ModRetro Chromatic(GB/GBC互換機)のカートリッジで動くシンセサイザー + シーケンサーROM。
音作り → シーケンサーで打ち込み → フラッシュカートに焼いて Chromatic で再生、が最終ゴール。
MIDI入出力(まず有線、最後に BLE MIDI)も行う。詳細設計は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)、進行状況は [docs/ROADMAP.md](docs/ROADMAP.md)。

## 技術スタック
- 言語: **RGBDS アセンブリ**(rgbasm/rgblink/rgbfix v1.0.x)。ハード直叩きが必要なため C/GBDK は使わない。
- ターゲット: DMG/CGB 両対応(`rgbfix -c`)。Chromatic は GBC 相当として扱う。
- エミュレータ: SameBoy(`make run`)。実機確認は Chromatic + フラッシュカート。
- ツール類は Python 3(`tools/`)。生成物は **コミットする**(ビルド時に Python を要求しないため)。

## コマンド
```bash
make          # build/chromasynth.gb を生成
make run      # SameBoy で起動
make gen      # notetable/font/waves の include を再生成
python3 tools/headless_test.py        # PyBoy で自動テスト(要 pip install pyboy pillow、先に make)
python3 tools/headless_save_test.py   # SRAM保存のテスト
make clean
```

## ディレクトリ
- `src/` ROMソース: `main.asm`(ベクタ/初期化/ループ), `ram.asm`(WRAM変数), `voice.asm`(発音), `midi.asm`, `joy.asm`, `ui.asm`, `seq.asm`(シーケンサ), `sram.asm`(保存)。シンボルは `-E` で全export
- `inc/` 共有 include(`hardware.inc` は必要なレジスタだけ定義した自前版)
- `tools/` コード/データ生成スクリプト
- `docs/` 設計・ロードマップ
- `.claude/skills/gb-synth-dev/SKILL.md` GB音源/RGBDS/MIDIの作業メモ(エージェント向け)

## ルール
1. **小さく進める**: マイルストーン単位(ROADMAP参照)で、各ステップで `make` が通る状態でコミット。
2. **コミットはConventional風**(`feat:`/`fix:`/`docs:`/`chore:`)。ビルド成果物(`build/`, `*.gb`)は無視。
3. **`-Weverything` で警告ゼロ**を維持。
4. 生成ファイル(`src/notetable.inc`, `font.inc`, `waves.inc`)は手で編集しない。`tools/gen_*.py` を直して `make gen`。音域は `inc/synth.inc` が唯一の定義元。
5. 割り込みハンドラは最小限に(シリアルISRはリングバッファに積むだけ)。重い処理はメインループ。
6. APU レジスタの注意: NR12 等のエンベロープは**トリガ時にしか反映されない**、DAC は NRx2 の上位5bitが0で OFF、波形RAMは CH3 停止中にのみ安全に書ける。
7. 実機/エミュレータで確認できていない動作を「動作確認済み」と書かない。ROADMAP の状態欄に `untested` を付ける。
8. **CGB パレット**: ヘッダが GBC 対応(`-c`)なので GBC 機/SameBoy では `BGP` が無視され、パレット RAM は白で始まる。画面に何か出すなら `InitPalette`(main.asm)のような CGB パレット設定が必須。PyBoy は独自パレットで描くため、この不具合は PyBoy では再現しない → 画面はSameBoyでも確認する。
9. 保存データ(`wPatch`/`wPattern`/`wBpm`)のレイアウトや大きさを変えたら `SAVE_VERSION`(sram.asm)を上げる。エミュレータの `.sav`/`.ram` は `build/` 配下にできるので `make clean` で消える。
10. 不明なハード仕様(Chromaticのリンクポート仕様等)は推測で断定せず、docs の「未確認事項」に記録する。
