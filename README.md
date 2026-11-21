# Talaria

서버에서 돌아가는 Hermes Agent를 iMessage로 쓰기 위한 개인용 프로젝트예요. 나 혼자만 쓸 수 있게 만들어요.

```
[내 iPhone] ─iMessage─▶ [Mac: Messages.app (봇 Apple ID)]
                              │ chat.db 읽기 / AppleScript 전송
                         [bridge/ talaria-bridge]  ← Swift
                              │ Tailscale + 토큰 (HTTP 롱 폴링)
                         [서버: Hermes + Talaria 플러그인]  ← Python
```

- [`bridge/`](bridge/README.md): Mac에서 도는 브리지예요. 빌드, 설치, 테스트 방법이 이 안에 있어요.
- [`hermes-plugin/`](hermes-plugin/README.md): 서버의 Hermes 플랫폼 플러그인이에요. 설치 방법이 이 안에 있어요.
