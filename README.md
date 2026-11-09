# ChromaSynth

ModRetro **Chromatic**(ゲームボーイ / GBC 互換機)のカートリッジで動く、**シンセサイザー + ピアノロール・シーケンサー**の ROM です。
音を作り、打ち込み、Chromatic で再生する。さらに、**Chromatic の内蔵 ESP32 を使って、Mac の DAW(Ableton Live など)から、ケーブルなしで(Bluetooth MIDI)、または USB-C の有線で、演奏できます**。

> 状態: 個人の開発中のプロジェクトです。実機(Chromatic + EMS 64M スマートカード)で動作確認した範囲は、`docs/ROADMAP.md` の状態欄に書いています。
> 確認していないことを「確認済み」とは書かない方針です(`AGENTS.md` のルール 7)。
> **対応カートリッジ**: 普通の **MBC5 + 32 KB 電池 SRAM** の GB / GBC カートリッジ向けです([docs/CARTRIDGES.md](docs/CARTRIDGES.md))。作者は EMS スマートカードで使っていますが、ROM は特定のカードに依存しません。
> **ライセンスは、まだ決めていません**(`chromatic-mcu/` のパッチは、ModRetro の MCU ファームウェア(GPL-3.0)の派生物です)。

## できること(実機で確認したもの)
- **ROM**(`src/`、RGBDS アセンブリ): 4 チャンネルの音源(パルス 2、波形、ノイズ)、ピアノロール、パターンの保存(SRAM)、MIDI(リンクケーブルでの入出力。実機は未確認)。
- **ケーブルなしのリンク**(`docs/CHROMATIC_LINK.md`): Chromatic の内蔵 ESP32 から、ROM へ、仮想ボタンで音符を送る(ROM の「キーボード画面」)。ROM から ESP32 へは、パレット RAM に書いた値を、ESP32 が読む。
- **Bluetooth MIDI**(`docs/BLE_MIDI.md`): Mac の Audio MIDI Setup で `ChromaSynth` に接続して、Live から弾ける。
- **有線(USB-C)**: Mac の中継プログラム(`tools/chromasynth_usb_bridge.swift`)が、Live の MIDI を、USB-C のシリアルへ。
- **MIDI モード**(OFF / BLE / USB): Chromatic のメニュー(System タブ)から切り替え。OFF のとき、ESP32 は純正のライトスリープに戻る。
- 遅れは、ノートオンで約 150 ms(MCU の中)、耳に届くまで約 200 ms(見込み)。**違う音が鳴らないことを、遅さより優先している**(`docs/BLE_MIDI.md`)。

## つくる・試す
必要なもの: RGBDS v1.0.x(ROM)、Python 3(`tools/`)、PyBoy(ヘッドレス試験)、ESP-IDF v5.3(MCU ファームウェア)、`swiftc`(Mac の中継)。

```bash
make                       # ROM: build/chromasynth.gb(警告ゼロ、ヘッダ検査つき。32 KB ROM、SRAM 32 KB)
make card                  # 作者の EMS スマートカード用(SRAM 128 KB、保存はバンク 12〜15): build-card/chromasynth.gb
make gen                   # 生成ファイル(音階表、フォント、波形、テンポ表など)を作り直す
python3 tools/headless_test.py            # PyBoy で ROM の自動試験(要 pip install pyboy pillow)
python3 tools/headless_clink_test.py      # ケーブルなしリンクの試験
python3 tools/headless_mcu_proto_test.py  # MCU の C の符号化器で ROM を鳴らす結合試験
make check-mcu             # MCU のプロトコル中核(C)を Python の参照実装と突き合わせる
make check-usb-bridge      # Mac の有線中継(MIDI → コンソールの行)の試験
chromatic-mcu/build.sh     # 本体の ESP32 用ファームウェア(ModRetro の v4.6 を取得してパッチを当てる。書き込みはしない)
```

## 本体への書き込みについて(重要)
- **ESP32 のファームウェアの書き込みは、本体を使えなくするリスクがあります。**必ず、`docs/MCU_FLASH_SAFETY.md` の手順(全体のバックアップ、復元のリハーサル、アプリの枠だけに書く、読み戻しの確認)に従ってください。
- **スマートカード(EMS 64M)の SRAM は、全 ROM で共有**です。ChromaSynth の保存(SELECT+A)は、同じカードの他のゲーム(LSDj など)のセーブデータを壊します。`docs/CARTRIDGE.md` を読んでください。

## ディレクトリ
| 場所 | 内容 |
|---|---|
| `src/`, `inc/` | ROM のソース(RGBDS) |
| `tools/` | 生成スクリプト、PyBoy の試験、Mac の有線中継、実機の試験(`mcu_mode_test.py`、`mcu_soak_test.py`) |
| `chromatic-mcu/` | 本体の ESP32 用のパッチとソース(純正のソースは入れない) |
| `firmware/` | 外付け ESP32-S3 ブリッジ(リンクケーブル用。実機は未確認) |
| `docs/` | 操作マニュアル(`MANUAL.md`)、設計、ロードマップ、実機の確認記録 |
| `AGENTS.md`, `CLAUDE.md` | 開発のルール(AI エージェント向けを兼ねる) |
