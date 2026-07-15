mod control_message {
    pub use crate::protocol::control_message::NodeType;
}

mod proto {
    include!(concat!(env!("OUT_DIR"), "/protocol.rpc.rs"));
}
pub use proto::*;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::control_message::NodeType;
    use prost::Message;

    fn fixture(path: &str) -> Vec<u8> {
        let value = match path {
            "rpc-client-info-v2-legacy.hex" => {
                include_str!("../../tests/fixtures/rpc-client-info-v2-legacy.hex")
            }
            "rpc-client-info-v2-wireguard.hex" => {
                include_str!("../../tests/fixtures/rpc-client-info-v2-wireguard.hex")
            }
            _ => panic!("unknown fixture: {path}"),
        };
        hex::decode(value.trim()).expect("fixture must be valid hex")
    }

    #[test]
    fn legacy_rpc_client_info_defaults_node_type_to_vnt() {
        let client = ClientInfo::decode(fixture("rpc-client-info-v2-legacy.hex").as_slice())
            .expect("legacy RPC client info must remain decodable");

        assert_eq!(client.node_type(), NodeType::Vnt);
        assert_eq!(
            client.encode_to_vec(),
            fixture("rpc-client-info-v2-legacy.hex")
        );
    }

    #[test]
    fn wireguard_rpc_client_info_uses_frozen_node_type_value() {
        let client = ClientInfo::decode(fixture("rpc-client-info-v2-wireguard.hex").as_slice())
            .expect("wireguard RPC client info must decode");

        assert_eq!(client.node_type(), NodeType::Wireguard);
        assert_eq!(
            client.encode_to_vec(),
            fixture("rpc-client-info-v2-wireguard.hex")
        );
    }
}
