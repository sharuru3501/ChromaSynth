# 画面の移動(ナビゲーション)の記録

画面をどう移るかの、いまの決まりと、これからの変更の予定。UX の面からの見直し(画面の移り方の全体の調整)をするときの、出発点にする。コードは `src/joy.asm` の `.nav`(START を押しながらの十字キー)。画面の番号は `inc/synth.inc` の `SCREEN_*`。

## 画面
| 番号 | 画面 | 役目 |
|---|---|---|
| 0 | PLAY(プレイ) | 音色の表示・演奏(鳴らす) |
| 1 | EDIT(編集) | 音色のパラメータ。CH4 の次のページは MIDI の設定 |
| 2 | SEQ(シーケンサー) | ピアノロール。打ち込む |
| 3 | KBD(キーボード) | 画面のキーボード。MIDI の受け口 |
| 4 | SLOT(スロット) | 曲の保存・読み込み・新規・複製・削除・名前 |
| 5 | SONG(ソング) | チェーン(ステップ × チャンネル)、ループ範囲、LOOP / SONG |
| 6 | WAVE(波形) | CH3 のサンプルの編集 |

## いまの移動(2026-11-15、M27 の最初の一歩まで)
すべて START を押しながら。START 中は、十字キーは画面の移動に使われ、その画面の操作には届かない。

```
PLAY ↔ SONG ↔ PATCH ↔ KEYBOARD      横の並び(START+←→。端で止まる)
              ↓  START+↓ (PLAY / SONG / PATCH から。KEYBOARD からは効かない)
             SEQ    ← START+↑ で、来る前にいた画面へ戻る
              ↓  START+↓
             SLOT   ← START+↑ で SEQ へ戻る
```

| 操作 | 動き |
|---|---|
| START+← / → | **PLAY ↔ SONG ↔ PATCH ↔ KEYBOARD** の順に、前後の画面へ(`ScreenRow`、`joy.asm`)。端で止まる。**SEQ、SLOT、WAVE からは効かない** |
| START+↓ | 横の並びの PLAY・SONG・PATCH から **SEQ** へ。**すでに SEQ にいるときは、SLOT を開く**。**KEYBOARD では効かない**(その画面は、パッドをデータとして読むため、START+↓ は、MCU の記号と区別できない。START+← で PATCH へ戻ってから使う) |
| START+↑ | **SEQ では、来る前にいた、横の並びの画面へ戻る**(`wScreenHome`)。横の並びの画面では、何もしない(空き) |
| SLOT で START+↑ | SEQ へ戻る(SLOT は SEQ からしか開けない) |
| SONG で START+A / START+B | **SONG / LOOP** の切り替え(START+←→ が画面の移動になったため) |
| PATCH で CH3 の WAVE を選んで START+A | **WAVE** を開く |
| WAVE で START+B | 戻る |

`wScreenHome` は、横の並びの画面から START+↓(SEQ へ)を押したときの、その画面(KEYBOARD からは、押せない)。SLOT で START+↓ は、何もしない。KEYBOARD 画面は、パッドをデータとして読むので、START+← の処理が `ReadJoy`(`joy.asm`)の中にあり、PATCH へ戻る。ソング画面へ START+←→ で入るとき、カーソルのチャンネルを、選んでいるチャンネルにそろえる。

## 変更の記録
- 2026-11-15(M27 の最初の一歩): START+↓ を、「PLAY・PATCH・SEQ・KBD から SLOT」から「どの画面からでも SEQ、SEQ からは SLOT」に変えた。**SEQ を、START+←→ の並びから外した**。SEQ の START+←→ は何もしない(「来る前の画面へ戻る」案を試したが、右でも左でも同じ画面へ行くので分かりにくかった)。SEQ の START+↑ は、来る前の画面へ戻る。KEYBOARD の START+← は、SEQ ではなく、1 つ前の画面(PATCH)へ戻る。スロット画面の置き場所は暫定。
- 2026-11-15: **SONG を、横の並びに入れた**(PLAY ↔ SONG ↔ PATCH ↔ KEYBOARD)。SONG から PLAY / PATCH へ、1 回で行ける。START+↑ で SONG を開くのは、やめた(横の並びの画面の START+↑ は、何もしない)。SONG の START+←→(LOOP / SONG の切り替え)は、画面の移動になったので、START+A(SONG)/ START+B(LOOP)に移した。SEQ の START+↑ が、SONG から来たときは SONG へ戻る(SONG ↔ SEQ が、↓ と ↑ で対称になった)。

## 見直しのときに考えること(メモ)
- 4 つの主な画面(PLAY・EDIT・SEQ・KBD)を、START+←→ で順に回る形は、画面が増えるほど遠くなる。SEQ と SONG は、よく行き来するので、近くに置きたい。
- SLOT の使い道は、保存・読み込み(SELECT+B / SELECT+A で、画面を開かずにできる)と、新規・複製・削除・名前の変更。開く回数は少ないので、深い場所でもよい。
- 戻り先を 1 つだけ覚える方式は、SONG ↔ SLOT のような行き来で、元の画面が分からなくなる。
- ヘルプの行(各画面の下)に、移動のキーを出すかどうか。
