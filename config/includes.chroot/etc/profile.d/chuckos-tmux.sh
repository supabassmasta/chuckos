# ChuckOS: drop into a shared tmux session ("main") on interactive login,
# whether at the physical console (tty1-6) or over SSH -- so you get the
# same set of terminal windows either way. Edit/remove this file if you'd
# rather get a plain shell (e.g. for scripted SSH commands).

case "$-" in
    *i*) ;;
    *) return 2>/dev/null || exit 0 ;;
esac

if command -v tmux >/dev/null 2>&1 && [ -z "${TMUX:-}" ]; then
    case "$(tty 2>/dev/null)" in
        /dev/tty[1-6]|/dev/pts/*)
            exec tmux new-session -A -s main
            ;;
    esac
fi
