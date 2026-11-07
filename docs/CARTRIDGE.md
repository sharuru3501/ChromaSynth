# GB USB Smart Card 64M(EMS 64M)の扱い

ChromaSynth を動かすカートリッジ。LSDJ v9.4.0 が入っている個体(ユーザー所有)。

## 1. 構造(ems-flasher のマニュアルより)
- フラッシュ 8MB = **2 ページ(各 4MB)**。1 ページに 32KB 単位で最大 128 本の ROM。
- **SRAM 128KB は全ページ・全 ROM で共有**。ROM ごとの区切りはない。別の ROM が SRAM に書くと、前の ROM のデータが壊れる。
- **ページごとに 1 つの動作モード**(DMG / カラー / SGB)を持ち、空のページに最初の ROM を書いたときに決まる。
- **ページの切り替えは電源の入れ直しの速さで決まる**(スイッチはない。§1.1)。

### 1.1 ページ切り替え(2026-11-06、実機で確認)
- カードにスイッチはない。通常の起動は**ページ 1**(LSDJ)。
- **本体の電源を切って、すぐ(約 1 秒以内)入れ直す**と**ページ 2**(メニュー → ChromaSynth)で起動した(ユーザーが Chromatic で確認)。
- ページ 1 に戻すには、電源を切って**数十秒おいて**から入れる(コンデンサが放電するまで。回路の説明は [ChipMusic のスレッド](https://chipmusic.org/forums/post/73754) による。個体によってはページ 2 に居座ることがある)。
- ems-flasher のマニュアル・ソースには、この切り替えの記述はない。

## 2. 2026-11-06 時点の中身(`ems-flasher --title`)
| ページ | 中身 |
|--------|------|
| 1 | `LSDj-v9.4.0`(1024KB、カラー対応、メニュー ROM なし)。空き 3072KB |
| 2 | **空**(4096KB すべて空き) |

ROM ヘッダ: CGB フラグ `0x80`、MBC5+RAM+バッテリー(`0x1B`)、ROM 1MB(`0x05`)、RAM 128KB(`0x04`)。

## 3. バックアップ(2026-11-06、`~/Documents/ChromaticBackup/lsdj_card/`、git の管理外)
| ファイル | 内容 | 確認 |
|----------|------|------|
| `page1_20261106-183422_{A,B}.gb` | ページ 1 のフラッシュ全体(4MB) | **2 回読んで完全一致**(SHA-256 `91db8ad4ec7c7262…`) |
| `sram_20261106-183422_{A,B}.sav` | SRAM 全体(128KB。LSDJ の曲データ) | **2 回読んで完全一致**(SHA-256 `5d50a5498ca3454c…`) |
| `title_20261106-183422.txt` | ページ 1・2 の一覧 | — |

SRAM の 16 ブロック(8KB ずつ)のうち、0〜8 にデータ、9・10 はほぼ空、11〜15 は空(`00`)。

- 吸い出しには [ems-flasher](https://github.com/mikeryan/ems-flasher)(Mike Ryan 作。`b88640a`)をビルドして使った(GPL)。ビルドは `CFLAGS` から `-Werror` を外す必要があった(`config.sh` の古い試験プログラムが、新しい clang で警告になるため)。使ったのは `--title` と `--dump`(読み出し)だけ。
- ベースの ems-qart v0.9.4(DMG)は、署名がなく GUI のため使わなかった。

## 4. 戻し方(**書き込みなので、ユーザーの確認を取ってから**)
```bash
# ページ 1 のフラッシュ全体を戻す(約 100 秒)
ems-flasher --page 1 --rom --restore page1_20261106-183422_A.gb
# SRAM(曲データ)を戻す
ems-flasher --save --restore sram_20261106-183422_A.sav
```
ems-flasher は `~/Documents/ChromaticBackup` の外のビルドディレクトリにある(`ems-flasher-real`。ソースは再取得してビルドし直せる)。

## 4.5 ChromaSynth をページ 2 に書いた結果(2026-11-06)
- **1 回目は失敗し、何も書かれなかった**。ems-flasher が、空のページに自動で入れるメニュー ROM のファイル名を壊して(`can't stat p���`)止まった。**原因は ems-flasher のバグ**: `cmd.c` の `cmd_write` で、`if` ブロックの中のローカル配列 `menupath[1024]` のアドレスを `romfile->path` に保存し、ブロックを抜けた後も使っている(use-after-scope)。古いコンパイラではスタックの内容が残っていたが、新しい clang の最適化では別の用途に再利用されて文字化けした。**作業用コピーの `cmd.c` を 1 行直した**(`static char menupath[1024];`)。失敗した 1 回目の後でも、ページ 1 と SRAM はバックアップと完全に一致していた。
- **2 回目は成功**: `ems-flasher --page 2 --verbose --write build/chromasynth.gb`(`MENUDIR` はビルドディレクトリ)。
  - ページ 2: `MENU#`(bank 0、32KB、カラー)+ `CHROMASYNTH`(bank 2、32KB、カラー)。空き 4032KB。「Page enhancements: Color、Compatible consoles: All」。
  - **ページ 2 の吸い出しに、ビルドした ROM(SHA-256 `68aa752d…`)が完全に同じ内容で入っていた**(オフセット `0x8000`)。
  - **ページ 1 を再度吸い出して、バックアップと完全に一致**(LSDJ は無傷)。**SRAM も、バックアップと完全に一致**。
- 起動時は、ページ 2 のバンク 0 のメニュー ROM が最初に動き、そこから ChromaSynth を選ぶ形になるはず(**未確認**)。ページ 2 への切り替えは §1.1(確認済み)。

## 4.6 事故: 実機の試験で ChromaSynth が SRAM に保存し、LSDJ のデータを上書きした(2026-11-06、復旧済み)
- 原因: ケーブルなしリンクの HELLO 試験で、MCU から仮想ボタンのシンボルを送った。シンボルには START/SELECT/B/A が同時に入るものがあり、FPGA が上下・左右の同時押しを消すため、ROM には **SELECT+A(保存)** だけが届いた。SRAM は LSDJ と共有なので、先頭の約 1KB(`CSYN` 付きの ChromaSynth の保存)が LSDJ のデータを上書きした(79 バイトが違った)。
- 発見: カードを Chromatic から外して SRAM を読み出し、バックアップ(`sram_20261106-183422_A.sav`)と比べて分かった。上書きされた状態は `sram_after_chromasynth_save_20261106.sav` に残した。
- 復旧: `ems-flasher --save --restore sram_20261106-183422_A.sav` で書き戻し、読み出し直して**完全一致**(SHA-256 `5d50a549…`)を確認した。ページ 1・2 の ROM には触れていない。
- 教訓: **実機の試験で、SELECT+A / SELECT+B が出る可能性があるボタンの組み合わせを送らない。** 送った試験の後は SRAM を読み出してバックアップと比べる。

## 4.7 キーボード画面版の ROM に入れ替えた結果(2026-11-06)
- 手順(ユーザーの確認後): SRAM がバックアップと一致することを確認 → `ems-flasher --page 2 --delete 2`(古い CHROMASYNTH)→ `--write`(新しい ROM、SHA-256 `726392ad…`)。メニュー ROM(bank 0)はそのまま。
- 結果: ページ 2 は `MENU#`(bank 0)+ `CHROMASYNTH`(bank 2)。空き 4032KB。ページ 2 の吸い出しに新しい ROM が完全に同じ内容で入っている(オフセット `0x8000`)。**ページ 1 を再度吸い出して、LSDJ のバックアップと完全に一致。SRAM もバックアップと完全に一致。**

## 4.8 ビーコン入りの ROM に入れ替えた結果(2026-11-06)
- 手順(ユーザーの確認後): SRAM がバックアップと一致 → `--page 2 --delete 2` → `--write`(SHA-256 `047709e9…`、キーボード画面のビーコンと、MCU の BLE MIDI 版に備えたもの)。
- 結果: ページ 2 は `MENU#` + `CHROMASYNTH`、空き 4032KB。ページ 2 の吸い出しに新しい ROM が完全に同じ内容で入っている。**ページ 1(LSDJ)と SRAM は、バックアップと完全に一致。**

## 4.9 検査付きノートオフ・ping・nack 拡張の ROM に入れ替えた結果(2026-11-07)
- 手順(ユーザーの確認後): SRAM がバックアップと一致 → `--page 2 --delete 2` → `--write`(SHA-256 `fa6272bc…`)。
- 結果: ページ 2 は `MENU#` + `CHROMASYNTH`、空き 4032KB。ページ 2 の吸い出しに新しい ROM が完全に同じ内容で入っている。**ページ 1(LSDJ)と SRAM は、バックアップと完全に一致。**

## 4.10 M10(START+←/→ で画面移動)の ROM に入れ替えた結果(2026-11-07)
- 手順(ユーザーの確認後): SRAM がバックアップと一致 → `--page 2 --delete 2` → `--write`(PR #1 のブランチ `d672f9a` のビルド、SHA-256 `b152f454…`)。
- 結果: ページ 2 は `MENU#` + `CHROMASYNTH`、空き 4032KB。ページ 2 の吸い出しに新しい ROM が完全に同じ内容で入っている(バンク 2)。**ページ 1(LSDJ)と SRAM は、バックアップと完全に一致。**

## 4.11 M9a(APU の音色パラメータ)の ROM に入れ替えた結果(2026-11-07)
- 手順(ユーザーの確認後): SRAM がバックアップと一致 → `--page 2 --delete 2` → `--write`(PR #2 のブランチ `c014d91` のビルド、SHA-256 `75496b0a…`)。今回から ems-flasher は `~/Documents/ChromaticBackup/tools/ems-flasher/` の保管版を使った。
- 結果: ページ 2 は `MENU#` + `CHROMASYNTH`、空き 4032KB。ページ 2 の吸い出しに新しい ROM が完全に同じ内容で入っている(バンク 2)。**ページ 1(LSDJ)と SRAM は、バックアップと完全に一致。**

## 5. ChromaSynth をページ 2 に書く場合の注意
- ページ 2 は空なので、**LSDJ(ページ 1)には触れない**。書き込みは `ems-flasher --page 2 --write build/chromasynth.gb`(ROM 32KB)。書いた後に**ページ 1 を再度吸い出して、バックアップと一致することを確認する**。
- **SRAM は共有**。ChromaSynth の保存(SELECT+A)は SRAM の先頭 8KB に書くので、**LSDJ の曲データ(ブロック 0〜)を壊す**。試験中は保存を使わないか、使ったあとにバックアップの SRAM を戻す。逆に、LSDJ の SRAM の内容を ChromaSynth が読むと、保存版(`SAVE_VERSION`)やチェックサムが合わず「読み込み失敗」になる(これは想定された動作)。
- ページ 2 のモード(DMG / カラー)は、最初に書く ROM のヘッダで決まる。ChromaSynth は CGB 対応(`-c`、フラグ `0x80`)。
- LSDJ に戻りたいときは、カードをページ 1 で起動すればよい(切り替え方法は §1.1)。
