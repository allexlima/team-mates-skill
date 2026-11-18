"""PreToolUse fence for /team teammates (active only when TEAM_FENCE_ROOTS is set).

- Edit/Write/MultiEdit/NotebookEdit: deny a path outside TEAM_FENCE_ROOTS (':'-separated:
  the teammate worktree, its run dir and its scratch dir). ~/.claude stays denied.
- Bash: deny git commands that skip hooks: the no-verify flag (or commit -n), and config
  keys core.hooksPath, alias.* and include*/includeIf.* set via -c, --config-env or a
  `git config` write; also GIT_CONFIG, GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM (a whole
  config file), and GIT_CONFIG_PARAMETERS/KEY_n naming one of those keys. The git argv is
  parsed, so `git -C <dir> ...` and wrapper forms (env, sudo, doas, sh -c, ...) are caught.
Known gaps, not fenced: every other Bash write; commands built by eval, backticks, $(...),
xargs or `env -S` split strings; HOME= or XDG_CONFIG_HOME= pointing git at another config;
aliases already present in the user's git config.
Reads tool_input to decide and never logs it.
"""
import json
import os
import shlex
import sys

WRAPPERS = {"command", "exec", "time", "nice", "nohup", "builtin", "env", "export", "timeout", "sudo", "doas",
            "if", "then", "elif", "else", "while", "until", "do", "!", "{"}  # reserved words too
SHELLS = {"sh", "bash", "zsh", "dash"}
GIT_VALUE_OPTS = {"-C", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix"}
WRAPPER_VALUE_LONG = {"--unset", "--chdir", "--split-string", "--adjustment", "--signal", "--kill-after",
                      "--user", "--group", "--host", "--prompt", "--role", "--type", "--close-from",
                      "--other-user", "--chroot", "--command-timeout"}
# per wrapper, a short-option cluster ending in one of these letters takes a value
WRAPPER_VALUE_SHORT = {"env": "uCSP", "nice": "n", "exec": "a", "timeout": "sk", "sudo": "ugCDhprtUTR", "doas": "uCa", "time": "of"}
COMMIT_VALUE_FLAGS = set("mFCctS")  # short commit options that take a value
HOOKS = "git must not override core.hooksPath, aliases or includes"
CONFIG_SAFE = {"--get", "--get-all", "--get-regexp", "-l", "--list", "get", "list", "--unset", "--unset-all", "unset"}
CONFIG_VALUE_OPTS = {"-f", "--file", "--blob", "--type", "--default", "--comment", "--value"}
CONFIG_SUBCMDS = {"set", "get", "unset", "list", "edit", "rename-section", "remove-section"}
CONFIG_FILE_VARS = {"GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM"}


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "/team fence: " + reason,
    }}))
    sys.exit(0)


def hookspath(text):
    """True if text names a config key that can redirect hooks or rewrite git commands."""
    t = text.lower()
    return "hookspath" in t or "alias." in t or "include" in t


def strip_comments(s):
    """Drop '#' comments the way the shell does: only an unquoted '#' at a word start."""
    out, q, i = [], None, 0
    while i < len(s):
        c = s[i]
        if c == "\\" and q != "'":
            out.append(s[i:i + 2])
            i += 2
            continue
        if q:
            q = None if c == q else q
        elif c in "'\"":
            q = c
        elif c == "#" and (not out or (len(out[-1]) == 1 and out[-1] in " \t\n;&|()")):
            j = s.find("\n", i)
            i = len(s) if j < 0 else j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def segments(cmd):
    """Split a shell command into simple-command argvs at ; & | ( ) and newlines."""
    cmd = strip_comments(cmd.replace("\\\n", ""))
    lex = shlex.shlex(cmd.replace("\n", " ; "), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    seg = []
    for tok in lex:
        if tok and set(tok) <= set(";&|()"):
            if seg:
                yield seg
            seg = []
        else:
            seg.append(tok)
    if seg:
        yield seg


def git_problem(argv):
    """Return a reason if this git argv (argv[0] is git) skips hooks."""
    i = 1
    while i < len(argv) and argv[i].startswith("-"):
        a = argv[i]
        if a in ("-c", "--config-env"):
            if i + 1 < len(argv) and hookspath(argv[i + 1].split("=", 1)[0]):
                return HOOKS
            i += 2
            continue
        if a.startswith("--config-env=") and hookspath(a[len("--config-env="):].split("=", 1)[0]):
            return HOOKS
        if a.startswith("-c") and not a.startswith("--") and hookspath(a[2:].split("=", 1)[0]):
            return HOOKS
        i += 2 if a in GIT_VALUE_OPTS else 1
    if i >= len(argv):
        return None
    sub = argv[i]
    if sub == "config":
        args, k, pos, safe = argv[i + 1:], 0, [], False
        while k < len(args):
            a = args[k]
            if a in CONFIG_VALUE_OPTS:
                k += 1
            elif not pos and a in CONFIG_SAFE:  # a read/unset counts only before the key
                safe = True
            elif not (a.startswith("-") or (not pos and a in CONFIG_SUBCMDS)):
                pos.append(a)
            k += 1
        names = pos[:2] if {"rename-section", "--rename-section"} & set(args) else pos[:1]
        if any(map(hookspath, names)) and not safe:
            return HOOKS
    for a in argv[i + 1:]:
        if a == "--":
            break
        if len(a) >= 6 and "--no-verify".startswith(a):  # git accepts unambiguous prefixes
            return "git hooks must not be skipped (--no-verify)"
        if sub == "commit" and a.startswith("-") and not a.startswith("--"):
            for ch in a[1:]:
                if ch == "n":
                    return "git hooks must not be skipped (commit -n)"
                if ch in COMMIT_VALUE_FLAGS:
                    break
    return None


def check_command(cmd, depth=0):
    try:
        segs = list(segments(cmd))
    except ValueError:
        return None  # unbalanced quotes: the shell rejects the command too
    for argv in segs:
        # drop leading VAR=value assignments and wrappers such as env/command/exec
        while argv and (os.path.basename(argv[0]) in WRAPPERS or "=" in argv[0].split("/")[0]):
            head = argv.pop(0)
            wrapper = os.path.basename(head)
            if head.split("=", 1)[0] in CONFIG_FILE_VARS or (head.startswith("GIT_CONFIG") and hookspath(head)):
                return HOOKS
            while argv and argv[0].startswith("-") and len(argv[0]) > 1:
                opt = argv.pop(0)
                short = opt[1] != "-"
                if argv and (opt in WRAPPER_VALUE_LONG or (short and opt[-1] in WRAPPER_VALUE_SHORT.get(wrapper, ""))):
                    val = argv.pop(0)
                    if wrapper == "env" and (opt == "--split-string" or (short and opt[-1] == "S")) and depth < 3:
                        why = check_command(val, depth + 1)
                        if why:
                            return why
            if wrapper == "timeout" and argv:
                argv.pop(0)
        if not argv:
            continue
        name = os.path.basename(argv[0])
        if name == "git":
            why = git_problem(argv)
            if why:
                return why
        elif name in SHELLS and depth < 3:
            j = next((k for k, a in enumerate(argv) if k and a[:1] == "-" and a[1:2] != "-" and "c" in a), 0)
            if j and j + 1 < len(argv):
                why = check_command(argv[j + 1], depth + 1)
                if why:
                    return why
    return None


roots = [os.path.realpath(r) for r in os.environ.get("TEAM_FENCE_ROOTS", "").split(":") if r]
if not roots:
    sys.exit(0)
try:
    data = json.load(sys.stdin)
except ValueError:
    data = {}
if not isinstance(data, dict):
    data = {}
ti = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}

if data.get("tool_name") == "Bash":
    cmd = ti.get("command")
    why = check_command(cmd) if isinstance(cmd, str) else None
    if why:
        deny(why)
    sys.exit(0)

path = ti.get("file_path") or ti.get("notebook_path") or ""
if not isinstance(path, str) or not path:
    sys.exit(0)
if not os.path.isabs(path):
    path = os.path.join(data.get("cwd") or os.getcwd(), path)
real = os.path.realpath(path)  # resolves '..' and symlinked dirs or files
if not any(real == r or real.startswith(r.rstrip(os.sep) + os.sep) for r in roots):
    deny("this teammate may edit only its worktree and run files")
