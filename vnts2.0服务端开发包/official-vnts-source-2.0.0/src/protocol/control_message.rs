#![allow(dead_code)]

use crate::protocol::ProtoToBytesMut;
use crate::protocol::control_message::proto::request_message::RequestPayload;
use crate::protocol::control_message::proto::response_message::ResponsePayload;
use anyhow::{anyhow, bail};
use bytes::BytesMut;
use prost::Message;
use std::collections::HashSet;
use std::net::Ipv4Addr;

pub(crate) mod proto {
    include!(concat!(env!("OUT_DIR"), "/protocol.control_message.rs"));
}

pub use proto::{NodeType, RegistrationMode};
pub const CLIENT_CAP_WIREGUARD_SUBNET_RELAY: u64 = 1 << 0;
pub const CLIENT_CAP_WIREGUARD_BROADCAST_RELAY: u64 = 1 << 1;
pub const CLIENT_CAP_WIREGUARD_EXTENDED_RELAY: u64 =
    CLIENT_CAP_WIREGUARD_SUBNET_RELAY | CLIENT_CAP_WIREGUARD_BROADCAST_RELAY;
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub struct WireGuardP2pRegistration {
    pub public_key: [u8; 32],
    pub port: u16,
}

#[derive(Debug, Clone)]
pub struct RegRequestMsg {
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
    pub const MAX_NETWORK_CODE_LEN: usize = 32;
    pub const MAX_DEVICE_ID_LEN: usize = 64;
    pub const MAX_NAME_LEN: usize = 128;
    pub const MAX_VERSION_LEN: usize = 32;
    pub fn check(&self) -> anyhow::Result<()> {
        if self.network_code.is_empty() {
            return Err(anyhow!("network_code cannot be empty"));
        }
        if self.network_code.len() > Self::MAX_NETWORK_CODE_LEN {
            return Err(anyhow!(
                "network_code length exceeds {} characters (current: {})",
                Self::MAX_NETWORK_CODE_LEN,
                self.network_code.len()
            ));
        }
        if self.device_id.is_empty() {
            return Err(anyhow!("device_id cannot be empty"));
        }
        if self.device_id.len() > Self::MAX_DEVICE_ID_LEN {
            return Err(anyhow!(
                "device_id length exceeds {} characters (current: {})",
                Self::MAX_DEVICE_ID_LEN,
                self.device_id.len()
            ));
        }

        if self.name.len() > Self::MAX_NAME_LEN {
            return Err(anyhow!(
                "name length exceeds {} characters (current: {})",
                Self::MAX_NAME_LEN,
                self.name.len()
            ));
        }

        if self.version.len() > Self::MAX_VERSION_LEN {
            return Err(anyhow!(
                "version length exceeds {} characters (current: {})",
                Self::MAX_VERSION_LEN,
                self.version.len()
            ));
        }

        if self.wireguard_p2p.is_some() && !self.allow_wire_guard {
            bail!("WireGuard P2P requires allow_wire_guard");
        }
        if self.client_capabilities & CLIENT_CAP_WIREGUARD_EXTENDED_RELAY != 0
            && !self.allow_wire_guard
        {
            bail!("WireGuard relay capabilities require allow_wire_guard");
        }

        Ok(())
    }
    pub fn from(msg: proto::RegRequestMsg) -> anyhow::Result<Self> {
        let registration_mode = msg.registration_mode();
        let wireguard_p2p = match (
            msg.wireguard_p2p_public_key.as_slice(),
            msg.wireguard_p2p_port,
        ) {
            ([], 0) => None,
            (key, port @ 1..=65_535) if key.len() == 32 => Some(WireGuardP2pRegistration {
                public_key: key.try_into().expect("length checked above"),
                port: port as u16,
            }),
            _ => bail!("WireGuard P2P requires a 32-byte public key and a non-zero UDP port"),
        };
        Ok(Self {
            network_code: msg.network_code,
            device_id: msg.device_id,
            ip: msg.ip.map(|ip| ip.into()),
            name: msg.name,
            version: msg.version,
            key_sign: msg.key_sign,
            ip_variable: msg.ip_variable,
            server_id: msg.server_id,
            registration_mode,
            allow_wire_guard: msg.allow_wire_guard,
            wireguard_p2p,
            client_capabilities: msg.client_capabilities,
        })
    }
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
            registration_mode: self.registration_mode as i32,
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
pub struct ConfirmRegMsg {}
impl ConfirmRegMsg {
    pub fn from(_msg: proto::ConfirmRegMsg) -> anyhow::Result<Self> {
        Ok(Self {})
    }
    pub fn to(self) -> proto::ConfirmRegMsg {
        proto::ConfirmRegMsg {}
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
#[derive(Debug, Clone)]
pub enum RequestMessage {
    Reg(RegRequestMsg),
    ConfirmReg(ConfirmRegMsg),
}
impl RequestMessage {
    pub fn from_slice(buf: &[u8]) -> anyhow::Result<Self> {
        let msg = proto::RequestMessage::decode(buf)?;
        let Some(payload) = msg.request_payload else {
            bail!("unsupported")
        };
        match payload {
            RequestPayload::Reg(reg) => Ok(RequestMessage::Reg(RegRequestMsg::from(reg)?)),
            RequestPayload::ConfirmReg(confirm) => {
                Ok(RequestMessage::ConfirmReg(ConfirmRegMsg::from(confirm)?))
            }
        }
    }
    pub fn encode(self) -> BytesMut {
        let request_payload = match self {
            RequestMessage::Reg(reg) => RequestPayload::Reg(reg.to()),
            RequestMessage::ConfirmReg(confirm) => RequestPayload::ConfirmReg(confirm.to()),
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
    pub fn encode(self) -> BytesMut {
        let response_payload = match self {
            ResponseMessage::Reg(reg) => ResponsePayload::Reg(reg.to()),
            ResponseMessage::Error(e) => ResponsePayload::Error(e.to()),
            ResponseMessage::ConfirmReg(confirm) => ResponsePayload::ConfirmReg(confirm.to()),
        };
        proto::ResponseMessage {
            response_payload: Some(response_payload),
        }
        .encode_bytes_mut()
    }
}

pub struct SelectiveBroadcast {
    pub ips: HashSet<Ipv4Addr>,
    pub data: Vec<u8>,
}
impl SelectiveBroadcast {
    pub fn from_slice(buf: &[u8]) -> anyhow::Result<Self> {
        let msg = proto::SelectiveBroadcast::decode(buf)?;
        Ok(Self {
            ips: msg.ips.into_iter().map(|v| v.into()).collect(),
            data: msg.data,
        })
    }
    pub fn encode(self) -> BytesMut {
        proto::SelectiveBroadcast {
            ips: self.ips.into_iter().map(|v| v.into()).collect(),
            data: self.data,
        }
        .encode_bytes_mut()
    }
}

#[derive(Debug, Clone)]
pub struct ClientSimpleInfo {
    pub ip: Ipv4Addr,
    pub online: bool,
    pub node_type: NodeType,
}
impl ClientSimpleInfo {
    pub fn from(msg: proto::ClientSimpleInfo) -> anyhow::Result<Self> {
        Ok(Self {
            ip: msg.ip.into(),
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

    fn fixture(path: &str) -> Vec<u8> {
        let value = match path {
            "reg-request-v2-legacy.hex" => {
                include_str!("../../tests/fixtures/reg-request-v2-legacy.hex")
            }
            "reg-request-v2-wireguard.hex" => {
                include_str!("../../tests/fixtures/reg-request-v2-wireguard.hex")
            }
            "client-list-v2-legacy.hex" => {
                include_str!("../../tests/fixtures/client-list-v2-legacy.hex")
            }
            "client-list-v2-wireguard.hex" => {
                include_str!("../../tests/fixtures/client-list-v2-wireguard.hex")
            }
            _ => panic!("unknown fixture: {path}"),
        };
        hex::decode(value.trim()).expect("fixture must be valid hex")
    }

    #[test]
    fn legacy_registration_defaults_wireguard_capability_to_false() {
        let decoded = RequestMessage::from_slice(&fixture("reg-request-v2-legacy.hex"))
            .expect("legacy registration must remain decodable");
        let RequestMessage::Reg(registration) = decoded else {
            panic!("fixture must contain a registration request");
        };

        assert!(!registration.allow_wire_guard);
        assert_eq!(registration.wireguard_p2p, None);
        assert_eq!(registration.client_capabilities, 0);
        assert_eq!(
            RequestMessage::Reg(registration).encode().as_ref(),
            fixture("reg-request-v2-legacy.hex")
        );
    }

    #[test]
    fn wireguard_registration_uses_frozen_field_ten() {
        let decoded = RequestMessage::from_slice(&fixture("reg-request-v2-wireguard.hex"))
            .expect("wireguard registration must decode");
        let RequestMessage::Reg(registration) = decoded else {
            panic!("fixture must contain a registration request");
        };

        assert!(registration.allow_wire_guard);
        assert_eq!(registration.wireguard_p2p, None);
        assert_eq!(registration.client_capabilities, 0);
        assert_eq!(
            RequestMessage::Reg(registration).encode().as_ref(),
            fixture("reg-request-v2-wireguard.hex")
        );
    }

    #[test]
    fn wireguard_p2p_registration_requires_capability_key_and_port() {
        let registration = RegRequestMsg::from(proto::RegRequestMsg {
            network_code: "network-a".to_string(),
            device_id: "device-a".to_string(),
            allow_wire_guard: true,
            wireguard_p2p_public_key: vec![0x2a; 32],
            wireguard_p2p_port: 51_820,
            ..Default::default()
        })
        .unwrap();
        assert_eq!(
            registration.wireguard_p2p,
            Some(WireGuardP2pRegistration {
                public_key: [0x2a; 32],
                port: 51_820,
            })
        );

        let invalid_key = RegRequestMsg::from(proto::RegRequestMsg {
            allow_wire_guard: true,
            wireguard_p2p_public_key: vec![0x2a; 31],
            wireguard_p2p_port: 51_820,
            ..Default::default()
        });
        assert!(invalid_key.is_err());

        let disabled = RegRequestMsg {
            wireguard_p2p: registration.wireguard_p2p,
            allow_wire_guard: false,
            ..registration
        };
        assert!(disabled.check().is_err());
    }

    #[test]
    fn extended_wireguard_capabilities_use_additive_field_thirteen() {
        let registration = RegRequestMsg::from(proto::RegRequestMsg {
            network_code: "network-a".to_string(),
            device_id: "device-a".to_string(),
            allow_wire_guard: true,
            client_capabilities: CLIENT_CAP_WIREGUARD_EXTENDED_RELAY,
            ..Default::default()
        })
        .unwrap();
        registration.check().unwrap();
        let encoded = RequestMessage::Reg(registration).encode();
        assert!(encoded.windows(2).any(|field| field == [0x68, 0x03]));

        let invalid = RegRequestMsg::from(proto::RegRequestMsg {
            network_code: "network-a".to_string(),
            device_id: "device-a".to_string(),
            client_capabilities: CLIENT_CAP_WIREGUARD_SUBNET_RELAY,
            ..Default::default()
        })
        .unwrap();
        assert!(invalid.check().is_err());
    }

    #[test]
    fn legacy_client_list_defaults_node_type_to_vnt() {
        let list = ClientSimpleInfoList::from_slice(&fixture("client-list-v2-legacy.hex"))
            .expect("legacy client list must remain decodable");

        assert_eq!(list.list[0].node_type, NodeType::Vnt);
        assert_eq!(list.encode().as_ref(), fixture("client-list-v2-legacy.hex"));
    }

    #[test]
    fn wireguard_client_list_uses_frozen_node_type_value() {
        let list = ClientSimpleInfoList::from_slice(&fixture("client-list-v2-wireguard.hex"))
            .expect("wireguard client list must decode");

        assert_eq!(list.list[0].node_type, NodeType::Wireguard);
        assert_eq!(
            list.encode().as_ref(),
            fixture("client-list-v2-wireguard.hex")
        );
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
    pub fn encode(self) -> BytesMut {
        let mut list = Vec::with_capacity(self.list.len());
        for x in self.list {
            list.push(x.to());
        }
        proto::ClientSimpleInfoList {
            data_version: self.data_version,
            list,
            is_all: self.is_all,
            time: self.time,
        }
        .encode_bytes_mut()
    }
}
