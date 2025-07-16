
#!/bin/bash

# Install Rust if not already installed
if ! command -v cargo &> /dev/null; then
    echo "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source $HOME/.cargo/env
fi

# Clone and build the TerminAI tool
echo "Building TerminAI..."
git clone https://github.com/HowieDuhzit/RustyTerminAI.git /tmp/TerminAI
cd /tmp/TerminAI
cargo build --release
sudo mv target/release/TerminAI /usr/local/bin/
cd - && rm -rf /tmp/TerminAI

# Install shell hook
echo "Setting up shell hooks..."
sudo cp TerminAI-hook.sh /etc/profile.d/TerminAI-hook.sh
chmod +x /etc/profile.d/TerminAI-hook.sh

echo "Installation complete. Please set XAI_API_KEY environment variable."
echo "Add 'export XAI_API_KEY=your-api-key' to ~/.bashrc or ~/.zshrc"
