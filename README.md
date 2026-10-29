# HongMix — Apple Silicon 네이티브 라이브 스위처

macOS 14 이상, Apple Silicon(M1~M4)에서 네이티브로 도는 라이브 프로덕션 스위처입니다. 화면 배치·단축키·제어 API를 vMix 운영 방식과 공개 API 문서에 맞췄고, 엔진(Metal · VideoToolbox · CoreAudio · AVFoundation)은 Mac용으로 새로 작성했습니다. vMix의 바이너리·코드·로고·아이콘은 쓰지 않았습니다.

만든 사람: 홍승훈 (Hong Seunghoon)

> **베타입니다. 써 보시고 의견을 주세요!** 불편한 점·안 되는 점·있었으면 하는 기능을 [Issues](https://github.com/HongMix/HongMix/issues)에 남겨 주시면 계속 고쳐 나가겠습니다. (메일 주소는 스팸 방지를 위해 공개하지 않습니다.)

**⬇️ 다운로드: [최신 릴리스 (HongMix-1.2.pkg)](https://github.com/HongMix/HongMix/releases/latest)**

A native Apple Silicon live production switcher with a vMix-style layout and a vMix-compatible control API (HTTP 8088 / TCP 8099). English manual: `docs/HongMix-Manual-EN.txt`.

## 주요 기능

| 구분 | 내용 |
|---|---|
| 입력 | 카메라·캡처 장치, SRT(리스너/콜러/랑데부), RTMP 수신, URL, 미디어 파일(재생 바·마크 인/아웃), **리스트 입력**, NDI®, DeckLink, 컬러/투명, 이미지, 타이틀 템플릿 24종, 화면 캡처, 웹 브라우저(Chromium), 오디오 장치 |
| 스위칭 | Cut, 전환 4슬롯, T-Bar, 스팅어, 오버레이 4채널, FTB, **트리거**, 런다운(큐시트), 스케줄 |
| 합성 | Metal GPU 합성, 레이어(4·9·16분할, PIP), 드래그로 위치 조정, 색보정, 크로마키, **3D LUT(.cube)** |
| 오디오 | 버스 M + A~G, EQ·컴프·게이트·딜레이, **자동 더킹**, EBU R128 LUFS, 헤드폰 모니터 |
| 출력 | RTMP/SRT 송출(**이중 경로**, **리턴 피드**), 녹화(H.264/HEVC/ProRes, **멀티트랙 오디오**), 방송 딜레이 + DUMP, MultiCorder, NDI 출력, DeckLink 출력, 풀스크린 |
| 모니터링 | 통계·상태판(SRT 링크 신호등), 블랙박스(사고 기록), **스코프**(웨이브폼·퍼레이드·벡터스코프·히스토그램), 실시간 자막(CC) |
| 제어 | vMix 호환 API: `http://맥IP:8088/api/?Function=Cut`, TCP 8099 — Bitfocus Companion vMix 모듈, Stream Deck 그대로 사용 |
| 언어 | 한국어 / English (설정에서 즉시 전환) |

자세한 사용법: `docs/HongMix-설명서.txt` (한국어), `docs/HongMix-Manual-EN.txt` (English).

## 빌드 (Mac, Command Line Tools만 있으면 됨)

```bash
xcode-select --install                 # Command Line Tools
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
./scripts/build-ffmpeg-lgpl.sh         # LGPL FFmpeg → build/ffmpeg-lgpl (한 번만, 5~10분)
./scripts/build-cli.sh                 # → build/cli/BraceletMix.app
./scripts/make-dmg.sh                  # → build/dist/HongMix-<버전>.dmg / .pkg
```

선택 SDK (없으면 그 기능만 빠진 채로 빌드됩니다):
- **NDI**: [NDI SDK for Apple](https://ndi.video/for-developers/ndi-sdk/)을 설치합니다. 설치 시 NDI SDK 라이선스에 직접 동의해야 합니다. SDK 파일은 이 저장소에 포함하지 않습니다.
- **DeckLink**: `ThirdParty/DeckLinkSDK/README.md`를 따라 Blackmagic SDK 헤더를 복사합니다(재배포 불가라 저장소에 없음).
- **웹 브라우저 입력**: Chromium Embedded Framework(CEF) 빌드가 있으면 포함됩니다.

GitHub Actions(`.github/workflows/build-dmg.yml`)로도 빌드할 수 있습니다.

> 설치 파일은 ad-hoc 서명이라 처음 실행할 때 macOS가 한 번 확인합니다(앱 우클릭 → 열기). Apple Developer ID가 있으면 `SIGN_ID="Developer ID Application: …" ./scripts/make-dmg.sh`로 서명한 뒤 `xcrun notarytool`로 공증하면 경고 없이 열립니다.

## 구조

```
Sources/
  Core/      C 미디어 코어 (FFmpeg 입력·출력, SRT, NDI, DeckLink)
  Shaders/   Mixer.metal — 합성·전환·레이어·LUT
  App/       Swift 엔진(Engine/)과 SwiftUI 화면(UI/)
Resources/   Info.plist, 아이콘, en.json(영어 번역)
docs/        설명서(한/영), THIRD-PARTY-NOTICES.txt
scripts/     빌드·배포 스크립트
```

## 원격 제어 보안

vMix처럼 HTTP 8088 / TCP 8099로 원격 제어가 열립니다. 설정 › 네트워크 › **원격 제어 보안**에서 다음을 정할 수 있습니다.

- 허용 범위: 같은 네트워크 / 이 맥에서만 / 끄기
- 허용할 IP 목록
- 웹·HTTP 비밀번호

다른 웹사이트가 운영자의 브라우저를 통해 명령을 보내는 요청(cross-site)은 항상 차단됩니다. 방송망이 아닌 공용 네트워크에서는 "이 맥에서만"이나 비밀번호를 쓰세요.

## 라이선스와 고지

- 서드파티 구성요소 고지: `docs/THIRD-PARTY-NOTICES.txt`
- **FFmpeg**는 GPL 부품 없이 LGPL로 빌드해 동적 링크합니다(`scripts/build-ffmpeg-lgpl.sh`). 인코딩은 macOS VideoToolbox 하드웨어 인코더를 씁니다.
- NDI® is a registered trademark of Vizrt NDI AB. HongMix is not a product of NDI.
- DeckLink is a trademark of Blackmagic Design Pty Ltd.
- vMix is a trademark of StudioCoast Pty Ltd. HongMix is independent and not affiliated with or endorsed by StudioCoast; "vMix" is mentioned only to describe API compatibility.
