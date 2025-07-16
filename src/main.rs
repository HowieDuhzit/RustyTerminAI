use clap::Parser;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::io::self;
use std::path::Path;
use tokio;

#[derive(Parser)]
struct Args {
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    command: Vec<String>,  // The unknown command and args
}

#[derive(Deserialize, Serialize)]
struct Config {
    api_provider: String,  // "grok" or "openrouter"
    api_key: String,
    model: String,  // e.g., "grok-3" or "anthropic/claude-3.5-sonnet"
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

async fn query_api(client: &Client, config: &Config, prompt: &str) -> Result<String, Box<dyn std::error::Error>> {
    let url = match config.api_provider.as_str() {
        "grok" => "https://api.x.ai/v1/chat/completions",  // See https://x.ai/api for exact endpoint
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

    // Add system prompt for context
    request.messages.insert(0, Message {
        role: "system".to_string(),
        content: "You are a helpful shell assistant. Provide safe, accurate command suggestions.".to_string(),
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

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    if args.command.is_empty() {
        println!("No command provided.");
        return Ok(());
    }

    // Load config from ~/.grok-cmd.toml
    let home = env::var("HOME")?;
    let config_path = Path::new(&home).join(".grok-cmd.toml");
    let config_str = fs::read_to_string(config_path)?;
    let config: Config = toml::from_str(&config_str)?;

    // Build prompt with context
    let cmd = args.command.join(" ");
    let pwd = env::current_dir()?.display().to_string();
    let username = whoami::username();
    let prompt = format!(
        "User '{}' in directory '{} typed unknown command '{}'. Suggest correction or alternative. Be concise and safe.",
        username, pwd, cmd
    );

    let client = Client::new();
    match query_api(&client, &config, &prompt).await {
        Ok(suggestion) => {
            println!("Suggestion: {}", suggestion);
            // Optional: Interactive execution
            //println!("Run this? [y/n]");
            //let stdin = io::stdin();
            //let mut lines = stdin.lines();
            //if let Some(Ok(line)) = lines.next() {
            //    if line.trim().to_lowercase() == "y" {
            //        // Execute suggestion (safely parse and run via std::process::Command)
            //        // Warning: Add safeguards to avoid dangerous commands!
            //    }
            //}
        }
        Err(e) => println!("Error: {}", e),
    }

    // Return 127 to mimic command-not-found exit code
    std::process::exit(127);
}