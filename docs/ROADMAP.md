# ROADMAP

状態: `done` / `untested`(実装済み・未確認) / `todo`

| M | 内容 | 状態 |
|---|------|------|
| M0 | 雛形: ビルド, ヘッダ, 割り込み, CH1発音(パッド操作), リンクポートMIDI受信(Note On/Off) | untested(ビルドのみ確認。SameBoyでの聴感未確認) |
| M1 | 全4ch発音 + チャンネル別パラメータ + テキストUI + MIDI ch1-4 対応 | untested(ヘッドレステストでRAM状態・画面は確認済み。CH3/CH4の音の聴感は未確認) |
| M2 | Patch エディタ画面(duty/エンベロープ/sweep/ビブラート/wave編集/noise) | todo |
| M3 | ポリ/マルチチャンネル MIDI(MIDI ch→ボイス割当, CC→パラメータ, ピッチベンド) | todo |
| M4 | シーケンサ(パターン編集, 再生, テンポ) | todo |
| M5 | ソング/チェイン, SRAM保存(MBC5) | todo |
| M6 | MIDI OUT + MIDI clock 同期(DAW), 有線ブリッジ(マイコン側ファーム) | todo |
| M7 | 実機(Chromatic+フラッシュカート)検証 | todo |
| M8 | BLE MIDI(ESP32ブリッジ) | todo |

## 操作(M1)
- A: 選択中のチャンネルで発音 / ←→: ±半音 / ↑↓: ±オクターブ(音域 MIDI 36–107)
- SELECT: チャンネル切替(CH1→CH4) / B: パラメータ切替(パルス=デューティ、WAVE=波形(矩形/ノコギリ/三角/サイン)、NOISE=LFSR幅)
- リンクポート(外部クロック)の MIDI: ch1-4 → CH1-4、各チャンネルはモノ。ch5以降は無視
- CH3(WAVE)の音域は MIDI 36–95(周波数が半分なので1オクターブ上にずらして鳴らす)
- 起動時に CH1 で約0.5秒ビープ
