[English](README.md) | [日本語](README-ja.md)

# DGX Spark 4台クラスタの設定: 1M文脈の1モデル、クロック上限なし

DGX Spark（GB10）4台で実際に動かしている構成を1か所にまとめました。GPUクロックの
方針、ファンカーブ、推論レシピ、消さないゴミ掃除、カーネルとドライバを凍結したまま
セキュリティ更新を当てる方法、そして2つの見張りです。数字はすべて実機で測ったもので、
データシートの写しではありません。

ファンだけ詳しく知りたい場合は、同梱の別リポジトリ
[`dgx-spark-fan-tuning`](https://github.com/tenhkspark/dgx-spark-fan-tuning)（GPL-2.0）を
読んでください。こちらは運用全体の一枚です。

## 構成

```
spark1 (head, rank 0) ─┐
spark2 (rank 1)        ├── ConnectX-7リング: 1-2-3-4-1、隣接ごとに2本
spark3 (rank 2)        │    1モデル・テンソル並列4・文脈1,048,576トークン
spark4 (rank 3) ───────┘    同時16系列・KVプール約11.3GB
```

| 項目 | 値 |
| --- | --- |
| 台数 | DGX Spark 4台（GB10・統合メモリ128GB/台） |
| カーネル | `7.0.0-1019-nvidia-64k`（64KiBページ・1M文脈に必須） |
| ドライバー | `580.178.04`（凍結。詳細は[docs/security.md](docs/security.md)） |
| エンジン | [`christopherowen/spark-ds41f`](https://github.com/christopherowen/spark-ds41f)（Apache-2.0）・TileLang |
| モデル | DeepSeek-V4.1-Flash-1017・native重み・TP4リング |
| 文脈 | 1,048,576トークン・`max_num_seqs` 16・DSpark投機5段 |
| API | `http://<head>:8000/v1`・モデル名`deepseek-v4.1-flash` |

実測（2026-10-31・レシピ付属の`bin/spark bench`・4台TP4・1M文脈・thinking off・コントロールプレーンはリングの有線）:

| 指標 | 結果 |
| --- | --- |
| Prefill（32K） | 7,990 tok/s |
| Prefill（128K） | 7,854 tok/s |
| Prefill（1M） | 5,828 tok/s |
| デコード（prose・単流） | 83.4 tok/s（デコード窓87.3） |
| デコード（code・単流） | 122.1 tok/s（デコード窓130.9） |
| 投機のトークン/ステップ | prose 2.500／code 4.339 |
| 品質ゲート | 5/5 |
| 1M prefill時の熱 | GPU72〜77°C・システム84°C・スロットル0ms |
| ファン アイドル／1M prefill | state 2〜4・3,600〜4,500rpm／state 12 |

1025との比較やeffort別の数字は[docs/results-1030.md](docs/results-1030.md)にまとめています。
以前載せていた165（構造化）・65（prose）・6,256（prefill）は、自前のrequests計測の値で、TTFT込みのためprefillを約15%低く見ていました。以後はベンチの値だけを載せます。

作者の公表値（157／75〜87／5,953）と同水準です。特別な個体ではなく、設定の問題です。

## 6つの設定（要約）

1. **クロック: 上限なし・下限2,500MHz。** 上限を掛けるとprefillが落ちます。下限は、
   軽負荷でクロックが落ちてprefillが崩れるのを防ぐため。熱はファンと電力・温度の監視で
   管理し、チップを絞って管理しません。→ [docs/clock.md](docs/clock.md)
2. **ファン: カーブを高温側へ、state 0には行かせない。** 既定はアイドルでも10,000rpm超。
   こちらは最低床state 1・全しきい値+7°C。アイドルは3,600〜4,200rpmに下がり、速度は
   変わりません。→ [docs/thermal.md](docs/thermal.md)
3. **推論: 4台で1M文脈の1モデル。** 64KiBページ・KVプール11.3GB・prefill予算16,384・
   ホスト予約3GiB/台。→ [docs/serving.md](docs/serving.md)
4. **ディスク: `rm`しない。** 古いモデル・ログ・コンテナは戻せる場所へ移すだけ。
   コンテナのログは再起動の前に外へコピー。→ [docs/disk.md](docs/disk.md)
5. **更新: セキュリティのみ、カーネルとファームは凍結。** ユーザー空間のセキュリティ修正は
   毎日自動。カーネル・NVIDIA・CUDA・Docker・ファーム系はブラックリストで止めます。
   → [docs/security.md](docs/security.md)
6. **見張り: 熱とAPIの2つ。** 熱はACPI・GPU温度とファン停止、APIは別ノードに確認してから
   再起動。→ [docs/watchdogs.md](docs/watchdogs.md)

## 使い方

```sh
git clone https://github.com/tenhkspark/dgx-spark-tuning
cd dgx-spark-tuning

# 1. クロック下限（各台・まずはdry-run）
sudo ./scripts/clock-floor.sh --apply

# 2. ファンカーブ（各台・上流のコントローラを入れてから）
sudo ./scripts/fan-curve.sh --apply

# 3. 見張り（全台に届く機械から）
cp configs/nodes.example.txt configs/nodes.txt   # ホストを書く
./scripts/thermal-watch.sh --check
./scripts/api-watchdog.sh --check
```

どのスクリプトも、何を変えるかを表示し、`--apply`が無い限り何も変えません。

## 触る前に読むこと

- **ファームは上げない。** 2026年10月版（EC 3.13.7／SoC 2.158.15／PD 5.25）はファン制御を
  壊し、上限が約4,350rpmに落ちます。3経路とも凍結済み。→ [docs/security.md](docs/security.md)
- **0RPMの罠:** ファンのモジュールだけ入れてデーモンを動かさないと、両ファンが0rpmに
  なり得ます。SoCが約96°Cへ上がり、GPUが611MHzにクランプ。`nvidia-smi`は使用率96%・
  8〜11Wと表示したままです。復旧は再起動ではなく電源ケーブルを30秒抜くこと。実測の記録は
  ファン側のリポジトリにあります。
- **ベンチ用の装置は置いていません。** 数字は実仕事と小さな閉ループの負荷生成で取っています。

## 対応範囲

上のカーネルとドライバーで動くDGX Spark 4台のみで確認しています。ファンカーブは
`dgx_ec_fan_control`モジュールと別リポジトリのデーモンが前提、クロック下限は
`nvidia-smi`だけで動きます。1台構成でもクロック・ディスク・更新・見張りはそのまま使え、
TP4の推論の節だけ読み飛ばせます。

## クレジットとライセンス

- ファン制御: [`christopherowen/dgx-spark-fan-control`](https://github.com/christopherowen/dgx-spark-fan-control)（GPL-2.0）。コードは同梱せず、数値と適用スクリプトだけを置いています。
- 推論エンジン: [`christopherowen/spark-ds41f`](https://github.com/christopherowen/spark-ds41f)（Apache-2.0）。設定だけを置いています。
- モデル: DeepSeek-V4.1-Flash-1017（各自のライセンスに従ってください）。

このリポジトリはMIT（[LICENSE](LICENSE)）。ファンカーブは手元のGPL-2.0ファイルに
適用する形なので、パッチ自体は再配布していません。
