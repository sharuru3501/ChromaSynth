# ChromaSynth をはじめる

ChromaSynth は ROM です。ゲームボーイカラー用のカートリッジに書いて、Chromatic(またはゲームボーイカラー互換機)で遊びます。**パート A** はカートリッジだけで使えます。**パート B**(DAW から鳴らす、シーケンサーを DAW に録音する)は任意で、Mac が要り、Chromatic の内蔵 ESP32 に、パッチ済みのファームウェアを**自己責任で**書き込む必要があります。

英語版: [GETTING_STARTED.md](GETTING_STARTED.md)。シンセ本体の使い方: [MANUAL.md](MANUAL.md)(英語版は [MANUAL.en.md](MANUAL.en.md))。

## パート A: カートリッジで使う

### 必要なもの
- ゲームボーイカラーのソフトが動く機械(Chromatic は動きます)。初代ゲームボーイ(DMG)では**動きません**。
- 書き込めるカートリッジか、フラッシュカート。**MBC5 + RAM + 電池**を推奨します([CARTRIDGES.md](CARTRIDGES.md))。
- カートリッジの SRAM(電池で保持する保存用メモリ)に合った ROM を選びます(ROM は [Releases](https://github.com/sharuru3501/ChromaSynth/releases) から)。

| ROM | カートリッジの SRAM | 保存できる曲 |
|---|---|---|
| `chromasynth-v0.1.0-sram32k.gb` | 32 KB 以上 | 4 曲 |
| `chromasynth-v0.1.0-sram8k.gb` | 8 KB | 1 曲 |

音作り・打ち込み・演奏は、どちらも同じです。違うのは、保存できる曲の数だけです。8 KB のカートリッジに 32 KB 用の ROM を書かないでください(スロット 2〜4 への保存が、スロット 1 を上書きします)。

### 手順
1. ROM をダウンロードして、`SHA256SUMS.txt` と照合します(`shasum -a 256 <ファイル>`)。
2. お使いのカートリッジやフラッシュカートの書き込みツールで、ROM を書きます(このプロジェクトでは、書き込みツールは配りません)。**保存は、カートリッジの SRAM に書きます。ほかのソフトのセーブデータを残したいカートリッジには、使わないでください。**ChromaSynth は、自分のものでないデータの上には書かず、`SLOT IN USE` と出します。
3. 電源を入れると、**プレイ画面**が出ます。**A** を押すと、音が鳴ります。
4. 続きは、[MANUAL.md](MANUAL.md) の「はじめの 5 分」へ。

## パート B: DAW で鳴らす・録音する(Mac、任意)

できること: Chromatic が、DAW に、`ChromaSynth` という MIDI ポートとして現れます。DAW のキーボードやクリップから、Chromatic のシンセを鳴らせます。Chromatic のシーケンサーを、4 つの MIDI トラックとして DAW に録音できます。DAW の再生・停止とテンポで、シーケンサーを動かせます。Bluetooth(ケーブルなし)でも、USB-C でも使えます。

```
DAW <-> ChromaSynth Link(Mac のアプリ) <-> Bluetooth か USB-C <-> Chromatic 内蔵の ESP32 <-> ChromaSynth の ROM
```

**既知の問題**: Bluetooth だと、シーケンサーのクロックと音符の一部が、遅れて届いたり、落ちたりします。録音のリズムが、不揃いになることがあります。DAW から Chromatic を鳴らすのは、影響が少ないです。*音*を録音するなら、Chromatic の USB オーディオを使ってください。`docs/M15_DESIGN.md` の §10 を参照。

### B1. Chromatic の ESP32 のファームウェア(一度だけ)
純正のファームウェアは、ROM と通信できません。このプロジェクトは、ModRetro のオープンなファームウェア([oss-chromatic-console-mcu](https://github.com/ModRetro/oss-chromatic-console-mcu) の v4.6、GPL-3.0)に、パッチを当てています。パッチは `chromatic-mcu/` にあります。
- **書き込みに失敗すると、純正のファームウェアに戻す作業が要ることがあります。自己責任で行ってください。**先に [MCU_FLASH_SAFETY.md](MCU_FLASH_SAFETY.md) を読み、純正のバックアップを取り、戻す練習を済ませてから書いてください。
- ビルド: `chromatic-mcu/build.sh`(ESP-IDF v5.3 が要る)。書き込み: `chromatic-mcu/flash.sh <イメージ> <sha256 の先頭 16 桁>`(アプリの枠だけに書き、前後で検査します)。
- 作者は、パッチ済みのファームウェアを、1 台の Chromatic でしか試していません。

### B2. Mac のアプリ(ChromaSynth Link)
Chromatic に(Bluetooth か USB で、自動的に)つなぎ、DAW に MIDI ポートを出す、メニューバーの小さなアプリです。ビルド済みのアプリは、まだ配っていません。自分でビルドします。
```bash
xcode-select --install          # 一度だけ(swiftc が入る)
git clone https://github.com/sharuru3501/ChromaSynth.git
cd ChromaSynth
tools/mac/build_app.sh
open build/ChromaSynthLink.app
```
- アプリは署名されていません。macOS が開くのを拒んだら、右クリックして「開く」を選びます。
- Bluetooth の許可を求められたら、許可します。メニューバーの項目(`♪●` 接続中、`♪○` 未接続)で状態を見られます。常に動かしたいなら、「ログイン時に開く」を入れます。
- Chromatic を「Audio MIDI 設定」で、ペアリング**しないで**ください(音符が 2 回鳴ります)。
- アプリの詳細: [MAC_APP.md](MAC_APP.md)。

### B3. Chromatic 側
1. Chromatic のメニューの **System > MIDI MODE** で、**BLE** か **USB** を選びます。選んだモードは覚えられます。(OFF にすると、ESP32 が眠って電池が持ちます。)
2. ChromaSynth で、**キーボード画面**を開きます(シーケンサーから START+→)。DAW からの音符は、この画面にいる間だけ届きます。
3. USB のときは、USB-C ケーブルを Mac につなぎます。アプリが自動で USB に切り替わります。

### B4. DAW から鳴らす(例: Ableton Live)
1. Live の設定 > Tempo & MIDI の**出力**の一覧に、`ChromaSynth` が出ます。その行の **Track** を入れます。
2. MIDI トラックを作り、**MIDI To** を `ChromaSynth` にして、弾くか、録音待機にします。Chromatic で音が鳴ります。
3. どの MIDI チャンネルがどのゲームボーイのチャンネルを鳴らすかは、PATCH 画面の MIDI ページで決めます(初期値は、MIDI チャンネル 1〜4 が CH1〜CH4)。

### B5. Chromatic のシーケンサーを DAW に録音する
1. ChromaSynth の PATCH 画面の MIDI ページで、**SYNC = 1**(OUT)にして、**SELECT+B** で保存します。
2. Live の設定 > Tempo & MIDI の**入力**の一覧で、`ChromaSynth` の **Track** と **Sync** を入れます。
3. MIDI トラックを 4 つ作ります。**MIDI From = `ChromaSynth`**、チャンネルは **Ch. 1 / 2 / 3 / 4**、**MIDI To = No Output**、**Monitor = In**。4 つとも録音待機にします(録音待機のボタンを、⌘ を押しながらクリック)。左上の **EXT** を入れます。
4. Chromatic で、キーボード画面にして、**SELECT+START** で再生します。Live が録音を始めます。Chromatic を止めると、Live も止まります。録音は、アレンジメントビューに入ります。

### B6. DAW でシーケンサーを動かす
SYNC を **3**(FOLLOW)にします。Live の設定 > Tempo & MIDI の**出力**の一覧で、`ChromaSynth` の **Sync** を入れます。Live の再生・停止で、シーケンサーが始まる・止まります。Live のテンポが BPM になります。プログラムチェンジ 0〜3 でパターン 1〜4 を選びます。CC20 / CC21 / CC10 で、デューティか波形・音量・パンを動かせます。(プログラムチェンジと CC は、まだ実機で試していません。)

### うまくいかないとき
| 症状 | 試すこと |
|---|---|
| DAW に `ChromaSynth` のポートが出ない | アプリを動かしておく。アプリを起動してから、DAW を一度終了して開き直す |
| 音符は届いている(Chromatic の画面に出る)のに、DAW の音源が鳴らない | トラックの **Monitor = In**。クリップが再生中のトラックは、Monitor が Auto だと、入力を通さない。環境設定の Tempo & MIDI で、コントロールサーフェスの枠に `ChromaSynth` を入れない |
| 設定は合っているのに、何も DAW に届かない | Mac を再起動する(一度、CoreMIDI の状態が原因だった)。アプリを先に、DAW を後に起動する |
| 音が 2 回鳴る | `ChromaSynth` が「Audio MIDI 設定」でもペアリングされている。または、DAW がキーボードを鳴らし、アプリも直接鳴らしている(アプリのメニューの「Play MIDI keyboards directly」) |
| Chromatic で何も鳴らない | ROM がキーボード画面にいること。MIDI MODE が OFF でないこと |
