#!/bin/bash
# Geriye donuk uyumluluk icin: ./build.sh --install ile ayni.
exec "$(dirname "$0")/build.sh" --install
