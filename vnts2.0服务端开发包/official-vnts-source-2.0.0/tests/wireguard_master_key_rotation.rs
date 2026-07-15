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
            "vnts2-wireguard-rotation-{}-{unique}",
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

fn rotation_command(binary: &Path, config: &Path, new_key: &Path) -> Output {
    command(binary)
        .arg("--conf")
        .arg(config)
        .arg("--rotate-wireguard-master-key")
        .arg(new_key)
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

fn wait_for_failure(child: &mut Child) {
    for _ in 0..100 {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(!status.success());
            return;
        }
        thread::sleep(Duration::from_millis(50));
    }
    panic!("old master key did not fail closed after rotation");
}

#[test]
fn cli_rotation_is_offline_atomic_and_preserves_wireguard_identity() {
    let directory = TestDirectory::new();
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_vnts2"));
    let old_key = directory.0.join("old-master.key");
    let new_key = directory.0.join("new-master.key");
    let config = directory.0.join("config.toml");
    let log = directory.0.join("logs").join("vnts2.log");

    fs::write(&old_key, [0x11; 32]).unwrap();
    fs::write(&new_key, [0x22; 32]).unwrap();
    let config_text = format!(
        "tcp_bind = \"127.0.0.1:0\"\n\
         network = \"10.88.0.0/24\"\n\
         white_list = []\n\
         lease_duration = 60\n\
         persistence = true\n\
         wireguard_master_key_file = '{}'\n\
         [custom_nets]\n",
        old_key.display()
    );
    fs::write(&config, &config_text).unwrap();

    let mut initial_server = ChildGuard::spawn(server_command(&binary, &config));
    let public_key = wait_for_public_key(initial_server.child_mut(), &log, 1);

    let online_attempt = rotation_command(&binary, &config, &new_key);
    assert!(!online_attempt.status.success());
    assert!(
        String::from_utf8_lossy(&online_attempt.stderr).contains("already in use"),
        "unexpected online rotation error: {}",
        String::from_utf8_lossy(&online_attempt.stderr)
    );
    initial_server.stop();

    let rotation = rotation_command(&binary, &config, &new_key);
    assert!(
        rotation.status.success(),
        "offline rotation failed: {}",
        String::from_utf8_lossy(&rotation.stderr)
    );
    let rotation_output = String::from_utf8_lossy(&rotation.stdout);
    assert!(rotation_output.contains("version 1 to 2"));
    assert!(rotation_output.contains(&public_key));

    let mut old_key_server = ChildGuard::spawn(server_command(&binary, &config));
    wait_for_failure(old_key_server.child_mut());
    old_key_server.stop();

    fs::write(
        &config,
        config_text.replace(
            &old_key.display().to_string(),
            &new_key.display().to_string(),
        ),
    )
    .unwrap();
    let mut new_key_server = ChildGuard::spawn(server_command(&binary, &config));
    let public_key_after_rotation = wait_for_public_key(new_key_server.child_mut(), &log, 2);
    assert_eq!(public_key_after_rotation, public_key);
    new_key_server.stop();
}
