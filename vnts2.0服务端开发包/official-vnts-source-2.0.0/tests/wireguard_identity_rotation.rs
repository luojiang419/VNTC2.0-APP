use base64::{Engine, engine::general_purpose::STANDARD as BASE64_STANDARD};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const CREATE_NO_WINDOW: u32 = 0x08000000;

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new() -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "vnts2-wireguard-identity-rotation-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let Ok(root) = self.0.canonicalize() else {
            return;
        };
        let Ok(temp) = std::env::temp_dir().canonicalize() else {
            return;
        };
        if root != temp && root.starts_with(&temp) {
            let _ = fs::remove_dir_all(root);
        }
    }
}

struct ChildGuard(Option<Child>);

impl ChildGuard {
    fn spawn(mut command: Command) -> Self {
        Self(Some(command.spawn().unwrap()))
    }

    fn child_mut(&mut self) -> &mut Child {
        self.0.as_mut().unwrap()
    }

    fn stop(&mut self) {
        if let Some(mut child) = self.0.take() {
            if child.try_wait().unwrap().is_none() {
                child.kill().unwrap();
            }
            child.wait().unwrap();
        }
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        self.stop();
    }
}

fn command(binary: &Path) -> Command {
    let command = Command::new(binary);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let mut command = command;
        command.creation_flags(CREATE_NO_WINDOW);
        command
    }
    #[cfg(not(windows))]
    {
        let _ = CREATE_NO_WINDOW;
        command
    }
}

fn server_command(binary: &Path, config: &Path) -> Command {
    let mut command = command(binary);
    command
        .arg("--conf")
        .arg(config)
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command
}

fn rotation_command(binary: &Path, config: &Path) -> Output {
    command(binary)
        .arg("--conf")
        .arg(config)
        .arg("--rotate-wireguard-identity")
        .output()
        .unwrap()
}

fn public_keys(log: &Path) -> Vec<String> {
    let Ok(content) = fs::read_to_string(log) else {
        return Vec::new();
    };
    content
        .lines()
        .filter_map(|line| {
            line.split_once("WireGuard server identity initialized, public key: ")
                .map(|(_, key)| key.trim().to_string())
        })
        .collect()
}

fn wait_for_public_key(child: &mut Child, log: &Path, minimum_count: usize) -> String {
    for _ in 0..100 {
        let keys = public_keys(log);
        if keys.len() >= minimum_count {
            return keys.last().unwrap().clone();
        }
        if let Some(status) = child.try_wait().unwrap() {
            panic!("VNTS server exited before identity initialization: {status}");
        }
        thread::sleep(Duration::from_millis(50));
    }
    panic!("timed out waiting for WireGuard identity initialization");
}

#[test]
fn cli_rotation_is_offline_atomic_and_immediately_replaces_identity() {
    let directory = TestDirectory::new();
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_vnts2"));
    let master_key = directory.0.join("wireguard-master.key");
    let config = directory.0.join("config.toml");
    let log = directory.0.join("logs").join("vnts2.log");

    let master_key_bytes = [0x33; 32];
    fs::write(&master_key, master_key_bytes).unwrap();
    let config_text = format!(
        "tcp_bind = \"127.0.0.1:0\"\n\
         network = \"10.89.0.0/24\"\n\
         white_list = []\n\
         lease_duration = 60\n\
         persistence = true\n\
         wireguard_master_key_file = '{}'\n\
         [custom_nets]\n",
        master_key.display()
    );
    fs::write(&config, &config_text).unwrap();

    let mut initial_server = ChildGuard::spawn(server_command(&binary, &config));
    let old_public_key = wait_for_public_key(initial_server.child_mut(), &log, 1);

    let online_attempt = rotation_command(&binary, &config);
    assert!(!online_attempt.status.success());
    assert!(
        String::from_utf8_lossy(&online_attempt.stderr).contains("already in use"),
        "unexpected online rotation error: {}",
        String::from_utf8_lossy(&online_attempt.stderr)
    );
    initial_server.stop();

    let rotation = rotation_command(&binary, &config);
    assert!(
        rotation.status.success(),
        "offline identity rotation failed: {}",
        String::from_utf8_lossy(&rotation.stderr)
    );
    let rotation_output = String::from_utf8_lossy(&rotation.stdout);
    assert!(rotation_output.contains(&old_public_key));
    let new_public_key = rotation_output
        .split_once("new public key ")
        .map(|(_, suffix)| suffix.lines().next().unwrap().trim().to_string())
        .expect("rotation output must contain the new public key");
    assert_ne!(new_public_key, old_public_key);
    let new_public_key_bytes = hex::decode(&new_public_key).unwrap();
    assert!(rotation_output.contains(&format!(
        "New WireGuard client public key (Base64): {}",
        BASE64_STANDARD.encode(new_public_key_bytes)
    )));
    assert!(rotation_output.contains("Update every WireGuard client"));
    assert_eq!(fs::read_to_string(&config).unwrap(), config_text);
    assert_eq!(fs::read(&master_key).unwrap(), master_key_bytes);

    let mut rotated_server = ChildGuard::spawn(server_command(&binary, &config));
    let loaded_public_key = wait_for_public_key(rotated_server.child_mut(), &log, 2);
    assert_eq!(loaded_public_key, new_public_key);
    rotated_server.stop();
}
