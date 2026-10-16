# WordCraft · GridCraft · DeckCraft → Claude Code / Codex MCP 설치 스크립트 (Windows)

`install-craft-mcp.cmd` 하나로 아래를 모두 처리합니다. 더블클릭하고 **관리자 권한 창(UAC)에서 "예"를 한 번** 누르면 됩니다.

1. CPU/OS 아키텍처(x64 · arm64 · x86)와 기존 설치 여부 확인
2. `storytold/wordcraft`, `storytold/gridcraft`, `storytold/deckcraft`의 **최신 GitHub Release**에서 맞는 `.msi`를 받아
   `SHA256SUMS.txt`와 코드 서명을 확인한 뒤 설치 (같은 버전이 이미 있으면 건너뜀)
3. 설치된 `*-cli.exe` 경로 확인 (기본: `C:\Program Files\<앱>\<앱>-cli.exe`), MCP 실행 방식은 `<앱>-cli.exe mcp` (stdio)
4. 등록 전에 `%USERPROFILE%\.claude.json`, `%USERPROFILE%\.codex\config.toml`을 `*.bak-<시각>`으로 백업하고,
   - Claude Code: `claude mcp add --scope user <앱> -- <cli 경로> mcp`
   - Codex: `codex mcp add <앱> -- <cli 경로> mcp` (Codex CLI가 없으면 `config.toml`의 해당 `[mcp_servers.<앱>]` 블록만 편집)
   - 다른 MCP 서버 항목은 건드리지 않습니다. 같은 이름 항목이 다른 경로를 가리킬 때만 그 항목을 교체합니다.
5. 검증
   - 각 CLI에 MCP `initialize` → `tools/list` 핸드셰이크를 직접 보내 도구 목록 확인
   - `claude mcp list`에서 `Connected` 확인, `codex mcp list` 출력 기록
   - `문서\Craft-MCP-Test`에 `wordcraft-test.docx`, `gridcraft-test.xlsx`(B4 = SUM → 4600), `deckcraft-test.pptx`를 만들고 내용을 다시 읽어 확인

결과는 바탕화면의 `craft-setup-log-<시각>.txt`에 저장됩니다. `[FAIL]`이 하나라도 있으면 "완료되지 않았습니다"로 끝나고 원인(MSI 종료 코드, MSI 로그 줄 등)을 함께 기록합니다.

## 직접 눌러야 하는 것

- 브라우저 다운로드 경고가 뜨면 **유지**
- "Windows의 PC 보호" 창이 뜨면 **추가 정보 → 실행**
- **사용자 계정 컨트롤** 창에서 **예** (한 번)
- 끝나면 아무 키나 눌러 창 닫기, 그다음 Claude Code / Codex를 새로 열기
