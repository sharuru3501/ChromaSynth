# ChromaSynth Link(Mac のメニューバーアプリ)

Chromatic で動く ChromaSynth を、Mac の DAW(Ableton Live など)や MIDI キーボードから鳴らすための小さなアプリです。**Bluetooth(BLE MIDI)と USB-C の両方**に対応し、接続は自動です。

## できること
- DAW の「MIDI To」に **`ChromaSynth`** という出力が出る(アプリが動いている間)。Audio MIDI 設定での Bluetooth の接続は**不要**(両方でつなぐと音が 2 回鳴る)。
- **Bluetooth**: Chromatic の MIDI モードが BLE のとき、アプリが探して自動で接続し、切れたらつなぎ直す。
- **USB-C**: ケーブルをつなぐと(`/dev/cu.usbmodem*` が現れる)自動で USB に切り替え、ノートを送る。抜くと、0.5 秒ごとの `hb`(ハートビート)が止まり、Chromatic は **2 秒後に保存してあるモード**へ戻って、鳴っている音を止める(BLE の起動と接続で、合わせて 4〜5 秒)。
- メニューバーの `♪●`(接続中)/ `♪○`(未接続)と、メニューの状態表示、「ログイン時に開く」。
- ハードの MIDI キーボードを直接聴くのは、メニューの「Play MIDI keyboards directly」を入れたときだけ(既定は切)。DAW がキーボードを `ChromaSynth` に送っているとき、入れると音が 2 回鳴る。
- メニューの **Disconnect / Connect**: 手動で接続を切る / つなぐ。切ると、つなぐまで自動では何もつながない。
- **Ableton Live の初回の設定**: Live の環境設定 > Tempo & MIDI の出力ポートの一覧に `ChromaSynth` が出るので、**その行の「Track」(トラック)を入れる**。入れないと、トラックの「MIDI To」に出ない(一度入れれば覚える)。
- ループ(Live が自分の出力を自分に返す)の検出つき: 1 秒に 60 通を超えると、静かになるまで捨てる。
- ChromaSynth の ROM は **キーボード画面**にしておく(ESP32 が送るのはそのときだけ)。

## 作る・動かす
```bash
tools/mac/build_app.sh          # build/ChromaSynthLink.app(Xcode のコマンドラインツールの swiftc が要る)
open build/ChromaSynthLink.app
```
初回は、Bluetooth の許可のダイアログが出ます(許可してください)。「ログイン時に開く」をメニューで入れると、次のログインから自動で起動します。

コマンドライン: `ChromaSynthLink --selftest`(変換などの自己試験)、`--dry-run`(送らずに行を出す。Bluetooth の許可は要らない)、`--list`。試験は `tools/mac/test.sh`(ハード不要)。

## Chromatic 側(本体の ESP32)
- OSD の System > MIDI MODE で選んだモード(OFF / BLE / USB)は**保存され、次の起動でも引き継がれる**(起動の 3 秒後に適用)。電池を節約したいときは OFF に戻す。
- コンソールの `mode usb` などは**一時的**(保存しない)。保存するのは `mode set ble` など。`mode saved` は保存してあるモードに戻す。
- `hb` を一度でも受けた USB モードは、2 秒途切れると保存モードへ戻る。モードが変わるとき(と BLE が切れたとき)は、鳴っている音を止める。起動直後に helper がモードを頼んでいたら、保存モードは上書きしない。`hb` を送らない古い helper(`tools/chromasynth_usb_bridge.swift`)には影響しない。

## Chromatic のシーケンサーを DAW に録音する(ROM → DAW、M15)
2026-11-10 に、Live で、USB と BLE のどちらでも、MIDI 録音できることを実機で確認した。

**条件(Chromatic)**: MIDI ページ(PATCH 画面の CH4 の次)で **SYNC = OUT(1)**(初期値は OFF。**SELECT+B で保存**しないと、ROM を書き換えたあとなどに、OFF に戻る)。ROM を**キーボード画面**にして、SELECT+START で再生。MIDI チャンネルは、MIDI ページの CH1〜CH4(既定 1・2・3・4)で、チャンネルごとに別の MIDI チャンネルで出る。
**条件(Live)**:
- 環境設定 > Tempo & MIDI: 入力ポート `ChromaSynth` の**トラック**(ノート)と**同期**(クロック・スタート/停止)を入れる。
- MIDI トラックを 4 つ: **MIDI From = `ChromaSynth`、チャンネルを Ch. 1〜4 に分ける**(同じチャンネルは、1 つのトラックにまとまる)。**MIDI To = No Output**(Chromatic に送り返して、ぐるぐる回らないように)。
- 4 つを、⌘ クリックで、すべて録音待機にする(Live は、初期設定では 1 つだけ)。
- **EXT** をオン(外部同期。Link はオフになる)。EXT ボタンは、同期を入れた入力ポート `ChromaSynth` が**存在するとき**(ChromaSynth Link が動いているとき)だけ出る。アプリが落ちていると、EXT は消える。全体録音(●)をオン。
- Chromatic で再生すると、Live が再生と録音を始める。Chromatic を止めると、Live も止まる。録音は、**アレンジメントビュー**(Tab キー)に、トラックごとに入る。
- ノートのないチャンネルは、空のままになる(初期のデモのパターンは、CH2 が空)。
- ROM のクロックは 1 拍 12 回なので、アプリが 1 つおきに足して 24 回にする。詳しくは [M15_DESIGN.md](M15_DESIGN.md)。

**調べるための道具**
- `ChromaSynthLink --emit-test`(アプリを止めてから): Chromatic の代わりに、入力 `ChromaSynth` を作って、チャンネル 1〜4 に 4 音ずつ送る(クロックは送らない)。DAW の設定の切り分けに使える。
- `build/midi_listen ChromaSynth 30`(`swiftc -O tools/mac/midi_listen.swift -o build/midi_listen`): 最初のメッセージが届いてから 30 秒間、チャンネルごとのノートの数を数える。
- `ChromaSynthLink --no-usb`: USB のポートを取らない(コンソールの試験と併用するとき)。

## DAW に追従する(DAW → Chromatic、M15)
ChromaSynth の MIDI ページで **SYNC = 3(FOLLOW)**。Live の環境設定 > Tempo & MIDI の**出力**ポート `ChromaSynth` の**同期**を入れる。
- Live の再生・停止で、シーケンサーが始まる・止まる(約 0.3〜0.4 s 遅れる)。
- Live のテンポ(BPM)が、Chromatic に届く(変わったときだけ。整数に丸める)。
- プログラムチェンジ 0〜3 でパターンを切り替える。CC20(デューティ・波形)、CC21(音量)、CC10(パン)で、音色を動かす。ノート(Live → Chromatic)は、これまでどおり MIDI To = `ChromaSynth`。
- 仕様の詳細は [M15_DESIGN.md](M15_DESIGN.md) の §8。

## 遅れの測定(音で測る)
Chromatic のイヤホンジャックと Mac のオーディオ入力を、3.5 mm ケーブルでつなぐ(マイクの許可のダイアログが出る)。ChromaSynth Link を先に動かしておく。
```bash
open -n --stdout /tmp/latency.log --stderr /tmp/latency.log build/ChromaSynthLink.app --args --latency down      # MIDI → 音の遅れ(アプリが 12 音を送る。約 15 秒)
open -n --stdout /tmp/latency.log --stderr /tmp/latency.log build/ChromaSynthLink.app --args --latency up 30     # Chromatic のシーケンサー → DAW(最初の MIDI が届いてから 30 秒)
cat /tmp/latency.log
```
- `down`: 遅れの平均・揺れ(標準偏差)と、MIDI チャンネルごとの左右の音量が出る(PAN で、CH1 を左、CH2 を右などにすると、左右にどれだけ漏れるかが分かる)。出た値を、Live の「トラック ディレイ」(マイナス)に入れる。
- `up`: シーケンサーのノートの MIDI と、その音のずれが出る。1 本のチャンネルに、拍ごとに 1 音だけのパターンで測ると、正確(近いノートは、数えない)。

## Chromatic の側でモードを切り替えたとき
- Chromatic のメニュー(System > MIDI MODE)で USB から BLE などへ切り替えると、アプリは 2 秒おきに `mode` で問い合わせて**切り替えを検知**し、USB のポートを手放して、BLE に切り替える(メニューの表示は `Chromatic MIDI mode: …`)。ケーブルを抜き差しするか、「Connect」を選ぶまで、USB を勝手に取り戻さない(メニューで選んだモードを尊重する)。
- BLE で接続中にメニューで USB に切り替えると、BLE が切れたことを手がかりに、アプリが USB を取りにいく。
- シリアルポートへの書き込みはすべて別のキューで、待たない書き方(ノンブロッキング)にした。ESP32 が 8 秒返事をしなければ、つなぎ直す。メインスレッドは、ポートを待たない。

## 弾いている途中で抜き差しした音について(2026-11-09)
- 原因: ノートオフが届かない。BLE から USB に切り替えるとき、シリアルポートを開くと ESP32 が**再起動**するので、その瞬間に鳴っていた音は、ESP32 の側から止められなくなる。
- 対策(三重): (1) アプリは、ポートを開く**前に** BLE で全ノートオフを送り、切り替え中のノートは捨てる。(2) ESP32 は、モードの切り替え・BLE の切断のときに、鳴っている音を止める。(3) **ROM は、リンクが 4.2 秒途切れてリンクを落とすとき、リンクが残した音を止める**(ESP32 が再起動した、落ちた、など、どの経路でも最後は止まる)。

## 未確認
- 実機での BLE の自動接続・再接続、USB の自動切り替えと保存モードへの復帰(ESP32 の書き込みが要る)。
- DAW の「MIDI From」に `ChromaSynth` を出すこと(ROM → DAW の上り。M15)。
- 署名なしの `.app`(ad-hoc 署名)を、他の Mac で開く手順(公開のときに整える)。
