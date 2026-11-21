# Talaria bridge

Mac의 Messages.app을 서버의 Hermes Agent와 연결하는 작은 HTTP 브리지예요. Swift로 만든 실행 파일 하나로 동작해요.

- **받기:** `~/Library/Messages/chat.db`를 1초마다 읽기 전용으로 확인해요. 본문만 `attributedBody`에 들어 있는 메시지는 애플의 해석기(`NSUnarchiver`)로 풀고, 실패하면 바이트 단위로 다시 해석해요.
- **보내기:** 프로그램 안에서 AppleScript 핸들러를 직접 호출해요. 메시지 내용은 스크립트 코드에 끼워 넣지 않고 인자로만 넘겨요.
- **보안:**
  - 허용 목록(`TALARIA_ALLOWED_HANDLES`)에 있는 주소와의 1:1 대화만 받고 보내요.
  - 모든 요청에 토큰이 필요해요.
  - Tailscale IP에서만 접속을 받도록 설정해요.

## 1. 빌드와 설치 (내 macOS 계정에서)

Xcode 또는 Command Line Tools가 설치되어 있어야 해요(Swift 6).

```bash
git clone https://github.com/luvxxxu/Talaria.git
cd Talaria/bridge
scripts/install.sh            # 결과물: /Users/Shared/talaria/bin/talaria-bridge
```

다시 빌드할 때마다 macOS가 이 프로그램에 준 권한(전체 디스크 접근, 자동화)을 잊어요. 키체인 접근에서 만든 자체 서명 "코드 서명" 인증서로 서명하면 권한이 유지돼요.
`TALARIA_SIGN_IDENTITY="인증서 이름" scripts/install.sh`

## 2. 봇 계정(`talaria`)에서 처음 설정하기

빠른 사용자 전환으로 `talaria`에 로그인한 뒤 터미널을 열고 진행해요.

1. **전체 디스크 접근 권한을 줘요.** 시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한에서 **터미널**을 켜고 터미널을 다시 열어요.
   이 권한은 앱 단위라서 내 계정에서 쓰는 터미널에도 같이 적용돼요. 테스트가 끝나면 꺼도 돼요.
2. **설정 파일을 만들어요.**
   ```bash
   echo 'export PATH="/Users/Shared/talaria/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
   mkdir -p ~/.config/talaria
   cp /Users/Shared/talaria/bridge.env.example ~/.config/talaria/bridge.env
   chmod 600 ~/.config/talaria/bridge.env
   talaria-bridge gen-token      # 출력된 값을 TALARIA_TOKEN에 붙여넣기
   open -e ~/.config/talaria/bridge.env
   ```
3. **상태를 점검해요.** 처음 실행하면 "터미널이 Messages를 제어하려고 합니다" 창이 떠요. 허용하세요.
   ```bash
   talaria-bridge check
   ```
   `chat.db : readable`과 `Messages : 1 iMessage account(s)`가 나오면 성공이에요.

## 3. 단계별로 테스트하기

1. **받기:**
   ```bash
   talaria-bridge watch
   ```
   - 아이폰에서 봇에게 메시지를 보내요.
   - 허용 목록이 비어 있으면 `[dropped] me@icloud.com: ...`처럼 **내 아이폰이 쓰는 주소**가 보여요. 이 주소를 `TALARIA_ALLOWED_HANDLES`에 넣고 다시 실행하면 메시지 본문이 출력돼요.
2. **보내기:**
   ```bash
   talaria-bridge send --to me@icloud.com "브리지 테스트"
   ```
   아이폰에 메시지가 도착하는지 확인해요.
3. **서버 실행:**
   - 설정 파일의 `TALARIA_HOST`를 이 Mac의 Tailscale IP(메뉴 막대 Tailscale 아이콘에서 확인)로 바꾸고 아래를 실행해요.
     ```bash
     talaria-bridge serve
     ```
   - Hermes가 있는 서버에서 확인해요. 먼저 그 서버의 셸에 토큰과 주소를 변수로 넣어요. 토큰은 Mac의 `~/.config/talaria/bridge.env`에 있는 `TALARIA_TOKEN` 값이에요.
     ```bash
     export TOKEN='bridge.env의 TALARIA_TOKEN 값'
     export BRIDGE='http://<Mac의 Tailscale IP>:8790'
     echo ${#TOKEN}               # 0이면 변수가 비어 있어요 (gen-token으로 만든 토큰은 43)
     curl -H "Authorization: Bearer $TOKEN" "$BRIDGE/health"
     curl -H "Authorization: Bearer $TOKEN" "$BRIDGE/events?timeout=30"   # 기다리는 동안 아이폰에서 메시지 보내기
     curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
          -d '{"to":"+821012345678","text":"서버에서 보냄"}' "$BRIDGE/send"     # watch에 나온 내 주소
     ```
     401이 나오면 응답의 `reason`과 브리지 로그에 원인이 나와요. 토큰이 비었는지, 틀렸는지, 헤더가 없는지 구분해서 알려줘요.

## 입력 중 표시 (선택, 실험적)

Hermes가 답을 만드는 동안 아이폰에 `…` 입력 중 표시가 뜨게 할 수 있어요. 기본값은 꺼져 있어요.

macOS에는 입력 중 표시를 띄우는 공개 API가 없어요. 그래서 브리지가 Messages에서 그 대화를 열고, 입력창에 `.` 한 글자를 대신 입력해요. 그러면 Messages가 진짜 입력 중 표시를 보내요. 답장을 보내기 직전에 그 글자를 지워요.

- **켜기:** `bridge.env`에 `TALARIA_TYPING=ui`를 넣고 `serve`를 다시 시작해요. 서버의 Hermes 플러그인은 브리지의 `/health`를 보고 자동으로 따라와요.
- **권한:** 실행하는 앱(터미널, 또는 launchd로 띄운 `talaria-bridge`)에 시스템 설정 → 개인정보 보호 및 보안 → **손쉬운 사용** 권한이 필요해요. `talaria-bridge check`로 확인할 수 있어요.
- **조건:** 봇 계정(`talaria`)이 **화면에 떠 있는 로그인 세션**이어야 하고 화면이 잠겨 있으면 안 돼요. 빠른 사용자 전환으로 백그라운드에 있는 세션에서는 동작하지 않아요.
- **영향:** 사람이 같이 쓰는 Mac에서는 쓰지 마세요. 대화를 여는 순간 Messages가 앞으로 나와요.
- **입력창 찾기:** 대화를 연 뒤 Messages 창에서 입력창을 직접 찾아요. 기준은 아래 두 가지예요.
  - 지금 Messages에서는 식별자가 `messageBodyField`인 칸이에요.
  - 그 칸이 없으면, 말풍선(`CKBalloonTextView`)을 제외하고 편집 가능한 칸 중 가장 아래에 있는 칸을 골라요.
  - 키보드 포커스가 다른 곳에 있으면 입력창으로 옮긴 뒤 입력해요.
- **안전장치:**
  - 키 입력은 Messages 프로세스에만 직접 보내요. 맨 앞에 있는 다른 앱으로 새지 않아요.
  - 직접 찾은 입력창에 포커스가 있고, 그 입력창이 비어 있거나 자기가 넣은 `.`만 있을 때만 입력하거나 지워요.
  - Return 키는 누르지 않아요.
  - Hermes 요청이 10초 동안 오지 않으면 스스로 지워요.
- **직접 확인:**
  - 아래 첫 번째 명령으로 5초 동안 아이폰에 `…`가 뜨는지 확인할 수 있어요.
  - 안 되면 두 번째 명령으로 브리지가 Messages 창에서 무엇을 보는지 확인해요. 이 명령은 아무것도 입력하지 않아요.
  ```bash
  talaria-bridge typing --to +821012345678 --seconds 5
  talaria-bridge typing --inspect --to +821012345678
  ```

화면 구조에 의존하는 방식이라 macOS 업데이트로 동작하지 않게 될 수 있어요. 안 되면 `TALARIA_TYPING=off`로 끄면 돼요. 메시지를 주고받는 기능은 영향을 받지 않아요.

## HTTP API

| 요청 | 응답 |
|---|---|
| `GET /health` | `{"ok": true, "cursor": N, "version": "0.3.0", "typing": "off"/"ui"}` |
| `GET /events?after=<id>&timeout=<초>` | `{"events": [...], "cursor": N}`. 새 메시지가 올 때까지 최대 55초 기다려요(롱 폴링). 다음 요청에는 `after=<cursor>`를 넣어요 |
| `POST /send` `{"text", "chat_guid"?, "to"?}` | `{"ok": true}`. 허용 목록에 없는 상대면 403, Messages 전송이 실패하면 502를 돌려줘요 |
| `POST /typing` `{"chat_guid"?, "to"?, "active"?}` | `{"ok": true, "enabled": true/false}`. `active: true`는 입력 중 표시를 10초 연장하고, `false`는 바로 꺼요. `TALARIA_TYPING=off`면 아무것도 하지 않고 `enabled: false`를 돌려줘요 |

모든 요청에 `Authorization: Bearer <TALARIA_TOKEN>` 헤더가 필요해요. 이벤트 하나에는 `rowid`, `guid`, `sender`, `text`, `chat_guid`, `chat_identifier`, `is_group`, `timestamp`, `service`, `attachments[{path, mime_type, name}]`가 들어 있어요.

## 설정 (`~/.config/talaria/bridge.env` 또는 환경 변수)

| 키 | 기본값 | 설명 |
|---|---|---|
| `TALARIA_TOKEN` | (필수) | 24자 이상. `talaria-bridge gen-token`으로 만들 수 있어요 |
| `TALARIA_ALLOWED_HANDLES` | (필수) | 쉼표로 구분한 이메일 또는 `+82…` 형식 번호 |
| `TALARIA_HOST` / `TALARIA_PORT` | `127.0.0.1` / `8790` | 접속을 받을 주소와 포트 |
| `TALARIA_MAX_AGE_SECONDS` | `600` | 이보다 오래된 메시지는 무시해요(`0`이면 제한 없음) |
| `TALARIA_POLL_INTERVAL` | `1` | chat.db를 확인하는 간격(초) |
| `TALARIA_TYPING` | `off` | `ui`로 바꾸면 입력 중 표시를 켜요(위 "입력 중 표시" 참고) |
| `TALARIA_DB_PATH` / `TALARIA_STATE_PATH` | Messages 기본 경로 / `~/Library/Application Support/Talaria/state.json` | chat.db 위치와 진행 상태 파일 위치 |

## 개발

```bash
swift build
swift test      # 가짜 chat.db, HTTP 서버, AppleScript 인자 전달을 테스트해요. Messages는 건드리지 않아요
```

`Tests/TalariaBridgeTests/Fixtures/*.bin`은 실제 NSArchiver 출력이에요. `scripts/generate-fixtures.swift`로 다시 만들 수 있어요.

## 아직 안 된 것

- launchd 자동 실행(Mac에 로그인하면 `serve`가 자동으로 시작되게 하는 것)
- 첨부 파일 보내기: 받은 첨부는 경로만 이벤트에 넣어줘요
- 그룹 채팅: 일부러 지원하지 않아요
