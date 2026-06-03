use anyhow::Result;
use clap::{Parser, Subcommand};
use std::path::PathBuf;

mod codec;
mod crypto_vectors;
mod repo;
mod script_corpus;
mod status;
mod storage;
mod storage_proof;

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
        } => print_json(&script_corpus::run(
            manifest.as_deref(),
            result_path.as_deref(),
            fixture_id.as_deref(),
        )?),
    }
}

fn print_json<T: serde::Serialize>(value: &T) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}
