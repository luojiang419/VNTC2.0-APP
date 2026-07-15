mod control_message {
    pub use crate::protocol::control_message::NodeType;
}

mod proto {
    include!(concat!(env!("OUT_DIR"), "/protocol.rpc.rs"));
}
pub use proto::*;
