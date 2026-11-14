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
              SONG
               ↑  START+↑ (PLAY / PATCH / KEYBOARD / SEQ から)
PLAY ↔ PATCH ↔ KEYBOARD      横の並び(START+←→。端で止まる)
               ↓  START+↓ (PLAY / PATCH / KEYBOARD / SONG から)
              SEQ
               ↓  START+↓
              SLOT
```

| 操作 | 動き |
|---|---|
| START+← / → | **PLAY ↔ PATCH ↔ KEYBOARD** の順に、前後の画面へ(SEQ は飛ばす)。端で止まる。**SLOT、WAVE からは効かない**。SEQ からは、**来る前にいた、横の並びの画面へ戻る**(`wScreenHome`)。SONG では LOOP / SONG の切り替え |
| START+↑ | PLAY・PATCH・KEYBOARD・SEQ から **SONG** を開く |
| START+↓ | PLAY・PATCH・KEYBOARD・SONG から **SEQ** へ。**すでに SEQ にいるときは、SLOT を開く** |
| SLOT で START+↑ | SEQ へ戻る(SLOT は SEQ からしか開けない) |
| PATCH で CH3 の WAVE を選んで START+A | **WAVE** を開く |
| WAVE で START+B | 戻る |

SLOT で START+↓ は、何もしない。KEYBOARD 画面は、パッドをデータとして読むので、START+← の処理が `ReadJoy`(`joy.asm`)の中にあり、PATCH へ戻る。

## 変更の記録
- 2026-11-15(M27 の最初の一歩): START+↓ を、「PLAY・PATCH・SEQ・KBD から SLOT」から「どの画面からでも SEQ、SEQ からは SLOT」に変えた。SONG の START+↓ は「開く前の画面へ戻る」から「SEQ へ」に変えた。**SEQ を、START+←→ の並びから外した**(PLAY ↔ PATCH ↔ KEYBOARD の 3 つ。SEQ で START+←→ は、来る前の画面へ戻る)。KEYBOARD の START+← は、SEQ ではなく PATCH へ戻る。スロット画面の置き場所は暫定。

## 見直しのときに考えること(メモ)
- 4 つの主な画面(PLAY・EDIT・SEQ・KBD)を、START+←→ で順に回る形は、画面が増えるほど遠くなる。SEQ と SONG は、よく行き来するので、近くに置きたい。
- SLOT の使い道は、保存・読み込み(SELECT+B / SELECT+A で、画面を開かずにできる)と、新規・複製・削除・名前の変更。開く回数は少ないので、深い場所でもよい。
- 戻り先を 1 つだけ覚える方式は、SONG ↔ SLOT のような行き来で、元の画面が分からなくなる。
- ヘルプの行(各画面の下)に、移動のキーを出すかどうか。
