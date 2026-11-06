# ブリッジのファームウェア設計(ESP32-S3)

[BRIDGE.md](BRIDGE.md) の仕様を実装するファームウェア。**M6a = USB-MIDI だけの版**(DIN-5 と BLE は後段)。

## 1. 現在の状態(何が検証済みで、何が未検証か)

| 部分 | 状態 |
|------|------|
| `core/bridge_core.c`(MIDI 振り分け、クロック変換、リンクの送出計画、キュー) | **ホストでテスト済み**。Python 参照実装の正解 6430 ステップと全て一致、AddressSanitizer/UBSan 通過、C 固有テスト(キュー溢れ、32bit 時刻の折り返し、チャンク分割非依存、リンク状態)通過 |
| ROM ⇄ この C コード | **PyBoy 上で往復テスト通過**(`tools/headless_midi_test.py`: ホスト MIDI → C コア → シリアル ISR → ROM、ROM の送信キュー → ISR の返信 → C コア → ホスト MIDI) |
| `main/main.c` `link.c` `usb_midi.c`(ESP-IDF との接続部) | **書いただけ。ESP-IDF ではコンパイルしていない**。ホストの C コンパイラ+手作りスタブヘッダで構文と型だけ検査(`make -C firmware/test syntax`)。これは自分のコードの誤りを見つけるだけで、**ESP-IDF/TinyUSB の関数が実在する証明にはならない** |
| 実機(ESP32-S3 基板、リンクケーブル、Chromatic) | **未検証**。Chromatic のリンクポートの電圧・ピン配置も未実測 |

つまり「判断と計算を全部ホストでテストし、ESP-IDF との境界を薄くした」状態。境界の確認は `idf.py build`(ハード不要)が最初の一歩。

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
| USB-MIDI | `espressif/esp_tinyusb ~3.0.0`、`CONFIG_TINYUSB_MIDI_COUNT=1`。ディスクリプタと呼び出し順は ESP-IDF の `examples/peripherals/usb/device/tusb_midi`(MIT)に従う。DAW に見えるポート名は `ChromaSynth MIDI` |
| 電源 | ブリッジは USB から給電。**リンクの VCC(ピン1)は接続しない** |

### ピン(ESP32-S3、`bridge_pins.h`)
| 信号 | GPIO | 備考 |
|------|------|------|
| SCK → GB の SC | 12 | SPI2 の IO_MUX ピン |
| MOSI → GB の SI | 11 | 〃 |
| MISO ← GB の SO | 13 | 〃 |
| (使わない) | 19, 20 | USB の D−/D+ |

電圧が 5V と分かった場合のレベル変換(74AHCT125 など)は [BRIDGE.md §4](BRIDGE.md)。**実測の前に接続しないこと。**

## 3. ビルドと書き込み(ESP-IDF が入っている環境で。ここでは未実行)
```bash
# ESP-IDF の導入は公式の手順に従う(v5.x)。以降は export.sh を読み込んだシェルで
cd firmware
idf.py set-target esp32s3
idf.py build
idf.py -p <シリアルポート> flash monitor
```
- `idf_component.yml` が `espressif/esp_tinyusb ~3.0.0` を自動取得する(ネットワークが必要)。
- **ESP-IDF のバージョンと esp_tinyusb の組み合わせは、手元の IDF にある `tusb_midi` 例と合わせる。** この例は IDF の master を参照して書いたので、古い IDF では API 名が違う可能性がある。
- 起動後、2 秒ごとにログが出る: `link UP/DOWN, losses N, dropped to GB / to host, USB mounted/not mounted`。

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
| `make syntax` | `main/*.c` がスタブに対して型検査を通る(**API の実在は証明しない**) |
| ROM との往復 | ROM のシリアル ISR(`$FD` の扱い、返信の順序)と C コアが噛み合う。24 回/拍 → 12 回/拍 → ROM のテンポ追従、ROM の送信 → 24 回/拍 → ホスト |

## 5. 未確認事項とリスク
| 項目 | 内容 | 確認方法 |
|------|------|----------|
| ESP-IDF でのビルド | 関数名・ヘッダ名の誤り(特に `tud_midi_stream_read`、`tinyusb_default_config.h`、`TINYUSB_DEFAULT_CONFIG()`) | `idf.py build`(ハード不要) |
| SPI 32 kHz | 文書に最小クロックの記載なし | 起動ログの実周波数。ダメならビットバン |
| TinyUSB タスクのコア | `link_task` を core 1 に固定したが、USB ドライバのタスクの割り当ては未確認 | sdkconfig の TinyUSB のタスク設定を確認。USB の遅れでリンクが乱れないか実機で確認 |
| ウォッチドッグ | `link_task` はバースト時に 250 µs の busy-wait を最大約 0.26 秒(キュー 512 B 分)続ける。アイドルタスクが飢える | 実機で TWDT のログを確認。必要なら `taskYIELD()` を入れる |
| ISR 遅延 | ROM の ISR は約 100 µs、バイト間隔は 250 µs(2.5 倍) | BRIDGE.md §6 の段階 6 で間隔を詰めて限界を測る |
| 起動直後の返信 | GB が待ち受ける前の最初の返信は `$FF` 以外のこともある(ROM が起動前など) | `bridge_link_rx` は `$FF` 以外ならリンクを上げる。誤ってリンクが上がっても `$FD` しか送らないので無害 |
| 実装していないもの | DIN-5 MIDI IN(UART)、BLE MIDI(セントラル/ペリフェラル)、LED 表示、USB のシリアル番号(チップ ID から作る) | 次の工程 |

## 6. 次の工程
1. **ESP-IDF を導入し、`idf.py build` を通す**(ハード不要。API の誤りがここで分かる)。
2. Chromatic のリンクを実測(BRIDGE.md §4)→ 配線と(必要なら)レベル変換を決める。
3. 実機ブリングアップ(BRIDGE.md §6 の段階 1〜3: SCK の波形、`$FD` ポーリング、ノートオン)。
4. DIN-5(M6b): UART1(31250 baud)+フォトカプラ。入力は `usb_midi_read` と同じ形で `bridge_host_in` に渡すだけ。
5. BLE MIDI(M8)。
