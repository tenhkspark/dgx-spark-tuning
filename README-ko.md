[English](README.md) | [日本語](README-ja.md) | [简体中文](README-zh.md) | [한국어](README-ko.md)

# DGX Spark 클러스터 튜닝: 4대, 100만 토큰 모델 하나, 클럭 상한 없음

4대 DGX Spark(GB10) 클러스터가 실제로 무엇을 돌리는지 한곳에 모았습니다. GPU 클럭 정책,
팬 커브, 서빙 레시피, 아무것도 지우지 않는 디스크 정리, 커널과 드라이버를 동결한 채 보안
패치를 적용하는 방법, 그리고 클러스터를 살려 두는 워치독 두 개입니다. 아래 숫자는 모두 이
4대에서 측정한 것이며 데이터시트에서 옮긴 값이 아닙니다.

팬 커브만 궁금하다면 자매 저장소
[`dgx-spark-fan-tuning`](https://github.com/tenhkspark/dgx-spark-fan-tuning)에 깊은 내용이
있습니다(GPL-2.0, GPL 컨트롤러에 패치를 적용하기 때문). 이 저장소는 운영 전체 그림입니다.

## 구성

```
spark1 (head, rank 0) ─┐
spark2 (rank 1)        ├── ConnectX-7 링: 1-2-3-4-1, 이웃마다 두 개 경로
spark3 (rank 2)        │    모델 하나, 텐서 병렬 4, 컨텍스트 1,048,576 토큰
spark4 (rank 3) ───────┘    동시 16 시퀀스, KV 풀 약 11.3 GB
```

| 항목 | 값 |
| --- | --- |
| 노드 | 4 × DGX Spark, GB10, 노드당 128 GB 통합 메모리 |
| 커널 | `7.0.0-1019-nvidia-64k` (64 KiB 페이지, 1M 컨텍스트에 필요) |
| 드라이버 | `580.178.04` (동결, [보안](docs/security.md) 참고) |
| 엔진 | [`christopherowen/spark-ds41f`](https://github.com/christopherowen/spark-ds41f) (Apache-2.0), TileLang 백엔드 |
| 모델 | DeepSeek-V4.1-Flash-1017, 네이티브 가중치, TP4 링 |
| 컨텍스트 | 1,048,576 토큰, `max_num_seqs` 16, DSpark 투기 5 드래프트 |
| API | `http://<head>:8000/v1`, 모델 이름 `deepseek-v4.1-flash` |

레시피에 포함된 `bin/spark bench`로 측정, spark-ds41f-1030, 2026-10-30
(4노드, TP4 링, 1M 컨텍스트, 사고 끔, 컨트롤 플레인은 링의 유선 링크):

| 지표 | 결과 |
| --- | --- |
| 프리필, 32K 프롬프트 | 7,990 tok/s |
| 프리필, 128K 프롬프트 | 7,854 tok/s |
| 프리필, 1M 프롬프트 | 5,828 tok/s |
| 디코드, 산문, 단일 스트림 | 83.4 tok/s (디코드 윈도 내 87.3) |
| 디코드, 코드, 단일 스트림 | 122.1 tok/s (디코드 윈도 내 130.9) |
| 투기 단계당 토큰 | 산문 2.500 / 코드 4.339 |
| 품질 게이트 | 5/5 |
| 1M 프리필 시 GPU 온도 | 72–77 °C, 시스템 84 °C, 스로틀 0 ms |
| 팬, 아이들 / 1M 프리필 | 상태 2–4, 3,600–4,500 rpm / 상태 12 |

전체 데이터(1025 비교와 effort별 실행 포함)는
[docs/results-1030.md](docs/results-1030.md)에 있습니다.

아이들 값은 요청이 없는 상태에서 측정했습니다. 2,500 MHz 하한은 정지 상태 온도를 몇 도
올립니다.

초기에 쓴 요청 루프 숫자(구조화 165 / 산문 65 / 프리필 6,256)는 직접 만든 클라이언트로
측정해 낮게 나왔습니다. 요청 루프는 첫 토큰 시간을 프리필에 포함하므로 프리필을 약 15%
과소평가합니다. 지금은 레시피 벤치마크 값만 인용합니다.

## 일곱 가지 설정, 요약

1. **클럭: 상한 없음, 2,500 MHz 하한.** GPU 클럭에 상한을 두지 않습니다. 상한은 프리필
   속도를 몇 도의 온도로 바꾸고, 하한은 가벼운 부하에서 클럭이 떨어져 프리필을 끌어내리는
   것을 막습니다. 열은 팬과 전력·온도 감시로 관리하며, 칩을 굶겨서 관리하지 않습니다.
   → [docs/clock.md](docs/clock.md)
2. **팬: 커브를 고온 쪽으로 옮기고 상태 0에는 절대 가지 않기.** 기본 커브는 아이들에서도
   10,000 rpm 이상 돕니다. 우리는 상태 1을 바닥으로 두고 모든 임계값을 +7 °C 옮겼습니다.
   아이들은 3,600–4,200 rpm으로 내려가고 초당 토큰 수는 그대로입니다.
   → [docs/thermal.md](docs/thermal.md)
3. **서빙: 1M 컨텍스트 모델 하나를 4대에.** 64 KiB 페이지, 11.3 GB KV 풀, 16,384 토큰
   프리필 예산, 그리고 풀이 들어가도록 노드당 3 GiB 호스트 예약.
   → [docs/serving.md](docs/serving.md) · [측정 결과](docs/results-1030.md)
4. **네트워크: 컨트롤 플레인을 Wi-Fi에 두지 않기.** 엔진 단계마다 오가는 몇 개의 패킷이
   무선이면 단일 스트림 디코드의 16.8%를 잡아먹습니다. 링 경로와 영구화는
   [docs/network.md](docs/network.md).
5. **디스크: 옮기기만 하고 `rm`은 하지 않기.** 오래된 모델, 로그, 컨테이너는 복원 경로와 함께
   휴지통 디렉터리로 보냅니다. 컨테이너 로그는 재시작 전에 먼저 복사합니다.
   → [docs/disk.md](docs/disk.md)
6. **패치: 보안 업데이트만, 커널과 펌웨어는 동결.** 사용자 공간 보안 수정은 매일 자동으로
   설치하고, 블랙리스트로 커널·NVIDIA·CUDA·Docker·모든 펌웨어 경로를 막습니다.
   → [docs/security.md](docs/security.md)
7. **워치독: 열용 하나, API용 하나.** 열 워치독은 ACPI나 GPU 온도 초과, 팬 정지에 경보하고,
   API 워치독은 무엇이든 재시작하기 전에 다른 노드에 먼저 묻습니다.
   → [docs/watchdogs.md](docs/watchdogs.md)

## 빠른 시작

```sh
git clone https://github.com/tenhkspark/dgx-spark-tuning
cd dgx-spark-tuning

# 1. 클럭 하한 (노드마다, 먼저 dry-run)
sudo ./scripts/clock-floor.sh --apply

# 2. 팬 커브 (노드마다, 업스트림 컨트롤러를 먼저 설치해야 함)
sudo ./scripts/fan-curve.sh --apply

# 3. 워치독 (모든 노드에 닿는 머신에서)
cp configs/nodes.example.txt configs/nodes.txt   # 호스트 수정
./scripts/thermal-watch.sh --check
./scripts/api-watchdog.sh --check
```

모든 스크립트는 무엇을 바꿀지 먼저 출력하고, `--apply` 없이는 아무것도 바꾸지 않습니다.

## 만지기 전에 읽어야 할 것

- **펌웨어: 업데이트하지 마세요.** 2026년 10월 번들(EC 3.13.7 / SoC 2.158.15 / PD 5.25)은
  팬 제어를 망가뜨립니다. 팬 상한이 약 4,350 rpm으로 떨어지고 기기가 과열됩니다. 우리는 세
  경로를 모두 동결했습니다. [docs/security.md](docs/security.md) 참고.
- **0 RPM 함정:** 팬 모듈만 올리고 데몬을 돌리지 않으면 두 팬이 0 rpm에 머물 수 있습니다.
  그러면 SoC가 약 96 °C까지 오르고 GPU가 611 MHz로 클램프되며, `nvidia-smi`는 여전히 사용률
  약 96%를 표시합니다. 복구는 재부팅이 아니라 전원 케이블을 30초 빼는 것입니다. 자세한 내용과
  실측 사고 기록은 팬 저장소에 있습니다.
- **이 저장소에는 벤치마크 장치가 없습니다.** 숫자는 실제 작업과 작은 폐루프 부하 생성기에서
  나옵니다. 운영 환경에 상시 벤치 장비를 두지 않습니다.

## 호환성

위 커널과 드라이버로 도는 DGX Spark 4대에서만 검증했습니다. 팬 커브는
`dgx_ec_fan_control` 모듈과 자매 저장소의 데몬이 필요하고, 클럭 하한은 `nvidia-smi`만
있으면 됩니다. 단일 노드 클러스터는 클럭·디스크·보안·워치독 부분을 그대로 쓰고 TP4 서빙
절만 건너뛰면 됩니다.

## 크레딧과 라이선스

- 팬 컨트롤러: [`christopherowen/dgx-spark-fan-control`](https://github.com/christopherowen/dgx-spark-fan-control) (GPL-2.0). 우리는 수치와 패치 스크립트를 배포하며 그들의 코드는 배포하지 않습니다.
- 서빙 엔진: [`christopherowen/spark-ds41f`](https://github.com/christopherowen/spark-ds41f) (Apache-2.0). 우리는 설정을 배포하며 그들의 코드는 배포하지 않습니다.
- 모델: DeepSeek-V4.1-Flash-1017, 자체 라이선스에 따라 사용.

이 저장소의 모든 내용은 MIT입니다([LICENSE](LICENSE)). 팬 커브는 사용자 기기에 있는
GPL-2.0 파일에 적용하는 형식이라, 패치 자체는 여기서 재배포하지 않습니다.
