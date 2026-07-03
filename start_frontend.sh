#!/bin/bash
set -e
cd "$(dirname "$0")/web"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm use 20
npm run dev
