<p align="center">
  <img src="Resources/AppIcon.png" width="140" alt="HongMix 아이콘">
</p>

<h1 align="center">HongMix</h1>

<p align="center">
  <b>맥용 무료 라이브 방송·송출 스위처. M1 이후 모든 맥북 하나로 충분합니다. 윈도우 PC는 이제 필요 없습니다.</b><br>
  vMix 스타일 화면 · vMix 호환 API · SRT · RTMP · NDI® · DeckLink
</p>

<p align="center">
  <a href="https://github.com/HongMix/HongMix/releases/latest"><b>⬇️ HongMix 1.2 (베타) 다운로드</b></a>
  &nbsp;·&nbsp; <a href="README.md">English</a>
  &nbsp;·&nbsp; <a href="https://github.com/HongMix/HongMix/issues">의견 남기기</a>
</p>


<p align="center">
  <img src="docs/screenshots/hongmix-main.jpg" alt="HongMix 메인 화면: 4분할 멀티캠 + 하단 자막·LIVE 표시·티커 온에어" width="100%">
</p>
<p align="center"><sub>HongMix 메인 화면: 4분할 멀티캠 + 하단 자막·LIVE 표시·티커 온에어</sub></p>

---

## 이제 맥북이 스위처입니다.

"맥으로 라이브 방송 할 수 있어요?" 이 질문에 대한 답은 오랫동안 **"윈도우 PC 하나 사세요"**였습니다.

HongMix는 그 답을 바꾸려고 만든 프로그램입니다. Apple Silicon용으로 처음부터 새로 짠 라이브 프로덕션 스위처입니다.
- 화면은 Metal로 처리합니다.
- 인코딩은 VideoToolbox를 씁니다.
- 소리는 CoreAudio로 다룹니다.

윈도우 PC도, 가상머신도, Rosetta도 필요 없습니다.

뚜껑을 열고 카메라, SRT, NDI를 꽂으면 바로 온에어입니다.

- **프레임당 평균 1.5ms 렌더**: 1080p59.94에서 M 시리즈 맥 기준 **프레임 드롭 0**
- **설치 한 번으로 끝**: FFmpeg, SRT, NDI® 런타임, Chromium 웹 엔진이 설치 파일 하나에 다 들어 있습니다.
- **손에 익은 그대로**: vMix와 같은 화면 구성·단축키·HTTP/TCP API를 씁니다. 그래서 Companion이나 Stream Deck을 그대로 연결할 수 있습니다.

## 만든 이유

안녕하세요. 한국에서 조그맣게 방송 기술을 하고 있는 **홍승훈**입니다. 라이브 프로덕션과 SRT·LiveU 원격 송출, 그리고 그 뒤의 시스템을 다룹니다.

저는 맥을 사랑합니다. 그리고 **vMix**도 사랑합니다. vMix는 많은 방송인에게 라이브 프로덕션이 어떠해야 하는지 알려 준 프로그램입니다. HongMix는 vMix를 **레퍼런스로 삼아, 존경하는 마음으로** 만들었습니다. 화면 구성도, 운영 흐름도, API도 vMix를 기준으로 했습니다. 그 경험을 제가 매일 들고 다니는 맥에서도 누리고 싶었습니다.

팔려고 만든 프로그램이 아닙니다. "내 맥으로도 이게 됐으면…" 하고 한 번쯤 생각해 본 **전 세계의 방송 기술자들을 위해** 만들었습니다. 이제 여러분 손에 드립니다. 마음껏 써 보시고, 부숴 보시고, 의견을 들려주세요.

> 나는 방송을 사랑하고, 기술을 사랑합니다. 당신들의 의견을 존중합니다. — 홍승훈

<p align="center"><img src="docs/screenshots/hongmix-program.jpg" alt="프로그램 출력 (1080p59.94)" width="80%"><br><sub>프로그램 출력 (1080p59.94)</sub></p>

## 들어 있는 기능

| 구분 | 기능 |
|---|---|
| **입력** | 카메라·캡처카드(FaceTime, 아이폰 연속성 카메라, USB HDMI), **SRT**(리스너/콜러/랑데부), **RTMP** 수신 서버, URL/UDP/HLS, **NDI®**, **Blackmagic DeckLink**, 재생 바가 있는 미디어 파일, **리스트(플레이리스트) 입력**, 컬러/투명, 이미지, **자막 템플릿 24종**, 화면 캡처, **웹 브라우저**(Chromium, 소리 포함), 오디오 장치 |
| **스위칭** | Cut, 전환 4슬롯, T‑바, 스팅어, 오버레이 4채널, FTB, **트리거**, **런다운(큐시트)**, 스케줄러 |
| **화면** | Metal GPU 합성, **레이어**(2·4·9·16분할, PIP, 마우스로 위치 조정), 색보정, 크로마키, **3D LUT(.cube)**, **스코프**(웨이브폼·RGB 퍼레이드·벡터스코프·히스토그램) |
| **오디오** | 마스터 + 버스 A~G, EQ·컴프·게이트·딜레이, **자동 더킹**, EBU R128 **LUFS** 미터, 헤드폰 모니터 |
| **출력** | RTMP·SRT 송출(**이중 경로**, **리턴 피드**), 녹화(H.264·HEVC·ProRes, **멀티트랙 오디오**), **방송 딜레이 + DUMP**, MultiCorder(입력별 녹화), NDI 출력, DeckLink 출력, 풀스크린 |
| **운영 도구** | 송출 전 점검, SRT 상황판, 사고 기록(블랙박스), 실시간 자막(CC), 온에어 시 자동 시작하는 카운트다운 |
| **제어** | vMix 호환 HTTP 8088 / TCP 8099 API, 휴대폰 탤리, 웹 리모트, **접근 제어**(IP 제한·비밀번호) |
| **언어** | 한국어 / English (설정에서 바로 전환) |

## 지금까지 확인된 것

Apple Silicon 맥에서 동작을 확인했습니다.
- SRT 입력·송출
- RTMP 입력·송출
- NDI® 송수신(NDI 6)
- 맥 내장 FaceTime 카메라, 아이폰 카메라 인식
- **Blackmagic DeckLink** 인식
- **USB HDMI 캡처카드(하기비전)** 인식
- 웹 브라우저 입력(소리 포함)
- 미디어·리스트 재생
- H.264 녹화와 멀티트랙 오디오
- 레이어, LUT
- 방송 딜레이
- vMix 호환 API(Companion 방식 연결)

**테스트를 부탁드립니다.** 아직 베타이고, 제 책상 위에 있는 장비로만 시험할 수 있었습니다. 특히 이런 환경에서 써 보시고 알려 주세요.
- 갖고 계신 캡처카드와 카메라
- 현장의 SRT / RTMP / NDI 연결(LiveU, OBS, 다른 스위처 등)
- Companion / Stream Deck 연결
- 몇 시간 이상 이어지는 방송
- 다른 맥 모델

"M2 Air + 엘가토에서 잘 됨" 같은 짧은 제보도 큰 도움이 됩니다. → **[의견 남기기 (Issues)](https://github.com/HongMix/HongMix/issues/new/choose)**

## 자주 묻는 질문

**윈도우에서 vMix를 쓰는데, 맥에서도 같은 방식으로 할 수 있나요?**
HongMix는 vMix의 화면 구성과 API를 존경하는 마음으로 참고했습니다. 그래서 맥에서도 손에 익은 흐름 그대로 운영할 수 있습니다. vMix를 대체하려는 게 아니라, 맥북밖에 없는 순간을 위한 프로그램입니다. vMix는 훌륭한 프로그램입니다.

**맥북에서 쓸 수 있는 무료 라이브 스위처, SRT·NDI 되는 거 없나요?**
HongMix가 바로 그겁니다.
- SRT 리스너/콜러 입·출력(링크 통계 포함)
- NDI® 입·출력
- RTMP 입·출력
- 녹화
- 이 모든 게 무료 설치 파일 하나에 들어 있습니다.

**Companion · Stream Deck 연결되나요?**
됩니다. vMix HTTP(8088)/TCP(8099) API를 그대로 지원합니다. Companion의 vMix 모듈에서 IP만 이 맥으로 바꾸면 연결됩니다.

**LiveU·SRT 피드, 캡처카드, DeckLink, 아이폰 카메라도 되나요?**
- SRT 피드(LiveU 등): 콜러·리스너로 연결됩니다.
- Blackmagic DeckLink: 인식됩니다.
- USB HDMI 캡처카드: 표준(UVC) 캡처카드는 카메라처럼 잡힙니다. 하기비전 캡처카드로 확인했고, 엘가토·매그웰 등도 같은 방식이라 될 것으로 보입니다(제보 부탁드립니다).
- 아이폰: 연속성 카메라로 바로 쓸 수 있습니다.

**OBS랑 뭐가 달라요?**
OBS는 훌륭한 송출 프로그램입니다. HongMix는 vMix 계열의 프로덕션 스위처입니다. Preview/Program, 전환, 오버레이, 멀티 버스 오디오, 자막, 제어 API 중심이라 쓰는 방식이 다릅니다.

**어떤 맥에서 되나요?** macOS 14 이상의 Apple Silicon 맥(M1 이후 전 모델)입니다. 인텔 맥은 지원하지 않습니다.

## 설치

1. [Releases](https://github.com/HongMix/HongMix/releases/latest)에서 **HongMix-1.2.pkg**를 받습니다. macOS 14 이상, Apple Silicon 맥이 필요합니다.
2. 더블클릭해서 설치합니다.
3. 처음 열 때만 응용 프로그램 폴더에서 HongMix를 우클릭 → **열기** → **열기** 하세요. 아직 Apple 공증을 받지 않은 앱이라 macOS가 한 번 확인합니다.

설명서: `docs/HongMix-설명서.txt` (한국어) · `docs/HongMix-Manual-EN.txt` (English)

## 소스로 빌드하기

```bash
xcode-select --install                 # Command Line Tools (Xcode 없어도 됨)
./scripts/build-ffmpeg-lgpl.sh         # LGPL FFmpeg → build/ffmpeg-lgpl (한 번만)
./scripts/build-cli.sh                 # → build/cli/BraceletMix.app
./scripts/make-dmg.sh                  # → build/dist/HongMix-<버전>.dmg / .pkg
```

선택 SDK (저장소에 포함하지 않음):
- [NDI SDK for Apple](https://ndi.video/for-developers/ndi-sdk/): 설치할 때 라이선스에 직접 동의해야 합니다.
- Blackmagic DeckLink SDK: `ThirdParty/DeckLinkSDK/README.md`를 따라 하세요.
- 웹 브라우저 입력용 CEF: `scripts/fetch-cef.sh`

## 원격 제어 보안

vMix처럼 HTTP 8088 / TCP 8099가 같은 네트워크에 열립니다. **설정 › 네트워크 › 원격 제어 보안**에서 다음을 정할 수 있습니다.
- 허용 범위: 같은 네트워크 / 이 맥에서만 / 끄기
- 허용할 IP 목록
- 웹·HTTP 비밀번호

다른 웹사이트가 브라우저를 통해 보내는 명령은 항상 차단됩니다.

## 의견 보내기

버그, 아이디어, "이건 불편해요", "덕분에 방송 살렸어요", 무엇이든 **[Issues](https://github.com/HongMix/HongMix/issues)**에 남겨 주세요. 메일 주소는 스팸 방지를 위해 공개하지 않습니다.

## 라이선스와 고지

- 서드파티 고지: [`docs/THIRD-PARTY-NOTICES.txt`](docs/THIRD-PARTY-NOTICES.txt)
- FFmpeg는 GPL 부품 없는 **LGPL v3**로 빌드해 동적 링크합니다.
- NDI®는 Vizrt NDI AB의 등록 상표입니다. HongMix는 NDI의 제품이 아닙니다.
- DeckLink는 Blackmagic Design Pty Ltd의 상표입니다.
- vMix는 StudioCoast Pty Ltd의 상표입니다. HongMix는 vMix를 존경하는 마음으로 만든 독립 프로젝트로, StudioCoast와 관계가 없으며 승인이나 후원을 받지 않았습니다. vMix의 코드나 자산은 사용하지 않았습니다.
