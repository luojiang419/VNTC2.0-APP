use crate::protocol::ProtoToBytesMut;
pub(crate) use crate::protocol::control_message::proto::SelectiveBroadcast;
use crate::protocol::control_message::proto::request_message::RequestPayload;
use crate::protocol::control_message::proto::response_message::ResponsePayload;
use anyhow::bail;
use bytes::BytesMut;
use prost::Message;
use std::net::Ipv4Addr;

#[allow(dead_code)]
pub(crate) mod proto {
    include!(concat!(env!("OUT_DIR"), "/protocol.control_message.rs"));
}

pub use proto::NodeType;
pub const CLIENT_CAP_WIREGUARD_SUBNET_RELAY: u64 = 1 << 0;
pub const CLIENT_CAP_WIREGUARD_BROADCAST_RELAY: u64 = 1 << 1;
pub const CLIENT_CAP_WIREGUARD_EXTENDED_RELAY: u64 =
    CLIENT_CAP_WIREGUARD_SUBNET_RELAY | CLIENT_CAP_WIREGUARD_BROADCAST_RELAY;
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub struct WireGuardP2pRegistration {
    pub public_key: [u8; 32],
    pub port: u16,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Default)]
pub enum RegistrationMode {
    #[default]
    Normal = 0,
    PreRegister = 1,
}

impl From<RegistrationMode> for proto::RegistrationMode {
    fn from(mode: RegistrationMode) -> Self {
        match mode {
            RegistrationMode::Normal => proto::RegistrationMode::Normal,
            RegistrationMode::PreRegister => proto::RegistrationMode::PreRegister,
        }
    }
}

impl From<proto::RegistrationMode> for RegistrationMode {
    fn from(mode: proto::RegistrationMode) -> Self {
        match mode {
            proto::RegistrationMode::Normal => RegistrationMode::Normal,
            proto::RegistrationMode::PreRegister => RegistrationMode::PreRegister,
        }
    }
}
pub(crate) struct RegRequestMsg {
    pub network_code: String,
    pub device_id: String,
    pub ip: Option<Ipv4Addr>,
    pub name: String,
    pub version: String,
    pub key_sign: Option<String>,
    pub ip_variable: bool,
    pub server_id: u32,
    pub registration_mode: RegistrationMode,
    pub allow_wire_guard: bool,
    pub wireguard_p2p: Option<WireGuardP2pRegistration>,
    pub client_capabilities: u64,
}
impl RegRequestMsg {
    // pub fn check(&self) -> anyhow::Result<()> {
    //     if self.network_code.is_empty() {
    //         return Err(anyhow!("network_code cannot be empty"));
    //     }
    //     if self.network_code.len() > MAX_NETWORK_CODE_LEN {
    //         return Err(anyhow!(
    //             "network_code length exceeds {} characters (current: {})",
    //             MAX_NETWORK_CODE_LEN,
    //             self.network_code.len()
    //         ));
    //     }
    //     if self.device_id.is_empty() {
    //         return Err(anyhow!("device_id cannot be empty"));
    //     }
    //     if self.device_id.len() > MAX_DEVICE_ID_LEN {
    //         return Err(anyhow!(
    //             "device_id length exceeds {} characters (current: {})",
    //             MAX_DEVICE_ID_LEN,
    //             self.device_id.len()
    //         ));
    //     }
    //
    //     if self.name.len() > MAX_NAME_LEN {
    //         return Err(anyhow!(
    //             "name length exceeds {} characters (current: {})",
    //             MAX_NAME_LEN,
    //             self.name.len()
    //         ));
    //     }
    //
    //     if self.version.len() > MAX_VERSION_LEN {
    //         return Err(anyhow!(
    //             "version length exceeds {} characters (current: {})",
    //             MAX_VERSION_LEN,
    //             self.version.len()
    //         ));
    //     }
    //
    //     Ok(())
    // }
    // pub fn from(msg: proto::RegRequestMsg) -> anyhow::Result<Self> {
    //     Ok(Self {
    //         network_code: msg.network_code,
    //         device_id: msg.device_id,
    //         ip: msg.ip.map(|ip| ip.into()),
    //         name: msg.name,
    //         version: msg.version,
    //         key_sign: msg.key_sign,
    //         ip_variable: msg.ip_variable,
    //         server_id: msg.server_id,
    //     })
    // }
    pub fn to(self) -> proto::RegRequestMsg {
        let (wireguard_p2p_public_key, wireguard_p2p_port) = self
            .wireguard_p2p
            .map(|registration| {
                (
                    registration.public_key.to_vec(),
                    u32::from(registration.port),
                )
            })
            .unwrap_or_default();
        proto::RegRequestMsg {
            network_code: self.network_code,
            device_id: self.device_id,
            ip: self.ip.map(|ip| ip.into()),
            name: self.name,
            version: self.version,
            key_sign: self.key_sign,
            ip_variable: self.ip_variable,
            server_id: self.server_id,
            registration_mode: proto::RegistrationMode::from(self.registration_mode).into(),
            allow_wire_guard: self.allow_wire_guard,
            wireguard_p2p_public_key,
            wireguard_p2p_port,
            client_capabilities: self.client_capabilities,
        }
    }
}
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct RegResponseMsg {
    pub ip: Ipv4Addr,
    pub prefix_len: u8,
    pub gateway: Ipv4Addr,
    pub server_version: String,
}
impl RegResponseMsg {
    pub fn from(msg: proto::RegResponseMsg) -> anyhow::Result<Self> {
        Ok(Self {
            ip: msg.ip.into(),
            prefix_len: (msg.prefix_len & 0xFF) as u8,
            gateway: msg.gateway.into(),
            server_version: msg.server_version,
        })
    }
    pub fn to(self) -> proto::RegResponseMsg {
        proto::RegResponseMsg {
            ip: self.ip.into(),
            prefix_len: self.prefix_len as _,
            gateway: self.gateway.into(),
            server_version: self.server_version,
        }
    }
}
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct ErrorResponseMsg {
    pub code: u32,
    pub message: String,
}
impl ErrorResponseMsg {
    pub fn from(msg: proto::ErrorResponseMsg) -> anyhow::Result<Self> {
        Ok(Self {
            code: msg.code,
            message: msg.message,
        })
    }
    pub fn to(self) -> proto::ErrorResponseMsg {
        proto::ErrorResponseMsg {
            code: self.code,
            message: self.message,
        }
    }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct ConfirmRegResponseMsg {
    pub success: bool,
}
impl ConfirmRegResponseMsg {
    pub fn from(msg: proto::ConfirmRegResponseMsg) -> anyhow::Result<Self> {
        Ok(Self {
            success: msg.success,
        })
    }
    pub fn to(self) -> proto::ConfirmRegResponseMsg {
        proto::ConfirmRegResponseMsg {
            success: self.success,
        }
    }
}
pub(crate) enum RequestMessage {
    Reg(RegRequestMsg),
    ConfirmReg,
}
impl RequestMessage {
    pub fn encode(self) -> BytesMut {
        let request_payload = match self {
            RequestMessage::Reg(reg) => RequestPayload::Reg(reg.to()),
            RequestMessage::ConfirmReg => RequestPayload::ConfirmReg(proto::ConfirmRegMsg {}),
        };
        proto::RequestMessage {
            request_payload: Some(request_payload),
        }
        .encode_bytes_mut()
    }
}
#[derive(Debug, Clone, Eq, PartialEq)]
pub enum ResponseMessage {
    Reg(RegResponseMsg),
    Error(ErrorResponseMsg),
    ConfirmReg(ConfirmRegResponseMsg),
}
impl ResponseMessage {
    pub fn from_slice(buf: &[u8]) -> anyhow::Result<Self> {
        let msg = proto::ResponseMessage::decode(buf)?;
        let Some(payload) = msg.response_payload else {
            bail!("unsupported")
        };
        match payload {
            ResponsePayload::Reg(reg) => Ok(ResponseMessage::Reg(RegResponseMsg::from(reg)?)),
            ResponsePayload::Error(e) => Ok(ResponseMessage::Error(ErrorResponseMsg::from(e)?)),
            ResponsePayload::ConfirmReg(c) => {
                Ok(ResponseMessage::ConfirmReg(ConfirmRegResponseMsg::from(c)?))
            }
        }
    }
    pub fn encode(self) -> BytesMut {
        let response_payload = match self {
            ResponseMessage::Reg(reg) => ResponsePayload::Reg(reg.to()),
            ResponseMessage::Error(e) => ResponsePayload::Error(e.to()),
            ResponseMessage::ConfirmReg(c) => ResponsePayload::ConfirmReg(c.to()),
        };
        proto::ResponseMessage {
            response_payload: Some(response_payload),
        }
        .encode_bytes_mut()
    }
}

impl SelectiveBroadcast {
    pub fn new(ips: &[Ipv4Addr], data: Vec<u8>) -> Self {
        SelectiveBroadcast {
            ips: ips.iter().map(|v| (*v).into()).collect(),
            data,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ClientSimpleInfo {
    pub ip: Ipv4Addr,
    pub name: String,
    pub online: bool,
    pub node_type: NodeType,
}
impl ClientSimpleInfo {
    pub fn from(msg: proto::ClientSimpleInfo) -> anyhow::Result<Self> {
        Ok(Self {
            ip: msg.ip.into(),
            name: String::new(),
            online: msg.online,
            node_type: msg.node_type(),
        })
    }
    pub fn to(self) -> proto::ClientSimpleInfo {
        proto::ClientSimpleInfo {
            ip: self.ip.into(),
            online: self.online,
            node_type: self.node_type as i32,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message;

    #[test]
    fn registration_encodes_wireguard_capability_at_field_ten() {
        let bytes = RegRequestMsg {
            network_code: "network-a".to_string(),
            device_id: "device-a".to_string(),
            ip: None,
            name: "device-a".to_string(),
            version: "2.0.0".to_string(),
            key_sign: None,
            ip_variable: true,
            server_id: 0,
            registration_mode: RegistrationMode::Normal,
            allow_wire_guard: true,
            wireguard_p2p: None,
            client_capabilities: CLIENT_CAP_WIREGUARD_EXTENDED_RELAY,
        }
        .to()
        .encode_to_vec();
        assert!(bytes.windows(2).any(|field| field == [0x50, 0x01]));
        assert!(bytes.windows(2).any(|field| field == [0x68, 0x03]));
    }

    #[test]
    fn registration_encodes_wireguard_p2p_at_fields_eleven_and_twelve() {
        let message = RegRequestMsg {
            network_code: "network-a".to_string(),
            device_id: "device-a".to_string(),
            ip: None,
            name: "device-a".to_string(),
            version: "2.0.0".to_string(),
            key_sign: None,
            ip_variable: true,
            server_id: 0,
            registration_mode: RegistrationMode::Normal,
            allow_wire_guard: true,
            wireguard_p2p: Some(WireGuardP2pRegistration {
                public_key: [0x2a; 32],
                port: 51_820,
            }),
            client_capabilities: CLIENT_CAP_WIREGUARD_EXTENDED_RELAY,
        }
        .to();
        assert_eq!(message.wireguard_p2p_public_key, vec![0x2a; 32]);
        assert_eq!(message.wireguard_p2p_port, 51_820);
    }

    #[test]
    fn legacy_node_type_defaults_to_vnt() {
        let info = ClientSimpleInfo::from(proto::ClientSimpleInfo {
            ip: Ipv4Addr::new(10, 26, 0, 2).into(),
            online: true,
            node_type: 0,
        })
        .unwrap();
        assert_eq!(info.node_type, NodeType::Vnt);
    }
}
#[derive(Debug)]
pub struct ClientSimpleInfoList {
    pub data_version: u64,
    pub list: Vec<ClientSimpleInfo>,
    pub is_all: bool,
    pub time: i64,
}
impl ClientSimpleInfoList {
    pub fn from_slice(buf: &[u8]) -> anyhow::Result<Self> {
        let msg = proto::ClientSimpleInfoList::decode(buf)?;
        let mut list = Vec::with_capacity(msg.list.len());
        for x in msg.list {
            list.push(ClientSimpleInfo::from(x)?);
        }
        Ok(Self {
            data_version: msg.data_version,
            list,
            is_all: msg.is_all,
            time: msg.time,
        })
    }
}
