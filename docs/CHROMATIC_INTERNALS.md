# Chromatic の内部構造(ケーブルなしで MIDI を通す経路の調査)

調査日: 2026-11-06。**情報源は ModRetro の公開リポジトリのソース読解のみ**で、実機では何も確認していない。
(`ModRetro/chromatic_fpga`、`ModRetro/oss-chromatic-console-mcu`。どちらも GPL-3.0。)

## 1. 構成
```
 カート ─► FPGA (Gowin GW5A, GB コア = MiSTer Gameboy_MiSTer) ─► 画面/音/リンクポート
             ▲  │  ボタン、USB(複合デバイス)
   UART      │  ▼  (システム管理用、非同期、低速)
          MCU (ESP32、WiFi/BLE あり、ファームウェア公開、ESP-IDF v5.3)
```
- USB-C は FPGA に繋がり、複合 USB デバイスのシリアル(CDC)が MCU の UART0 に橋渡しされる(115200bps、書き込みとコンソール用)。
- MCU と FPGA の間はもう1本の UART(MCU 側 GPIO9 = TX、GPIO10 = RX)で、パケット(ヘッダ 0x8A/0x8F)を交換する。
- 既存のカスタムファームウェア(ChroMagic、KortaMod、chromatic-recon)は MCU 側だけを置き換える。**FPGA は純正のまま**。

## 2. リンクポートの電気的な手がかり(FPGA ソースより)
- FPGA の端子は `LVCMOS33`(3.3V)。外側との間に**レベルシフタ**があり、`LINK_CLK_DIR_LV` がクロックの向きを制御する(`emu_system_top.v`、`evt1_x2.cst`)。
- したがって**ポート側の電圧は FPGA ではなくレベルシフタの外側の電源で決まり、ソースだけでは分からない**。実測の必要は残る。
- `LINK_SD`(ピン4)は「使っていない、FPGA 側は常に入力」とコメントされている。

## 3. ケーブルなしで ROM と MCU が通信できるか
FPGA 内の GB コアのシリアル(SB/SC)は**外部リンクポートにしか繋がっていない**。MCU の UART には繋がっていない(`emu_system_top.v`)。したがってシリアルでの通信は、FPGA を改造しない限りできない。

ただし**別の経路が2本ある**(どちらも未検証):

| 方向 | 経路 | 根拠 | 見込み |
|------|------|------|--------|
| MCU → ROM | **仮想ボタン**。MCU が UART でアドレス 9 に 9bit を書くと、FPGA が物理ボタンと OR して GB コアの入力に渡す(`top.v` の `BTN_x_filtered \| MCU_buttons[n]`)。MCU 側は `FPGA_Tx_PokeButtons`。 | ソースで確認。ROM は `$FF00` の読みで見える | 1フレームに 8 ビット(十字 4 + A/B/SELECT/START)。**約 60 B/s**。MIDI のノートには足りるが、人間の操作と混ざる。ボタンを押すと誤動作しないよう、通信専用画面かモードが要る |
| ROM → MCU | **パレット読み出し**。MCU がアドレス 0xD で要求すると、FPGA がコア由来の `gpd`(64bit、「Game Palette Data」)を返す(`system_monitor.sv`)。 | 返ってくることは確認。**`gpd` が何のレジスタ由来か(ゲームが書いた色を反映するか)は未確認** | 不明。もし ROM が書いたパレットが見えるなら、1回 8 バイトの上り経路になる |

どちらも**純正 FPGA のまま、MCU のファームウェアだけで実現できる**。FPGA の改造(Gowin のライセンスと開発環境が必要)は不要。

## 4. 方針
1. **ケーブルあり(A)**: リンクポート+外付け ESP32-S3。設計とテストは済み(BRIDGE.md、FIRMWARE.md)。実測が先。
2. **ケーブルなし(C)**: 本体の ESP32 の BLE MIDI + 仮想ボタン(下り)。ROM → MCU はパレット次第。MIDI IN(キーボード→ROM)なら下りだけで成立する。DAW 同期の送信(ROM → 外)と MIDI OUT は上りが必要。
3. FPGA 改造(B): 最終手段。

## 5. 未確認事項
- 実機で MCU が仮想ボタンを送ると ROM の `$FF00` に現れるか(遅延、チャタリング除去、メニュー状態との関係)。
- `gpd` の中身。ROM から書いたパレットや BGP/OBP が反映されるか。
- ESP32 の BLE と WiFi は**同時に使えない**と chromatic-recon が記している(radio の時分割)。BLE MIDI だけなら問題ない。
- 本体の ESP32 は USB を持たない通常の ESP32 なので、USB-MIDI は使えない(BLE MIDI のみ)。
- MCU ファームウェアを入れ替えるリスク(KortaMod は復元手順と元のバックアップを推奨)。実行前に必ず `esptool.py read_flash` で全体をバックアップする。
