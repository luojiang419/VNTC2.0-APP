fn main() {
    println!("cargo:rerun-if-changed=src/platform/windows/tun/bindings.rs");
}
