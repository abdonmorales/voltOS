# VoltOS: pico is the default text editor (git, crontab, systemctl edit,
# pacdiff, ...).  Set EDITOR / VISUAL in ~/.profile or ~/.bashrc to change it.
: "${EDITOR:=pico}"
: "${VISUAL:=pico}"
export EDITOR VISUAL
