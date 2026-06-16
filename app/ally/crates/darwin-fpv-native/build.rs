// build.rs — web/ 자산(include_dir!("$CARGO_MANIFEST_DIR/web"))이 바뀌면 재컴파일하도록
// cargo 에 알린다. 없으면 include_dir 임베드가 stale 해져(app.js/index.html 등 수정이
// 바이너리에 반영 안 됨) "코드 고쳤는데 콕핏 그대로"가 된다(2026-06-16 실기 발견).
fn main() {
    println!("cargo:rerun-if-changed=web");

    // §icon — Windows exe 에 DarwinForge 아이콘 임베드(PE 리소스). 탐색기·작업표시줄·콕핏
    // 서버 프로세스 아이콘이 다윈포지로 표시된다. Windows 전용(rc.exe/windres 필요) — 다른
    // OS 에선 no-op. 아이콘 변경 시 재컴파일.
    #[cfg(windows)]
    {
        println!("cargo:rerun-if-changed=icons/darwinforge.ico");
        let mut res = winresource::WindowsResource::new();
        res.set_icon("icons/darwinforge.ico");
        if let Err(e) = res.compile() {
            // 리소스 컴파일러 부재 등은 빌드를 깨지 않도록 경고만(아이콘만 미적용).
            println!("cargo:warning=icon embed skipped: {e}");
        }
    }
}
