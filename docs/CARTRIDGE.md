# GB USB Smart Card 64M(EMS 64M)の扱い

ChromaSynth を動かすカートリッジ。LSDJ v9.4.0 が入っている個体(ユーザー所有)。

## 1. 構造(ems-flasher のマニュアルより)
- フラッシュ 8MB = **2 ページ(各 4MB)**。1 ページに 32KB 単位で最大 128 本の ROM。
- **SRAM 128KB は全ページ・全 ROM で共有**。ROM ごとの区切りはない。別の ROM が SRAM に書くと、前の ROM のデータが壊れる。
- **ページごとに 1 つの動作モード**(DMG / カラー / SGB)を持ち、空のページに最初の ROM を書いたときに決まる。
- ページの切り替え(どのページから起動するか)の方法は**未確認**(カードの切り替えスイッチか、メニュー ROM か。実機で確認する)。

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
- 起動時は、ページ 2 のバンク 0 のメニュー ROM が最初に動き、そこから ChromaSynth を選ぶ形になるはず(**未確認**)。ページをどう切り替えて起動するかも未確認(§1)。

## 5. ChromaSynth をページ 2 に書く場合の注意
- ページ 2 は空なので、**LSDJ(ページ 1)には触れない**。書き込みは `ems-flasher --page 2 --write build/chromasynth.gb`(ROM 32KB)。書いた後に**ページ 1 を再度吸い出して、バックアップと一致することを確認する**。
- **SRAM は共有**。ChromaSynth の保存(SELECT+A)は SRAM の先頭 8KB に書くので、**LSDJ の曲データ(ブロック 0〜)を壊す**。試験中は保存を使わないか、使ったあとにバックアップの SRAM を戻す。逆に、LSDJ の SRAM の内容を ChromaSynth が読むと、保存版(`SAVE_VERSION`)やチェックサムが合わず「読み込み失敗」になる(これは想定された動作)。
- ページ 2 のモード(DMG / カラー)は、最初に書く ROM のヘッダで決まる。ChromaSynth は CGB 対応(`-c`、フラグ `0x80`)。
- LSDJ に戻りたいときは、カードをページ 1 で起動すればよい(切り替え方法は §1 の未確認事項)。
