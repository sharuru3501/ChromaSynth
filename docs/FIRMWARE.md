# ブリッジのファームウェア設計(ESP32-S3)

[BRIDGE.md](BRIDGE.md) の仕様を実装するファームウェア。**M6a = USB-MIDI だけの版**(DIN-5 と BLE は後段)。

## 1. 現在の状態(何が検証済みで、何が未検証か)

| 部分 | 状態 |
|------|------|
| `core/bridge_core.c`(MIDI 振り分け、クロック変換、リンクの送出計画、キュー) | **ホストでテスト済み**。Python 参照実装の正解 6430 ステップと全て一致、AddressSanitizer/UBSan 通過、C 固有テスト(キュー溢れ、32bit 時刻の折り返し、チャンク分割非依存、リンク状態)通過 |
| ROM ⇄ この C コード | **PyBoy 上で往復テスト通過**(`tools/headless_midi_test.py`: ホスト MIDI → C コア → シリアル ISR → ROM、ROM の送信キュー → ISR の返信 → C コア → ホスト MIDI) |
| `main/main.c` `link.c` `usb_midi.c`(ESP-IDF との接続部) | **ESP-IDF v5.5.6 でビルド成功**(SPI 版・ビットバン版とも、警告なし。`esp_tinyusb 3.0.0`)。アプリは約 267 KB(1 MB のパーティションの 26%)。**実機では動かしていない**。ホストのスタブでの型検査(`make -C firmware/test syntax`)は ESP-IDF が無い環境向けの簡易版 |
| 実機(ESP32-S3 基板、リンクケーブル、Chromatic) | **未検証**。Chromatic のリンクポートの電圧・ピン配置も未実測 |

つまり「判断と計算を全部ホストでテストし、ESP-IDF との境界を薄くして、そこもビルドで確認した」状態。残るのは**実機でしか分からないこと**(§5)。

## 2. 構成

```
firmware/
  core/bridge_core.{h,c}   純粋な C11。ハード・RTOS・動的確保なし。Python 参照実装(tools/bridge_ref.py)の移植
  main/main.c              タスクの生成、core を守るミューテックス
  main/link.{h,c}          リンクの駆動(SPI ペリフェラル。ビットバンの代替付き)
  main/usb_midi.{h,c}      USB-MIDI デバイス(esp_tinyusb)
  main/bridge_pins.h       ピン、SCK 周波数、ビットバン切替
  test/                    ホストのテスト(test_core.c、vectors.txt、スタブ、Makefile)
  CMakeLists.txt, sdkconfig.defaults, main/idf_component.yml
```

```
  USB-MIDI ◄─► midi_task (core 0) ─┐                           ┌─ link_task (core 1) ◄─► link_transfer ◄─► GB
                                   ├─► bridge core (1 mutex) ◄─┤        32 kHz SPI mode 3
  stats_task (2 秒ごとにログ)       ┘                           └
```

### 中核(`bridge_core`)
- メモリ: `bridge_t` は **約 1 KB**(GB 向けキュー 512 B、ホスト向けスケジュール 64 件 × 8 B、状態数十 B)。動的確保なし。
- **時刻は 32bit のマイクロ秒カウンタ**(71 分で折り返す)。比較は全て符号付き差で行い、折り返しをまたいでも正しい(テスト済み)。
- **スレッド非安全**: 呼び出し側が1つのミューテックスで守る。呼び出しは全て O(キュー長)以下で短い(最大でホスト向け 64 件の挿入ソート)。
- GB 向けキューは**メッセージ単位で入れる**(満杯なら半端に入れず丸ごと捨てる)。ホスト向けスケジュールも満杯なら捨てる(どちらもカウンタで見える)。
- Python モデルとの対応は 1 対 1。**算術(整数 µs、切り捨て除算、`half > 0 && half < 250000`)を変えたら両方直し、`make -C firmware/test vectors test`** で突き合わせる。

### ESP-IDF 側
| 項目 | 内容 |
|------|------|
| `link_task`(core 1、優先度高) | `bridge_link_next` → `link_transfer`(約 250 µs、ポーリング) → `bridge_link_rx` → 待ち。250 µs 以下の待ちは `esp_rom_delay_us`、それ以上は `vTaskDelay`(アイドルポーリングは 1〜2 ms になる) |
| `midi_task`(core 0) | USB から読む → `bridge_host_in`。期限の来たホスト向けバイトを取り出して USB へ書く。1 ms ごと(補間クロックの遅れは最大 1 ms) |
| ロック | `xSemaphoreCreateMutex`(優先度継承)。`link_task` は 250〜2000 µs ごとに2回、数 µs だけ取る |
| SPI | `spi_bus_initialize(SPI2_HOST, …, SPI_DMA_DISABLED)`、デバイスは `mode = 3`、`clock_speed_hz = 32000`、`spics_io_num = -1`。1バイト = `SPI_TRANS_USE_TXDATA/RXDATA`、`length = 8`、`spi_device_polling_transmit`。起動時に `spi_device_get_actual_freq` をログに出し、20〜40 kHz から外れたら警告 |
| **SPI の最小クロック** | ESP-IDF の文書に**最小値の記載がない**。32 kHz が出るかは起動ログで確認する。出なければ `bridge_pins.h` の `LINK_USE_BITBANG` を 1 にする(GPIO のビットバン。SCK は立ち下がりで GB がビットを出し、立ち上がりで両者が取り込む) |
| USB-MIDI | `espressif/esp_tinyusb ~3.0.0`(解決結果は 3.0.0、IDF 5.3 以上が必要)、`CONFIG_TINYUSB_MIDI_COUNT=1`。ディスクリプタと呼び出し順は ESP-IDF の `examples/peripherals/usb/device/tusb_midi`(MIT)に従う。DAW に見えるポート名は `ChromaSynth MIDI`。**TinyUSB のタスクは既定で core 1(`link_task` と同じ)なので、`cfg.task.xCoreID = 0` で core 0 に移した**(ビルド時に esp_tinyusb のヘッダで発見)。VID/PID は esp_tinyusb の既定(Espressif の VID と既定 PID)のまま。開発用としては問題ないが、他人に配るなら自分の PID を用意する |
| 電源 | ブリッジは USB から給電。**リンクの VCC(ピン1)は接続しない** |

### ピン(ESP32-S3、`bridge_pins.h`)
| 信号 | GPIO | 備考 |
|------|------|------|
| SCK → GB の SC | 12 | SPI2 の IO_MUX ピン |
| MOSI → GB の SI | 11 | 〃 |
| MISO ← GB の SO | 13 | 〃 |
| (使わない) | 19, 20 | USB の D−/D+ |

電圧が 5V と分かった場合のレベル変換(74AHCT125 など)は [BRIDGE.md §4](BRIDGE.md)。**実測の前に接続しないこと。**

## 3. ビルドと書き込み
```bash
# ESP-IDF v5.5.6 を ~/esp/esp-idf に導入済みの環境(導入は公式の get-started に従う: git clone → ./install.sh esp32s3)
make firmware            # = . ~/esp/esp-idf/export.sh && cd firmware && idf.py build  (初回は esp_tinyusb を自動取得)
# 手動なら
. ~/esp/esp-idf/export.sh
cd firmware
idf.py set-target esp32s3      # 初回のみ
idf.py build
idf.py -p <シリアルポート> flash monitor   # 実機があるとき
# ビットバン版(SPI で 32 kHz が出ないとき)
idf.py -B build_bitbang -DCMAKE_C_FLAGS=-DLINK_USE_BITBANG=1 build
```
- `dependencies.lock` で `esp_tinyusb 3.0.0` を固定している(コミット対象)。`managed_components/` と `sdkconfig` と `build/` は生成物で、コミットしない。
- `esp_tinyusb 3.0.0` は IDF 5.3 以上を要求する。
- 起動後、2 秒ごとにログが出る: `link UP/DOWN, losses N, dropped to GB / to host, USB mounted/not mounted`。
- **ビルドで確認したこと**: 上記の API 名とヘッダは全て実在した(`tud_midi_stream_read/write`、`TINYUSB_DEFAULT_CONFIG()`、`tinyusb_default_config.h`、`spi_device_get_actual_freq` ほか)。`CONFIG_FREERTOS_HZ=1000` と `CONFIG_TINYUSB_MIDI_COUNT=1` が `sdkconfig` に反映される。ウォッチドッグは既定で両コアのアイドルタスクを 5 秒で監視する。

## 4. テスト(ESP32 なしで走るもの)
```bash
make check-bridge          # Python モデルの単体テスト + C コアのテスト(通常・ASan・構文検査・共有ライブラリ)
make -C firmware/test vectors test    # 参照実装を変えたら正解を作り直して突き合わせる
python3 tools/headless_midi_test.py   # ROM との結合テスト(要 pip install pyboy pillow。先に make と make -C firmware/test lib)
```
| テスト | 何を保証するか |
|--------|----------------|
| 正解トレース 6430 ステップ | ランダムな MIDI(ゴミ・SysEx・ランニングステータス・クロック)、ランダムな GB 返信と時刻、ランダムなリンク結果で、C が Python モデルとバイト単位・µs 単位で一致する。**わざと壊した C(クロック位相、補間の上限、スタート時のリセット、ベンドの転送、CC の絞り込み、時刻順の挿入)6 通りを全て検出した** |
| C 固有 | キュー満杯でメッセージが半端に入らない / ホスト向けが満杯でも静かに捨てる / 32bit カウンタの折り返し / 1 バイトずつ入れても同じ出力 / リンクの上下と古い入力の破棄 |
| `make syntax` | `main/*.c` がスタブに対して型検査を通る(ESP-IDF が無い環境向けの簡易版。実在の確認は `idf.py build`) |
| ROM との往復 | ROM のシリアル ISR(`$FD` の扱い、返信の順序)と C コアが噛み合う。24 回/拍 → 12 回/拍 → ROM のテンポ追従、ROM の送信 → 24 回/拍 → ホスト |

## 5. 未確認事項とリスク(実機でしか分からないこと)
| 項目 | 内容 | 確認方法 |
|------|------|----------|
| SPI 32 kHz | ESP-IDF の文書に最小クロックの記載なし。ビルドは通るが、**実際に 32 kHz が出るかは実行しないと分からない** | 起動ログの実周波数。ダメならビットバン版(ビルド確認済み) |
| ウォッチドッグ | `link_task` はバースト時に 250 µs の busy-wait を最大約 0.26 秒(キュー 512 B 分)続ける。既定のウォッチドッグは両コアのアイドルタスクを 5 秒で監視する(0.26 秒なら余裕) | 実機でログを確認。それでも出るなら `taskYIELD()` を入れる |
| ISR 遅延 | ROM の ISR は約 100 µs、バイト間隔は 250 µs(2.5 倍) | BRIDGE.md §6 の段階 6 で間隔を詰めて限界を測る |
| USB の安定性 | USB を core 0 に移したので `link_task`(core 1)の busy-wait の影響は受けないはず。DAW が繋がったまま連続運転して確認していない | 実機で長時間(数十分)動かす |
| 起動直後の返信 | GB が待ち受ける前の最初の返信は `$FF` 以外のこともある(ROM が起動前など) | `bridge_link_rx` は `$FF` 以外ならリンクを上げる。誤ってリンクが上がっても `$FD` しか送らないので無害 |
| 実装していないもの | DIN-5 MIDI IN(UART)、BLE MIDI(セントラル/ペリフェラル)、LED 表示、USB のシリアル番号(チップ ID から作る)、自分の USB PID | 次の工程 |

## 6. 次の工程
1. ~~ESP-IDF を導入し、`idf.py build` を通す~~(完了)。
2. Chromatic のリンクを実測(BRIDGE.md §4)→ 配線と(必要なら)レベル変換を決める。**基板の購入はこの結果次第。**
3. 実機ブリングアップ(BRIDGE.md §6 の段階 1〜3: SCK の波形、`$FD` ポーリング、ノートオン)。
4. DIN-5(M6b): UART1(31250 baud)+フォトカプラ。入力は `usb_midi_read` と同じ形で `bridge_host_in` に渡すだけ。
5. BLE MIDI(M8)。
