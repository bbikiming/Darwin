# research/

Phase 1에서 수집한 오픈소스 자료 아카이브.

## 구조

- [`SURVEY.md`](SURVEY.md) — 상위 조사 보고서 (어떤 저장소가 있고 무엇이 유용한가)
- [`INDEX.md`](INDEX.md) — 표 형식 카탈로그 (URL · 라이선스 · 핵심 모듈 · 적용 여부)
- [`EXTERNAL_LINKS.md`](EXTERNAL_LINKS.md) — 동영상·PDF·외부 링크 (다운로드하지 않고 링크만)
- `papers/REFERENCES.bib` — 인용 가능한 학술자료
- `robotis-official/` — ROBOTIS 공식 / 준공식 저장소 mirror (얕은 클론)
- `community/` — 커뮤니티·학술 저장소 mirror

## 수집 절차 요약

```bash
cd research/robotis-official
git clone --depth=1 <repo>
cd <repo>
echo "<repo URL> | <license> | <commit hash> | <YYYY-MM-DD>" >> ../INDEX.md
```

각 클론 root에 `_NOTES.md` 작성 — 어떤 모듈이 우리에게 유용한지 한 줄 요약.
라이선스는 [`../vendor/LICENSES.md`](../vendor/LICENSES.md)에 누적.
