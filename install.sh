#!/bin/bash

# Install script for TerminAI: A Rust-based CLI tool for AI-assisted command suggestions.
# Run this script WITHOUT sudo; it will prompt for sudo when installing the binary.
# This script:
# - Checks for and installs Rust if needed.
# - Creates the project directory and writes necessary files (Cargo.toml, main.rs).
# - Builds the static binary.
# - Installs the binary to /usr/local/bin (prompts for sudo).
# - If no ~/.env, prompts for API configuration and creates it.
# - Generates and saves AI personality based on system specs.
# - Detects and updates shell config (Bash or Zsh) with command-not-found hooks.

set -e

# Warn if running as root/sudo
if [ "$(id -u)" -eq 0 ]; then
    echo "Warning: Do not run this script with sudo. It may fail due to missing user environment (e.g., rustup PATH)."
    echo "Please rerun without sudo; the script will prompt for sudo when needed."
    exit 1
fi

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Step 1: Install Rust if not present
if ! command_exists rustc; then
    echo "Rust not found. Installing Rust via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    rustup target add x86_64-unknown-linux-musl
else
    echo "Rust is already installed."
    # Ensure rustup is in PATH (edge case if env not sourced)
    if ! command_exists rustup; then
        if [ -f "$HOME/.cargo/env" ]; then
            source "$HOME/.cargo/env"
        else
            echo "Rust is installed but rustup not found. Please ensure ~/.cargo/env is sourced or reinstall Rust."
            exit 1
        fi
    fi
    echo "Checking if target x86_64-unknown-linux-musl is installed..."
    if ! rustup target list | grep -q "x86_64-unknown-linux-musl (installed)"; then
        echo "Target not installed. Adding it now..."
        rustup target add x86_64-unknown-linux-musl
    else
        echo "Target is already installed."
    fi
fi

# Step 2: Create project directory
PROJECT_DIR="$HOME/terminai"
if [ -d "$PROJECT_DIR" ]; then
    echo "Project directory $PROJECT_DIR already exists. Removing and recreating..."
    rm -rf "$PROJECT_DIR"
fi
mkdir -p "$PROJECT_DIR/src"
cd "$PROJECT_DIR"

# Step 3: Write Cargo.toml (with reqwest fix, sysinfo, and dotenvy)
cat << EOF > Cargo.toml
[package]
name = "terminai"
version = "0.1.0"
edition = "2021"

[dependencies]
clap = { version = "4.5", features = ["derive"] }
reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
tokio = { version = "1.38", features = ["full"] }
toml = "0.8"
whoami = "1.5"
sysinfo = "0.30.13"
dotenvy = "0.15"
EOF

# Step 4: Write src/main.rs
cat << 'EOF' > src/main.rs
use clap::{Parser, Subcommand};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::env;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;
use std::process::Command;
use sysinfo::{CpuRefreshKind, MemoryRefreshKind, RefreshKind, System};
use tokio;

#[derive(Parser)]
#[command(version = "0.1.0")]
struct Args {
    #[command(subcommand)]
    command: Option<Commands>,

    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    unknown_command: Vec<String>,
}

#[derive(Subcommand)]
enum Commands {
    Init,
}

#[derive(Deserialize, Serialize)]
struct Config {
    api_provider: String,
    api_key: String,
    model: String,
}

#[derive(Deserialize, Serialize, Default)]
struct Personality {
    name: String,
    description: String,
}

#[derive(Serialize)]
struct Request {
    model: String,
    messages: Vec<Message>,
}

#[derive(Serialize)]
struct Message {
    role: String,
    content: String,
}

#[derive(Deserialize)]
struct Response {
    choices: Vec<Choice>,
}

#[derive(Deserialize)]
struct Choice {
    message: MessageContent,
}

#[derive(Deserialize)]
struct MessageContent {
    content: String,
}

async fn query_api(client: &Client, config: &Config, prompt: &str, system_prompt: &str) -> Result<String, Box<dyn std::error::Error>> {
    let url = match config.api_provider.as_str() {
        "grok" => "https://api.x.ai/v1/chat/completions",
        "openrouter" => "https://openrouter.ai/api/v1/chat/completions",
        _ => return Err("Invalid provider".into()),
    };

    let mut request = Request {
        model: config.model.clone(),
        messages: vec![Message {
            role: "user".to_string(),
            content: prompt.to_string(),
        }],
    };

    request.messages.insert(0, Message {
        role: "system".to_string(),
        content: system_prompt.to_string(),
    });

    let res = client.post(url)
        .header("Authorization", format!("Bearer {}", config.api_key))
        .header("Content-Type", "application/json")
        .json(&request)
        .send()
        .await?;

    let body: Response = res.json().await?;
    Ok(body.choices[0].message.content.clone())
}

fn load_config() -> Result<Config, Box<dyn std::error::Error>> {
    let home = env::var("HOME")?;
    let env_path = Path::new(&home).join(".env");
    dotenvy::from_path(&env_path).ok();  // Load .env if exists

    let api_provider = env::var("api_provider").unwrap_or_default();
    let api_key = env::var("api_key").unwrap_or_default();
    let model = env::var("model").unwrap_or_default();

    if api_provider.is_empty() || api_key.is_empty() || model.is_empty() {
        return Err("Missing config in .env".into());
    }

    Ok(Config {
        api_provider,
        api_key,
        model,
    })
}

fn load_personality() -> Personality {
    let home = env::var("HOME").unwrap_or_default();
    let personality_path = Path::new(&home).join(".terminai-personality.toml");
    if let Ok(personality_str) = fs::read_to_string(&personality_path) {
        toml::from_str(&personality_str).unwrap_or_default()
    } else {
        Personality::default()
    }
}

fn save_personality(personality: &Personality) -> Result<(), Box<dyn std::error::Error>> {
    let home = env::var("HOME")?;
    let personality_path = Path::new(&home).join(".terminai-personality.toml");
    let personality_toml = toml::to_string(personality)?;
    fs::write(personality_path, personality_toml)?;
    Ok(())
}

async fn generate_personality(config: &Config) -> Result<Personality, Box<dyn std::error::Error>> {
    let mut sys = System::new_with_specifics(
        RefreshKind::new()
            .with_cpu(CpuRefreshKind::everything())
            .with_memory(MemoryRefreshKind::everything())
    );
    sys.refresh_all();

    let hostname = System::host_name().unwrap_or("Unknown".to_string());
    let specs = format!(
        "Hostname: {}\nCPU: {} ({} cores)\nMemory: {} GB\nOS: {}",
        hostname,
        sys.global_cpu_info().brand(),
        sys.physical_core_count().unwrap_or(0),
        sys.total_memory() / 1024 / 1024 / 1024,
        System::long_os_version().unwrap_or("Unknown".to_string())
    );

    let client = Client::new();
    let prompt = format!(
        "Based on this hardware specs: {}\nGenerate a unique personality for an AI shell assistant. Include a name (default to hostname), and a short description of traits (e.g., 'Energetic multitasker'). Output strictly in TOML format like:\nname = \"Name\"\ndescription = \"Desc\"",
        specs
    );
    let system_prompt = "You are a personality generator.".to_string();

    let response = query_api(&client, config, &prompt, &system_prompt).await?;
    let cleaned_response = response.trim().trim_start_matches("```toml\n").trim_end_matches("\n```").trim();
    let personality: Personality = toml::from_str(&cleaned_response)?;
    Ok(personality)
}

fn parse_response(response: &str) -> (String, Option<String>) {
    let mut explanation = String::new();
    let mut command = None;
    for line in response.lines() {
        if line.starts_with("Command: ") {
            command = Some(line.trim_start_matches("Command: ").trim().to_string());
        } else if line.starts_with("Explanation: ") {
            explanation = line.trim_start_matches("Explanation: ").trim().to_string();
        } else {
            explanation.push_str(line);
            explanation.push('\n');
        }
    }
    (explanation.trim().to_string(), command)
}

async fn handle_unknown_command(args: &Args, config: &Config, personality: &Personality) -> Result<(), Box<dyn std::error::Error>> {
    if args.unknown_command.is_empty() {
        println!("No command provided.");
        return Ok(());
    }

    let cmd = args.unknown_command.join(" ");
    let pwd = env::current_dir()?.display().to_string();
    let username = whoami::username();
    let prompt = format!(
        "User '{}' in directory '{}' typed unknown command '{}'. Suggest correction or alternative. Be concise and safe. Structure output as:\nExplanation: [text]\nCommand: [optional command to run, if applicable]",
        username, pwd, cmd
    );
    let system_prompt = format!(
        "You are TerminAI, a helpful shell assistant named {}. Your personality: {}. Provide safe, accurate command suggestions.",
        personality.name, personality.description
    );

    let client = Client::new();
    let response = query_api(&client, config, &prompt, &system_prompt).await?;
    let (explanation, command_opt) = parse_response(&response);

    println!("Suggestion: {}", explanation);

    if let Some(command) = command_opt {
        // Safeguard: Check for dangerous commands
        if command.contains("rm -rf") || command.contains("sudo") || command.contains("rm ") || command.contains("dd ") || command.contains("mkfs") {
            println!("Warning: Suggested command '{}' appears unsafe. Skipping auto-run.", command);
        } else {
            println!("Auto-running safe command: {}", command);
            let status = Command::new("sh")
                .arg("-c")
                .arg(&command)
                .status()?;
            if !status.success() {
                println!("Command failed with exit code: {:?}", status.code());
            }
        }
    }

    std::process::exit(127);
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    let config = load_config()?;
    let mut personality = load_personality();

    match &args.command {
        Some(Commands::Init) => {
            personality = generate_personality(&config).await?;
            save_personality(&personality)?;
            println!("Personality generated and saved: Name = {}, Description = {}", personality.name, personality.description);
        }
        None => {
            if personality.name.is_empty() {
                println!("Personality not initialized. Run 'terminai init' to generate.");
            }
            handle_unknown_command(&args, &config, &personality).await?;
        }
    }

    Ok(())
}
EOF

# Step 5: Build the binary
echo "Building the binary..."
cargo build --release --target x86_64-unknown-linux-musl

# Step 6: Install binary
BINARY_PATH="target/x86_64-unknown-linux-musl/release/terminai"
if [ -f "$BINARY_PATH" ]; then
    echo "Installing binary to /usr/local/bin (requires sudo)..."
    sudo cp "$BINARY_PATH" /usr/local/bin/terminai
    sudo chmod +x /usr/local/bin/terminai
else
    echo "Build failed. Binary not found."
    exit 1
fi

# Step 7: Check and prompt for .env if not exists
ENV_PATH="$HOME/.env"
if [ ! -f "$ENV_PATH" ]; then
    echo "No ~/.env found. Configuring API settings..."
    read -p "Enter API provider (grok or openrouter): " API_PROVIDER
    read -p "Enter API key: " API_KEY
    read -p "Enter model (e.g., xai/grok-3): " MODEL

    cat << EOF > "$ENV_PATH"
api_provider = "$API_PROVIDER"
api_key = "$API_KEY"
model = "$MODEL"
EOF
    chmod 600 "$ENV_PATH"  # Secure permissions
else
    echo "~/.env already exists. Using existing config."
fi

# Step 8: Generate personality
echo "Generating AI personality based on system specs..."
terminai init

# Step 9: Add shell hooks
SHELL_TYPE="${SHELL##*/}"
if [ "$SHELL_TYPE" = "bash" ]; then
    CONFIG_FILE="$HOME/.bashrc"
    HOOK='
command_not_found_handle() {
    /usr/local/bin/terminai "$@"
    return $?
}'
elif [ "$SHELL_TYPE" = "zsh" ]; then
    CONFIG_FILE="$HOME/.zshrc"
    HOOK='
command_not_found_handler() {
    /usr/local/bin/terminai "$@"
    return $?
}'
else
    echo "Unsupported shell: $SHELL_TYPE. Please add hooks manually."
    exit 1
fi

if ! grep -q "terminai" "$CONFIG_FILE"; then
    echo "Adding hook to $CONFIG_FILE..."
    echo "$HOOK" >> "$CONFIG_FILE"
    echo "Please run 'source $CONFIG_FILE' or restart your shell."
else
    echo "Hook already present in $CONFIG_FILE."
fi

echo "Installation complete! Test by typing an unknown command like 'ls-l'."