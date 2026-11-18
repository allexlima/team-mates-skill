# Re-record: vhs assets/readme/tapes/monitor.tape   (from the repo root)
# Illustrative demo: the TUI plays a synthetic team, nothing real is read.
Output assets/readme/monitor.gif
Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 720
Set Padding 12
Set Theme "Catppuccin Mocha"
Set Framerate 10
Hide
Type "uv run --script skills/team/scripts/monitor_tui.py --demo --demo-speed 60 --demo-at 15"
Enter
Show
Sleep 16s
Hide
Ctrl+C
