#!/usr/bin/env python3
"""Command guard: a PreToolUse hook for shell commands.

Blocks commands that write to a cluster or cloud account, destroy data, or send
data off the machine. Reads one PreToolUse event as JSON on stdin. Exits 2 with
a reason on stderr to block, or 0 to leave the decision to the normal
permission flow.
"""

import json
import re
import shlex
import sys
from pathlib import PurePosixPath

# Flags that take a separate value, so the value is not mistaken for a subcommand.
VALUE_FLAGS = {
    "-n", "--namespace", "--context", "--kubeconfig", "--cluster", "--user", "-s", "--server",
    "-l", "--selector", "-o", "--output", "--kube-context", "--profile", "--region", "-chdir",
}

KUBECTL_WRITES = {
    "apply", "create", "delete", "edit", "patch", "replace", "scale", "autoscale", "set",
    "label", "annotate", "taint", "drain", "cordon", "uncordon", "expose", "run", "exec",
    "cp", "debug", "rollout",
}
KUBECTL_ROLLOUT_READS = {"status", "history"}


def subcommands(args):
    """Non-flag arguments, skipping the values of flags that take one."""
    words = []
    skip_next = False
    for arg in args:
        if skip_next:
            skip_next = False
            continue
        if arg.startswith("-"):
            skip_next = "=" not in arg and arg in VALUE_FLAGS
            continue
        words.append(arg)
    return words


def check_kubectl(args):
    words = subcommands(args)
    if not words or words[0] not in KUBECTL_WRITES:
        return None
    if words[0] == "rollout" and len(words) > 1 and words[1] in KUBECTL_ROLLOUT_READS:
        return None
    return f"kubectl {words[0]} changes a cluster. Change the GitOps area and let Argo CD sync it"


HELM_WRITES = {"install", "upgrade", "uninstall", "delete", "rollback"}
ARGOCD_WRITES = {"sync", "delete", "create", "set", "patch", "rollback", "terminate-op", "add", "rm", "edit", "unset"}
TERRAFORM_WRITES = {"apply", "destroy", "import", "taint", "untaint", "force-unlock"}
TERRAFORM_STATE_WRITES = {"rm", "mv", "push", "replace-provider"}
AWS_WRITE_VERB = re.compile(
    r"^(create|delete|put|update|attach|detach|modify|terminate|run|start|stop|reboot|remove|add|"
    r"tag|untag|set|associate|disassociate|revoke|authorize|deregister|register|enable|disable|"
    r"reset|restore|import|invoke|send|publish|upload|copy|replace|cancel)(-|$)"
)
AWS_S3_WRITES = {"rm", "mv", "cp", "sync", "rb", "mb"}


def check_helm(args):
    words = subcommands(args)
    if words and words[0] in HELM_WRITES:
        return f"helm {words[0]} changes a cluster. Let Terraform or Argo CD install charts"
    return None


def check_argocd(args):
    words = subcommands(args)
    if len(words) > 1 and words[1] in ARGOCD_WRITES:
        return f"argocd {words[0]} {words[1]} changes what Argo CD manages. Change the GitOps area instead"
    return None


def check_kind(args):
    words = subcommands(args)
    if words and words[0] == "delete":
        return "kind delete removes local clusters. Ask the human to run it"
    return None


def check_terraform(args):
    words = subcommands(args)
    if not words:
        return None
    if words[0] in TERRAFORM_WRITES:
        return f"terraform {words[0]} changes real infrastructure or state. Only the human or CI applies"
    if words[0] == "state" and len(words) > 1 and words[1] in TERRAFORM_STATE_WRITES:
        return f"terraform state {words[1]} edits state by hand"
    if words[0] == "workspace" and len(words) > 1 and words[1] == "delete":
        return "terraform workspace delete removes state"
    return None


def check_aws(args):
    words = subcommands(args)
    if len(words) < 2:
        return None
    service, operation = words[0], words[1]
    if service == "s3" and operation in AWS_S3_WRITES:
        return f"aws s3 {operation} changes or copies cloud data"
    if AWS_WRITE_VERB.match(operation):
        return f"aws {service} {operation} changes a cloud account"
    return None


BROAD_TARGETS = {"/", "/*", "~", "~/", "~/*", "$HOME", "$HOME/", "$HOME/*", ".", "./", "./*", "..", "../", "*", ".*"}


def is_broad_target(target):
    if target in BROAD_TARGETS or target.startswith(".."):
        return True
    # A top-level folder such as /home or /etc.
    return target.startswith("/") and len(PurePosixPath(target).parts) <= 2


def check_rm(args):
    flags = [a for a in args if a.startswith("-")]
    short = "".join(a[1:] for a in flags if not a.startswith("--"))
    recursive = "r" in short.lower() or "--recursive" in flags
    if not recursive:
        return None
    targets = [a for a in args if not a.startswith("-")]
    broad = [t for t in targets if is_broad_target(t)]
    if broad:
        return f"rm -r on {broad[0]} would delete far more than a build folder"
    return None


def check_git(args):
    words = subcommands(args)
    if not words:
        return None
    flags = [a for a in args if a.startswith("-")]
    if words[0] == "push":
        if any(f in ("-f", "--force", "--force-with-lease", "--mirror", "--delete", "-d") or f.startswith("--force") for f in flags):
            return "git push with force or delete rewrites shared history"
        if any(w.startswith("+") or w.startswith(":") for w in words[1:]):
            return "git push with a + or : refspec rewrites or deletes a remote branch"
    if words[0] == "reset" and "--hard" in flags:
        return "git reset --hard throws away uncommitted work"
    if words[0] == "clean" and any(f.startswith("-") and not f.startswith("--") and "f" in f for f in flags):
        return "git clean -f deletes untracked files"
    if words[0] in ("filter-branch", "filter-repo"):
        return f"git {words[0]} rewrites history"
    return None


def check_dd(args):
    if any(a.startswith("of=/dev/") for a in args):
        return "dd onto a device overwrites a disk"
    return None


def check_shred(args):
    return "shred destroys files beyond recovery"


def check_docker(args):
    words = subcommands(args)
    if "prune" in words:
        return "docker prune removes containers, images or volumes beyond this demo"
    return None


UPLOAD_LONG_FLAGS = ("--data", "--form", "--upload-file", "--json", "--post-data", "--post-file", "--body-data", "--body-file")
SENDING_METHODS = {"POST", "PUT", "PATCH", "DELETE"}
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"}
URL_HOST = re.compile(r"^[a-z][a-z0-9+.-]*://(?:[^@/]*@)?(\[[^\]]*\]|[^/:?#]+)", re.IGNORECASE)
REMOTE_PATH = re.compile(r"^(?:[\w.-]+@)?[\w.-]+:(?!//)|^rsync://")


def sends_data(args):
    for index, arg in enumerate(args):
        if arg.startswith(UPLOAD_LONG_FLAGS):
            return True
        if arg.startswith("-") and not arg.startswith("--") and set(arg[1:]) & set("dFT"):
            # A short flag cluster such as -d, -sd or -F; -X takes a method.
            if not arg[1:].startswith("X"):
                return True
        method = None
        if arg in ("-X", "--request", "--method") and index + 1 < len(args):
            method = args[index + 1]
        elif arg.startswith("-X") and len(arg) > 2:
            method = arg[2:]
        elif arg.startswith(("--request=", "--method=")):
            method = arg.split("=", 1)[1]
        if method and method.upper() in SENDING_METHODS:
            return True
    return False


def all_hosts_local(args):
    hosts = [m.group(1).lower() for m in (URL_HOST.match(a) for a in args) if m]
    return bool(hosts) and all(h in LOCAL_HOSTS or h.endswith(".localhost") for h in hosts)


def check_http_client(args):
    if sends_data(args) and not all_hosts_local(args):
        return "sending data to a remote host could leak files or secrets"
    return None


def check_network_tool(args):
    return "raw network tools can send data off the machine"


def check_remote_copy(args):
    if any(REMOTE_PATH.match(a) for a in args if not a.startswith("-")):
        return "copying files to or from a remote host could leak them"
    return None


def check_gh(args):
    words = subcommands(args)
    if words[:2] == ["gist", "create"]:
        return "gh gist create publishes files outside the repo"
    return None


CHECKS = {
    "curl": check_http_client,
    "wget": check_http_client,
    "nc": check_network_tool,
    "ncat": check_network_tool,
    "netcat": check_network_tool,
    "socat": check_network_tool,
    "telnet": check_network_tool,
    "scp": check_remote_copy,
    "sftp": check_remote_copy,
    "rsync": check_remote_copy,
    "gh": check_gh,
    "rm": check_rm,
    "git": check_git,
    "dd": check_dd,
    "shred": check_shred,
    "docker": check_docker,
    "kubectl": check_kubectl,
    "helm": check_helm,
    "argocd": check_argocd,
    "kind": check_kind,
    "terraform": check_terraform,
    "tofu": check_terraform,
    "aws": check_aws,
}

PREFIXES = {"sudo", "time", "command", "exec", "nohup", "env"}


def split_segments(command):
    """Split a command line into simple commands, including nested ones."""
    command = command.replace("${HOME}", "$HOME")
    flattened = re.sub(r"\$\(|`|\(|\)|\{|\}", " ; ", command)
    lexer = shlex.shlex(flattened, posix=True, punctuation_chars=";&|")
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        tokens = flattened.split()
    segment = []
    for token in tokens:
        if token and set(token) <= set(";&|"):
            if segment:
                yield segment
            segment = []
            continue
        segment.append(token)
        # A quoted argument may itself be a command, e.g. bash -c '...'.
        if " " in token:
            yield from split_segments(token)
    if segment:
        yield segment


def strip_prefixes(words):
    while words and (words[0] in PREFIXES or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0])):
        words = words[1:]
    return words


PIPE_TO_SHELL = re.compile(r"\b(?:curl|wget)\b[^;&|]*\|\s*(?:sudo\s+)?(?:ba|z|da|k)?sh\b")
RAW_SOCKET = re.compile(r"/dev/(?:tcp|udp)/")


def find_problem(command):
    if PIPE_TO_SHELL.search(command):
        return "piping a download straight into a shell runs unreviewed code"
    if RAW_SOCKET.search(command):
        return "writing to /dev/tcp or /dev/udp sends data off the machine"
    for segment in split_segments(command):
        words = strip_prefixes(segment)
        if not words:
            continue
        program = PurePosixPath(words[0]).name
        if program.startswith("mkfs"):
            return f"{program} formats a disk"
        check = CHECKS.get(program)
        problem = check(words[1:]) if check else None
        if problem:
            return problem
    return None


def main():
    try:
        event = json.load(sys.stdin)
        command = (event.get("tool_input") or {}).get("command", "")
    except (ValueError, AttributeError):
        print("Command guard: could not read the tool call, so it was blocked.", file=sys.stderr)
        return 2
    if event.get("tool_name") != "Bash" or not isinstance(command, str):
        return 0
    problem = find_problem(command)
    if problem:
        print(f"Command guard: blocked. {problem}. If it is really needed, ask the human to run it.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
