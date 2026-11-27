fn main() {
    let core_sha256 = std::env::var("CORE_SHA256").unwrap_or_default();
    let core_name = std::env::var("CORE_NAME").unwrap_or_else(|_| "FlClashCore.exe".to_string());
    let core_public_key = std::env::var("FLCLASHZ_CORE_UPDATE_PUBLIC_KEY").unwrap_or_default();
    println!("cargo:rustc-env=FLCLASHZ_CORE_UPDATE_PUBLIC_KEY={}", core_public_key.trim());
    println!("cargo:rerun-if-env-changed=FLCLASHZ_CORE_UPDATE_PUBLIC_KEY");
    println!("cargo:rustc-env=CORE_SHA256={}", core_sha256);
    println!("cargo:rustc-env=CORE_NAME={}", core_name);
    println!("cargo:rerun-if-env-changed=CORE_SHA256");
    println!("cargo:rerun-if-env-changed=CORE_NAME");
}
