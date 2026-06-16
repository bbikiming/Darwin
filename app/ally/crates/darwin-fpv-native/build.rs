// build.rs — web/ 자산(include_dir!("$CARGO_MANIFEST_DIR/web"))이 바뀌면 재컴파일하도록
// cargo 에 알린다. 없으면 include_dir 임베드가 stale 해져(app.js/index.html 등 수정이
// 바이너리에 반영 안 됨) "코드 고쳤는데 콕핏 그대로"가 된다(2026-06-16 실기 발견).
fn main() {
    println!("cargo:rerun-if-changed=web");
}
