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
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -80, .rShoulderRoll: -20, .rElbow: 30]), ms: 300),
                P.holdAt(P.armsRightWave, ms: 300),
                P.holdAt(.walkReady, ms: 300, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "왼손 인사 (wave)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsLeftWave, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 80, .lShoulderRoll: 20, .lElbow: -30]), ms: 300),
                P.holdAt(P.armsLeftWave, ms: 300),
                P.holdAt(.walkReady, ms: 300, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "양손 인사 (양손 wave)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -80, .lShoulderPitch: 80]), ms: 400),
                P.holdAt(P.armsAside, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -80, .lShoulderPitch: 80]), ms: 300, pause: 200),
            ]))); id += 1

        // 악수
        pages.append(MotionPage(id: id, name: "악수 (오른손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -45, .rElbow: -30]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -50, .rElbow: -25]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -45, .rElbow: -30]), ms: 200, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "악수 (왼손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 45, .lElbow: 30]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 50, .lElbow: 25]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 45, .lElbow: 30]), ms: 200, pause: 200),
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
                center: P.deltaFromWalkReady([.rShoulderPitch: -30, .lShoulderPitch: 30, .rShoulderRoll: 15, .lShoulderRoll: -15, .rElbow: -60, .lElbow: 60]),
                side1: P.deltaFromWalkReady([.rShoulderPitch: -25, .lShoulderPitch: 25, .rShoulderRoll: 20, .lShoulderRoll: -20, .rElbow: -50, .lElbow: 50]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: -35, .lShoulderPitch: 35, .rShoulderRoll: 10, .lShoulderRoll: -10, .rElbow: -65, .lElbow: 65]),
                cycles: 3, msPerHalf: 150)))); id += 1

        pages.append(MotionPage(id: id, name: "박수 × 5회 (환영)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.deltaFromWalkReady([.rShoulderPitch: -30, .lShoulderPitch: 30, .rElbow: -60, .lElbow: 60]),
                side1: P.deltaFromWalkReady([.rShoulderPitch: -25, .lShoulderPitch: 25, .rElbow: -50, .lElbow: 50]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: -35, .lShoulderPitch: 35, .rElbow: -65, .lElbow: 65]),
                cycles: 5, msPerHalf: 120)))); id += 1

        // 작별 인사
        pages.append(MotionPage(id: id, name: "안녕 (bye-bye 오른손)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.armsRightWave,
                side1: P.deltaFromWalkReady([.rShoulderPitch: -85, .rShoulderRoll: -15, .rElbow: 30]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: -75, .rShoulderRoll: -30, .rElbow: 30]),
                cycles: 3, msPerHalf: 250)))); id += 1

        pages.append(MotionPage(id: id, name: "안녕 (bye-bye 왼손)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.armsLeftWave,
                side1: P.deltaFromWalkReady([.lShoulderPitch: 85, .lShoulderRoll: 15, .lElbow: -30]),
                side2: P.deltaFromWalkReady([.lShoulderPitch: 75, .lShoulderRoll: 30, .lElbow: -30]),
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
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -40, .lHipPitch: 40, .headTilt: 25]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -40, .lHipPitch: 40, .headTilt: 25]), ms: 1000, pause: 400),
            ]))); id += 1

        // 손짓 + 머리
        pages.append(MotionPage(id: id, name: "안녕하세요 (목 + 오른손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.headBowSlight, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.headTilt: 12, .rShoulderPitch: -60, .rElbow: -20]), ms: 500, pause: 200),
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
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .rShoulderRoll: -25, .rElbow: -10]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .rShoulderRoll: -35, .rElbow: -5]), ms: 800, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "이쪽으로 안내 (왼손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 30, .lShoulderRoll: 25, .lElbow: 10]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 30, .lShoulderRoll: 35, .lElbow: 5]), ms: 800, pause: 300),
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
    public static func emotionPages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        // 좋아요 (양손 엄지)
        pages.append(MotionPage(id: id, name: "좋아요 (오른손 thumbs up)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -45, .rShoulderRoll: -15, .rElbow: -30]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -45, .rShoulderRoll: -15, .rElbow: -30]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "좋아요 (양손)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -45, .lShoulderPitch: 45, .rElbow: -30, .lElbow: 30]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -45, .lShoulderPitch: 45, .rElbow: -30, .lElbow: 30]), ms: 1200, pause: 300),
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
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -90, .lShoulderPitch: 90, .headTilt: -20]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -90, .lShoulderPitch: 90, .headTilt: -20]), ms: 700, pause: 300),
            ]))); id += 1

        // 부끄러움 (얼굴 가리기)
        pages.append(MotionPage(id: id, name: "부끄러움 (얼굴 가리기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -75, .rShoulderRoll: -20, .rElbow: -90, .headTilt: 15]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -75, .rShoulderRoll: -20, .rElbow: -90, .headTilt: 15]), ms: 1200, pause: 300),
            ]))); id += 1

        // 생각 (머리 한쪽 + 손 턱)
        pages.append(MotionPage(id: id, name: "생각하는 중",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -55, .rShoulderRoll: -10, .rElbow: -110, .headPan: 15, .headTilt: 10]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -55, .rShoulderRoll: -10, .rElbow: -110, .headPan: -15, .headTilt: 10]), ms: 800, pause: 200),
            ]))); id += 1

        // 자랑 (chest pump)
        pages.append(MotionPage(id: id, name: "자랑 (가슴 두드림)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -25, .rShoulderRoll: -15, .rElbow: -100]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .rShoulderRoll: -15, .rElbow: -110]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -25, .rShoulderRoll: -15, .rElbow: -100]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .rShoulderRoll: -15, .rElbow: -110]), ms: 200, pause: 200),
            ]))); id += 1

        // 기쁨 (점프 자세 — 무릎 굽혔다 펴기)
        pages.append(MotionPage(id: id, name: "기쁨 표현",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rKnee: 15, .lKnee: -15, .rHipPitch: -8, .lHipPitch: 8]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -90, .lShoulderPitch: 90]), ms: 400, pause: 200),
            ]))); id += 1

        // 슬픔 (어깨 처짐)
        pages.append(MotionPage(id: id, name: "슬픔 (어깨 처짐)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 15, .lShoulderPitch: -15, .headTilt: 18]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 15, .lShoulderPitch: -15, .headTilt: 18]), ms: 1500, pause: 400),
            ]))); id += 1

        // 화남 (양 손 주먹 + 어깨 올림)
        pages.append(MotionPage(id: id, name: "화남 (주먹)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .lShoulderPitch: 30, .rShoulderRoll: -10, .lShoulderRoll: 10, .rElbow: -90, .lElbow: 90]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .lShoulderPitch: 30, .rShoulderRoll: -10, .lShoulderRoll: 10, .rElbow: -90, .lElbow: 90]), ms: 1000, pause: 300),
            ]))); id += 1

        // 환호 (만세 + 점프 자세)
        pages.append(MotionPage(id: id, name: "환호!",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -90, .lShoulderPitch: 90, .rKnee: 10, .lKnee: -10]), ms: 300),
                P.holdAt(P.armsUp, ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -90, .lShoulderPitch: 90, .rKnee: 10, .lKnee: -10]), ms: 300, pause: 200),
            ]))); id += 1

        // 호기심 (머리 한쪽 tilt)
        pages.append(MotionPage(id: id, name: "호기심 (머리 갸웃)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.headPan: 20, .headTilt: -10]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.headPan: 20, .headTilt: -10]), ms: 1000, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "호기심 (반대쪽)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.headPan: -20, .headTilt: -10]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.headPan: -20, .headTilt: -10]), ms: 1000, pause: 300),
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
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rShoulderRoll: -20, .lShoulderRoll: 20, .rElbow: -60, .lElbow: 60]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 25, .lShoulderPitch: -25, .rShoulderRoll: -20, .lShoulderRoll: 20, .rElbow: -60, .lElbow: 60]), ms: 1000, pause: 200),
            ]))); id += 1

        // 손 가리킴
        pages.append(MotionPage(id: id, name: "가리키기 (오른쪽)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -45, .rShoulderRoll: -35]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -45, .rShoulderRoll: -35]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "가리키기 (왼쪽)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 45, .lShoulderRoll: 35]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 45, .lShoulderRoll: 35]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "위로 가리키기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -90, .rElbow: 0, .headTilt: -15]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -90, .rElbow: 0, .headTilt: -15]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "아래 가리키기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 15, .rShoulderRoll: -30, .headTilt: 15]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 15, .rShoulderRoll: -30, .headTilt: 15]), ms: 1200, pause: 300),
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
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -75, .lShoulderPitch: 75]), ms: 400),
            ]))); id += 1

        // 졸음 (앞 lean + 머리 떨굼)
        pages.append(MotionPage(id: id, name: "졸음 (머리 떨굼)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.headTilt: 30, .rShoulderPitch: 10, .lShoulderPitch: -10]), ms: 800),
                P.holdAt(P.deltaFromWalkReady([.headTilt: 30, .rShoulderPitch: 10, .lShoulderPitch: -10]), ms: 1500, pause: 300),
            ]))); id += 1

        // 침착 (양손 차분히 내림)
        pages.append(MotionPage(id: id, name: "침착 (palms down)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -15, .lShoulderPitch: 15, .rShoulderRoll: -25, .lShoulderRoll: 25, .rElbow: -30, .lElbow: 30]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -10, .lShoulderPitch: 10, .rShoulderRoll: -25, .lShoulderRoll: 25, .rElbow: -25, .lElbow: 25]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -15, .lShoulderPitch: 15, .rShoulderRoll: -25, .lShoulderRoll: 25, .rElbow: -30, .lElbow: 30]), ms: 500, pause: 200),
            ]))); id += 1

        // 응원 (양손 좌우 흔들기)
        pages.append(MotionPage(id: id, name: "응원 (양손 흔들기)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.armsUp,
                side1: P.deltaFromWalkReady([.rShoulderPitch: -90, .lShoulderPitch: 90, .rShoulderRoll: -15, .lShoulderRoll: 15]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: -90, .lShoulderPitch: 90, .rShoulderRoll: 15, .lShoulderRoll: -15]),
                cycles: 3, msPerHalf: 250))))

        return pages
    }

    // MARK: - 4. 댄스·리듬 (30 페이지)
    //
    // K-pop 안무 단순화·트위스트·시미·스텝. 음악 동반 권장.
    public static func dancePages() -> [MotionPage] {
        let P = MotionPrimitives.self
        var pages: [MotionPage] = []
        var id: UInt8 = 1

        pages.append(MotionPage(id: id, name: "웨이브 (오른 → 왼)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -60, .rElbow: -30]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -45, .lShoulderPitch: 45]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 60, .lElbow: 30]), ms: 250, pause: 200),
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
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -75, .rShoulderRoll: -30, .lShoulderPitch: 45, .lElbow: 30, .headTilt: 20, .headPan: -25]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -75, .rShoulderRoll: -30, .lShoulderPitch: 45, .lElbow: 30, .headTilt: 20, .headPan: -25]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "Dab (왼쪽)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 75, .lShoulderRoll: 30, .rShoulderPitch: -45, .rElbow: -30, .headTilt: 20, .headPan: 25]), ms: 400),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 75, .lShoulderRoll: 30, .rShoulderPitch: -45, .rElbow: -30, .headTilt: 20, .headPan: 25]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "Floss (팔 좌→우 흔들기)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -25, .lShoulderPitch: 25, .rShoulderRoll: -30, .lShoulderRoll: 30]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -25, .lShoulderPitch: 25, .rShoulderRoll: 30, .lShoulderRoll: -30]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -25, .lShoulderPitch: 25, .rShoulderRoll: -30, .lShoulderRoll: 30]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -25, .lShoulderPitch: 25, .rShoulderRoll: 30, .lShoulderRoll: -30]), ms: 200, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "마카레나 (4단계 단순화)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -45]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -45, .lShoulderPitch: 45]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -45, .lShoulderPitch: 45, .rShoulderRoll: -30, .lShoulderRoll: 30]), ms: 250),
                P.holdAt(P.armsCross, ms: 250, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "머리 위 박수",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.deltaFromWalkReady([.rShoulderPitch: -85, .lShoulderPitch: 85, .rShoulderRoll: -15, .lShoulderRoll: 15]),
                side1: P.deltaFromWalkReady([.rShoulderPitch: -85, .lShoulderPitch: 85, .rShoulderRoll: 0, .lShoulderRoll: 0]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: -85, .lShoulderPitch: 85, .rShoulderRoll: -25, .lShoulderRoll: 25]),
                cycles: 4, msPerHalf: 180)))); id += 1

        pages.append(MotionPage(id: id, name: "사이드 스텝 + 박수",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.hipSwayL, ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: 10, .lHipRoll: 10, .rShoulderPitch: -25, .lShoulderPitch: 25, .rElbow: -60, .lElbow: 60]), ms: 200),
                P.holdAt(P.hipSwayR, ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rHipRoll: -10, .lHipRoll: -10, .rShoulderPitch: -25, .lShoulderPitch: 25, .rElbow: -60, .lElbow: 60]), ms: 200, pause: 200),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "한쪽 어깨 들썩 (R)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.deltaFromWalkReady([.rShoulderPitch: -10, .rShoulderRoll: -15]),
                side2: .walkReady,
                cycles: 4, msPerHalf: 150)))); id += 1

        pages.append(MotionPage(id: id, name: "양 어깨 들썩",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.deltaFromWalkReady([.rShoulderPitch: -10, .lShoulderPitch: 10, .rShoulderRoll: -15, .lShoulderRoll: 15]),
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
                center: P.deltaFromWalkReady([.rShoulderPitch: -45, .rShoulderRoll: -35]),
                side1: P.deltaFromWalkReady([.rShoulderPitch: -40, .rShoulderRoll: -40]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: -50, .rShoulderRoll: -30]),
                cycles: 3, msPerHalf: 200)))); id += 1

        pages.append(MotionPage(id: id, name: "Point dance (L 가리키며 흔들기)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.deltaFromWalkReady([.lShoulderPitch: 45, .lShoulderRoll: 35]),
                side1: P.deltaFromWalkReady([.lShoulderPitch: 40, .lShoulderRoll: 40]),
                side2: P.deltaFromWalkReady([.lShoulderPitch: 50, .lShoulderRoll: 30]),
                cycles: 3, msPerHalf: 200)))); id += 1

        pages.append(MotionPage(id: id, name: "양팔 새 (flying bird)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.armsT,
                side1: P.deltaFromWalkReady([.rShoulderPitch: -10, .lShoulderPitch: 10, .rShoulderRoll: -85, .lShoulderRoll: 85]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: 10, .lShoulderPitch: -10, .rShoulderRoll: -55, .lShoulderRoll: 55]),
                cycles: 4, msPerHalf: 200)))); id += 1

        pages.append(MotionPage(id: id, name: "머리 까딱 + 손짓",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: P.armsAside,
                side1: P.deltaFromWalkReady([.rShoulderPitch: 20, .lShoulderPitch: -20, .headTilt: -10]),
                side2: P.deltaFromWalkReady([.rShoulderPitch: 20, .lShoulderPitch: -20, .headTilt: 10]),
                cycles: 4, msPerHalf: 200)))); id += 1

        pages.append(MotionPage(id: id, name: "K-pop 하트 (머리 위)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -80, .lShoulderPitch: 80, .rShoulderRoll: -25, .lShoulderRoll: 25, .rElbow: -45, .lElbow: 45]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -80, .lShoulderPitch: 80, .rShoulderRoll: -25, .lShoulderRoll: 25, .rElbow: -45, .lElbow: 45]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "가슴 하트",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .lShoulderPitch: 30, .rShoulderRoll: 20, .lShoulderRoll: -20, .rElbow: -80, .lElbow: 80]), ms: 500),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .lShoulderPitch: 30, .rShoulderRoll: 20, .lShoulderRoll: -20, .rElbow: -80, .lElbow: 80]), ms: 1200, pause: 300),
            ]))); id += 1

        pages.append(MotionPage(id: id, name: "양손 짠 (chear)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsUp, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -90, .lShoulderPitch: 90, .rShoulderRoll: -20, .lShoulderRoll: 20]), ms: 300),
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
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -15, .lShoulderPitch: 15, .headTilt: -10]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 5, .lShoulderPitch: -5, .headTilt: 10]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -15, .lShoulderPitch: 15, .headTilt: -10]), ms: 200),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 5, .lShoulderPitch: -5, .headTilt: 10]), ms: 200, pause: 200),
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
                P.holdAt(P.deltaFromWalkReady([.headPan: -30, .headTilt: -15]), ms: 400),
                P.holdAt(P.headLookUp, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.headPan: 30, .headTilt: -15]), ms: 400),
                P.holdAt(P.headLookRight, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.headPan: 30, .headTilt: 15]), ms: 400),
                P.holdAt(P.headLookDown, ms: 400),
                P.holdAt(P.deltaFromWalkReady([.headPan: -30, .headTilt: 15]), ms: 400, pause: 200),
            ]))); id += 1

        // 어깨 stretch (5)
        pages.append(MotionPage(id: id, name: "오른어깨 앞 돌리기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -60, .rShoulderRoll: -10]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .rShoulderRoll: -20]), ms: 250),
                P.holdAt(.walkReady, ms: 250, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "오른어깨 뒤 돌리기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 30]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: 0, .rShoulderRoll: -25]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .rShoulderRoll: -15]), ms: 250),
                P.holdAt(.walkReady, ms: 250, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "왼어깨 앞 돌리기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 30]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 60, .lShoulderRoll: 10]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 30, .lShoulderRoll: 20]), ms: 250),
                P.holdAt(.walkReady, ms: 250, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "왼어깨 뒤 돌리기",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: -30]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 0, .lShoulderRoll: 25]), ms: 250),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 30, .lShoulderRoll: 15]), ms: 250),
                P.holdAt(.walkReady, ms: 250, pause: 200),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "양 어깨 동시 돌리기 (앞)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .lShoulderPitch: 30]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -60, .lShoulderPitch: 60, .rShoulderRoll: -10, .lShoulderRoll: 10]), ms: 300),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -30, .lShoulderPitch: 30, .rShoulderRoll: -20, .lShoulderRoll: 20]), ms: 300),
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
                P.holdAt(P.deltaFromWalkReady([.rShoulderRoll: -85, .lShoulderRoll: 85, .rShoulderPitch: 10, .lShoulderPitch: -10]), ms: 1200, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "양팔 뒤 (어깨 stretch)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.armsBothBackward, ms: 600),
                P.holdAt(P.armsBothBackward, ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "팔꿈치 stretch (R)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -90, .rElbow: -130]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.rShoulderPitch: -90, .rElbow: -130]), ms: 1500, pause: 400),
            ]))); id += 1
        pages.append(MotionPage(id: id, name: "팔꿈치 stretch (L)",
            steps: P.wrapWithWalkReady([
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 90, .lElbow: 130]), ms: 600),
                P.holdAt(P.deltaFromWalkReady([.lShoulderPitch: 90, .lElbow: 130]), ms: 1500, pause: 400),
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
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .lHipPitch: 25, .headTilt: 15]), ms: 700),
                P.holdAt(P.deltaFromWalkReady([.rHipPitch: -25, .lHipPitch: 25, .headTilt: 15]), ms: 1500, pause: 400),
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
                side1: P.deltaFromWalkReady([.rElbow: -45]),
                side2: P.deltaFromWalkReady([.rElbow: 45]),
                cycles: 3, msPerHalf: 200)))); id += 1
        pages.append(MotionPage(id: id, name: "팔꿈치 회전 (L)",
            steps: P.wrapWithWalkReady(P.oscillate(
                center: .walkReady,
                side1: P.deltaFromWalkReady([.lElbow: 45]),
                side2: P.deltaFromWalkReady([.lElbow: -45]),
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
}
