
#!/bin/bash

# Bash hook for command_not_found_handle
command_not_found_handle() {
    /usr/local/bin/grok-cli "$@"
    return $?
}

# Zsh hook for command_not_found_handler
if [[ -n $ZSH_VERSION ]]; then
    command_not_found_handler() {
        /usr/local/bin/grok-cli "$@"
        return $?
    }
fi
