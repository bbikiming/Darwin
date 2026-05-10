use std::env;
use std::path::PathBuf;

fn main() {
    let crate_dir = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set");
    let out_dir = env::var("OUT_DIR").expect("OUT_DIR not set");

    println!("cargo:rerun-if-changed=src/lib.rs");
    println!("cargo:rerun-if-changed=cbindgen.toml");

    // Generate header into OUT_DIR (will be copied to dist/ by build-mac.sh).
    let header_out = PathBuf::from(&out_dir).join("forge_core.h");
    match cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(
            cbindgen::Config::from_file(PathBuf::from(&crate_dir).join("cbindgen.toml"))
                .expect("read cbindgen.toml"),
        )
        .generate()
    {
        Ok(b) => {
            b.write_to_file(&header_out);
            println!(
                "cargo:warning=cbindgen generated header at {}",
                header_out.display()
            );
        }
        Err(e) => {
            // Don't fail the build for cbindgen issues — header can be regenerated manually.
            println!("cargo:warning=cbindgen generation failed: {}", e);
        }
    }
}
