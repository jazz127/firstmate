#!/bin/bash
export HOME="$PWD/.validation-tmp/fjhome/home" XDG_CONFIG_HOME="$PWD/.validation-tmp/fjhome/xdg"
exec .validation-tmp/tools/forgejo --work-path "$PWD/.validation-tmp/fjhome" web
