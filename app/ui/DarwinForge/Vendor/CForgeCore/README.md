# Vendor/CForgeCore/

`forge-core` Rust 라이브러리의 C-ABI 산출물이 위치하는 디렉토리.

> **이 디렉토리의 `lib/`와 `include/forge_core.h`, `include/module.modulemap`은
> git 추적에서 제외되어 있다.** 사용자가 처음 클론한 뒤 `scripts/build-mac.sh`를
> 실행하면 자동으로 채워진다.

## 채우는 방법

```sh
# 저장소 루트에서:
bash scripts/build-mac.sh                # 현재 호스트 아키 release
bash scripts/build-mac.sh -u              # universal (arm64 + x86_64)
bash scripts/build-mac.sh -u --swift      # universal + swift build까지
```

스크립트가 다음을 생성한다:

```
Vendor/CForgeCore/
├── README.md                       (이 파일)
├── include/
│   ├── forge_core.h                (cbindgen이 forge-ffi에서 생성)
│   └── module.modulemap            (build-mac.sh가 생성)
└── lib/
    └── libforge_core.a             (forge-ffi staticlib)
```

이후 `swift build`가 `CForgeCore` 시스템 라이브러리 타깃을 통해 임포트.
