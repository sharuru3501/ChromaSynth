# ROADMAP

状態: `done` / `untested`(実装済み・未確認) / `todo`

| M | 内容 | 状態 |
|---|------|------|
| M0 | 雛形: ビルド, ヘッダ, 割り込み, CH1発音(パッド操作), リンクポートMIDI受信(Note On/Off) | done(音はSameBoyで確認。MIDI受信はヘッドレスで注入テストのみ) |
| M1 | 全4ch発音 + テキストUI + MIDI ch1-4 対応 | done(4chの発音をSameBoyで聴感確認) |
| M2 | 音色(Patch)エディタ: duty/音量/エンベロープ/スイープ/ビブラート/波形選択/ノイズ幅 | untested(ヘッドレス33項目通過。音の聴感は未確認。カスタム波形の編集は未実装) |
| M3 | ポリ/マルチチャンネル MIDI(MIDI ch→ボイス割当, CC→パラメータ, ピッチベンド) | todo |
| M4 | シーケンサ(パターン編集, 再生, テンポ) | todo |
| M5 | ソング/チェイン, SRAM保存(MBC5) | todo |
| M6 | MIDI OUT + MIDI clock 同期(DAW), 有線ブリッジ(マイコン側ファーム) | todo |
| M7 | 実機(Chromatic+フラッシュカート)検証 | todo |
| M8 | BLE MIDI(ESP32ブリッジ) | todo |

## 操作(M2)
共通: A=発音(選択chで) / SELECT=ch切替 / START=プレイ画面⇔編集画面
- プレイ画面: 十字キー=音程(←→半音, ↑↓オクターブ)。各chの発音中ノートとMIDI受信バイトを表示
- 編集画面: ↑↓=パラメータ行, ←→=値(範囲内でクランプ), B押しながら十字キー=試聴ノート変更
- パラメータ(CH1): DUTY VOL ENV(bit3=上昇,下位3bit=速さ) SWT/SWD/SWS(スイープ) VIBD/VIBS(ビブラート深さ/速さ)
- CH2: DUTY VOL ENV VIBD VIBS / CH3: WAVE(矩形,ノコギリ,三角,サイン) LVL(100/50/25%) VIBD VIBS / CH4: WDTH(LFSR幅) VOL ENV
- 値の変更は次のノートオンから反映(ビブラートだけは発音中も即時反映)
- リンクポート(外部クロック)の MIDI: ch1-4 → CH1-4、各チャンネルはモノ。ch5以降は無視
- CH3 の音域は MIDI 36–95。起動時に CH1 で約0.5秒ビープ
