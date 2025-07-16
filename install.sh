
#!/bin/bash

# Install Rust if not already installed
if ! command -v cargo &> /dev/null; then
    echo "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source $HOME/.cargo/env
fi

# Clone and build the grok-cli tool
echo "Building grok-cli..."
git clone https://github.com/your-repo/grok-cli.git /tmp/grok-cli
cd /tmp/grok-cli
cargo build --release
sudo mv target/release/grok-cli /usr/local/bin/
cd - && rm -rf /tmp/grok-cli

# Install shell hook
echo "Setting up shell hooks..."
sudo cp grok-cli-hook.sh /etc/profile.d/grok-cli-hook.sh
chmod +x /etc/profile.d/grok-cli-hook.sh

echo "Installation complete. Please set XAI_API_KEY environment variable."
echo "Add 'export XAI_API_KEY=your-api-key' to ~/.bashrc or ~/.zshrc"
