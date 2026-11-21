# Talaria Hermes plugin

Talaria 브리지(Mac)와 서버의 Hermes Agent를 연결하는 플랫폼 플러그인이에요.

- **받기:** 브리지의 `/events`를 롱 폴링해서 메시지를 Hermes에 넘겨요.
- **보내기:** Hermes의 답장을 `/send`로 보내요.

추가로 설치할 패키지는 없어요. Hermes에 이미 들어 있는 `httpx`만 써요.

## 서버에 설치하기

1. **GitHub에서 플러그인을 설치해요.** 서버에서 실행해요. 저장소 안의 `hermes-plugin/talaria` 폴더만 `~/.hermes/plugins/talaria`에 설치돼요.
   ```bash
   hermes plugins install luvxxxu/Talaria/hermes-plugin/talaria
   ```
   나중에 업데이트할 때는 `hermes plugins update talaria`를 실행하고 gateway를 다시 시작해요.
2. **서버의 `~/.hermes/.env`에 설정을 추가해요.**
   ```bash
   TALARIA_BRIDGE_URL=http://<Mac의 Tailscale IP>:8790
   TALARIA_BRIDGE_TOKEN=<Mac bridge.env의 TALARIA_TOKEN>
   TALARIA_ALLOWED_USERS=+821012345678          # watch에 나온 내 주소를 그대로
   TALARIA_HOME_CHANNEL=+821012345678           # (선택) 예약 작업과 알림을 받을 곳
   ```
3. **플러그인을 켜고 gateway를 다시 시작해요.**
   ```bash
   hermes plugins enable talaria
   hermes gateway restart
   ```
4. **연결을 확인해요.**
   ```bash
   hermes logs gateway     # "Talaria: connected to bridge http://... (version 0.3.0, cursor N, typing off)"
   ```
   이 줄이 보이면 아이폰에서 봇에게 메시지를 보내 보세요. Hermes가 답장하면 끝이에요.

## 설정

| 키 | 필수 | 설명 |
|---|---|---|
| `TALARIA_BRIDGE_URL` | ✓ | 브리지 주소 |
| `TALARIA_BRIDGE_TOKEN` | ✓ | 브리지의 `TALARIA_TOKEN` 값 |
| `TALARIA_ALLOWED_USERS` | 권장 | Hermes 쪽 허용 목록이에요. 브리지 허용 목록과 같은 주소를 넣어요. 형식은 `+82…` 또는 소문자 이메일이에요 |
| `TALARIA_HOME_CHANNEL` (+`_NAME`) | | 예약 작업(`deliver=talaria`)과 알림을 받을 주소, 또는 1:1 대화 ID예요 |
| `TALARIA_MAX_AGE_SECONDS` | | Hermes가 꺼져 있던 동안 쌓인 메시지 중 이보다 오래된 건 무시해요. 기본값 600, `0`이면 제한 없음 |

`config.yaml`의 `gateway.platforms.talaria.extra`에 `bridge_url`, `bridge_token`, `max_age_seconds`로 써도 돼요. 같은 설정이 양쪽에 있으면 환경 변수가 이겨요.

## 동작 방식

- **재시작 대비:** 마지막으로 받은 위치를 `~/.hermes/talaria/state.json`에 저장해요. Hermes를 재시작하는 동안 온 메시지도 이어서 받아요.
- **Mac이 꺼졌을 때:** Mac이 잠들거나 꺼지면 대기 시간을 점점 늘려가며(최대 60초) 다시 연결을 시도해요. 연결되면 바로 정상으로 돌아와요.
- **허용 목록:** 브리지와 Hermes 양쪽에서 확인해요. 모르는 사람에게는 페어링 코드도 보내지 않아요.
- **답장 형식:** 마크다운 기호를 지우고 일반 텍스트로 보내요. 4000자가 넘는 답장은 문단 단위로 나눠서 보내요.
- **입력 중 표시:** 브리지가 `TALARIA_TYPING=ui`로 켜져 있으면, 에이전트가 일하는 동안 2초마다 `/typing`을 보내 아이폰에 `…`가 뜨게 해요.
  - 브리지의 `/health`를 보고 알아서 켜고 꺼요. 서버 쪽에서 따로 설정할 건 없어요.
  - 브리지 설정을 바꿨다면 브리지가 재시작된 뒤 다시 연결될 때 반영돼요.
  - 자세한 내용은 [브리지 README](../bridge/README.md#입력-중-표시-선택-실험적)에 있어요.
- **아직 안 되는 것:**
  - 사진과 파일은 아직 주고받을 수 없어요. 받은 첨부는 파일 이름만 Hermes에 알려줘요.
  - 읽음 표시는 지원하지 않아요.

## 테스트

```bash
cd hermes-plugin/tests
python -m unittest test_adapter                                   # 가짜 브리지로 하는 단위 테스트 (httpx 필요)
HERMES_SRC=/path/to/hermes-agent python -m unittest test_hermes_compat         # 실제 Hermes 소스와의 API 호환성 확인
TALARIA_BRIDGE_BIN=../../bridge/.build/release/talaria-bridge python -m unittest test_bridge_e2e   # 실제 브리지 실행 파일로 확인
```

`tests/stubs/gateway`는 Hermes의 `gateway` 패키지 중 플러그인이 쓰는 부분만 흉내 낸 가짜예요. 실제 Hermes와 어긋나지 않았는지는 `test_hermes_compat`이 Hermes 소스를 직접 분석해서 확인해요.
