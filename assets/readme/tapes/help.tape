# Re-record: vhs assets/readme/tapes/help.tape   (from the repo root)
# Shows the text `/team --help` prints (skills/team/references/HELP.md).
Output assets/readme/help.gif
Set Shell "bash"
Set FontSize 15
Set Width 1000
Set Height 580
Set Padding 14
Set Theme "Catppuccin Mocha"
Set Framerate 8
Set TypingSpeed 60ms
Hide
Type "clear; export PS1='> '"
Enter
Show
Type "# the text /team --help prints"
Enter
Sleep 500ms
Type "sed -n '/^## Usage/,/^    --help /p' skills/team/references/HELP.md"
Enter
Sleep 6s
