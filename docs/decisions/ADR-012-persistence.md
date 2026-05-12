# ADR-012: 영속성 — SQLite (rusqlite + Swift FFI)

- Status: Accepted
- Date: 2026-05-09

## Context

저장 대상:
- 모션 라이브러리 (페이지·스텝·메타데이터)
- 로봇 프로파일 (이름, 세대, 시리얼, 캘리브레이션 오프셋)
- 워크 파라미터 프리셋
- 마지막 연결 정보 (포트 경로, 마지막 펌웨어 버전)

대안:
- **SQLite (rusqlite)** — 단일 파일, 트랜잭션, 스키마 마이그레이션 도구 풍부
- **SwiftData / Core Data** — Swift 네이티브, but Rust 코어와 공유 어려움
- **JSON 파일 + 디렉토리** — 단순하지만 동시성·인덱스 약함

## Decision

**SQLite (rusqlite)**.

- DB 파일: `~/Library/Application Support/DarwinForge/library.sqlite`
- 마이그레이션: `refinery` 또는 자체 SQL 파일 시퀀스 (`schema/0001_init.sql`, ...)
- Rust가 single source of truth. Swift는 read-only 쿼리만 직접 (SwiftData/Core Data 안 씀).
- 변경(write)은 Swift → FFI → Rust → SQLite 경유.

## Consequences

- **긍정**: Mac/Linux 모두 같은 파일 포맷. 포팅 무비용.
- **긍정**: 사용자가 sqlite3 CLI로 직접 조회·백업 가능.
- **긍정**: Rust 단위 테스트가 `:memory:` DB로 빠르게 통과.
- **부정**: SwiftUI `@Query` 같은 자동 reactivity 없음. NotificationCenter / Combine으로 수동 발행.
- **위험**: 동시성 — Rust 측이 mutex로 single writer 보장.

## 스키마 (Sprint 4 시작 시 확정)

```sql
CREATE TABLE robots (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    generation TEXT NOT NULL,        -- 'op' or 'op2'
    controller TEXT NOT NULL,        -- 'cm730' or 'cm740'
    serial_number TEXT,
    build_date TEXT,
    notes TEXT
);

CREATE TABLE motions (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    robot_id TEXT,                    -- nullable: shared motion
    json TEXT NOT NULL,               -- 내부 JSON 표현
    source_mtn TEXT,                  -- 원본 .mtn 경로 (있으면)
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (robot_id) REFERENCES robots(id)
);

CREATE TABLE walk_presets (
    id TEXT PRIMARY KEY,
    robot_id TEXT NOT NULL,
    name TEXT NOT NULL,
    params_json TEXT NOT NULL,
    FOREIGN KEY (robot_id) REFERENCES robots(id)
);
```
