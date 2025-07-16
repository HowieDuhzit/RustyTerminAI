
use std::env;
use std::process::{Command, Stdio};
use std::time::Instant;
use reqwest::blocking::Client;
use serde_json::{json, Value};
use std::io::{self, Write};

fn main() {
    // Start timing for latency measurement
    let start = Instant::now();

    // Get command-line arguments (the unrecognized command)
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("No command provided");
        std::process::exit(1);
    }

    let command = args.join(" ");

    // Step 1: Validate if the command exists locally (~1-5ms target)
    if is_command_valid(&command) {
        println!("Command '{}' exists, executing normally.", command);
        std::process::exit(0);
    }

    // Step 2: Query the selected API for unrecognized command
    let api_provider = env::var("API_PROVIDER").unwrap_or_else(|_| "xai".to_string());
    let response = match api_provider.as_str() {
        "openrouter" => query_openrouter_api(&command),
        _ => query_xai_api(&command), // Default to xAI
    };

    match response {
        Ok(response) => {
            println!("{}", response);
        }
        Err(e) => {
            eprintln!("Error querying API: {}", e);
            std::process::exit(1);
        }
    }

    // Measure and report latency
    let duration = start.elapsed();
    eprintln!("Processing time: {:?}", duration);
}

// Check if a command exists in the system PATH
fn is_command_valid(command: &str) -> bool {
    let cmd = command.split_whitespace().next().unwrap_or(command);
    Command::new("which")
        .arg(cmd)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

// Query xAI Grok API
fn query_xai_api(command: &str) -> Result<String, Box<dyn std::error::Error>> {
    let api_key = env::var("XAI_API_KEY").unwrap_or_else(|_| {
        eprintln!("XAI_API_KEY environment variable not set");
        std::process::exit(1);
    });

    let client = Client::new();
    let context = format!(
        "User entered an unrecognized command: '{}'. Provide a helpful suggestion or explanation.",
        command
    );

    let payload = json!({
        "prompt": context,
        "model": "grok-3"
    });

    let response = client
        .post("https://api.x.ai/v1/grok")
        .header("Authorization", format!("Bearer {}", api_key))
        .json(&payload)
        .send()?;

    let json: Value = response.json()?;
    let suggestion = json["choices"][0]["message"]["content"]
        .as_str()
        .unwrap_or("No suggestion available")
        .to_string();

    Ok(suggestion)
}

// Query OpenRouter API
fn query_openrouter_api(command: &str) -> Result<String, Box<dyn std::error::Error>> {
    let api_key = env::var("OPENROUTER_API_KEY").unwrap_or_else(|_| {
        eprintln!("OPENROUTER_API_KEY environment variable not set");
        std::process::exit(1);
    });

    let client = Client::new();
    let context = format!(
        "User entered an unrecognized command: '{}'. Provide a helpful suggestion or explanation.",
        command
    );

    let payload = json!({
        "model": "meta-ai/llama-3.1-8b-instruct", // Example model, adjustable
        "messages": [
            {"role": "user", "content": context}
        ]
    });

    let response = client
        .post("https://openrouter.ai/api/v1/chat/completions")
        .header("Authorization", format!("Bearer {}", api_key))
        .header("HTTP-Referer", "https://SleepyStudio.xyz") // Replace with your app's URL
        .header("X-Title", "TerminAI")
        .json(&payload)
        .send()?;

    let json: Value = response.json()?;
    let suggestion = json["choices"][0]["message"]["content"]
        .as_str()
        .unwrap_or("No suggestion available")
        .to_string();

    Ok(suggestion)
}
