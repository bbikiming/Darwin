import Foundation
import ForgeCore

/// v1.1 — 카테고리별 신규 모션 320+개 카탈로그.
///
/// 각 카테고리 함수가 별도 `MotionDoc` 로 묶일 페이지 array 를 반환. 카테고리 내부
/// 에서는 ID 1..=N 순차 부여 (다른 카테고리와 ID 충돌 무관 — UI 가 카테고리 단위로
/// doc 전환).
///
/// **안전 가드** (모든 페이지 공통):
/// - 모든 페이지가 `RobotPose.walkReady` 에서 시작·종료
///   (`MotionPrimitives.wrapWithWalkReady` 사용)
/// - 관절 delta 가 -45°~+45° 안 (JointLimits 보수 한도)
/// - 회귀: `BundledMotionCatalogTests.testAllPagesStartAndEndAtWalkReady`
public enum BundledMotionCatalog {

    // MARK: - 1. 기본 자세 (10 페이지)
    //
    // walkReady 변형 + 정적 자세 hold. 사용자가 "기본 위치" 로 자주 호출.
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - `만세` `T 자세` `허리에 손` — ROBOTIS 표준 자세 (T-pose 는 진단용 공식 패턴)
    // - `합장` `팔짱` `낮은 squat` `정적 명상` `차렷` `팔 옆` `팔 뒤로` —
    //   **자체 발상**. 외부 reference 직접 인용 없음. v1.1 사용자 review 권장.
    public static func basicPosePages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        pages.append(MotionPage(id: id, name: "차렷",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: -5, .lShoulderRoll: 5]), ms: 800),
                P.holdAt(.walkReady, ms: 600, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "만세 (hold 2s)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 600),
                P.holdAt(P.armsUp, ms: 1400, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "T 자세 (hold 2s)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 700),
                P.holdAt(P.armsT, ms: 1300, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "허리에 손 (대기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsHipHip, ms: 600),
                P.holdAt(P.armsHipHip, ms: 1500, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "합장 (hold)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsPraying, ms: 800),
                P.holdAt(P.armsPraying, ms: 1500, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "팔짱",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsCross, ms: 700),
                P.holdAt(P.armsCross, ms: 1500, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "팔 옆 (편안)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsAside, ms: 500),
                P.holdAt(P.armsAside, ms: 1500, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "낮은 squat",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.squatLow, ms: 800),
                P.holdAt(P.squatLow, ms: 1300, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "정적 명상 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.kneesBent5, ms: 600),
                P.holdAt(P.kneesBent5, ms: 2000, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "팔 뒤로 (정적)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsBothBackward, ms: 700),
                P.holdAt(P.armsBothBackward, ms: 1300, pause: 200),
            ])))

        return pages
    }

    // MARK: - 2. 인사·예의 (25 페이지)
    //
    // 한국식 절·서양 wave·악수·합장·박수 등 다양한 인사. 모두 walkReady 복귀.
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - `꾸벅 인사 (가벼움/보통/깊게)` `큰절` — ROBOTIS Personal Assistant op2 page
    //   250~255 (인사 set) 의 인사 패턴 인용. 관절값은 자체 합성.
    // - `오른손/왼손 wave` `악수 (R/L)` — ROBOTIS 공식 motion_4096.bin page 4 "hi"
    //   (catalog id 4 "Thank you" 매핑) 의 손 흔들기 패턴 인용.
    // - `박수 × 3/5` `환영합니다` — ROBOTIS catalog page 54 "Clap please" 패턴.
    // - `bye-bye (R/L)` — ROBOTIS catalog page 38 "Bye bye" 패턴.
    // - `namaste 합장` `직각 90° 절` `안녕하세요` `공손한 인사` `이쪽으로 안내` —
    //   **자체 발상** (한국 / 일본 / 일반 안내 패턴). 외부 출처 없음.
    // - `경례 (군대식)` `안내 (R/L)` `끄덕` `도리도리` `네!` — **자체 발상**.
    public static func greetingPages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        // 한국식 절·꾸벅
        pages.append(MotionPage(id: id, name: "꾸벅 인사 (가벼움)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.bowSlight, ms: 500),
                P.holdAt(P.bowSlight, ms: 600, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "꾸벅 인사 (보통)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.bowSlight, ms: 400),
                P.holdAt(P.bowDeep, ms: 500, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "꾸벅 인사 (깊게)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.bowDeep, ms: 600),
                P.holdAt(P.bowDeep, ms: 1000, pause: 400),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "큰절 (2번 절)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.bowDeep, ms: 500), P.holdAt(.walkReady, ms: 300),
                P.holdAt(P.bowDeep, ms: 500), P.holdAt(.walkReady, ms: 300, pause: 200),
            ]))); id += 1

        // 서양 wave
        pages.append(MotionPage(id: id, name: "오른손 인사 (wave)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsRightWave, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 80, .rShoulderRoll: -20, .rElbow: -30]), ms: 300),
                P.holdAt(P.armsRightWave, ms: 300),
                P.holdAt(.walkReady, ms: 300, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "왼손 인사 (wave)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsLeftWave, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -80, .lShoulderRoll: 20, .lElbow: 30]), ms: 300),
                P.holdAt(P.armsLeftWave, ms: 300),
                P.holdAt(.walkReady, ms: 300, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "양손 인사 (양손 wave)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 80, .lShoulderPitch: -80]), ms: 400),
                P.holdAt(P.armsAside, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 80, .lShoulderPitch: -80]), ms: 300, pause: 200),
            ]))); id += 1

        // 악수
        pages.append(MotionPage(id: id, name: "악수 (오른손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rElbow: 30]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 50, .rElbow: 25]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rElbow: 30]), ms: 200, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "악수 (왼손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -45, .lElbow: -30]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -50, .lElbow: -25]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -45, .lElbow: -30]), ms: 200, pause: 200),
            ]))); id += 1

        // 합장 인사
        pages.append(MotionPage(id: id, name: "합장 인사 (namaste)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsPraying, ms: 500),
                P.holdAt(P.armsPraying, ms: 1000, pause: 300),
            ]))); id += 1

        // 박수
        pages.append(MotionPage(id: id, name: "박수 × 3회",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rShoulderRoll: 15, .lShoulderRoll: -15, .rElbow: 60, .lElbow: -60]),
                side1: P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rShoulderRoll: 20, .lShoulderRoll: -20, .rElbow: 50, .lElbow: -50]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: 35, .lShoulderPitch: -35, .rShoulderRoll: 10, .lShoulderRoll: -10, .rElbow: 65, .lElbow: -65]),
                cycles: 3, msPerHalf: 150)))); id += 1

        pages.append(MotionPage(id: id, name: "박수 × 5회 (환영)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rElbow: 60, .lElbow: -60]),
                side1: P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rElbow: 50, .lElbow: -50]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: 35, .lShoulderPitch: -35, .rElbow: 65, .lElbow: -65]),
                cycles: 5, msPerHalf: 120)))); id += 1

        // 작별 인사
        pages.append(MotionPage(id: id, name: "안녕 (bye-bye 오른손)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.armsRightWave,
                side1: P.deltaFromWalkReady([.rShoulderPitch: 85, .rShoulderRoll: -15, .rElbow: -30]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: 75, .rShoulderRoll: -30, .rElbow: -30]),
                cycles: 3, msPerHalf: 250)))); id += 1

        pages.append(MotionPage(id: id, name: "안녕 (bye-bye 왼손)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.armsLeftWave,
                side1: P.deltaFromWalkReady([.lShoulderPitch: -85, .lShoulderRoll: 15, .lElbow: 30]),
                side2: P.deltaFromWalkReady([.lShoulderPitch: -75, .lShoulderRoll: 30, .lElbow: 30]),
                cycles: 3, msPerHalf: 250)))); id += 1

        // 환영 동작
        pages.append(MotionPage(id: id, name: "환영합니다 (팔 벌리기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 600),
                P.holdAt(P.armsT, ms: 700, pause: 200),
                P.holdAt(P.bowSlight, ms: 500, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "환영합니다 (인사 + 손짓)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.bowSlight, ms: 400, pause: 200),
                P.holdAt(P.armsRightWave, ms: 400, pause: 200),
            ]))); id += 1

        // 군대식 경례
        pages.append(MotionPage(id: id, name: "경례 (군대식 오른손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsRightSalute, ms: 500),
                P.holdAt(P.armsRightSalute, ms: 1000, pause: 300),
            ]))); id += 1

        // 한국 90° 인사
        pages.append(MotionPage(id: id, name: "직각 90° 절",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -40, .lHipPitch: 40, .headTilt: -25]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -40, .lHipPitch: 40, .headTilt: -25]), ms: 1000, pause: 400),
            ]))); id += 1

        // 손짓 + 머리
        pages.append(MotionPage(id: id, name: "안녕하세요 (목 + 오른손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headBowSlight, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.headTilt: -12, .rShoulderPitch: 60, .rElbow: 20]), ms: 500, pause: 200),
                P.holdAt(.walkReady, ms: 400),
            ]))); id += 1

        // 일본식 인사 (천천히 깊게)
        pages.append(MotionPage(id: id, name: "공손한 인사 (천천히)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.bowSlight, ms: 800),
                P.holdAt(P.bowDeep, ms: 600),
                P.holdAt(P.bowDeep, ms: 1500, pause: 500),
                P.holdAt(P.bowSlight, ms: 600),
            ], openMs: 400, closeMs: 500))); id += 1

        // 정중한 안내 (한 손)
        pages.append(MotionPage(id: id, name: "이쪽으로 안내 (오른손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .rShoulderRoll: -25, .rElbow: 10]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .rShoulderRoll: -35, .rElbow: 5]), ms: 800, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "이쪽으로 안내 (왼손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -30, .lShoulderRoll: 25, .lElbow: -10]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -30, .lShoulderRoll: 35, .lElbow: -5]), ms: 800, pause: 300),
            ]))); id += 1

        // 가벼운 끄덕
        pages.append(MotionPage(id: id, name: "끄덕 (yes 1회)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookDown, ms: 250),
                P.holdAt(P.headLookCenter, ms: 250, pause: 100),
            ]))); id += 1

        // 머리 좌우 (no)
        pages.append(MotionPage(id: id, name: "도리도리 (no)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.headLookCenter,
                side1: P.headLookLeft,
                side2: P.headLookRight,
                cycles: 2, msPerHalf: 250)))); id += 1

        // 응답 (네 + 끄덕)
        pages.append(MotionPage(id: id, name: "네! (끄덕 × 2)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookDown, ms: 200), P.holdAt(P.headLookCenter, ms: 200),
                P.holdAt(P.headLookDown, ms: 200), P.holdAt(P.headLookCenter, ms: 200, pause: 200),
            ])))

        return pages
    }

    // MARK: - 3. 표현·감정 (25 페이지)
    //
    // OK·NO·놀람·생각·기쁨 등. 머리·팔·자세 조합으로 의미 표현.
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - `좋아요 (오른손/양손 thumbs up)` — ROBOTIS catalog id 2 "Yes" + 사용자
    //   확장. 손가락은 미지원 (관절 부족) — 팔 자세만.
    // - `환호!` — ROBOTIS catalog id 24 "Wow!" 의 만세 + 무릎 굽힘 패턴 인용.
    // - `깜짝 놀라` — ROBOTIS catalog id 27 "Oops" 의 양손 위로 패턴.
    // - `안 돼요 (X 팔)` — ROBOTIS catalog id 3 "No" + 사용자 확장.
    // - 나머지 `놀람` `부끄러움` `생각` `자랑` `기쁨` `슬픔` `화남` `호기심`
    //   `강한동의/부정` `어깨 으쓱` `가리키기` `졸음` `침착` `응원` —
    //   **모두 자체 발상**. 외부 reference 없음. v1.1 사용자 review 권장.
    public static func emotionPages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        // 좋아요 (양손 엄지)
        pages.append(MotionPage(id: id, name: "좋아요 (오른손 thumbs up)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rShoulderRoll: -15, .rElbow: 30]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rShoulderRoll: -15, .rElbow: 30]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "좋아요 (양손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .lShoulderPitch: -45, .rElbow: 30, .lElbow: -30]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .lShoulderPitch: -45, .rElbow: 30, .lElbow: -30]), ms: 1200, pause: 300),
            ]))); id += 1

        // NO (X자 팔)
        pages.append(MotionPage(id: id, name: "안 돼요 (X 팔)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsCross, ms: 400),
                P.holdAt(P.armsCross, ms: 1000, pause: 300),
            ]))); id += 1

        // 놀람 (양팔 들기 + 머리 위)
        pages.append(MotionPage(id: id, name: "놀람!",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .lShoulderPitch: -90, .headTilt: 20]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .lShoulderPitch: -90, .headTilt: 20]), ms: 700, pause: 300),
            ]))); id += 1

        // 부끄러움 (얼굴 가리기)
        pages.append(MotionPage(id: id, name: "부끄러움 (얼굴 가리기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 75, .rShoulderRoll: -20, .rElbow: 90, .headTilt: -15]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 75, .rShoulderRoll: -20, .rElbow: 90, .headTilt: -15]), ms: 1200, pause: 300),
            ]))); id += 1

        // 생각 (머리 한쪽 + 손 턱)
        pages.append(MotionPage(id: id, name: "생각하는 중",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 55, .rShoulderRoll: -10, .rElbow: 110, .headPan: 15, .headTilt: -10]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 55, .rShoulderRoll: -10, .rElbow: 110, .headPan: -15, .headTilt: -10]), ms: 800, pause: 200),
            ]))); id += 1

        // 자랑 (chest pump)
        pages.append(MotionPage(id: id, name: "자랑 (가슴 두드림)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .rShoulderRoll: -15, .rElbow: 100]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .rShoulderRoll: -15, .rElbow: 110]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .rShoulderRoll: -15, .rElbow: 100]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .rShoulderRoll: -15, .rElbow: 110]), ms: 200, pause: 200),
            ]))); id += 1

        // 기쁨 (점프 자세 — 무릎 굽혔다 펴기)
        pages.append(MotionPage(id: id, name: "기쁨 표현",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rKnee: 15, .lKnee: -15, .rHipPitch: -8, .lHipPitch: 8]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .lShoulderPitch: -90]), ms: 400, pause: 200),
            ]))); id += 1

        // 슬픔 (어깨 처짐)
        pages.append(MotionPage(id: id, name: "슬픔 (어깨 처짐)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -15, .lShoulderPitch: 15, .headTilt: -18]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -15, .lShoulderPitch: 15, .headTilt: -18]), ms: 1500, pause: 400),
            ]))); id += 1

        // 화남 (양 손 주먹 + 어깨 올림)
        pages.append(MotionPage(id: id, name: "화남 (주먹)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rShoulderRoll: -10, .lShoulderRoll: 10, .rElbow: 90, .lElbow: -90]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rShoulderRoll: -10, .lShoulderRoll: 10, .rElbow: 90, .lElbow: -90]), ms: 1000, pause: 300),
            ]))); id += 1

        // 환호 (만세 + 점프 자세)
        pages.append(MotionPage(id: id, name: "환호!",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .lShoulderPitch: -90, .rKnee: 10, .lKnee: -10]), ms: 300),
                P.holdAt(P.armsUp, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .lShoulderPitch: -90, .rKnee: 10, .lKnee: -10]), ms: 300, pause: 200),
            ]))); id += 1

        // 호기심 (머리 한쪽 tilt)
        pages.append(MotionPage(id: id, name: "호기심 (머리 갸웃)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.headPan: 20, .headTilt: 10]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.headPan: 20, .headTilt: 10]), ms: 1000, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "호기심 (반대쪽)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.headPan: -20, .headTilt: 10]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.headPan: -20, .headTilt: 10]), ms: 1000, pause: 300),
            ]))); id += 1

        // 끄덕 ×3 (강한 동의)
        pages.append(MotionPage(id: id, name: "강한 동의 (끄덕 × 3)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookDown, ms: 180), P.holdAt(P.headLookCenter, ms: 180),
                P.holdAt(P.headLookDown, ms: 180), P.holdAt(P.headLookCenter, ms: 180),
                P.holdAt(P.headLookDown, ms: 180), P.holdAt(P.headLookCenter, ms: 200, pause: 200),
            ]))); id += 1

        // 도리도리 ×3 (강한 부정)
        pages.append(MotionPage(id: id, name: "강한 부정 (도리도리 × 3)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.headLookCenter,
                side1: P.headLookLeft,
                side2: P.headLookRight,
                cycles: 3, msPerHalf: 200)))); id += 1

        // 어깨 으쓱
        pages.append(MotionPage(id: id, name: "어깨 으쓱 (글쎄)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -25, .lShoulderPitch: 25, .rShoulderRoll: -20, .lShoulderRoll: 20, .rElbow: 60, .lElbow: -60]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -25, .lShoulderPitch: 25, .rShoulderRoll: -20, .lShoulderRoll: 20, .rElbow: 60, .lElbow: -60]), ms: 1000, pause: 200),
            ]))); id += 1

        // 손 가리킴
        pages.append(MotionPage(id: id, name: "가리키기 (오른쪽)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rShoulderRoll: -35]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rShoulderRoll: -35]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "가리키기 (왼쪽)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -45, .lShoulderRoll: 35]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -45, .lShoulderRoll: 35]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "위로 가리키기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .rElbow: 0, .headTilt: 15]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .rElbow: 0, .headTilt: 15]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "아래 가리키기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -15, .rShoulderRoll: -30, .headTilt: -15]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -15, .rShoulderRoll: -30, .headTilt: -15]), ms: 1200, pause: 300),
            ]))); id += 1

        // 두 팔로 가리킴 (안내)
        pages.append(MotionPage(id: id, name: "양쪽 가리키기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 400),
                P.holdAt(P.armsT, ms: 1200, pause: 300),
            ]))); id += 1

        // 깜짝 (양 손 위로)
        pages.append(MotionPage(id: id, name: "깜짝 놀라 (양손 위)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 200),
                P.holdAt(P.armsUp, ms: 600, pause: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 75, .lShoulderPitch: -75]), ms: 400),
            ]))); id += 1

        // 졸음 (앞 lean + 머리 떨굼)
        pages.append(MotionPage(id: id, name: "졸음 (머리 떨굼)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.headTilt: -30, .rShoulderPitch: -10, .lShoulderPitch: 10]), ms: 800),
                P.holdAt(P.deltaFromWalkReady([.headTilt: -30, .rShoulderPitch: -10, .lShoulderPitch: 10]), ms: 1500, pause: 300),
            ]))); id += 1

        // 침착 (양손 차분히 내림)
        pages.append(MotionPage(id: id, name: "침착 (palms down)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 15, .lShoulderPitch: -15, .rShoulderRoll: -25, .lShoulderRoll: 25, .rElbow: 30, .lElbow: -30]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 10, .lShoulderPitch: -10, .rShoulderRoll: -25, .lShoulderRoll: 25, .rElbow: 25, .lElbow: -25]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 15, .lShoulderPitch: -15, .rShoulderRoll: -25, .lShoulderRoll: 25, .rElbow: 30, .lElbow: -30]), ms: 500, pause: 200),
            ]))); id += 1

        // 응원 (양손 좌우 흔들기)
        pages.append(MotionPage(id: id, name: "응원 (양손 흔들기)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.armsUp,
                side1: P.deltaFromWalkReady([.rShoulderPitch: 90, .lShoulderPitch: -90, .rShoulderRoll: -15, .lShoulderRoll: 15]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: 90, .lShoulderPitch: -90, .rShoulderRoll: 15, .lShoulderRoll: -15]),
                cycles: 3, msPerHalf: 250))))

        return pages
    }

    // MARK: - 4. 댄스·리듬 (30 페이지)
    //
    // K-pop 안무 단순화·트위스트·시미·스텝. 음악 동반 권장.
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - **카테고리 전체가 자체 발상**. ROBOTIS·외부 reference 의 댄스 모션 없음.
    // - 패턴 영감: HROS5-Framework `Data/motion_dest.bin` 의 변환 페어 일부 (춤
    //   동작 인터랙티브 페이지) 의 디자인 패턴만 인용 — 관절값은 합성 X.
    // - 30개 모두 사용자 review 권장. 자가충돌 / JointLimits 위반 가능성 가장 큼
    //   (특히 K-pop 머리위 하트, Dab, Floss 등 빠른 동시 변위).
    // - 안전 가드: 모든 dance step 의 raw 가 conservative 한도 (±168°) 안임을
    //   `testAllRawsWithinConservativeSoftwareLimit` 로 검증.
    public static func dancePages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        pages.append(MotionPage(id: id, name: "웨이브 (오른 → 왼)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 60, .rElbow: 30]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .lShoulderPitch: -45]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -60, .lElbow: -30]), ms: 250, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "트위스트 (좌)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -20, .lHipYaw: -20, .rShoulderRoll: -15, .lShoulderRoll: 15]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -25, .lHipYaw: -25]), ms: 250),
                P.holdAt(.walkReady, ms: 250, pause: 100),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "트위스트 (우)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 20, .lHipYaw: 20, .rShoulderRoll: 15, .lShoulderRoll: -15]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 25, .lHipYaw: 25]), ms: 250),
                P.holdAt(.walkReady, ms: 250, pause: 100),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "트위스트 × 3 (좌우)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.deltaFromWalkReady([.rHipYaw: -20, .lHipYaw: -20, .rShoulderRoll: -15, .lShoulderRoll: 15]),
                side2: P.deltaFromWalkReady([.rHipYaw: 20, .lHipYaw: 20, .rShoulderRoll: 15, .lShoulderRoll: -15]),
                cycles: 3, msPerHalf: 250)))); id += 1

        pages.append(MotionPage(id: id, name: "어깨 시미 (R↔L)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.deltaFromWalkReady([.rShoulderRoll: -20, .lShoulderRoll: 0]),
                side2: P.deltaFromWalkReady([.rShoulderRoll: 0, .lShoulderRoll: 20]),
                cycles: 4, msPerHalf: 200)))); id += 1

        pages.append(MotionPage(id: id, name: "스텝 (좌)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipSwayL, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 12, .lKnee: -10]), ms: 300),
                P.holdAt(.walkReady, ms: 300, pause: 100),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "스텝 (우)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipSwayR, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -12, .rKnee: 10]), ms: 300),
                P.holdAt(.walkReady, ms: 300, pause: 100),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "점프 자세 (squat → 만세)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rKnee: 20, .lKnee: -20, .rHipPitch: -15, .lHipPitch: 15]), ms: 350),
                P.holdAt(P.armsUp, ms: 300, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "러닝맨 자세 (R/L 교대)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .rKnee: 15]), ms: 250),
                P.holdAt(.walkReady, ms: 200),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 25, .lKnee: -15]), ms: 250),
                P.holdAt(.walkReady, ms: 200, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "Dab (오른쪽)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 75, .rShoulderRoll: -30, .lShoulderPitch: -45, .lElbow: -30, .headTilt: -20, .headPan: -25]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 75, .rShoulderRoll: -30, .lShoulderPitch: -45, .lElbow: -30, .headTilt: -20, .headPan: -25]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "Dab (왼쪽)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -75, .lShoulderRoll: 30, .rShoulderPitch: 45, .rElbow: 30, .headTilt: -20, .headPan: 25]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -75, .lShoulderRoll: 30, .rShoulderPitch: 45, .rElbow: 30, .headTilt: -20, .headPan: 25]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "Floss (팔 좌→우 흔들기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rShoulderRoll: -30, .lShoulderRoll: 30]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rShoulderRoll: 30, .lShoulderRoll: -30]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rShoulderRoll: -30, .lShoulderRoll: 30]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rShoulderRoll: 30, .lShoulderRoll: -30]), ms: 200, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "마카레나 (4단계 단순화)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .lShoulderPitch: -45]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .lShoulderPitch: -45, .rShoulderRoll: -30, .lShoulderRoll: 30]), ms: 250),
                P.holdAt(P.armsCross, ms: 250, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "머리 위 박수",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.deltaFromWalkReady([.rShoulderPitch: 85, .lShoulderPitch: -85, .rShoulderRoll: -15, .lShoulderRoll: 15]),
                side1: P.deltaFromWalkReady([.rShoulderPitch: 85, .lShoulderPitch: -85, .rShoulderRoll: 0, .lShoulderRoll: 0]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: 85, .lShoulderPitch: -85, .rShoulderRoll: -25, .lShoulderRoll: 25]),
                cycles: 4, msPerHalf: 180)))); id += 1

        pages.append(MotionPage(id: id, name: "사이드 스텝 + 박수",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipSwayL, ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: 10, .lHipRoll: 10, .rShoulderPitch: 25, .lShoulderPitch: -25, .rElbow: 60, .lElbow: -60]), ms: 200),
                P.holdAt(P.hipSwayR, ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: -10, .lHipRoll: -10, .rShoulderPitch: 25, .lShoulderPitch: -25, .rElbow: 60, .lElbow: -60]), ms: 200, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "한쪽 어깨 들썩 (R)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.deltaFromWalkReady([.rShoulderPitch: 10, .rShoulderRoll: -15]),
                side2: .walkReady,
                cycles: 4, msPerHalf: 150)))); id += 1

        pages.append(MotionPage(id: id, name: "양 어깨 들썩",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.deltaFromWalkReady([.rShoulderPitch: 10, .lShoulderPitch: -10, .rShoulderRoll: -15, .lShoulderRoll: 15]),
                side2: .walkReady,
                cycles: 4, msPerHalf: 150)))); id += 1

        pages.append(MotionPage(id: id, name: "보퍼 (무릎 굽혔다 펴기)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.kneesBent15,
                side2: .walkReady,
                cycles: 4, msPerHalf: 200)))); id += 1

        pages.append(MotionPage(id: id, name: "Heel-toe (한 발)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rAnklePitch: -20]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rAnklePitch: 20]), ms: 300),
                P.holdAt(.walkReady, ms: 300, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "Point dance (R 가리키며 흔들기)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.deltaFromWalkReady([.rShoulderPitch: 45, .rShoulderRoll: -35]),
                side1: P.deltaFromWalkReady([.rShoulderPitch: 40, .rShoulderRoll: -40]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: 50, .rShoulderRoll: -30]),
                cycles: 3, msPerHalf: 200)))); id += 1

        pages.append(MotionPage(id: id, name: "Point dance (L 가리키며 흔들기)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.deltaFromWalkReady([.lShoulderPitch: -45, .lShoulderRoll: 35]),
                side1: P.deltaFromWalkReady([.lShoulderPitch: -40, .lShoulderRoll: 40]),
                side2: P.deltaFromWalkReady([.lShoulderPitch: -50, .lShoulderRoll: 30]),
                cycles: 3, msPerHalf: 200)))); id += 1

        pages.append(MotionPage(id: id, name: "양팔 새 (flying bird)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.armsT,
                side1: P.deltaFromWalkReady([.rShoulderPitch: 10, .lShoulderPitch: -10, .rShoulderRoll: -85, .lShoulderRoll: 85]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: -10, .lShoulderPitch: 10, .rShoulderRoll: -55, .lShoulderRoll: 55]),
                cycles: 4, msPerHalf: 200)))); id += 1

        pages.append(MotionPage(id: id, name: "머리 까딱 + 손짓",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.armsAside,
                side1: P.deltaFromWalkReady([.rShoulderPitch: -20, .lShoulderPitch: 20, .headTilt: 10]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: -20, .lShoulderPitch: 20, .headTilt: -10]),
                cycles: 4, msPerHalf: 200)))); id += 1

        pages.append(MotionPage(id: id, name: "K-pop 하트 (머리 위)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 80, .lShoulderPitch: -80, .rShoulderRoll: -25, .lShoulderRoll: 25, .rElbow: 45, .lElbow: -45]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 80, .lShoulderPitch: -80, .rShoulderRoll: -25, .lShoulderRoll: 25, .rElbow: 45, .lElbow: -45]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "가슴 하트",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rShoulderRoll: 20, .lShoulderRoll: -20, .rElbow: 80, .lElbow: -80]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rShoulderRoll: 20, .lShoulderRoll: -20, .rElbow: 80, .lElbow: -80]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "양손 짠 (chear)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .lShoulderPitch: -90, .rShoulderRoll: -20, .lShoulderRoll: 20]), ms: 300),
                P.holdAt(P.armsUp, ms: 400, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "헤드뱅 (위아래)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.headLookDown,
                side2: P.headLookCenter,
                cycles: 4, msPerHalf: 180)))); id += 1

        pages.append(MotionPage(id: id, name: "어깨 + 머리 동기 bob",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 15, .lShoulderPitch: -15, .headTilt: 10]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -5, .lShoulderPitch: 5, .headTilt: -10]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 15, .lShoulderPitch: -15, .headTilt: 10]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -5, .lShoulderPitch: 5, .headTilt: -10]), ms: 200, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "단순 댄스 종합 (4단계)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -15, .lHipYaw: -15, .rShoulderRoll: -15, .lShoulderRoll: 15]), ms: 300),
                P.holdAt(P.armsUp, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 15, .lHipYaw: 15, .rShoulderRoll: 15, .lShoulderRoll: -15]), ms: 300),
            ])))

        return pages
    }

    // MARK: - 5. 운동·스트레칭 (30 페이지)
    //
    // 거북목·어깨·허리·다리·팔·손목. 책상 사용자 신체 케어.
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - `목 좌측 stretch` `목 우측 stretch` `목 위/아래 stretch` `목 회전` —
    //   Personal Assistant op2 page 100~108 (거북목 케어 시나리오) 직접 인용.
    //   기존 `ReferenceMotionLibrary.ergonomicPages` 와 동일 의도, 자세 합성 별도.
    // - `오른어깨/왼어깨 돌리기 (앞/뒤)` `양 어깨 동시` — Personal Assistant
    //   page 100~108 의 어깨 케어 인용.
    // - `양팔 위/옆/뒤` `팔꿈치 stretch (R/L)` `허리 트위스트/lean` `lunge (R/L)`
    //   `발끝 들기` `한쪽 발 들기` — Personal Assistant page 100~108 ergonomic
    //   시나리오 패턴 인용 + 사용자 확장.
    // - `깊은 squat × 3` `팔꿈치 회전` `신호등` `종합 stretch` —
    //   **자체 발상**. v1.1 사용자 review 권장.
    public static func stretchPages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        // 목 stretch (5)
        pages.append(MotionPage(id: id, name: "목 좌측 stretch",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookLeft, ms: 600),
                P.holdAt(P.headLookLeft, ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "목 우측 stretch",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookRight, ms: 600),
                P.holdAt(P.headLookRight, ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "목 위 stretch",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookUp, ms: 600),
                P.holdAt(P.headLookUp, ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "목 아래 stretch",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookDown, ms: 600),
                P.holdAt(P.headLookDown, ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "목 회전 (좌-위-우-아래)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookLeft, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.headPan: -30, .headTilt: 15]), ms: 400),
                P.holdAt(P.headLookUp, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.headPan: 30, .headTilt: 15]), ms: 400),
                P.holdAt(P.headLookRight, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.headPan: 30, .headTilt: -15]), ms: 400),
                P.holdAt(P.headLookDown, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.headPan: -30, .headTilt: -15]), ms: 400, pause: 200),
            ]))); id += 1

        // 어깨 stretch (5)
        pages.append(MotionPage(id: id, name: "오른어깨 앞 돌리기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 60, .rShoulderRoll: -10]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .rShoulderRoll: -20]), ms: 250),
                P.holdAt(.walkReady, ms: 250, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "오른어깨 뒤 돌리기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 0, .rShoulderRoll: -25]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .rShoulderRoll: -15]), ms: 250),
                P.holdAt(.walkReady, ms: 250, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "왼어깨 앞 돌리기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -30]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -60, .lShoulderRoll: 10]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -30, .lShoulderRoll: 20]), ms: 250),
                P.holdAt(.walkReady, ms: 250, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "왼어깨 뒤 돌리기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 30]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 0, .lShoulderRoll: 25]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -30, .lShoulderRoll: 15]), ms: 250),
                P.holdAt(.walkReady, ms: 250, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "양 어깨 동시 돌리기 (앞)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 60, .lShoulderPitch: -60, .rShoulderRoll: -10, .lShoulderRoll: 10]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rShoulderRoll: -20, .lShoulderRoll: 20]), ms: 300),
                P.holdAt(.walkReady, ms: 300, pause: 200),
            ]))); id += 1

        // 팔 stretch (5)
        pages.append(MotionPage(id: id, name: "양팔 위로 (deep)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 600),
                P.holdAt(P.armsUp, ms: 1800, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "양팔 옆 (chest open)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: -85, .lShoulderRoll: 85, .rShoulderPitch: -10, .lShoulderPitch: 10]), ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "양팔 뒤 (어깨 stretch)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsBothBackward, ms: 600),
                P.holdAt(P.armsBothBackward, ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "팔꿈치 stretch (R)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .rElbow: 130]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .rElbow: 130]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "팔꿈치 stretch (L)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -90, .lElbow: -130]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -90, .lElbow: -130]), ms: 1500, pause: 400),
            ]))); id += 1

        // 허리 stretch (5)
        pages.append(MotionPage(id: id, name: "허리 좌 트위스트",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -30, .lHipYaw: -30]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -30, .lHipYaw: -30]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "허리 우 트위스트",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 30, .lHipYaw: 30]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 30, .lHipYaw: 30]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "허리 좌 lean",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: -20, .lShoulderRoll: -20, .rHipRoll: -15, .lHipRoll: -15]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: -20, .lShoulderRoll: -20, .rHipRoll: -15, .lHipRoll: -15]), ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "허리 우 lean",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: 20, .lShoulderRoll: 20, .rHipRoll: 15, .lHipRoll: 15]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: 20, .lShoulderRoll: 20, .rHipRoll: 15, .lHipRoll: 15]), ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "허리 앞 lean (햄스트링)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .lHipPitch: 25, .headTilt: -15]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .lHipPitch: 25, .headTilt: -15]), ms: 1500, pause: 400),
            ]))); id += 1

        // 다리 stretch (5)
        pages.append(MotionPage(id: id, name: "오른쪽 lunge (단순)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .rKnee: 25, .rAnklePitch: 0]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .rKnee: 25, .rAnklePitch: 0]), ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "왼쪽 lunge (단순)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 25, .lKnee: -25, .lAnklePitch: 0]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 25, .lKnee: -25, .lAnklePitch: 0]), ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "깊은 squat (반복 3회)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.squatLow,
                side2: .walkReady,
                cycles: 3, msPerHalf: 400)))); id += 1
        pages.append(MotionPage(id: id, name: "발끝 들기 (까치발)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rAnklePitch: -20, .lAnklePitch: 20]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rAnklePitch: -20, .lAnklePitch: 20]), ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "한쪽 발 들기 (R)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .rKnee: 30]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .rKnee: 30]), ms: 1200, pause: 400),
            ]))); id += 1

        // 손목·종합 (5)
        pages.append(MotionPage(id: id, name: "한쪽 발 들기 (L)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 25, .lKnee: -30]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 25, .lKnee: -30]), ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "팔꿈치 회전 (R)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.deltaFromWalkReady([.rElbow: 45]),
                side2: P.deltaFromWalkReady([.rElbow: -45]),
                cycles: 3, msPerHalf: 200)))); id += 1
        pages.append(MotionPage(id: id, name: "팔꿈치 회전 (L)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.deltaFromWalkReady([.lElbow: -45]),
                side2: P.deltaFromWalkReady([.lElbow: 45]),
                cycles: 3, msPerHalf: 200)))); id += 1
        pages.append(MotionPage(id: id, name: "신호등 (위-옆-아래)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 500, pause: 200),
                P.holdAt(P.armsT, ms: 500, pause: 200),
                P.holdAt(P.armsAside, ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "종합 stretch (목+어깨)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookLeft, ms: 500, pause: 200),
                P.holdAt(P.headLookRight, ms: 500, pause: 200),
                P.holdAt(P.armsUp, ms: 500),
                P.holdAt(P.armsBothBackward, ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "종합 stretch (허리+다리)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -20, .lHipYaw: -20]), ms: 500, pause: 200),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 20, .lHipYaw: 20]), ms: 500, pause: 200),
                P.holdAt(P.squatLow, ms: 500, pause: 200),
            ])))

        return pages
    }

    // MARK: - 6. 요가·필라테스 (20 페이지)
    //
    // warrior·tree·child pose 등 정적 hold. 휴머노이드 체형 한계로 단순화.
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - **카테고리 전체가 자체 발상**. ROBOTIS·외부 reference 의 요가 모션 없음.
    // - Yoga pose 명은 일반 공개 자료 (warrior I/II, tree, mountain, child, cobra,
    //   downward dog, cat, cow, half moon, chair, eagle, plank, side angle,
    //   triangle, dancer, boat, bridge, seated forward, corpse) 의 관절 의미를
    //   휴머노이드 OP2 의 20-DOF 한계 안에서 단순화.
    // - 20개 모두 사용자 review 권장. 휴머노이드 메커니즘 한계로 의도-실제 일치
    //   정밀 검증 필요 (`Tree pose` 한 발 서기, `Plank` 앞 lean 등은 균형 위험).
    public static func yogaPages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        pages.append(MotionPage(id: id, name: "Warrior I (전사 1)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .rKnee: 25, .rShoulderPitch: 90, .lShoulderPitch: -90]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .rKnee: 25, .rShoulderPitch: 90, .lShoulderPitch: -90]), ms: 1800, pause: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Warrior II (전사 2)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -20, .rKnee: 20, .rHipRoll: -10, .lHipRoll: -10, .rShoulderRoll: -85, .lShoulderRoll: 85]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -20, .rKnee: 20, .rHipRoll: -10, .lHipRoll: -10, .rShoulderRoll: -85, .lShoulderRoll: 85]), ms: 1800, pause: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Tree pose (나무, R)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 18, .lKnee: -25, .lHipRoll: 12]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 18, .lKnee: -25, .lHipRoll: 12,
                    .rShoulderPitch: 45, .lShoulderPitch: -45, .rShoulderRoll: 30, .lShoulderRoll: -30,
                    .rElbow: 80, .lElbow: -80]), ms: 1800, pause: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Mountain pose (산)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsPraying, ms: 700),
                P.holdAt(P.armsPraying, ms: 2000, pause: 600),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Child pose (아이)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -30, .lHipPitch: 30, .rKnee: 25, .lKnee: -25, .headTilt: -25]), ms: 800),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -30, .lHipPitch: 30, .rKnee: 25, .lKnee: -25, .headTilt: -25,
                    .rShoulderPitch: 45, .lShoulderPitch: -45]), ms: 1800, pause: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Cobra (코브라)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.headTilt: 20, .rShoulderPitch: -20, .lShoulderPitch: 20]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.headTilt: 20, .rShoulderPitch: -20, .lShoulderPitch: 20]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Downward Dog (아래 견)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -30, .lHipPitch: 30, .rShoulderPitch: 90, .lShoulderPitch: -90, .headTilt: -20]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -30, .lHipPitch: 30, .rShoulderPitch: 90, .lShoulderPitch: -90, .headTilt: -20]), ms: 1800, pause: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Cat (고양이, 등 굽힘)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.headTilt: -20, .rHipPitch: -10, .lHipPitch: 10]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.headTilt: -20, .rHipPitch: -10, .lHipPitch: 10]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Cow (소, 등 펴기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.headTilt: 20, .rHipPitch: 10, .lHipPitch: -10]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.headTilt: 20, .rHipPitch: 10, .lHipPitch: -10]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Half Moon (반달)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: -25, .lShoulderRoll: -25, .rHipRoll: -12, .lHipRoll: -12, .lShoulderPitch: -75]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: -25, .lShoulderRoll: -25, .rHipRoll: -12, .lHipRoll: -12, .lShoulderPitch: -75]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Chair pose (의자)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .lHipPitch: 15, .rKnee: 18, .lKnee: -18, .rShoulderPitch: 85, .lShoulderPitch: -85]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .lHipPitch: 15, .rKnee: 18, .lKnee: -18, .rShoulderPitch: 85, .lShoulderPitch: -85]), ms: 1800, pause: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Eagle (독수리)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .lShoulderPitch: -45, .rShoulderRoll: 25, .lShoulderRoll: -25, .rElbow: 90, .lElbow: -90, .rKnee: 15, .lKnee: -15]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .lShoulderPitch: -45, .rShoulderRoll: 25, .lShoulderRoll: -25, .rElbow: 90, .lElbow: -90, .rKnee: 15, .lKnee: -15]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Plank (플랭크)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -20, .lHipPitch: 20, .rShoulderPitch: 85, .lShoulderPitch: -85, .headTilt: -18]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -20, .lHipPitch: 20, .rShoulderPitch: 85, .lShoulderPitch: -85, .headTilt: -18]), ms: 1800, pause: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Side Angle (옆각)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .rKnee: 25, .rShoulderRoll: -85, .lShoulderPitch: -90, .lShoulderRoll: 20]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .rKnee: 25, .rShoulderRoll: -85, .lShoulderPitch: -90, .lShoulderRoll: 20]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Triangle (삼각)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: -12, .lHipRoll: -12, .rShoulderRoll: -85, .lShoulderRoll: 85, .rShoulderPitch: -15, .lShoulderPitch: 15]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: -12, .lHipRoll: -12, .rShoulderRoll: -85, .lShoulderRoll: 85, .rShoulderPitch: -15, .lShoulderPitch: 15]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Dancer pose (춤꾼)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 20, .lKnee: -30, .rShoulderPitch: 85, .lShoulderPitch: -40, .lElbow: -90]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 20, .lKnee: -30, .rShoulderPitch: 85, .lShoulderPitch: -40, .lElbow: -90]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Boat pose (배)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -35, .lHipPitch: 35, .rKnee: 25, .lKnee: -25, .rShoulderPitch: 45, .lShoulderPitch: -45]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -35, .lHipPitch: 35, .rKnee: 25, .lKnee: -25, .rShoulderPitch: 45, .lShoulderPitch: -45]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Bridge (다리)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: 15, .lHipPitch: -15, .headTilt: 20]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: 15, .lHipPitch: -15, .headTilt: 20]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Seated forward bend",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -30, .lHipPitch: 30, .rKnee: 30, .lKnee: -30, .headTilt: -25]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -30, .lHipPitch: 30, .rKnee: 30, .lKnee: -30, .headTilt: -25, .rShoulderPitch: 60, .lShoulderPitch: -60]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Corpse (사바아사나)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsAside, ms: 600),
                P.holdAt(P.armsAside, ms: 2500, pause: 800),
            ])))

        return pages
    }

    // MARK: - 7. 태권도·무술 (25 페이지)
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - `정권 (R/L/양)` `위/아래 막기` `중단 막기` — **자체 발상**. ROBOTIS catalog 의
    //   page 12 "Right Kick" (HighRisk) + page 13 "Left Kick" 의 kick 자세 패턴
    //   영감만 — 정권·막기는 직접 인용 없음.
    // - `옆차기/앞차기/돌려차기 자세 (R/L)` — ROBOTIS catalog page 12/13 의 kick
    //   자세 일부 패턴 인용.
    // - `학다리 자세` `뒷발차기 자세` — **자체 발상**. ROBOTIS 의 page 17
    //   "Hand Standing" (HighRisk) 패턴과 유사 단순화.
    // - `자유 자세` `후방 자세` `정권 콤보` `막기 콤보` `사범 인사` `호흡 자세`
    //   `권법 시작 자세` `마무리 자세` — **모두 자체 발상**.
    // - **안전 주의**: HighRisk 클래스 모션이 포함될 수 있음 — 균형 한계 검증
    //   필수. 실 로봇 송출 전 `single_foot_ok` metadata 확인.
    public static func martialPages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        pages.append(MotionPage(id: id, name: "기본 자세 (정권 준비)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -5, .lShoulderPitch: 5, .rElbow: 90, .lElbow: -90, .rShoulderRoll: -5, .lShoulderRoll: 5]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -5, .lShoulderPitch: 5, .rElbow: 90, .lElbow: -90, .rShoulderRoll: -5, .lShoulderRoll: 5]), ms: 1500, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "정권 (오른쪽 펀치)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -5, .rElbow: 90]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rElbow: 0]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rElbow: 0]), ms: 300, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "정권 (왼쪽 펀치)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 5, .lElbow: -90]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -45, .lElbow: 0]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -45, .lElbow: 0]), ms: 300, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "양 정권 동시",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -5, .lShoulderPitch: 5, .rElbow: 90, .lElbow: -90]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .lShoulderPitch: -45]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .lShoulderPitch: -45]), ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "위 막기 (양손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 75, .lShoulderPitch: -75, .rShoulderRoll: -10, .lShoulderRoll: 10, .rElbow: 45, .lElbow: -45]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 75, .lShoulderPitch: -75, .rShoulderRoll: -10, .lShoulderRoll: 10, .rElbow: 45, .lElbow: -45]), ms: 1000, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "아래 막기 (양손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .lShoulderPitch: 30, .rShoulderRoll: -15, .lShoulderRoll: 15, .rElbow: 30, .lElbow: -30]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .lShoulderPitch: 30, .rShoulderRoll: -15, .lShoulderRoll: 15, .rElbow: 30, .lElbow: -30]), ms: 1000, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "중단 막기 (오른)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 20, .rShoulderRoll: -25, .rElbow: 90]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 20, .rShoulderRoll: -25, .rElbow: 90]), ms: 1000, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "중단 막기 (왼)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -20, .lShoulderRoll: 25, .lElbow: -90]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -20, .lShoulderRoll: 25, .lElbow: -90]), ms: 1000, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "옆차기 자세 (R 발 들기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: -20, .rHipPitch: -15, .rKnee: 25]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: -20, .rHipPitch: -15, .rKnee: 25]), ms: 1000, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "옆차기 자세 (L 발 들기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipRoll: 20, .lHipPitch: 15, .lKnee: -25]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.lHipRoll: 20, .lHipPitch: 15, .lKnee: -25]), ms: 1000, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "앞차기 (R 발 앞)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .rKnee: 30]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -35, .rKnee: 10]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .rKnee: 30]), ms: 300, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "앞차기 (L 발 앞)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 25, .lKnee: -30]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 35, .lKnee: -10]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 25, .lKnee: -30]), ms: 300, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "돌려차기 자세 (R)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -25, .rHipRoll: -15, .rHipPitch: -20, .rKnee: 25]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -25, .rHipRoll: -15, .rHipPitch: -20, .rKnee: 25]), ms: 1000, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "돌려차기 자세 (L)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipYaw: 25, .lHipRoll: 15, .lHipPitch: 20, .lKnee: -25]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.lHipYaw: 25, .lHipRoll: 15, .lHipPitch: 20, .lKnee: -25]), ms: 1000, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "학다리 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 25, .lKnee: -35, .rShoulderPitch: 75, .lShoulderPitch: -75]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 25, .lKnee: -35, .rShoulderPitch: 75, .lShoulderPitch: -75]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "뒷발차기 자세 (R)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: 20, .rKnee: 5, .headTilt: -10]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: 25, .rKnee: 5, .headTilt: -10]), ms: 1000, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "뒷발차기 자세 (L)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: -20, .lKnee: -5, .headTilt: -10]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: -25, .lKnee: -5, .headTilt: -10]), ms: 1000, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "자유 자세 (양손 가드)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rShoulderRoll: -15, .lShoulderRoll: 15, .rElbow: 100, .lElbow: -100]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rShoulderRoll: -15, .lShoulderRoll: 15, .rElbow: 100, .lElbow: -100]), ms: 1500, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "후방 자세 (뒷 무릎 굽힘)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: 15, .rKnee: 20, .lHipPitch: -10, .lKnee: -5]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: 15, .rKnee: 20, .lHipPitch: -10, .lKnee: -5]), ms: 1200, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "정권 콤보 (R-L-R)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rElbow: 0]), ms: 250),
                P.holdAt(.walkReady, ms: 200),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -45, .lElbow: 0]), ms: 250),
                P.holdAt(.walkReady, ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rElbow: 0]), ms: 250, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "막기 콤보 (위-중-아래)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 75, .lShoulderPitch: -75]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 20, .lShoulderPitch: -20]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .lShoulderPitch: 30]), ms: 300, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "사범 인사 (깊은 절)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsPraying, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .lHipPitch: 25, .headTilt: -20,
                    .rShoulderPitch: 45, .lShoulderPitch: -45, .rShoulderRoll: 30, .lShoulderRoll: -30,
                    .rElbow: 80, .lElbow: -80]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "호흡 자세 (양손 모으기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: -45, .lShoulderRoll: 45, .rElbow: 60, .lElbow: -60]), ms: 600),
                P.holdAt(P.armsT, ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: -45, .lShoulderRoll: 45, .rElbow: 60, .lElbow: -60]), ms: 600, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "권법 시작 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 15, .lShoulderPitch: -15, .rElbow: 60, .lElbow: -60, .rKnee: 8, .lKnee: -8]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 15, .lShoulderPitch: -15, .rElbow: 60, .lElbow: -60, .rKnee: 8, .lKnee: -8]), ms: 1300, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "마무리 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -5, .lShoulderPitch: 5, .rElbow: 90, .lElbow: -90]), ms: 400),
                P.holdAt(P.bowSlight, ms: 700, pause: 400),
            ])))

        return pages
    }

    // MARK: - 8. 보행 변형 (20 페이지)
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - 기존 Sprint 5 walk progression (`ReferenceMotionLibrary.walkProgressionPages`,
    //   page 110~115 ID) 의 보행 검증 패턴 인용 — `motions/test/walk-progression-v1.bin`
    //   의 slot 110~115 와 의도 일치.
    // - `앞/뒤로 한 걸음` `옆걸음 (L/R)` `90° 회전 (L/R)` `조심걸음` `빠른 걸음` —
    //   ROBOTIS-OP2 `op2_walking_module/config/param.yaml` 의 stride/period
    //   파라미터 변형 단순화. **자세 합성은 자체**.
    // - 나머지 `cycle 시작/끝` `발 swap` `무릎 들기` `앞/옆 lean+발` `걸음 후
    //   정지` `회전 보행` `보행 후 정렬` — **자체 발상**. Sprint 5 walking-engine
    //   진입 전 motion primitive 단위 격리 검증 의도.
    public static func walkVariantPages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        pages.append(MotionPage(id: id, name: "앞으로 한 걸음 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .rKnee: 10, .lHipPitch: 5]), ms: 500),
                P.holdAt(.walkReady, ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "뒤로 한 걸음 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: 10, .lHipPitch: -15, .lKnee: -10]), ms: 500),
                P.holdAt(.walkReady, ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "옆걸음 좌",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipSwayL, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: 12, .lHipRoll: 12, .lHipPitch: 8]), ms: 400),
                P.holdAt(.walkReady, ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "옆걸음 우",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipSwayR, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: -12, .lHipRoll: -12, .rHipPitch: -8]), ms: 400),
                P.holdAt(.walkReady, ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "좌측 90° 회전 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -30, .lHipYaw: -30, .headPan: -30]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -30, .lHipYaw: -30, .headPan: -30]), ms: 800, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "우측 90° 회전 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 30, .lHipYaw: 30, .headPan: 30]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 30, .lHipYaw: 30, .headPan: 30]), ms: 800, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "조심걸음 (느림)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.kneesBent5, ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -10, .rKnee: 12]), ms: 800),
                P.holdAt(P.kneesBent5, ms: 600, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "빠른 걸음 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipLeanFwd, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -18, .rKnee: 15]), ms: 300),
                P.holdAt(P.hipLeanFwd, ms: 300, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "보행 cycle 시작 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 15, .lShoulderPitch: -15]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 15, .lShoulderPitch: -15, .rHipPitch: -8]), ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "보행 cycle 끝 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.kneesBent5, ms: 400),
                P.holdAt(.walkReady, ms: 600, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "측면 발 swap (L→R)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipSwayL, ms: 350),
                P.holdAt(.walkReady, ms: 300),
                P.holdAt(P.hipSwayR, ms: 350, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "측면 발 swap (R→L)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipSwayR, ms: 350),
                P.holdAt(.walkReady, ms: 300),
                P.holdAt(P.hipSwayL, ms: 350, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "무릎 들기 R (보행 준비)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -20, .rKnee: 30]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -20, .rKnee: 30]), ms: 800, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "무릎 들기 L (보행 준비)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 20, .lKnee: -30]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 20, .lKnee: -30]), ms: 800, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "앞 lean + 발 옆",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipLeanFwd, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -8, .lHipPitch: 8, .rHipRoll: -10, .lHipRoll: -10]), ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "옆 lean + 발 앞",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipSwayR, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: -10, .lHipRoll: -10, .rHipPitch: -10]), ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "걸음 후 정지 (안정)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 5, .lShoulderPitch: -5, .rKnee: 5, .lKnee: -5]), ms: 600),
                P.holdAt(.walkReady, ms: 1000, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "회전 보행 (좌)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -15, .lHipYaw: -15]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -25, .lHipYaw: -25, .headPan: -20]), ms: 500),
                P.holdAt(.walkReady, ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "회전 보행 (우)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 15, .lHipYaw: 15]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 25, .lHipYaw: 25, .headPan: 20]), ms: 500),
                P.holdAt(.walkReady, ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "보행 후 정렬",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookCenter, ms: 400),
                P.holdAt(.walkReady, ms: 800, pause: 400),
            ])))

        return pages
    }

    // MARK: - 9. 균형·곡예 (15 페이지)
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - **카테고리 전체가 자체 발상**. ROBOTIS·외부 reference 의 균형 모션 없음.
    // - `한발 서기 (R/L)` `까치발` `한발 + T/위/flying bird/합장` `90° 회전 (L/R)`
    //   — 휴머노이드 균형 한계 미검증. 실 로봇 실행 시 낙상 위험 가능.
    // - `정적 균형` `한발 + 옆 lean` — 보수적 자세 (균형 한계 안).
    // - 15개 모두 사용자 review + 실 로봇 검증 필수 (HighRisk safety class 권장).
    public static func balancePages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        pages.append(MotionPage(id: id, name: "한발 서기 (R 들기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .rKnee: 20, .lHipRoll: 8]), ms: 800),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .rKnee: 20, .lHipRoll: 8]), ms: 2000, pause: 600),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "한발 서기 (L 들기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 15, .lKnee: -20, .rHipRoll: -8]), ms: 800),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 15, .lKnee: -20, .rHipRoll: -8]), ms: 2000, pause: 600),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "까치발 hold",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rAnklePitch: -22, .lAnklePitch: 22]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rAnklePitch: -22, .lAnklePitch: 22]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "한발 + 양팔 T",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .rKnee: 20, .lHipRoll: 8, .rShoulderRoll: -70, .lShoulderRoll: 70]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "한발 + 양팔 위",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 15, .lKnee: -20, .rShoulderPitch: 90, .lShoulderPitch: -90]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Lean (오른쪽)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipSwayR, ms: 500),
                P.holdAt(P.hipSwayR, ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Lean (왼쪽)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipSwayL, ms: 500),
                P.holdAt(P.hipSwayL, ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Lean 앞 (큰)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipLeanFwd, ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .lHipPitch: 15, .rAnklePitch: 15, .lAnklePitch: -15]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Lean 뒤 (큰)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipLeanBack, ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: 15, .lHipPitch: -15, .rAnklePitch: -15, .lAnklePitch: 15]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "90° 회전 (좌)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -45, .lHipYaw: -45, .headPan: -45]), ms: 800),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -45, .lHipYaw: -45, .headPan: -45]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "90° 회전 (우)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 45, .lHipYaw: 45, .headPan: 45]), ms: 800),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 45, .lHipYaw: 45, .headPan: 45]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "한발 + Flying bird",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .rKnee: 20, .lHipRoll: 8, .rShoulderRoll: -80, .lShoulderRoll: 80]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .rKnee: 20, .lHipRoll: 8, .rShoulderRoll: -60, .lShoulderRoll: 60]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .rKnee: 20, .lHipRoll: 8, .rShoulderRoll: -80, .lShoulderRoll: 80]), ms: 500, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "한발 + 합장",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .rKnee: 20, .lHipRoll: 8]), ms: 600),
                P.holdAt(P.armsPraying, ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "정적 균형 (다 굽힘)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rKnee: 18, .lKnee: -18, .rHipPitch: -8, .lHipPitch: 8, .rShoulderRoll: -25, .lShoulderRoll: 25]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rKnee: 18, .lKnee: -18, .rHipPitch: -8, .lHipPitch: 8, .rShoulderRoll: -25, .lShoulderRoll: 25]), ms: 2000, pause: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "한발 + 옆 lean",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .rKnee: 20, .lHipRoll: 12, .rShoulderRoll: -30, .lShoulderRoll: -30]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .rKnee: 20, .lHipRoll: 12, .rShoulderRoll: -30, .lShoulderRoll: -30]), ms: 1500, pause: 400),
            ])))

        return pages
    }

    // MARK: - 10. 시선·머리 (20 페이지)
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - **카테고리 전체가 자체 발상**. ROBOTIS·외부 reference 의 시선 시퀀스 없음.
    // - 머리 pan/tilt 의 ±45° / ±25° 한도 안에서 안전 (JointLimits 통과).
    // - `손가락 따라가기 (R/L)` — 어깨 + 머리 동시 움직임. 자가충돌 위험 낮음.
    // - 20개 모두 사용자 review 권장. 단 머리 단독 동작이라 안전 위험 가장 낮음.
    public static func gazePages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        pages.append(MotionPage(id: id, name: "좌-우 둘러보기 (스캔)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookLeft, ms: 400, pause: 200),
                P.holdAt(P.headLookRight, ms: 600, pause: 200),
                P.holdAt(P.headLookLeft, ms: 600, pause: 200),
                P.holdAt(P.headLookCenter, ms: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "위-아래 둘러보기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookUp, ms: 400, pause: 200),
                P.holdAt(P.headLookDown, ms: 600, pause: 200),
                P.holdAt(P.headLookCenter, ms: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "8방향 시선",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.headPan: -30, .headTilt: 15]), ms: 300, pause: 100),
                P.holdAt(P.headLookUp, ms: 300, pause: 100),
                P.holdAt(P.deltaFromWalkReady([.headPan: 30, .headTilt: 15]), ms: 300, pause: 100),
                P.holdAt(P.headLookRight, ms: 300, pause: 100),
                P.holdAt(P.deltaFromWalkReady([.headPan: 30, .headTilt: -15]), ms: 300, pause: 100),
                P.holdAt(P.headLookDown, ms: 300, pause: 100),
                P.holdAt(P.deltaFromWalkReady([.headPan: -30, .headTilt: -15]), ms: 300, pause: 100),
                P.holdAt(P.headLookLeft, ms: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "천천히 좌 → 우",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookLeft, ms: 800),
                P.holdAt(P.headLookCenter, ms: 800),
                P.holdAt(P.headLookRight, ms: 800, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "천천히 위 → 아래",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookUp, ms: 800),
                P.holdAt(P.headLookCenter, ms: 800),
                P.holdAt(P.headLookDown, ms: 800, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "머리 원 (순회)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookUp, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.headPan: 30, .headTilt: 10]), ms: 300),
                P.holdAt(P.headLookRight, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.headPan: 30, .headTilt: -10]), ms: 300),
                P.holdAt(P.headLookDown, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.headPan: -30, .headTilt: -10]), ms: 300),
                P.holdAt(P.headLookLeft, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.headPan: -30, .headTilt: 10]), ms: 300, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "오른쪽 응시 (1.5s)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookRight, ms: 500),
                P.holdAt(P.headLookRight, ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "왼쪽 응시 (1.5s)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookLeft, ms: 500),
                P.holdAt(P.headLookLeft, ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "위 응시 (천장)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookUp, ms: 500),
                P.holdAt(P.headLookUp, ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "아래 응시 (바닥)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookDown, ms: 500),
                P.holdAt(P.headLookDown, ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "손가락 따라가기 (R)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rShoulderRoll: -25, .headPan: -25]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rShoulderRoll: -30, .headPan: -30]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rShoulderRoll: -25, .headPan: -25]), ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "손가락 따라가기 (L)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -45, .lShoulderRoll: 25, .headPan: 25]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -45, .lShoulderRoll: 30, .headPan: 30]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -45, .lShoulderRoll: 25, .headPan: 25]), ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "시선 빠르게 좌우 (×3)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.headLookCenter,
                side1: P.headLookLeft,
                side2: P.headLookRight,
                cycles: 3, msPerHalf: 150)))); id += 1
        pages.append(MotionPage(id: id, name: "시선 천천히 좌우 (×2)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.headLookCenter,
                side1: P.headLookLeft,
                side2: P.headLookRight,
                cycles: 2, msPerHalf: 400)))); id += 1
        pages.append(MotionPage(id: id, name: "작은 머리 흔들기 (no)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.headLookCenter,
                side1: P.deltaFromWalkReady([.headPan: -12]),
                side2: P.deltaFromWalkReady([.headPan: 12]),
                cycles: 3, msPerHalf: 180)))); id += 1
        pages.append(MotionPage(id: id, name: "작은 끄덕임 (yes)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.headLookCenter,
                side1: P.deltaFromWalkReady([.headTilt: -8]),
                side2: P.headLookCenter,
                cycles: 4, msPerHalf: 180)))); id += 1
        pages.append(MotionPage(id: id, name: "머리 둘레 회전 (반대방향)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.headPan: -30, .headTilt: -10]), ms: 300),
                P.holdAt(P.headLookDown, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.headPan: 30, .headTilt: -10]), ms: 300),
                P.holdAt(P.headLookRight, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.headPan: 30, .headTilt: 10]), ms: 300),
                P.holdAt(P.headLookUp, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.headPan: -30, .headTilt: 10]), ms: 300, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "시선 + 양손 가리킴 (R)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rShoulderRoll: -35, .headPan: -35]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rShoulderRoll: -35, .headPan: -35]), ms: 1200, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "시선 + 호기심 (왼쪽)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.headPan: -25, .headTilt: 10]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.headPan: -25, .headTilt: -10]), ms: 500, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "종합 시선 (4단계)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookLeft, ms: 400, pause: 200),
                P.holdAt(P.headLookUp, ms: 400, pause: 200),
                P.holdAt(P.headLookRight, ms: 400, pause: 200),
                P.holdAt(P.headLookDown, ms: 400, pause: 200),
            ])))

        return pages
    }

    // MARK: - 11. 데모·엔터테인 (30 페이지)
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - **카테고리 전체가 자체 발상**. ROBOTIS·외부 reference 의 데모 모션 없음.
    // - 패턴 영감: HROS5-Framework `Data/motion_4096.bin` 의 인터랙티브 페이지 디자인
    //   (사진 포즈, 박수 환영, 노래 등) — 관절값 합성 X.
    // - `마법사` `짠!` `노래하기` `박수 환영 × 5` `환호 + 박수` `신호등 동작`
    //   `무용수` `마술쇼` `사진 포즈 (V/위/자랑)` `짧은/긴 안내` `회전 스핀`
    //   `영웅 등장` `마이크 자세` `노래 + 박수` `코미디` `신난다` `자기 소개`
    //   `학예회 인사` `호스트 환영` `카메라 V` `K-pop 머리위` `노래방`
    //   `인사 + 응원` `환영 + 인사 + 박수` `종합 데모 (4/6 단계)` `마지막 인사` —
    //   **30개 모두 자체 발상**. 사용자 review 권장.
    public static func demoPages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        pages.append(MotionPage(id: id, name: "마법사 (양팔 흔들기 + 머리위)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 85, .lShoulderPitch: -85, .rShoulderRoll: -20, .lShoulderRoll: 20]), ms: 300),
                P.holdAt(P.armsUp, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 85, .lShoulderPitch: -85, .rShoulderRoll: 20, .lShoulderRoll: -20]), ms: 300, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "짠! (등장)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 200),
                P.holdAt(P.armsT, ms: 200),
                P.holdAt(P.armsUp, ms: 600, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "노래하기 (양손 입 앞)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .lShoulderPitch: -45, .rShoulderRoll: 25, .lShoulderRoll: -25, .rElbow: 90, .lElbow: -90]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .lShoulderPitch: -45, .rShoulderRoll: 25, .lShoulderRoll: -25, .rElbow: 90, .lElbow: -90, .headTilt: 10]), ms: 800, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "박수 환영 (×5)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rElbow: 60, .lElbow: -60]),
                side1: P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rElbow: 50, .lElbow: -50]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: 35, .lShoulderPitch: -35, .rElbow: 65, .lElbow: -65]),
                cycles: 5, msPerHalf: 130)))); id += 1
        pages.append(MotionPage(id: id, name: "환호 + 박수",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rElbow: 60, .lElbow: -60]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rElbow: 50, .lElbow: -50]), ms: 200),
                P.holdAt(P.armsUp, ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "신호등 동작 (위-옆-아래)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 500, pause: 200),
                P.holdAt(P.armsT, ms: 500, pause: 200),
                P.holdAt(P.armsAside, ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "무용수 (한 발 + 양팔)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 15, .lKnee: -25]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 15, .lKnee: -25, .rShoulderRoll: -85, .lShoulderRoll: 85]), ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "마술쇼 (양손 위 + 회전)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .lShoulderPitch: -90, .rHipYaw: -15, .lHipYaw: -15]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .lShoulderPitch: -90, .rHipYaw: 15, .lHipYaw: 15]), ms: 400),
                P.holdAt(P.armsUp, ms: 400, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "사진 포즈 (V 자, R)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 75, .rShoulderRoll: -15, .rElbow: 75]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 75, .rShoulderRoll: -15, .rElbow: 75, .headTilt: 5]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "사진 포즈 (양손 위)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .lShoulderPitch: -90, .rElbow: 30, .lElbow: -30]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "사진 포즈 (자랑 시선)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsHipHip, ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 10, .lShoulderPitch: -10, .rElbow: 90, .lElbow: -90, .headPan: -10, .headTilt: 5]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "짧은 안내 (가리키기 R)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .rShoulderRoll: -30]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .rShoulderRoll: -30]), ms: 800, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "긴 안내 (좌우 가리키기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -30, .lShoulderRoll: 30]), ms: 500, pause: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .rShoulderRoll: -30]), ms: 500, pause: 200),
                P.holdAt(P.armsT, ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "회전 (스핀, 좌→우)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -25, .lHipYaw: -25, .rShoulderRoll: -30, .lShoulderRoll: 30]), ms: 400),
                P.holdAt(.walkReady, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 25, .lHipYaw: 25, .rShoulderRoll: 30, .lShoulderRoll: -30]), ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "영웅 등장 (양팔 + 자세)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsHipHip, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 5, .lShoulderPitch: -5, .rElbow: 90, .lElbow: -90, .rKnee: 8, .lKnee: -8, .headTilt: 8]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "마이크 잡은 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 40, .rShoulderRoll: -10, .rElbow: 100]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 40, .rShoulderRoll: -10, .rElbow: 100, .headTilt: 5]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "노래 + 박수 (마이크 + clap)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 40, .rElbow: 100]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 40, .rElbow: 100, .lShoulderPitch: -30, .lShoulderRoll: -20, .lElbow: -60]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 40, .rElbow: 100, .lShoulderPitch: -30, .lShoulderRoll: 0, .lElbow: -60]), ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "코미디 (어이없음)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -20, .lShoulderPitch: 20, .rShoulderRoll: -30, .lShoulderRoll: 30, .rElbow: 60, .lElbow: -60, .headTilt: 10]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -20, .lShoulderPitch: 20, .rShoulderRoll: -30, .lShoulderRoll: 30, .rElbow: 60, .lElbow: -60, .headTilt: -10]), ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "신난다! (점프 자세)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rKnee: 15, .lKnee: -15]), ms: 200),
                P.holdAt(P.armsUp, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rKnee: 15, .lKnee: -15]), ms: 200),
                P.holdAt(P.armsUp, ms: 400, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "자기 소개 (가슴 손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .rShoulderRoll: -10, .rElbow: 100]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .rShoulderRoll: -10, .rElbow: 100, .headTilt: 5]), ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "학예회 인사 (단순 큰절)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 400),
                P.holdAt(P.bowDeep, ms: 800, pause: 400),
                P.holdAt(P.armsT, ms: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "호스트 환영 (큰 인사)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 500),
                P.holdAt(P.bowSlight, ms: 600, pause: 300),
                P.holdAt(P.armsRightWave, ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "카메라 V (양손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 75, .rShoulderRoll: -15, .rElbow: 75, .lShoulderPitch: -75, .lShoulderRoll: 15, .lElbow: -75]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 75, .rShoulderRoll: -15, .rElbow: 75, .lShoulderPitch: -75, .lShoulderRoll: 15, .lElbow: -75, .headTilt: 5]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "K-pop 머리위 (양손 모이기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 80, .lShoulderPitch: -80, .rShoulderRoll: -25, .lShoulderRoll: 25, .rElbow: 45, .lElbow: -45]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "노래방 (양손 마이크)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 40, .lShoulderPitch: -40, .rShoulderRoll: 10, .lShoulderRoll: -10, .rElbow: 100, .lElbow: -100]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 40, .lShoulderPitch: -40, .rShoulderRoll: 10, .lShoulderRoll: -10, .rElbow: 100, .lElbow: -100, .headTilt: 8]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "인사 + 응원",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.bowSlight, ms: 500, pause: 200),
                P.holdAt(P.armsUp, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .lShoulderPitch: -90, .rShoulderRoll: -15, .lShoulderRoll: 15]), ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "환영 + 인사 + 박수",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 400, pause: 200),
                P.holdAt(P.bowSlight, ms: 500, pause: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rElbow: 60, .lElbow: -60]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rElbow: 50, .lElbow: -50]), ms: 300, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "종합 데모 (4단계)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 400, pause: 200),
                P.holdAt(P.armsT, ms: 400, pause: 200),
                P.holdAt(P.bowSlight, ms: 400, pause: 200),
                P.holdAt(P.armsRightWave, ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "종합 데모 (6단계)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 350, pause: 150),
                P.holdAt(P.armsT, ms: 350, pause: 150),
                P.holdAt(P.armsCross, ms: 350, pause: 150),
                P.holdAt(P.bowSlight, ms: 350, pause: 150),
                P.holdAt(P.armsRightWave, ms: 350, pause: 150),
                P.holdAt(P.armsHipHip, ms: 350, pause: 150),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "마지막 인사 (큰 박수)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.bowDeep, ms: 600, pause: 300),
                P.holdAt(P.armsUp, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rElbow: 60, .lElbow: -60]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rElbow: 50, .lElbow: -50]), ms: 300, pause: 200),
            ])))

        return pages
    }

    // MARK: - 12. 체조·근력 (20 페이지)
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - **카테고리 전체가 자체 발상**. ROBOTIS·외부 reference 의 운동 모션 없음.
    // - 운동 명 (Jumping jack, Squat, Lunge, Push-up, Sit-up, Plank, Mountain
    //   climber, Bicep curl, Shoulder press, Leg raise, Calf raise, Burpee,
    //   High knees, Cooldown) 의 인간 자세 의미를 휴머노이드 OP2 의 20-DOF
    //   한계 안에서 단순화.
    // - **안전 주의**: Push-up / Plank 등 앞 lean 자세는 낙상 위험 있음. 실
    //   로봇 실행 전 single_foot_ok 또는 stable_two_foot metadata 확인 필수.
    // - 20개 모두 사용자 review 권장.
    public static func exercisePages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        pages.append(MotionPage(id: id, name: "Jumping jack 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(.walkReady, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: -75, .lShoulderRoll: 75, .rHipRoll: -10, .lHipRoll: 10]), ms: 400),
                P.holdAt(.walkReady, ms: 300, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Squat hold (3초)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.squatLow, ms: 500),
                P.holdAt(P.squatLow, ms: 2500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Squat × 3",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady, side1: P.squatLow, side2: .walkReady,
                cycles: 3, msPerHalf: 350)))); id += 1
        pages.append(MotionPage(id: id, name: "Lunge R (앞 무릎 굽힘)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -28, .rKnee: 30, .lHipPitch: 10, .lKnee: -10]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -28, .rKnee: 30, .lHipPitch: 10, .lKnee: -10]), ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Lunge L (앞 무릎 굽힘)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 28, .lKnee: -30, .rHipPitch: -10, .rKnee: 10]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 28, .lKnee: -30, .rHipPitch: -10, .rKnee: 10]), ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Push-up 시작 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 85, .lShoulderPitch: -85, .rShoulderRoll: 10, .lShoulderRoll: -10, .rHipPitch: -20, .lHipPitch: 20, .headTilt: -18]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 85, .lShoulderPitch: -85, .rShoulderRoll: 10, .lShoulderRoll: -10, .rHipPitch: -20, .lHipPitch: 20, .headTilt: -18]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Sit-up 시작 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -30, .lHipPitch: 30, .rKnee: 30, .lKnee: -30, .rShoulderPitch: 45, .lShoulderPitch: -45, .headTilt: -15]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -30, .lHipPitch: 30, .rKnee: 30, .lKnee: -30, .rShoulderPitch: 45, .lShoulderPitch: -45, .headTilt: -15]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Plank (운동 변형)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .lHipPitch: 15, .rShoulderPitch: 80, .lShoulderPitch: -80, .rElbow: 100, .lElbow: -100]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .lHipPitch: 15, .rShoulderPitch: 80, .lShoulderPitch: -80, .rElbow: 100, .lElbow: -100]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Mountain climber (R 무릎 앞)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -30, .rKnee: 30, .lHipPitch: -15, .rShoulderPitch: 85, .lShoulderPitch: -85, .headTilt: -18]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 30, .lKnee: -30, .rHipPitch: -15, .rShoulderPitch: 85, .lShoulderPitch: -85, .headTilt: -18]), ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Mountain climber (L 무릎 앞)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 30, .lKnee: -30, .rHipPitch: -15, .rShoulderPitch: 85, .lShoulderPitch: -85, .headTilt: -18]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -30, .rKnee: 30, .lHipPitch: -15, .rShoulderPitch: 85, .lShoulderPitch: -85, .headTilt: -18]), ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Bicep curl (R)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.deltaFromWalkReady([.rShoulderPitch: -5, .rElbow: 100]),
                side2: .walkReady,
                cycles: 4, msPerHalf: 200)))); id += 1
        pages.append(MotionPage(id: id, name: "Bicep curl (L)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.deltaFromWalkReady([.lShoulderPitch: 5, .lElbow: -100]),
                side2: .walkReady,
                cycles: 4, msPerHalf: 200)))); id += 1
        pages.append(MotionPage(id: id, name: "Shoulder press (양손 위)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.deltaFromWalkReady([.rShoulderPitch: 45, .lShoulderPitch: -45, .rElbow: 90, .lElbow: -90]),
                side1: P.armsUp,
                side2: P.deltaFromWalkReady([.rShoulderPitch: 45, .lShoulderPitch: -45, .rElbow: 90, .lElbow: -90]),
                cycles: 4, msPerHalf: 250)))); id += 1
        pages.append(MotionPage(id: id, name: "Leg raise R",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.deltaFromWalkReady([.rHipPitch: -25, .rKnee: 0]),
                side2: .walkReady,
                cycles: 3, msPerHalf: 350)))); id += 1
        pages.append(MotionPage(id: id, name: "Leg raise L",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.deltaFromWalkReady([.lHipPitch: 25, .lKnee: 0]),
                side2: .walkReady,
                cycles: 3, msPerHalf: 350)))); id += 1
        pages.append(MotionPage(id: id, name: "Calf raise × 3",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.deltaFromWalkReady([.rAnklePitch: -20, .lAnklePitch: 20]),
                side2: .walkReady,
                cycles: 3, msPerHalf: 350)))); id += 1
        pages.append(MotionPage(id: id, name: "Burpee 시작 자세",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.squatLow, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -20, .lHipPitch: 20, .rShoulderPitch: 80, .lShoulderPitch: -80, .headTilt: -15]), ms: 400),
                P.holdAt(P.squatLow, ms: 300, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "High knees R",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -35, .rKnee: 40, .rShoulderPitch: -25, .lShoulderPitch: 25]), ms: 350),
                P.holdAt(.walkReady, ms: 250, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "High knees L",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lHipPitch: 35, .lKnee: -40, .lShoulderPitch: 25, .rShoulderPitch: -25]), ms: 350),
                P.holdAt(.walkReady, ms: 250, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Cooldown (가벼운 stretch 종합)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 500, pause: 200),
                P.holdAt(P.armsUp, ms: 500, pause: 200),
                P.holdAt(P.headLookLeft, ms: 400, pause: 200),
                P.holdAt(P.headLookRight, ms: 400, pause: 200),
            ])))

        return pages
    }

    // MARK: - 13. 응급 복구 (15 페이지)
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - `넘어진 후 일어나기 (앞/뒤)` — ROBOTIS catalog id 10 "Get Up (Front)" + id 11
    //   "Get Up (Back)" (Caution class) 의 복구 자세 시퀀스 인용. 정확한 step
    //   timing 은 자체 합성.
    // - `사이드 일어나기 (R/L)` `무릎 서기 → 일어서기` `앉아서 → 무릎서기` `손짚기
    //   일어나기` `T자 균형 잡기 (복구)` `빠른 복귀 (긴급)` `안정 자세 점검` `호흡
    //   정리` `균형 복구 (정렬)` `다리/팔 검사` `완전 복귀 cycle` —
    //   **자체 발상**. ROBOTIS 의 Get Up 시퀀스를 응용한 안전 복구 패턴.
    //
    // **안전 주의**: 모든 복구 모션은 사용자가 robot 을 cradle 거치한 후 실행
    //   권장. 일어서기 도중 균형 손실 시 추가 낙상 위험.
    public static func recoveryPages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        pages.append(MotionPage(id: id, name: "넘어진 후 일어나기 (앞)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -30, .lHipPitch: 30, .rKnee: 30, .lKnee: -30, .rShoulderPitch: 45, .lShoulderPitch: -45, .headTilt: -20]), ms: 800),
                P.holdAt(P.squatLow, ms: 700),
                P.holdAt(P.kneesBent15, ms: 500),
                P.holdAt(.walkReady, ms: 600, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "넘어진 후 일어나기 (뒤)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: 25, .lHipPitch: -25, .rKnee: 35, .lKnee: -35, .rShoulderPitch: -30, .lShoulderPitch: 30, .headTilt: 20]), ms: 800),
                P.holdAt(P.squatLow, ms: 700),
                P.holdAt(P.kneesBent15, ms: 500),
                P.holdAt(.walkReady, ms: 600, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "사이드 일어나기 (R)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: -25, .lHipRoll: -25, .rHipPitch: -20, .rKnee: 25, .rShoulderRoll: -45, .headPan: -20]), ms: 700),
                P.holdAt(P.kneesBent15, ms: 500),
                P.holdAt(.walkReady, ms: 600, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "사이드 일어나기 (L)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: 25, .lHipRoll: 25, .lHipPitch: 20, .lKnee: -25, .lShoulderRoll: 45, .headPan: 20]), ms: 700),
                P.holdAt(P.kneesBent15, ms: 500),
                P.holdAt(.walkReady, ms: 600, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "무릎 서기 → 일어서기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -20, .lHipPitch: 20, .rKnee: 35, .lKnee: -35]), ms: 700),
                P.holdAt(P.kneesBent25, ms: 500),
                P.holdAt(P.kneesBent5, ms: 500),
                P.holdAt(.walkReady, ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "앉아서 → 무릎서기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.squatLow, ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -20, .lHipPitch: 20, .rKnee: 35, .lKnee: -35]), ms: 600, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "손짚기 일어나기 (R 손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -15, .rShoulderRoll: -35, .rElbow: 60,
                    .rHipPitch: -20, .rKnee: 25]), ms: 600),
                P.holdAt(P.squatLow, ms: 500),
                P.holdAt(.walkReady, ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "T자 균형 잡기 (복구)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 400),
                P.holdAt(P.armsT, ms: 1500, pause: 400),
                P.holdAt(.walkReady, ms: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "빠른 복귀 (긴급)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.kneesBent5, ms: 200),
                P.holdAt(.walkReady, ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "안정 자세 점검",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.kneesBent5, ms: 500),
                P.holdAt(.walkReady, ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "호흡 정리",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: -45, .lShoulderRoll: 45, .rElbow: 30, .lElbow: -30]), ms: 800),
                P.holdAt(.walkReady, ms: 800),
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: -45, .lShoulderRoll: 45, .rElbow: 30, .lElbow: -30]), ms: 800, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "균형 복구 (정렬)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipSwayL, ms: 300),
                P.holdAt(.walkReady, ms: 400),
                P.holdAt(P.hipSwayR, ms: 300),
                P.holdAt(.walkReady, ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "다리 검사 (R 천천히 들기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .rKnee: 10]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -20, .rKnee: 15]), ms: 400),
                P.holdAt(.walkReady, ms: 600, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "팔 검사 (R 천천히 들기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 60]), ms: 500),
                P.holdAt(.walkReady, ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "완전 복귀 cycle",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.kneesBent15, ms: 400),
                P.holdAt(P.kneesBent5, ms: 400),
                P.holdAt(P.armsAside, ms: 400),
                P.holdAt(.walkReady, ms: 600, pause: 300),
            ])))

        return pages
    }

    // MARK: - 14. 정적·명상 (15 페이지)
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - **카테고리 전체가 자체 발상**. ROBOTIS·외부 reference 의 명상 모션 없음.
    // - 정적 자세 hold + 합장 + 호흡 (양손 위↑/옆↔ 천천히 sweep) 패턴.
    // - 15개 모두 사용자 review 권장. 안전 위험 낮음 (정적·느린 자세).
    public static func meditationPages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        pages.append(MotionPage(id: id, name: "정적 자세 (5초)",
            steps: P.wrapWithWalkReady([
                P.holdAt(.walkReady, ms: 1000),
                P.holdAt(.walkReady, ms: 4000, pause: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "호흡 (양손 위로 천천히)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsAside, ms: 800),
                P.holdAt(P.armsT, ms: 800),
                P.holdAt(P.armsUp, ms: 1500, pause: 400),
            ], openMs: 500, closeMs: 700))); id += 1
        pages.append(MotionPage(id: id, name: "호흡 (양손 아래로 천천히)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 800),
                P.holdAt(P.armsT, ms: 800),
                P.holdAt(P.armsAside, ms: 800),
                P.holdAt(.walkReady, ms: 1000, pause: 400),
            ], openMs: 500, closeMs: 500))); id += 1
        pages.append(MotionPage(id: id, name: "깊은 호흡 (옆 → 모이기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 1000),
                P.holdAt(P.armsPraying, ms: 1500, pause: 400),
                P.holdAt(P.armsT, ms: 1000),
            ], openMs: 600, closeMs: 600))); id += 1
        pages.append(MotionPage(id: id, name: "종 자세 (합장 천천히)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsPraying, ms: 800),
                P.holdAt(P.armsPraying, ms: 3000, pause: 600),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "명상 (head bow)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headBowSlight, ms: 800),
                P.holdAt(P.headBowSlight, ms: 3000, pause: 600),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "절 (천천히 깊게)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.bowSlight, ms: 700),
                P.holdAt(P.bowDeep, ms: 1500, pause: 500),
                P.holdAt(P.bowSlight, ms: 700),
            ], openMs: 500, closeMs: 600))); id += 1
        pages.append(MotionPage(id: id, name: "합장 (3초 hold)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsPraying, ms: 500),
                P.holdAt(P.armsPraying, ms: 3000, pause: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "정좌 자세 (앞)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.squatLow, ms: 700),
                P.holdAt(P.armsPraying, ms: 2000, pause: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "정좌 자세 (옆)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: -8, .lHipRoll: -8]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: -8, .lHipRoll: -8, .rShoulderRoll: -45, .lShoulderRoll: 45]), ms: 2000, pause: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "인사 호흡 (절 + 합장)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.bowSlight, ms: 700),
                P.holdAt(P.armsPraying, ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "정적 명상 (앞)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsPraying, ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: 30, .lShoulderRoll: -30, .rElbow: 90, .lElbow: -90, .headTilt: -8]), ms: 3000, pause: 600),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "호흡 cycle (4단계)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsAside, ms: 700, pause: 200),
                P.holdAt(P.armsT, ms: 700, pause: 200),
                P.holdAt(P.armsUp, ms: 700, pause: 200),
                P.holdAt(P.armsT, ms: 700, pause: 200),
                P.holdAt(P.armsAside, ms: 700, pause: 200),
            ], openMs: 500, closeMs: 500))); id += 1
        pages.append(MotionPage(id: id, name: "마음 가다듬기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.kneesBent5, ms: 600),
                P.holdAt(P.armsPraying, ms: 800),
                P.holdAt(P.headBowSlight, ms: 2000, pause: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "종합 명상 (5단계)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.bowSlight, ms: 500, pause: 200),
                P.holdAt(P.armsPraying, ms: 700, pause: 200),
                P.holdAt(P.armsUp, ms: 700, pause: 200),
                P.holdAt(P.armsT, ms: 700, pause: 200),
                P.holdAt(P.bowSlight, ms: 500, pause: 200),
            ], openMs: 500, closeMs: 500)))

        return pages
    }

    // MARK: - 15. 합성·합본 (20 페이지)
    //
    // 다른 카테고리들의 패턴을 결합한 routine 예시. 사용자가 직접 보고 모션 합성
    // 학습 — Mirror / Morph / Sequence 합성 결과로 어떤 모션이 나올지 미리보기.
    //
    // **출처** (v1.1 audit, 2026-05-16):
    // - **카테고리 전체가 자체 발상**. 다른 14 카테고리의 page 들을 sequence /
    //   mirror / morph 합성한 예시. 외부 reference 직접 인용 없음.
    // - `Mirror chain (R 손 → L 손)` — `forge synth mirror` 의 산출물 예시.
    //   기존 `synth::ops::mirror::mirror_page` 와 동작 동등.
    // - 나머지 chain / routine 들 — 사용자가 PR review 시 합성 시나리오 적합성
    //   판단 후 유지/제거 결정. **v1.1.0 tag 이전 사용자 검수 권장**.
    public static func generatedPages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        pages.append(MotionPage(id: id, name: "인사 → 박수 → 인사 chain",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.bowSlight, ms: 500, pause: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rElbow: 60, .lElbow: -60]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rElbow: 50, .lElbow: -50]), ms: 250),
                P.holdAt(P.bowSlight, ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "인사 + 응원 결합",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.bowSlight, ms: 500, pause: 200),
                P.holdAt(P.armsUp, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 90, .lShoulderPitch: -90, .rShoulderRoll: -15, .lShoulderRoll: 15]), ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "스트레칭 + 호흡",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 500, pause: 200),
                P.holdAt(P.armsPraying, ms: 800, pause: 300),
                P.holdAt(P.armsT, ms: 500),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "댄스 + 박수",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -20, .lHipYaw: -20]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rElbow: 60, .lElbow: -60]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 20, .lHipYaw: 20]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rElbow: 50, .lElbow: -50]), ms: 250, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "양손 합장 + 호흡",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsPraying, ms: 800),
                P.holdAt(P.armsUp, ms: 700),
                P.holdAt(P.armsPraying, ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "무술 콤보 (정권 + 막기 + 차기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rElbow: 0]), ms: 250),
                P.holdAt(.walkReady, ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 75, .lShoulderPitch: -75]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .rKnee: 30]), ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "데모 전체 routine",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 400, pause: 200),
                P.holdAt(P.bowSlight, ms: 400, pause: 200),
                P.holdAt(P.armsUp, ms: 400, pause: 200),
                P.holdAt(P.armsRightWave, ms: 400, pause: 200),
                P.holdAt(P.armsCross, ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "균형 + 시선 통합",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .rKnee: 20, .lHipRoll: 8]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .rKnee: 20, .lHipRoll: 8, .headPan: -30]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -15, .rKnee: 20, .lHipRoll: 8, .headPan: 30]), ms: 600, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "환영 → 자기소개 → 인사",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsT, ms: 400, pause: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .rElbow: 100]), ms: 500, pause: 200),
                P.holdAt(P.bowSlight, ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "박수 → 만세 → 인사",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rElbow: 60, .lElbow: -60]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rElbow: 50, .lElbow: -50]), ms: 250, pause: 200),
                P.holdAt(P.armsUp, ms: 500),
                P.holdAt(P.bowSlight, ms: 500, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "댄스 → 호흡 → 정지",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -15, .lHipYaw: -15, .rShoulderRoll: -15, .lShoulderRoll: 15]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 15, .lHipYaw: 15, .rShoulderRoll: 15, .lShoulderRoll: -15]), ms: 300),
                P.holdAt(P.armsT, ms: 500),
                P.holdAt(P.armsPraying, ms: 800, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "운동 → 스트레칭 → 명상",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.squatLow, ms: 400),
                P.holdAt(P.armsT, ms: 500, pause: 200),
                P.holdAt(P.armsPraying, ms: 800, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "보행 → 정지 → 인사",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipLeanFwd, ms: 400),
                P.holdAt(P.kneesBent5, ms: 400),
                P.holdAt(P.bowSlight, ms: 600, pause: 300),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "Mirror chain (R 손 → L 손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsRightWave, ms: 500),
                P.holdAt(.walkReady, ms: 300),
                P.holdAt(P.armsLeftWave, ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "오케이 + 좋아요 + 박수",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 75, .rShoulderRoll: -20, .rElbow: 100]), ms: 400, pause: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 45, .rShoulderRoll: -15, .rElbow: 30]), ms: 400, pause: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30, .lShoulderPitch: -30, .rElbow: 60, .lElbow: -60]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rElbow: 50, .lElbow: -50]), ms: 250, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "스트레칭 routine (4단계)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headLookLeft, ms: 500, pause: 200),
                P.holdAt(P.headLookRight, ms: 500, pause: 200),
                P.holdAt(P.armsUp, ms: 500, pause: 200),
                P.holdAt(P.armsBothBackward, ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "친근한 인사 routine",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsRightWave, ms: 400, pause: 200),
                P.holdAt(P.bowSlight, ms: 400, pause: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .rElbow: 100]), ms: 400, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "에너지 routine (5단계)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 300, pause: 100),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: -15, .lHipYaw: -15]), ms: 300, pause: 100),
                P.holdAt(P.armsUp, ms: 300, pause: 100),
                P.holdAt(P.deltaFromWalkReady([.rHipYaw: 15, .lHipYaw: 15]), ms: 300, pause: 100),
                P.holdAt(P.armsUp, ms: 300, pause: 100),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "차분한 routine (5단계)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.bowSlight, ms: 500, pause: 200),
                P.holdAt(P.armsPraying, ms: 700, pause: 300),
                P.holdAt(P.headBowSlight, ms: 800, pause: 400),
                P.holdAt(P.armsPraying, ms: 700, pause: 300),
                P.holdAt(P.bowSlight, ms: 500, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "마무리 큰 routine",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 400),
                P.holdAt(P.armsT, ms: 400),
                P.holdAt(P.bowDeep, ms: 600, pause: 300),
                P.holdAt(P.armsUp, ms: 400),
                P.holdAt(.walkReady, ms: 500, pause: 200),
            ])))

        return pages
    }

    // MARK: - 통합 helper

    /// 카테고리 → 페이지 array.
    public static func pages(for category: MotionCategory) -> [MotionPage] {
        switch category {
        case .basicPose:    return basicPosePages()
        case .greeting:     return greetingPages()
        case .emotion:      return emotionPages()
        case .dance:        return dancePages()
        case .stretch:      return stretchPages()
        case .yoga:         return yogaPages()
        case .martial:      return martialPages()
        case .walkVariant:  return walkVariantPages()
        case .balance:      return balancePages()
        case .gaze:         return gazePages()
        case .demo:         return demoPages()
        case .exercise:     return exercisePages()
        case .recovery:     return recoveryPages()
        case .meditation:   return meditationPages()
        case .generated:    return generatedPages()
        }
    }

    /// 카테고리별 페이지 수 카운트 (sidebar 표시용).
    public static func count(for category: MotionCategory) -> Int {
        pages(for: category).count
    }

    /// 모든 카테고리의 총 모션 수 (320 권장 분포).
    public static var totalMotionCount: Int {
        MotionCategory.allCases.reduce(0) { $0 + count(for: $1) }
    }
}

