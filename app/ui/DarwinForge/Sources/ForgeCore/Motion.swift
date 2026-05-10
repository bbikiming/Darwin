import CForgeCore
import Foundation

/// 모션 import/export — `.mtn` ↔ JSON 라운드트립.
public enum Motion {
    /// `.mtn` 텍스트를 우리 내부 JSON으로 변환. generation은 "op" / "op2".
    public static func mtnToJSON(_ mtn: String, generation: String = "op2") throws -> String {
        var err: Int32 = FC_OK
        let raw = mtn.withCString { mtnPtr -> UnsafeMutablePointer<CChar>? in
            generation.withCString { genPtr in
                fc_motion_mtn_to_json(mtnPtr, genPtr, &err)
            }
        }
        guard let raw else { throw ForgeError.from(err) ?? .codec }
        return consumeForgeString(raw) ?? ""
    }

    /// 우리 JSON을 `.mtn` 텍스트로 변환.
    public static func jsonToMTN(_ json: String) throws -> String {
        var err: Int32 = FC_OK
        let raw = json.withCString { fc_motion_json_to_mtn($0, &err) }
        guard let raw else { throw ForgeError.from(err) ?? .codec }
        return consumeForgeString(raw) ?? ""
    }
}
