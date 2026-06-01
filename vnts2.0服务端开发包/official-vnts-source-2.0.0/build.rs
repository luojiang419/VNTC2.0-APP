fn main() {
    if std::env::var_os("PROTOC").is_none() {
        if let Ok(path) = protoc_bin_vendored::protoc_bin_path() {
            unsafe {
                std::env::set_var("PROTOC", path);
            }
        }
    }
    let mut config = prost_build::Config::new();
    config.protoc_arg("--experimental_allow_proto3_optional");

    config
        .compile_protos(
            &[
                "proto/control_message.proto",
                "proto/rpc.proto",
                "proto/server_message.proto",
            ],
            &["proto"],
        )
        .unwrap();
}
