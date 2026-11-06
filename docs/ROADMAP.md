# ROADMAP

状態: `done` / `untested`(実装済み・未確認) / `todo`

| M | 内容 | 状態 |
|---|------|------|
| M0 | 雛形: ビルド, ヘッダ, 割り込み, CH1発音(パッド操作), リンクポートMIDI受信(Note On/Off) | untested(ビルドのみ確認。SameBoyでの聴感未確認) |
| M1 | 全4ch発音 + Patch 構造 + 画面にテキスト表示(フォント) | todo |
| M2 | Patch エディタ画面(duty/エンベロープ/sweep/ビブラート/wave編集/noise) | todo |
| M3 | ポリ/マルチチャンネル MIDI(MIDI ch→ボイス割当, CC→パラメータ, ピッチベンド) | todo |
| M4 | シーケンサ(パターン編集, 再生, テンポ) | todo |
| M5 | ソング/チェイン, SRAM保存(MBC5) | todo |
| M6 | MIDI OUT + MIDI clock 同期(DAW), 有線ブリッジ(マイコン側ファーム) | todo |
| M7 | 実機(Chromatic+フラッシュカート)検証 | todo |
| M8 | BLE MIDI(ESP32ブリッジ) | todo |

## M0 操作
- A: 発音 / ←→: ±半音 / ↑↓: ±オクターブ(音域 MIDI 36–107)
- リンクポート(外部クロック)に MIDI を流すと Note On/Off で CH1 が鳴る(モノ)
