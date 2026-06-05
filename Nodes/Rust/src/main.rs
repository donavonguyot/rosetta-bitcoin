use anyhow::Result;
use clap::{Parser, Subcommand};
use std::path::PathBuf;

mod codec;
mod connect;
mod crypto_vectors;
mod local_reference;
mod p2p;
mod refsync;
mod repo;
mod script_corpus;
mod script_verify;
mod status;
mod storage;
mod storage_proof;
mod tx;

#[derive(Parser)]
#[command(name = "rsbitnode")]
#[command(about = "RustNode Core-native scaffold")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Status {
        #[arg(long, default_value = "./data-rust")]
        datadir: PathBuf,
        #[arg(long, default_value = "host")]
        runtime_surface: String,
    },
    StorageProof {
        #[arg(long, default_value = "./data-rust-proof")]
        datadir: PathBuf,
        #[arg(long)]
        result_path: Option<PathBuf>,
        #[arg(long, default_value = "host")]
        runtime_surface: String,
    },
    CodecVectors {
        #[arg(long)]
        fixture_path: Option<PathBuf>,
    },
    NativeCryptoVectors {
        #[arg(long)]
        fixture_path: Option<PathBuf>,
    },
    ScriptCorpus {
        #[arg(long)]
        manifest: Option<PathBuf>,
        #[arg(long)]
        result_path: Option<PathBuf>,
        #[arg(long)]
        fixture_id: Option<String>,
        #[arg(long, default_value = "host")]
        runtime_surface: String,
    },
    Sync {
        #[arg(long, default_value = "./data-rust-sync")]
        datadir: PathBuf,
        #[arg(long, default_value_t = 10000)]
        target: u32,
        #[arg(long)]
        rpc_url: Option<String>,
        #[arg(long)]
        rpc_user: Option<String>,
        #[arg(long)]
        rpc_password: Option<String>,
        #[arg(long, default_value_t = 1000)]
        progress: u32,
        #[arg(long, default_value = "host")]
        runtime_surface: String,
    },
    Connect {
        #[arg(long, default_value = "./data-rust-sync")]
        datadir: PathBuf,
        #[arg(long, default_value_t = 10000)]
        target: u32,
        #[arg(long, default_value_t = 100)]
        progress: u32,
        #[arg(long, default_value = "host")]
        runtime_surface: String,
    },
    LocalReferenceProof {
        #[arg(long, default_value = "./data-rust-docker-proof")]
        datadir: PathBuf,
        #[arg(long, default_value_t = 10000)]
        target: u32,
        #[arg(long)]
        rpc_url: Option<String>,
        #[arg(long)]
        rpc_user: Option<String>,
        #[arg(long)]
        rpc_password: Option<String>,
        #[arg(long)]
        peer: Option<String>,
        #[arg(long)]
        result_path: Option<PathBuf>,
        #[arg(long, default_value_t = 1000)]
        progress: u32,
        #[arg(long, default_value = "pipeline")]
        mode: String,
        #[arg(long, default_value = "rpc")]
        byte_source: String,
        #[arg(long, default_value = "host")]
        runtime_surface: String,
    },
    ExternalPeerProof {
        #[arg(long, default_value = "./data-rust-external-proof")]
        datadir: PathBuf,
        #[arg(long, default_value_t = 5000)]
        target: u32,
        #[arg(long)]
        peer: String,
        #[arg(long)]
        result_path: Option<PathBuf>,
        #[arg(long, default_value_t = 1000)]
        progress: u32,
        #[arg(long, default_value = "host")]
        runtime_surface: String,
    },
    BlockerInspect {
        #[arg(long, default_value = "./data-rust-sync")]
        datadir: PathBuf,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Status {
            datadir,
            runtime_surface,
        } => print_json(&status::build(&datadir, &runtime_surface)?),
        Command::StorageProof {
            datadir,
            result_path,
            runtime_surface,
        } => print_json(&storage_proof::run(
            &datadir,
            result_path.as_deref(),
            &runtime_surface,
        )?),
        Command::CodecVectors { fixture_path } => {
            print_json(&codec::run_vectors(fixture_path.as_deref())?)
        }
        Command::NativeCryptoVectors { fixture_path } => {
            print_json(&crypto_vectors::run(fixture_path.as_deref())?)
        }
        Command::ScriptCorpus {
            manifest,
            result_path,
            fixture_id,
            runtime_surface,
        } => print_json(&script_corpus::run(
            manifest.as_deref(),
            result_path.as_deref(),
            fixture_id.as_deref(),
            &runtime_surface,
        )?),
        Command::Sync {
            datadir,
            target,
            rpc_url,
            rpc_user,
            rpc_password,
            progress,
            runtime_surface,
        } => {
            let (default_url, default_user, default_pass) = refsync::rpc_defaults(false);
            let rpc_url = rpc_url.unwrap_or_else(|| default_url.to_string());
            let rpc_user = rpc_user.unwrap_or_else(|| default_user.to_string());
            let rpc_password = rpc_password.unwrap_or_else(|| default_pass.to_string());
            print_json(&refsync::run(refsync::SyncOptions {
                datadir: &datadir,
                target,
                rpc_url: &rpc_url,
                rpc_user: &rpc_user,
                rpc_password: &rpc_password,
                progress,
                runtime_surface: &runtime_surface,
            })?)
        }
        Command::Connect {
            datadir,
            target,
            progress,
            runtime_surface,
        } => print_json(&connect::run(connect::ConnectOptions {
            datadir: &datadir,
            target,
            progress,
            quiet: false,
            runtime_surface: &runtime_surface,
        })?),
        Command::LocalReferenceProof {
            datadir,
            target,
            rpc_url,
            rpc_user,
            rpc_password,
            peer,
            result_path,
            progress,
            mode,
            byte_source,
            runtime_surface,
        } => {
            let docker = runtime_surface == "docker";
            let (default_url, default_user, default_pass) = refsync::rpc_defaults(docker);
            let rpc_url = rpc_url.unwrap_or_else(|| default_url.to_string());
            let rpc_user = rpc_user.unwrap_or_else(|| default_user.to_string());
            let rpc_password = rpc_password.unwrap_or_else(|| default_pass.to_string());
            let peer = peer.unwrap_or_else(|| {
                if docker {
                    "host.docker.internal:48333".to_string()
                } else {
                    "127.0.0.1:48333".to_string()
                }
            });
            print_json(&local_reference::run(
                local_reference::LocalReferenceOptions {
                    datadir: &datadir,
                    target,
                    rpc_url: &rpc_url,
                    rpc_user: &rpc_user,
                    rpc_password: &rpc_password,
                    peer: &peer,
                    result_path: result_path.as_deref(),
                    progress,
                    mode: &mode,
                    byte_source: &byte_source,
                    runtime_surface: &runtime_surface,
                },
            )?)
        }
        Command::ExternalPeerProof {
            datadir,
            target,
            peer,
            result_path,
            progress,
            runtime_surface,
        } => print_json(&local_reference::run(
            local_reference::LocalReferenceOptions {
                datadir: &datadir,
                target,
                rpc_url: "",
                rpc_user: "",
                rpc_password: "",
                peer: &peer,
                result_path: result_path.as_deref(),
                progress,
                mode: "pipeline",
                byte_source: "external_p2p",
                runtime_surface: &runtime_surface,
            },
        )?),
        Command::BlockerInspect { datadir } => {
            let meta =
                storage::read_metadata(&datadir).unwrap_or_else(|_| storage::missing_metadata());
            print_json(&serde_json::json!({
                "implementation": "RustNode",
                "category": "blocker_inspect",
                "datadir": datadir,
                "current_blocker": meta.current_blocker,
                "validated_height": meta.validated_height,
                "validated_hash": meta.validated_hash,
                "sync_status": meta.sync_status,
                "binary_gate_status": "not_attempted"
            }))
        }
    }
}

fn print_json<T: serde::Serialize>(value: &T) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}
