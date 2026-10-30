[English](README.md) | [日本語](README-ja.md) | [简体中文](README-zh.md) | [한국어](README-ko.md)

# DGX Spark 集群调优：4 台节点、一个 100 万 token 模型、不设时钟上限

四台 DGX Spark（GB10）集群实际在跑什么，集中在这里：GPU 时钟策略、风扇曲线、推理配方、
不删任何东西的磁盘清理、在内核与驱动冻结的前提下打安全补丁，以及两个让它活着的看门狗。
下面每个数字都在这四台机器上实测，不是从数据手册抄来的。

如果你只关心风扇曲线，深入内容在同系列仓库
[`dgx-spark-fan-tuning`](https://github.com/tenhkspark/dgx-spark-fan-tuning)（GPL-2.0，
因为它给一个 GPL 控制器打补丁）。本仓库是完整的运行全景。

## 配置

```
spark1 (head, rank 0) ─┐
spark2 (rank 1)        ├── ConnectX-7 环形：1-2-3-4-1，每个邻居两条链路
spark3 (rank 2)        │    单模型、张量并行 4、上下文 1,048,576 token
spark4 (rank 3) ───────┘    16 路并发、KV 池约 11.3 GB
```

| 项目 | 值 |
| --- | --- |
| 节点 | 4 × DGX Spark，GB10，每台 128 GB 统一内存 |
| 内核 | `7.0.0-1019-nvidia-64k`（64 KiB 页，1M 上下文必需） |
| 驱动 | `580.178.04`（冻结；见[安全](docs/security.md)） |
| 引擎 | [`christopherowen/spark-ds41f`](https://github.com/christopherowen/spark-ds41f)（Apache-2.0），TileLang 后端 |
| 模型 | DeepSeek-V4.1-Flash-1017，原生权重，TP4 环形 |
| 上下文 | 1,048,576 token，`max_num_seqs` 16，DSpark 投机 5 草稿 |
| API | `http://<head>:8000/v1`，模型名 `deepseek-v4.1-flash` |

使用配方自带的 `bin/spark bench` 实测，spark-ds41f-1030，2026-10-30
（四节点、TP4 环形、1M 上下文、关闭思考、控制平面走环形有线链路）：

| 指标 | 结果 |
| --- | --- |
| 预填充，32K 提示 | 7,990 tok/s |
| 预填充，128K 提示 | 7,854 tok/s |
| 预填充，1M 提示 | 5,828 tok/s |
| 解码，散文，单流 | 83.4 tok/s（解码窗口内 87.3） |
| 解码，代码，单流 | 122.1 tok/s（解码窗口内 130.9） |
| 每投机步 token 数 | 散文 2.500 / 代码 4.339 |
| 质量门 | 5/5 |
| 1M 预填充时的 GPU 温度 | 72–77 °C，系统 84 °C，降频 0 ms |
| 风扇，空闲 / 1M 预填充 | 状态 2–4，3,600–4,500 rpm / 状态 12 |

完整数据（含与 1025 的对比和不同 effort 的运行）在
[docs/results-1030.md](docs/results-1030.md)。

空闲数据是在没有请求在途时测的；2,500 MHz 的下限会让静置温度高几度。

早期那组请求循环的数字（结构化 165 / 散文 65 / 预填充 6,256）是用手写客户端测的，偏低：
请求循环把首 token 时间算进了预填充，会把预填充低估约 15%。现在只引用配方的基准。

## 七项设置，简要

1. **时钟：不设上限，只设 2,500 MHz 下限。** 我们不给 GPU 时钟封顶。封顶用预填充速度换几度
   温度；下限则防止轻载时时钟掉下去、把预填充一起拖慢。热由风扇和功率、温度监控来管，
   不是靠饿着芯片。→ [docs/clock.md](docs/clock.md)
2. **风扇：曲线往高温侧移，绝不到状态 0。** 原厂曲线空闲也要 10,000+ rpm。我们把状态 1 作为
   最低床，所有阈值 +7 °C。空闲降到 3,600–4,200 rpm，每秒 token 数不变。
   → [docs/thermal.md](docs/thermal.md)
3. **推理：一个 1M 上下文模型跑在四台节点上。** 64 KiB 页、11.3 GB KV 池、16,384 token 的
   预填充预算，以及每节点 3 GiB 的主机预留，好让池子放得下。
   → [docs/serving.md](docs/serving.md) · [实测结果](docs/results-1030.md)
4. **网络：控制平面不要放 Wi-Fi。** 每个引擎步都要走几包控制流量，走无线会让单流解码掉 16.8%。
   环形路由及其持久化在 [docs/network.md](docs/network.md)。
5. **磁盘：只移动，不 `rm`。** 旧模型、日志、容器都移到回收站目录并带还原路径；容器日志在
   任何重启之前先复制出来。→ [docs/disk.md](docs/disk.md)
6. **补丁：只打安全更新，内核与固件冻结。** 用户空间的安全修复每天自动安装，黑名单挡掉内核、
   NVIDIA、CUDA、Docker 以及所有固件路径。→ [docs/security.md](docs/security.md)
7. **看门狗：一个看热，一个看 API。** 热看门狗在 ACPI 或 GPU 温度超线、风扇停转时告警；
   API 看门狗在重启任何东西之前先问第二个节点。→ [docs/watchdogs.md](docs/watchdogs.md)

## 快速开始

```sh
git clone https://github.com/tenhkspark/dgx-spark-tuning
cd dgx-spark-tuning

# 1. 时钟下限（每节点，先 dry-run）
sudo ./scripts/clock-floor.sh --apply

# 2. 风扇曲线（每节点；需先安装上游控制器）
sudo ./scripts/fan-curve.sh --apply

# 3. 看门狗（从能连到所有节点的机器上跑）
cp configs/nodes.example.txt configs/nodes.txt   # 改成你的主机
./scripts/thermal-watch.sh --check
./scripts/api-watchdog.sh --check
```

每个脚本都会先打印将要改什么，没有 `--apply` 就什么都不改。

## 动手之前请读

- **固件：不要升级。** 2026 年 10 月那版（EC 3.13.7 / SoC 2.158.15 / PD 5.25）会破坏风扇控制：
  风扇上限掉到约 4,350 rpm，机器会过热。我们把三条升级路径都冻住了。
  见 [docs/security.md](docs/security.md)。
- **0 RPM 陷阱：** 只装风扇模块、不跑守护进程，可能让两个风扇停在 0 rpm。SoC 随后升到约
  96 °C，GPU 被钳到 611 MHz，而 `nvidia-smi` 仍然显示约 96% 利用率。恢复要拔电源线等 30 秒，
  重启没用。细节和实测事故在风扇仓库里。
- **本仓库不含基准测试装置。** 数字来自实际工作和一个小型闭环负载生成器；我们不在生产上
  常驻跑分设备。

## 兼容性

只在四台 DGX Spark 上验证过，系统为 DGX OS，内核与驱动如上。风扇曲线需要
`dgx_ec_fan_control` 模块和同系列仓库里的守护进程；时钟下限只要 `nvidia-smi`。单节点集群
可以原样使用时钟、磁盘、安全和看门狗部分，跳过 TP4 推理那一节。

## 致谢与许可

- 风扇控制器：[`christopherowen/dgx-spark-fan-control`](https://github.com/christopherowen/dgx-spark-fan-control)（GPL-2.0）。我们发布数值和打补丁脚本，不发布他们的代码。
- 推理引擎：[`christopherowen/spark-ds41f`](https://github.com/christopherowen/spark-ds41f)（Apache-2.0）。我们发布配置，不发布他们的代码。
- 模型：DeepSeek-V4.1-Flash-1017，按其自身许可使用。

本仓库全部为 MIT（见 [LICENSE](LICENSE)）。风扇曲线是应用到你机器上的 GPL-2.0 文件，
所以补丁本身不在这里再分发。
