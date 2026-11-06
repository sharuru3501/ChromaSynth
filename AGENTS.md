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
make gen      # notetable/font/waves/tempo/divs/pattern/bend の include を再生成
python3 tools/headless_test.py        # PyBoy で自動テスト(要 pip install pyboy pillow、先に make)
python3 tools/headless_save_test.py   # SRAM保存のテスト
python3 tools/headless_midi_test.py   # MIDI入力・DAW同期・シリアルISR・ブリッジ参照実装との往復のテスト
python3 tools/headless_clink_test.py  # 本体内蔵 ESP32 とのケーブルなしリンク(キーボード画面+パレット)のテスト
python3 tools/headless_mcu_proto_test.py  # MCU 側の C の符号化器(chromatic-mcu/)で ROM を鳴らす結合テスト(要 cc)
make check-mcu                        # MCU 側プロトコル中核の C を Python 参照実装と突き合わせる(ESP32 不要)
make check-usb-bridge                 # Mac の有線 MIDI 中継(tools/chromasynth_usb_bridge.swift)の変換の自己試験(要 swiftc)
python3 tools/test_bridge_ref.py      # ブリッジ参照実装の単体テスト(標準ライブラリのみ)
make firmware                         # ESP32-S3 ファームウェアのビルド(要 ESP-IDF)
make check-bridge                     # 上記 + firmware の C 中核テスト(正解トレース照合・ASan・構文検査)。ESP32 不要
make clean
```

## ディレクトリ
- `src/` ROMソース: `main.asm`(ベクタ/初期化/ループ), `ram.asm`(WRAM変数), `voice.asm`(発音), `midi.asm`(MIDI解析とルーティング。仕様は `docs/MIDI.md`), `joy.asm`, `ui.asm`, `seq.asm`(ティック再生エンジン+ピアノロール編集操作), `roll.asm`(ピアノロール描画), `sram.asm`(保存)。ピアノロールの設計は `docs/ROLL_DESIGN.md`シンボルは `-E` で全export
- `inc/` 共有 include(`hardware.inc` は必要なレジスタだけ定義した自前版)
- `tools/` コード/データ生成スクリプト
- `firmware/` ブリッジ(ESP32-S3)のファームウェア。`core/` は純粋な C(ホストでテスト可)、`main/` は ESP-IDF との接続部(ESP-IDF v5.5.6 でビルド確認済み、実機は未確認)。設計は `docs/FIRMWARE.md`
- `docs/` 設計・ロードマップ
- `.claude/skills/gb-synth-dev/SKILL.md` GB音源/RGBDS/MIDIの作業メモ(エージェント向け)

## ルール
1. **小さく進める**: マイルストーン単位(ROADMAP参照)で、各ステップで `make` が通る状態でコミット。
2. **コミットはConventional風**(`feat:`/`fix:`/`docs:`/`chore:`)。ビルド成果物(`build/`, `*.gb`)は無視。
3. **`-Weverything` で警告ゼロ**を維持。
4. 生成ファイル(`src/notetable.inc`, `font.inc`, `waves.inc`, `tempo.inc`, `divs.inc`, `pattern.inc`, `bend.inc`)は手で編集しない。`tools/gen_*.py` を直して `make gen`。音域は `inc/synth.inc` が唯一の定義元。
5. 割り込みハンドラは最小限に(シリアルISRはリングバッファに積むだけ)。重い処理はメインループ。
6. APU レジスタの注意: NR12 等のエンベロープは**トリガ時にしか反映されない**、DAC は NRx2 の上位5bitが0で OFF、波形RAMは CH3 停止中にのみ安全に書ける。
7. 実機/エミュレータで確認できていない動作を「動作確認済み」と書かない。ROADMAP の状態欄に `untested` を付ける。
8. **CGB パレット**: ヘッダが GBC 対応(`-c`)なので GBC 機/SameBoy では `BGP` が無視され、パレット RAM は白で始まる。画面に何か出すなら `InitPalette`(main.asm)のような CGB パレット設定が必須。PyBoy は独自パレットで描くため、この不具合は PyBoy では再現しない → 画面はSameBoyでも確認する。
9. 保存データ(`wPatch`/`wPattern`/`wBpm`)のレイアウトや大きさを変えたら `SAVE_VERSION`(sram.asm)を上げる。エミュレータの `.sav`/`.ram` は `build/` 配下にできるので `make clean` で消える。
10. **VBlankは約1140サイクル**。VRAM/OAMへの書き込みはその間だけ。重い描画はシャドウバッファにVBlank外で作り、VBlankでは少量コピーするだけにする。`tools/headless_test.py` の「UpdateUI finishes inside VBlank」テストが超過を検出する(PyBoyはVRAMアクセス制限を再現しないので、LYをフックして測る)。
11. **SameBoyのキー割り当てに修飾キー(⌘/⇧/⌃/⌥)を使わない。** `Right ⌘` を START にすると、押している間の他キーが「⌘+キー」扱いになり、キーを離した信号が失われて SELECT が押しっぱなしになる等、ROMのバグに見える誤動作が起きた(実例)。START は Return など通常キーに。入力まわりの不具合報告を受けたら、まずエミュレータのキー設定を確認する(iPhone版SameBoyのタッチ操作では同じROMが問題なく動き、原因がキー設定だったと確定済み)。
12. 時間の単位は**ティック(1拍=12)**。ステップ単位のコードを書かない。1フレームに2ティック以上処理しない前提(`gen_tempo.py` が検証する)。グリッド分割は表示/入力の単位であって、データはいつもティック。ページは必ず拍から始まり整数拍を表示する(分割を変えても小節が動かないこと)。ページ幅は `tools/gen_divs.py` の表で決める。
13. 編集操作は「変わった行だけ」再描画する(`RollRefresh`)。全行は `RollRefreshAll`(ページ/表示窓/チャンネル/ロード時のみ)。押してから画面反映まで4フレーム以内をテストで守る。
14. **リンクプロトコルを変えたら** `docs/BRIDGE.md`・`tools/bridge_ref.py`・ROM(`SerialISR`/`midi.asm`)を同時に直し、`headless_midi_test.py` の往復テストで確かめる。`$FD` はアイドル、`$FF` は「GBが待ち受けていない」の印なのでデータに使わない。
15. **ブリッジの動作を変えたら** `tools/bridge_ref.py` と `firmware/core/bridge_core.c` を同じ算術(整数µs、切り捨て除算)で両方直し、`make -C firmware/test vectors` で正解を作り直して `make check-bridge` で突き合わせる。`main/` を変えたら `make firmware` でビルドして確かめる(ESP-IDF は `~/esp/esp-idf`、v5.5.6。無い環境ではスタブでの型検査 `make -C firmware/test syntax` だけになり、API の実在は証明できない)。ESP32 の実機で動かしていないことは、動かすまで「未確認」と書く。
19. **スマートカード(EMS 64M)は `docs/CARTRIDGE.md`**。LSDJ が入っている(ページ 1)ので、**ページ 1 とバックアップ(`~/Documents/ChromaticBackup/lsdj_card/`)は壊さない**。書くのはページ 2 だけ。SRAM は全 ROM で共有なので、ChromaSynth の保存(SELECT+A)は LSDJ の曲データを壊す。カードへの書き込みは必ずユーザーの確認を取り、書いた後にページ 1 を再度吸い出して一致を確認する。
18. **本体内蔵 ESP32 に書くファームウェア**は `chromatic-mcu/`(ModRetro の v4.6 + パッチ。GPL-3.0)。`chromatic-mcu/build.sh` でビルドするだけで、**本体への書き込みは必ずユーザーの確認を取り**、`docs/MCU_FLASH_SAFETY.md` の手順(バックアップ → 復元のリハーサル → 読み戻しで一致確認)に従う。ゲームを動かしたまま・カートリッジの SRAM に触れる状態で書かない。接続できないときは、完全な電源の入れ直し(USB を抜いて 10 秒、カートを挿し、USB を繋いでから電源 ON)を試す。
17. **ケーブルなしリンクを変えたら** `docs/CHROMATIC_LINK.md`・`tools/chromatic_link_ref.py`・ROM(`src/clink.asm`、`ReadJoy`、`SerialISR`)を同時に直し、`headless_clink_test.py` で確かめる。上り(パレット RAM への書き込み)は VBlank の先頭だけ。下りのシンボルは**キーボード画面(`SCREEN_KBD`)でだけ**読み、その間 `ReadJoy` は物理ボタンを UI に通さない(SELECT だけ通す。SELECT+START の長押しで抜ける)。**FPGA は上下・左右の同時押しを消す**ので、シンボルに反対のペアを使わない。MCU は SELECT と右を押さない。仮想ボタンが ROM に届くこと・`gpd` が返ることは確認済み(`docs/CHROMATIC_LINK.md` §6.6)。ノートオンの 4 シンボル・4 ビットの検査は変えない(違う音が鳴らないことが最優先。遅延を理由に縮めない)。ROM は古い MCU の 4 シンボルのノートオフも受け付けるので、**ROM を先に、MCU を後に**書く。キーボード画面にいる間・出るときの上りのビーコン(`$F4`/`$F5`、`docs/CHROMATIC_LINK.md` §2)は、MCU の安全装置(キーボード画面以外では送らない)なので、変えるときは MCU の判定(`chl_classify`)と PyBoy のテストを同時に直す。
20. **カードの上で ChromaSynth を動かす実機試験では、SELECT+A(保存)/SELECT+B(読み込み)が出る組み合わせのボタンを MCU から送らない。** 仮想ボタンの上下・左右の同時押しは FPGA が消すので、残りのボタンだけが ROM に届く。試験の後は SRAM を読み出してバックアップと比べる(実例は `docs/CARTRIDGE.md` §4.6)。
16. 不明なハード仕様(Chromaticのリンクポートのピン配置・電圧等)は推測で断定せず、docs の「未確認事項」に記録する。ブリッジを配線する前に実測する(BRIDGE.md §4)。
