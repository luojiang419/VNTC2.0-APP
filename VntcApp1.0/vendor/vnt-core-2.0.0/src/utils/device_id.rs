use anyhow::Context;
use std::fs;
use std::path::Path;
pub fn get_device_id() -> anyhow::Result<String> {
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        match machine_uid::get() {
            Ok(id) => {
                if let Some(id) = normalized_id(&id) {
                    return Ok(id);
                }
                log::warn!("System ID is empty. Using fallback.");
            }
            Err(e) => {
                log::warn!("Failed to get system ID: {}. Using fallback.", e);
            }
        }
    }

    get_fallback_id()
}

fn normalized_id(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn get_fallback_id() -> anyhow::Result<String> {
    let path = Path::new("device_id");

    if let Ok(content) = fs::read_to_string(path) {
        let id = content.trim();
        if !id.is_empty() {
            return Ok(id.to_string());
        }
    }

    let new_id = uuid::Uuid::new_v4().to_string();

    fs::write(path, &new_id).context("Failed to write device_id file")?;

    Ok(new_id)
}

#[cfg(test)]
mod tests {
    use super::normalized_id;

    #[test]
    fn rejects_empty_machine_id() {
        assert_eq!(normalized_id("\n  \t"), None);
    }

    #[test]
    fn trims_non_empty_machine_id() {
        assert_eq!(
            normalized_id("  linux-device\n"),
            Some("linux-device".to_string())
        );
    }
}
