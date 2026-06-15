import Foundation

/// 다윈 로봇 측에서 실행할 마이크 캡처용 셸 명령 빌더 + `arecord -l` 출력 파서.
///
/// # 비유
///
/// 녹음 스튜디오 엔지니어가 "어떤 마이크가 콘솔에 꽂혀 있지?"(probe)를 먼저 확인하고,
/// 그 채널을 골라 "레코드 버튼"(record)을 누른 뒤, 테이프를 복사해(transfer) 밖으로
/// 빼내는 흐름과 같다. 본 enum 은 그 각 단계의 *명령 문자열* 만 만든다 — 실제 실행은
/// `RobotShellRunning` 이 담당하므로 여기 함수는 전부 **순수** 하고 단위 테스트가 쉽다.
///
/// 로봇 OS(Ubuntu 12.04)에 `alsa-utils`(`arecord`)가 설치돼 있다는 사실에만 의존한다.
/// 캡처 *장치* 가 실제 존재하는지는 미지수이므로 `probe` 가 먼저 그것을 검사한다.
public enum RobotMicCommands {

    /// 녹음 파일이 저장될 로봇 측 임시 경로.
    public static let remoteWavPath = "/tmp/df_mic_check.wav"

    /// 캡처 장치 탐색 명령.
    ///
    /// `arecord` 존재 여부 + `arecord -l`(캡처 하드웨어 목록) + `/proc/asound/cards`
    /// 를 한 번에 수집한다. 각 섹션은 `== 제목 ==` 마커로 구분해 파서가 분리하기 쉽게 한다.
    /// `arecord` 자체가 없으면 `NO_ARECORD` 토큰을 남긴다.
    public static let probe: String =
        "echo '== which =='; which arecord 2>/dev/null || echo NO_ARECORD; "
        + "echo '== arecord-l =='; arecord -l 2>&1; "
        + "echo '== cards =='; cat /proc/asound/cards 2>&1"

    /// 녹음 명령.
    ///
    /// - Parameters:
    ///   - durationSeconds: 녹음 길이(초). 1~15초로 clamp.
    ///   - device: ALSA 장치(예 `plughw:0,0`). `nil` 이면 ALSA default PCM 사용.
    ///
    /// `S16_LE` 16 kHz mono 로 고정 — Apple Speech 전사에 친화적이고 전송량이 작다.
    /// stdout/stderr 를 합쳐(`2>&1`) 진행 메시지/에러를 모두 회수한다.
    public static func record(durationSeconds: Int, device: String?) -> String {
        let clamped = clampDuration(durationSeconds)
        let deviceArg = device.map { "-D \($0) " } ?? ""
        return "arecord \(deviceArg)-f S16_LE -r 16000 -c 1 -d \(clamped) "
            + "\(remoteWavPath) 2>&1"
    }

    /// 녹음 파일 크기(바이트)를 숫자만 출력하는 명령. 파일이 없으면 0.
    public static let fileSizeBytes: String =
        "wc -c < \(remoteWavPath) 2>/dev/null || echo 0"

    /// 녹음 파일을 base64 로 인코딩해 stdout 으로 내보내는 명령 — 맥으로 전송하는 통로.
    public static let transferBase64: String = "base64 \(remoteWavPath)"

    /// 로봇 측 임시 파일 정리.
    public static let cleanup: String = "rm -f \(remoteWavPath)"

    /// 녹음 길이를 허용 범위(1~15초)로 제한.
    public static func clampDuration(_ seconds: Int) -> Int {
        min(max(seconds, minDurationSeconds), maxDurationSeconds)
    }

    public static let minDurationSeconds = 1
    public static let maxDurationSeconds = 15

    // MARK: - arecord -l 파서

    /// ALSA 캡처 장치 한 개 — card/device 인덱스 + 사람이 읽는 이름.
    public struct CaptureDevice: Equatable {
        public let card: Int
        public let device: Int
        public let name: String

        public init(card: Int, device: Int, name: String) {
            self.card = card
            self.device = device
            self.name = name
        }

        /// `arecord -D` 인자로 쓸 plughw 문자열 (자동 포맷 변환 포함).
        public var plughwArgument: String { "plughw:\(card),\(device)" }
    }

    /// probe 출력에 `arecord` 바이너리가 없다고 표시됐는지.
    public static func isArecordMissing(in probeOutput: String) -> Bool {
        probeOutput.contains("NO_ARECORD")
    }

    /// probe/`arecord -l` 출력에서 캡처 장치 목록을 파싱.
    ///
    /// `arecord -l` 의 한 줄은 다음 형태다:
    /// ```
    /// card 0: Device [USB Audio], device 0: USB Audio [USB Audio]
    /// ```
    /// 캡처 장치가 없으면 `arecord` 는 `no soundcards found...` 를 출력하므로 빈 배열을 돌려준다.
    public static func parseCaptureDevices(from output: String) -> [CaptureDevice] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { parseCaptureLine(String($0)) }
    }

    /// 첫 캡처 장치의 plughw 인자. 없으면 `nil` → 호출자는 ALSA default 로 fallback.
    public static func firstDeviceArgument(from output: String) -> String? {
        parseCaptureDevices(from: output).first?.plughwArgument
    }

    /// `card N: ... device M: ...` 한 줄을 CaptureDevice 로. 형식이 안 맞으면 nil.
    private static func parseCaptureLine(_ line: String) -> CaptureDevice? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("card "),
              let card = firstInt(after: "card ", in: trimmed),
              let device = firstInt(after: "device ", in: trimmed) else {
            return nil
        }
        return CaptureDevice(card: card, device: device, name: deviceName(in: trimmed))
    }

    /// `marker` 직후에 나오는 첫 정수를 추출. (예: "card 0:" → 0)
    private static func firstInt(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }

    /// 장치 줄에서 첫 `[대괄호]` 안의 이름을 추출. 없으면 줄 전체를 fallback 이름으로.
    private static func deviceName(in line: String) -> String {
        guard let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]"),
              line.index(after: open) < close else {
            return line
        }
        return String(line[line.index(after: open)..<close])
    }
}
