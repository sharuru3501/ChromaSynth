# AGENTS.md — ChromaSynth

ModRetro Chromatic(GB/GBC互換機)のカートリッジで動くシンセサイザー + シーケンサーROM。音作り → 打ち込み → カードに焼いて Chromatic で再生、が最終ゴール。MIDI は本体内蔵 ESP32 経由(BLE / Mac の USB 中継)で実機で動いている。設計は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)、進行状況は [docs/ROADMAP.md](docs/ROADMAP.md)。

## 技術スタック
- ROM: **RGBDS アセンブリ**(v1.0.x)。DMG/CGB 両対応(`rgbfix -c`)。Chromatic は GBC 相当。エミュレータは SameBoy(`make run`)。
- ツールは Python 3(`tools/`)。生成物は**コミットする**。
- 本体内蔵 ESP32: `chromatic-mcu/`(ModRetro v4.6 + パッチ、ESP-IDF 5.3)。外付けブリッジ(未製作): `firmware/`(ESP32-S3、ESP-IDF 5.5.6)。

## コマンド
```bash
make / make run / make gen / make clean    # ROM のビルド・SameBoy 起動・生成 include の再生成
python3 tools/headless_test.py            # PyBoy の自動テスト(先に make)。ほかに headless_{save,midi,clink,mcu_proto}_test.py
make check-mcu                            # MCU のプロトコル中核の C を Python 参照実装と照合(ESP32 不要)
make check-usb-bridge / make check-bridge # Mac の USB 中継の自己試験 / 外付けブリッジの C 中核テスト
chromatic-mcu/build.sh                    # 本体 ESP32 のファームウェアをビルド(書き込みはしない)
python3 tools/mcu_{mode,soak,longrun}_test.py   # 実機(コンソール経由)の試験。数字で判定
```

## ディレクトリ
- `src/` ROM: `main.asm`(ベクタ/初期化/ループ)、`ram.asm`、`voice.asm`(発音)、`midi.asm`(仕様 `docs/MIDI.md`)、`joy.asm`、`ui.asm`、`seq.asm`(再生エンジン+ロール編集)、`roll.asm`(ロール描画、設計 `docs/ROLL_DESIGN.md`)、`sram.asm`、`clink.asm`(ケーブルなしリンク)。シンボルは `-E` で全 export
- `inc/` 共有 include(`hardware.inc` は自前の最小版、音域は `inc/synth.inc` が唯一の定義元)
- `tools/` 生成スクリプト・テスト・Mac の MIDI 中継 / `docs/` 設計と記録
- 作業メモ(スキル): ROM・APU・RGBDS は `.claude/skills/gb-synth-dev/SKILL.md`、実機・ESP32・リンク・カードは `.claude/skills/chromatic-hw/SKILL.md`

## ルール
1. **小さく進める**: マイルストーン単位で、各ステップで `make` が通る状態でコミット。コミットは Conventional 風(`feat:`/`fix:`/`docs:`/`chore:`)。
   - **PR にする**(ブランチ `feat/…`・`fix/…` → PR → ユーザーがマージ): ROM(`src/`・`inc/`)、本体 ESP32 のファームウェア(`chromatic-mcu/`)、外付けブリッジ(`firmware/`)、Mac の中継(`tools/*.swift`)の**挙動を変える**もの、リンクやセーブデータの形式を変えるもの、マイルストーン(ROADMAP の M 番号)の実装。PR の説明には、決めたことと理由、試験の結果、未確認の項目(実機・聴感)を書く。
   - **main に直接 push**: docs だけ、コメントだけ、テストや試験スクリプトだけ、エージェント設定(`AGENTS.md`・`CLAUDE.md`・`.claude/`)、生成物の再生成で挙動が変わらないもの。
   - 迷ったら PR。push・PR の作成はユーザーの指示があるときだけ。
2. **`-Weverything` で警告ゼロ**、`rgbfix -v` 成功を維持。
3. 生成ファイル(`src/{notetable,font,waves,tempo,divs,pattern,bend}.inc`)は手で編集しない。`tools/gen_*.py` を直して `make gen`。
4. 割り込みハンドラは最小限(シリアル ISR はリングバッファに積むだけ)。重い処理はメインループ。
5. APU: エンベロープは**トリガ時にしか反映されない**、NRx2 の上位 5bit が 0 で DAC OFF、波形 RAM は CH3 停止中にだけ書く。
6. 確認できていない動作を「動作確認済み」と書かない。ROADMAP の状態欄に `untested`。不明なハード仕様は推測で断定せず「未確認事項」に記録する。
7. **CGB パレット**: GBC 機/SameBoy では `BGP` が無視されパレット RAM は白で始まる。画面に出すなら `InitPalette` 相当が必須。PyBoy では再現しないので画面は SameBoy でも確認する。
8. 保存データ(`wPatch`/`wPattern`/`wBpm`)のレイアウトや大きさを変えたら `SAVE_VERSION`(sram.asm)を上げる。
9. **VBlank は約 1140 サイクル**。VRAM/OAM はその間だけ。重い描画は VBlank 外でシャドウバッファに作る。`headless_test.py` の「UpdateUI finishes inside VBlank」が超過を検出する。
10. SameBoy のキー割り当てに修飾キー(⌘/⇧/⌃/⌥)を使わない(key-up が失われ ROM のバグに見える)。入力の不具合報告は、まずエミュレータのキー設定を疑う。
11. 時間の単位は**ティック(1拍=12)**。1 フレームに 2 ティック以上処理しない。グリッド分割は表示/入力の単位で、データはいつもティック。ページは拍から始まる整数拍(幅は `tools/gen_divs.py`)。
12. 編集操作は変わった行だけ再描画(`RollRefresh`)。全行(`RollRefreshAll`)はページ/表示窓/チャンネル/ロード時のみ。押してから反映まで 4 フレーム以内。
13. プロトコル(ケーブル方式・ケーブルなしリンク・外付けブリッジ)を変えるときは、参照実装・ROM・C・テストを同時に直す。詳細は `chromatic-hw` スキル。**ノートオンの 4 シンボル・4 ビットの検査は縮めない**(違う音が鳴らないことが最優先)。ROM を先に、MCU を後に書く。
14. **本体 ESP32 とスマートカードへの書き込みは、毎回ユーザーの確認を取る**(手順は `docs/MCU_FLASH_SAFETY.md`、`docs/CARTRIDGE.md`)。カードの**ページ 1(LSDj)とバックアップは壊さない**、書くのはページ 2 だけ。
15. **MCU から SELECT+A / SELECT+B が出るボタンの組み合わせを送らない**(共有 SRAM の LSDj の曲データを壊す)。
16. 大きな docs(`BLE_MIDI.md`、`MCU_FLASH_SAFETY.md`、`CHROMATIC_LINK.md`)は冒頭の「現状」と目次を読んでから、必要な節だけ読む。日付つきの記録は `docs/log/` に分けてある(必要なときだけ読む)。
