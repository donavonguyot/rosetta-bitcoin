use anyhow::{anyhow, Result};
use std::path::{Path, PathBuf};

pub fn root() -> Result<PathBuf> {
    let mut dir = std::env::current_dir()?;
    loop {
        if dir.join("AGENTS.md").is_file() && dir.join("Shared").is_dir() {
            return Ok(dir);
        }
        if !dir.pop() {
            return Err(anyhow!("could not locate RB workspace root"));
        }
    }
}

pub fn rel(path: &Path) -> String {
    match root()
        .ok()
        .and_then(|root| path.strip_prefix(root).ok().map(Path::to_path_buf))
    {
        Some(relative) => relative.to_string_lossy().replace('\\', "/"),
        None => path.to_string_lossy().replace('\\', "/"),
    }
}

pub fn git_commit() -> String {
    let root = match root() {
        Ok(root) => root,
        Err(_) => return "unknown".to_string(),
    };
    let output = std::process::Command::new("git")
        .args(["rev-parse", "--short=12", "HEAD"])
        .current_dir(root)
        .output();
    match output {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        _ => "unknown".to_string(),
    }
}
