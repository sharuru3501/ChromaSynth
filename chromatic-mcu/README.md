# chromatic-mcu — ChromaSynth の本体内蔵 ESP32 用パッチ

ModRetro の MCU ファームウェア([oss-chromatic-console-mcu](https://github.com/ModRetro/oss-chromatic-console-mcu) の `v4.6`、**GPL-3.0**)に対する**パッチだけ**を置く。純正のソースはここに入れない(`build.sh` が取得して、パッチを当てる)。パッチは GPL-3.0 の派生物。

| ファイル | 内容 |
|----------|------|
| `patches/0001-chlink-test-commands.patch` | 試験用 v0: コンソールを USB(UART0)に出し、`chver` / `sym <hex>`(FPGA のボタンレジスタを直接書く)/ `gpd [回数 [ms]]`(ゲームのパレットデータを読んで表示)を足す。純正のパレット処理は、`gpd` を要求したときだけ迂回する |
| `build.sh` | v4.6 を取得 → パッチを当てる → ESP-IDF v5.3 でビルド。**書き込みはしない** |

書き込みの安全手順は [../docs/MCU_FLASH_SAFETY.md](../docs/MCU_FLASH_SAFETY.md)。**書く前に必ずバックアップと復元のリハーサルを済ませること。** 本体の版は MCU 0.13.8 / FPGA 18.14 / FW 4.6 専用。
