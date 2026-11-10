# chromatic-mcu のライセンス: GPL-3.0

このディレクトリの `patches/` は、ModRetro の MCU ファームウェア
([oss-chromatic-console-mcu](https://github.com/ModRetro/oss-chromatic-console-mcu)、`v4.6`)に対するパッチで、その派生物です。
元のファームウェアは **GNU General Public License v3.0** で公開されているので、**パッチと、ビルドで一緒にリンクされる `src/`(`chlink_*.c` / `.h`)も、GPL-3.0 の下で配布します。**
ライセンス全文: <https://www.gnu.org/licenses/gpl-3.0.txt>(全文は、このディレクトリの `LICENSE`)。

- 元のファームウェアのソースと、ビルド済みのバイナリは、このリポジトリに含めません(`build.sh` が元のソースを取得してパッチを当てる)。
- ビルドしたファームウェアを配布するときは、GPL-3.0 に従って、対応するソース(元のソース + このパッチ + `src/`)を、同じ版で入手できるようにしてください。
- リポジトリのほかの部分(ROM、`tools/`、`firmware/`、`docs/`)は、ルートの `LICENSE`(MIT)です。
