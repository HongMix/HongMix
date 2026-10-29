# DeckLink SDK (선택)

Blackmagic **Desktop Video SDK**는 재배포가 허용되지 않아 저장소에 포함하지 않았습니다.

1. https://www.blackmagicdesign.com/developer/products/capture-and-playback/sdk-and-software 에서 SDK를 받습니다.
2. SDK 압축을 풀고 `Mac/include/` 안의 **모든 파일**을 이 폴더의 `include/`에 복사합니다.
   (`DeckLinkAPI.h`, `DeckLinkAPIDispatch.cpp`, `DeckLinkAPIVersion.h` 등)
3. `scripts/bootstrap.sh`를 다시 실행해 Xcode 프로젝트를 재생성합니다.

SDK가 없으면 DeckLink 기능만 빠진 채로 빌드됩니다. 실행 시에는 Desktop Video 드라이버가 설치되어 있어야 합니다.
