#!/bin/bash
# **v1.11.12 (2026-05-19)** — fake Claude CLI for integration test.
# stdin 으로 prompt 받음. argument 로 어떤 응답 반환할지 결정.
#
# Usage (test 에서):
#   fake-claude.sh -p --output-format text   # default — safe response
#   fake-claude.sh --fixture=fail              # quality.fail response
#   fake-claude.sh --fixture=malformed         # JSON parse error 강제
#   fake-claude.sh --fixture=empty             # empty stdout
#   fake-claude.sh --fixture=forbidden         # forbidden 조합 권고 (validation fail)
#
# 진단 문서 §HIGH 5 fix: 실 Claude CLI 호출 성공 path 검증.

# stdin 소비 (analyst 가 prompt 보냄).
cat > /dev/null

fixture="default"
for arg in "$@"; do
  case "$arg" in
    --fixture=*) fixture="${arg#--fixture=}" ;;
  esac
done

case "$fixture" in
  fail)
    cat <<'JSON'
{
  "summary": "데이터 품질 부족 — 재수집 필요",
  "sessionsAnalyzed": ["s1"],
  "dataQuality": {
    "verdict": "fail",
    "reasons": ["duration < 1s", "phaseCoverage 0/6"]
  },
  "diagnosis": [],
  "nextExperiment": null,
  "forbiddenChanges": ["hybridBA + applyToRobot"],
  "recommendation": { "action": "recollect", "requiresHumanApproval": true }
}
JSON
    ;;
  malformed)
    echo "{ not valid json"
    ;;
  empty)
    ;;
  forbidden)
    cat <<'JSON'
{
  "dataQuality": { "verdict": "pass", "reasons": [] },
  "diagnosis": [{"axis": "applyToRobot", "severity": "high", "evidence": ["test"], "confidence": 0.8}],
  "nextExperiment": {
    "changeOneAxisOnly": true, "axis": "applyToRobot",
    "from": "false", "to": "true", "preset": "march",
    "safety": "cradle", "successMetric": "x", "rollbackCondition": "x"
  },
  "forbiddenChanges": []
}
JSON
    ;;
  *)
    # default — safe response.
    cat <<'JSON'
{
  "summary": "최근 v110 fall 패턴 — gainProfile 권고 변경",
  "sessionsAnalyzed": ["s1"],
  "dataQuality": { "verdict": "pass", "reasons": [] },
  "diagnosis": [
    {
      "axis": "gainProfile",
      "severity": "high",
      "evidence": ["s1 peakAbsPitch 38°"],
      "confidence": 0.85
    }
  ],
  "nextExperiment": {
    "changeOneAxisOnly": true,
    "axis": "gainProfile",
    "from": "v110Experimental",
    "to": "robotisOriginal",
    "preset": "slowWalk",
    "safety": "cradle + tether",
    "successMetric": "peakAbsPitch 감소 -10° 이상",
    "rollbackCondition": "peakAbsPitch > 30° 또는 fall",
    "riskNote": null
  },
  "forbiddenChanges": ["hybridBA + applyToRobot"],
  "recommendation": { "action": "holdAndObserve", "requiresHumanApproval": true },
  "confidence": 0.8
}
JSON
    ;;
esac
