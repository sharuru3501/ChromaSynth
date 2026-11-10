---
name: chromatic-hw
description: Chromatic 実機まわり(本体内蔵 ESP32 のファームウェア chromatic-mcu/、ケーブルなしリンク src/clink.asm、BLE/USB MIDI、外付けブリッジ firmware/、EMS スマートカードへの書き込み)を変更・ビルド・書き込み・試験するときの規則と手順。
---

# chromatic-hw

AGENTS.md のルール 13〜15 の詳細。安全に関わる要点(書き込みは必ずユーザーの確認、カードのページ 1 を壊さない、SELECT+A を送らない)は AGENTS.md にもある。

## どの文書を読むか(大きいので必要な節だけ)
| やること | 読む |
|---|---|
| 現在の実機の状態・版 | `docs/ROADMAP.md`(M6b/M8 の行)、`docs/BLE_MIDI.md` の冒頭の「現状」 |
| ケーブルなしリンクのプロトコル | `docs/CHROMATIC_LINK.md` §1〜§4.5(実機の記録は `docs/log/CHROMATIC_LINK_LOG.md`) |
| BLE/USB MIDI、MIDI モード | `docs/BLE_MIDI.md` §2・§3・§9.1〜9.2(実装と実機の記録は `docs/log/BLE_MIDI_LOG.md`) |
| MCU への書き込み | `docs/MCU_FLASH_SAFETY.md` §0・§2・§6。各版の記録は `docs/log/MCU_FLASH_SAFETY_LOG.md`(最新は末尾) |
| カード | `docs/CARTRIDGE.md` |
| 外付けブリッジ(ケーブル方式) | `docs/BRIDGE.md`、`docs/FIRMWARE.md` |

## 規則
1. **リンクプロトコル(ケーブル方式)を変えたら** `docs/BRIDGE.md`・`tools/bridge_ref.py`・ROM(`SerialISR`/`midi.asm`)を同時に直し、`headless_midi_test.py` の往復テストで確かめる。`$FD` はアイドル、`$FF` は「GB が待ち受けていない」の印なのでデータに使わない。
2. **外付けブリッジの動作を変えたら** `tools/bridge_ref.py` と `firmware/core/bridge_core.c` を同じ算術(整数 µs、切り捨て除算)で両方直し、`make -C firmware/test vectors` で正解を作り直して `make check-bridge`。`main/` を変えたら `make firmware`(ESP-IDF v5.5.6、`~/esp/esp-idf`。無い環境では `make -C firmware/test syntax` の型検査だけで、API の実在は証明できない)。
3. **ケーブルなしリンクを変えたら** `docs/CHROMATIC_LINK.md`・`tools/chromatic_link_ref.py`・ROM(`src/clink.asm`、`ReadJoy`、`SerialISR`)を同時に直し、`headless_clink_test.py` で確かめる。
   - 上り(パレット RAM への書き込み)は VBlank の先頭だけ。
   - 下りのシンボルは**キーボード画面(`SCREEN_KBD`)でだけ**読み、その間 `ReadJoy` は物理ボタンを UI に通さない(SELECT だけ通す)。上も下も押されていないフレームだけを人の操作とみなし、そこで START+← = 抜ける(シーケンサーへ)、SELECT+START = 再生・停止。**MCU は ← を必ず ↑か↓と一緒に押す**ので、これを変えるときはこの判定も直す。
   - **FPGA は上下・左右の同時押しを消す**ので、シンボルに反対のペアを使わない。MCU は SELECT と右を押さない。
   - **ノートオンの 4 シンボル・4 ビットの検査は変えない**(違う音が鳴らないことが最優先。遅延を理由に縮めない)。
   - ROM は古い MCU の 4 シンボルのノートオフも受け付けるので、**ROM を先に、MCU を後に**書く。
   - 上りのビーコン(`$F4`/`$F5`)は MCU の安全装置(キーボード画面以外では送らない)。変えるときは MCU の `chl_classify` と PyBoy のテストを同時に直す。
4. **本体内蔵 ESP32 のファームウェア**は `chromatic-mcu/`(ModRetro v4.6 + `patches/`、GPL-3.0、ESP-IDF **5.3**: `~/esp/esp-idf-v5.3`)。`chromatic-mcu/build.sh` でビルド。
   - **本体への書き込みは毎回ユーザーの確認を取る**(承認は次の書き込みに持ち越さない)。書く前に、バックアップが無事・現在のイメージが前回のビルドと一致・ガードを見せる。手順は `docs/MCU_FLASH_SAFETY.md`。アプリの枠だけを書く。
   - ユーザーが留守中の書き込みを明示的に許したときだけ `chromatic-mcu/flash_verify.sh`(書く → 試験 → 失敗なら確認済みのイメージを自動で書き戻す)。
   - ゲームを動かしたまま・カートリッジの SRAM に触れる状態で書かない。接続できないときは完全な電源の入れ直し(USB を抜いて 10 秒、カートを挿し、USB を繋いでから電源 ON)。
   - USB シリアルのポートを開くと ESP32 がリセットされ、BLE の接続が切れる。OFF モードでは起動から約 20 秒でライトスリープに入り、コンソールが応答しなくなる。
   - 確認済みのイメージは `~/Documents/ChromaticBackup/mcu_fw/`、カード用の ems-flasher(バグ修正済み)は `~/Documents/ChromaticBackup/tools/ems-flasher/`。新しく確認済みになったイメージは、一時フォルダでなくここに置く。
   - 実機の試験(耳なし、数字で判定): `tools/mcu_mode_test.py`、`mcu_soak_test.py`、`mcu_longrun_test.py`(`mcu_mode_test.py` だけ `--mock` で実機なしの自己確認ができる)。
5. **スマートカード(EMS 64M)**: ページ 1 は LSDj、**ページ 1 とバックアップ(`~/Documents/ChromaticBackup/lsdj_card/`)は壊さない**。書くのはページ 2 だけ。SRAM は全 ROM で共有なので ChromaSynth の保存(SELECT+A)は LSDj の曲データを壊す。書き込みは必ずユーザーの確認を取り、書いた後にページ 1 を再度吸い出して一致を確認する。
6. **カードの上で動かす実機試験では、SELECT+A / SELECT+B が出る組み合わせのボタンを MCU から送らない**(FPGA が反対のペアを消すので、残りのボタンだけが ROM に届く点も考える)。試験の後は SRAM を読み出してバックアップと比べる(`docs/CARTRIDGE.md` §4.6)。
7. ESP32 の実機で動かしていないことは「未確認」と書く。不明なハード仕様は推測で断定せず、docs の「未確認事項」に記録する。

## コマンド(AGENTS.md にないもの)
```bash
python3 tools/mcu_mode_test.py --cycles 6 --no-sleep-test   # モード切り替え、BLE の起動・停止で漏れなし、`m` の規則
python3 tools/mcu_soak_test.py --seconds 90                 # 有線で人間らしいメロディと連打。再送・中断・メモリの減り
python3 tools/mcu_longrun_test.py --minutes 5               # 洪水・放置の試験
chromatic-mcu/flash_verify.sh <新> <sha> <確認済み> <sha>   # 書く → 試験 → 失敗なら自動で書き戻す(許可されたときだけ)
CHLINK_BLE_TRIM=1 chromatic-mcu/build.sh                     # BLE の SM を外す候補(-95 KB)。Mac での接続確認前は書かない
python3 tools/test_bridge_ref.py                            # 外付けブリッジ参照実装の単体テスト
make firmware                                               # 外付けブリッジ(ESP32-S3)のビルド
tools/start_usb_bridge.sh                                   # Mac の有線 MIDI 中継(出力 "ChromaSynth USB")
```

## ESP-IDF メモ
- 判断・計算は純粋な C(`firmware/core/`、`chromatic-mcu/src/` のプロトコル中核)に集め、ESP-IDF との境界は薄くする。ホストの cc で全部テストできるようにする(`make check-mcu`、`make check-bridge`)。
- 参照実装(Python)→ 正解トレース → C の差分照合。算術は整数にして丸めまで一致させる。
- ESP-IDF の API は推測で書かず、ヘッダで宣言を確認する。確認できなかった名前には `TODO(verify)`。ビルド後は `managed_components/` のヘッダの既定値も読む(例: esp_tinyusb の既定では USB タスクが core 1 でリンク駆動タスクと衝突した)。
- シェルごとに `. <idf>/export.sh`。ESP-IDF 本体とツールで約 6 GB(ディスクが逼迫しがち)。
- 外付けブリッジ(ESP32-S3)の USB-MIDI は `esp_tinyusb`。SPI は `mode = 3`、`spics_io_num = -1`、`SPI_TRANS_USE_TXDATA/RXDATA`、`spi_device_polling_transmit`。実周波数は `spi_device_get_actual_freq`(kHz)。

## リンクポート(ケーブル方式)メモ
- GB はスレーブ(`SC=$80`)。マスターは GB が SB/SC を再設定し終える前に次のバイトを始めない。ISR は約 100 サイクルなので、バイト間隔は 250 µs 以上。
- 返信は 1 転送遅れる。送信キューが空なら `$FD`。
- PyBoy はシリアルを模擬できない(SB は常に `$FF`)。ISR のテストは `SerialISR+5` に A を注入するフックと、`SerialISR.send` で B を読むフック。
