---
title: "Local AI for Development: You Own Everything"
pubDatetime: 2026-03-29T10:00:00+01:00
description: "A weekend of setting up an HP ZGX workstation, bringing TurboQuant to life, and discovering that local AI for development is already here — no cloud, no vendor lock-in, run it from anywhere."
heroImage: /assets/img/2026/remote-ai-dev-machine/local_models.png
tags: ["llm", "ollama", "vllm", "devcontainers", "ssh", "claude-code", "selfhosted"]
---

Last weekend I got a new HP ZGX AI Studio and spent the weekend turning it into a remote
AI dev machine — getting Ollama running, getting a properly quantized 35B model serving
fast enough to actually use, and wiring it all up so Claude Code on my Mac talks to the
GPU in the other room without knowing it's remote. I also tried to get
[TurboQuant](https://github.com/mitkox/vllm-turboquant) working — a custom vLLM fork
that makes compressed models run efficiently on the new GPU hardware. That part got messy:
build failures, missing Python packages, CUDA compilation times measured in cups of
coffee, and a 52 GB model download that reset twice.

But it worked. And the conclusion I walked away with is worth stating plainly: **local
AI for development is already here, and there's no meaningful catch.** No API key. No
cloud bill. No code leaving your machine. You own everything — the model, the data,
the whole setup — and it runs anywhere, including offline.

## What This Is

First things first: Claude Code isn't locked to Anthropic's API. It sends requests in
Anthropic's format, and both Ollama and vLLM now support that same format — so you can
point Claude Code at either one and it just works. Point it at a local model server and
you get the full experience: file editing, subagents, tool use, memory, the works. All
running on your own hardware, nothing leaving your network.

I'll be honest — Claude Code is genuinely great. The agentic stuff, the way it handles
multi-step tasks, the tool use — it's the best AI coding experience I've used. And
running it against local models makes it even better in a way that's hard to describe
until you try it. No latency spikes, no watching a cost meter, no wondering what's
happening to your code on someone else's server. It just runs.

The hardware I'm using is an HP ZGX AI Studio — NVIDIA GB10 (Grace Blackwell chip), 128 GB
of shared CPU/GPU memory, Ubuntu 24.04. It lives on my home network, runs Ollama as a
background service and vLLM when I need more throughput. One SSH connection from my Mac
forwards the ports, and Claude Code just talks to `localhost` without knowing the GPU is
in the next room.

```
Your Mac                          HP ZGX (remote)
─────────────────                 ──────────────────────────
Claude Code (client)              Ollama  :11434 (systemd)
  - runs locally        SSH        vLLM    :8000  (manual)
  - reads local files   tunnel    NVIDIA GB10 GPU
  - edits your code    ────────►  128GB unified memory
  - sends prompts (local only)
```

This post covers the setup end-to-end: Ollama, vLLM, the SSH tunnel, shell wrappers
for Claude Code, and a devcontainer that makes it fully reproducible — including
`--dangerously-skip-permissions`.

## Why Bother?

Claude Code in agentic mode is chatty. It spawns subagents, reads files, rewrites context,
iterates. A lot of that is mechanical work that racks up API costs quickly. Running it
locally is cheaper for that kind of volume, and your code stays on your own machine.

The honest catch is hardware. Most laptops can only run small models, and small models
aren't great for coding tasks. A machine with 128 GB of memory helps a lot — you can
run something like a 35B model with a decent context window and not feel the squeeze.
That's the setup I have, and it's what made this feel viable rather than a fun experiment.

I'll be upfront: I went in skeptical. I expected it to feel like a downgrade — slower
responses, worse output, more friction. It wasn't. I was genuinely surprised how well it
worked once everything was connected. Your mileage may vary depending on the model you
pick, but for day-to-day coding work it held up fine.

---

## Serving with Ollama

Ollama is the right starting point — one-command install, systemd service out of the
box, built-in model library, and an OpenAI-compatible API on port 11434.

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Two things need changing from the defaults: Ollama must listen on all interfaces
(not just localhost) so the SSH tunnel can reach it, and the context window needs to
be expanded. Ollama's default of 4 096 tokens is too small for Claude Code; the minimum
for agentic use is around 64 k, and 128 k is the comfortable setting.

Create a systemd override at `/etc/systemd/system/ollama.service.d/override.conf`:

```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_NUM_CTX=131072"
```

```bash
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

Then pull the model:

```bash
ollama pull qwen3-coder-next   # ~52 GB, Qwen3.5 hybrid architecture
```

`qwen3-coder-next` is a MoE model — only ~3B parameters are active per token despite
the full model being much larger. It fits in memory with plenty of room for a 128 k
KV cache and runs well for code-heavy workloads.

---

## Serving with vLLM

vLLM is worth the extra setup when you need throughput, want a specific
HuggingFace-hosted model, or plan to run multiple Claude Code agents concurrently
against the same endpoint.

The setup on an ARM64 Blackwell GPU involved some real friction — PyPI's pre-built
torch wheels are CPU-only, CUDA kernel compilation has to target the right GPU
architecture, and build times are measured in tens of minutes per iteration. If you
hit those same walls, the key flags are `--no-build-isolation-package vllm` for uv and
`CMAKE_ARGS="-DCMAKE_CUDA_ARCHITECTURES=120"` for the Blackwell target. Worth it once
it compiles.

Running a compressed (AWQ 4-bit) model efficiently on new GPU hardware requires
low-level kernels that have been compiled specifically for that GPU. The Blackwell chip
is new enough that those kernels didn't exist yet in mainline vLLM — which is where
[TurboQuant](https://github.com/mitkox/vllm-turboquant) comes in.
[Mitko Vasilev](https://www.linkedin.com/posts/ownyourai_i-stayed-up-till-2-am-finished-turboquant-activity-7443239891074953216-Y5mT)
stayed up until 2 AM to sort this out and then put the whole thing on GitHub. Without
his repo, this section would end with "I gave up." That kind of quiet infrastructure
work is what actually makes this stuff usable — so thanks Mitko.

The serving config lives in a YAML file and is passed to vLLM at startup:

```yaml
# vllm-config.yaml
model: cyankiwi/Qwen3.5-35B-A3B-AWQ-4bit
served_model_name: qwen
max_model_len: 262144          # 256k context
max_num_seqs: 64               # concurrent sessions
gpu_memory_utilization: 0.70
enable_auto_tool_choice: true
tool_call_parser: qwen3_xml    # required for Qwen3.5
default_chat_template_kwargs:
  enable_thinking: false       # saves tokens for Claude Code
host: 0.0.0.0
port: 8000
```

A few things here worth calling out:

- `tool_call_parser: qwen3_xml` — Qwen3.5 uses an XML-style tool call format. Using
  `hermes` or the default silently breaks tool use.
- `enable_thinking: false` — Qwen3 models have a thinking/reasoning mode enabled by
  default that narrates its own chain of thought. For Claude Code use, this wastes
  tokens on output you don't need.
- The AWQ 4-bit model occupies ~22 GB of VRAM; `gpu_memory_utilization: 0.70`
  leaves the remaining ~84 GB for the KV cache, which at 256 k context supports
  around 11 concurrent full-context requests.

The start script activates the venv and hands off to vLLM:

```bash
#!/bin/bash
# /usr/local/bin/start-vllm
PROJECT_DIR="${VLLM_PROJECT_DIR:-$HOME/repos/hp-zgx-workflow}"
source "${PROJECT_DIR}/.venv/bin/activate"
export HF_HUB_OFFLINE=1
python -m vllm.entrypoints.openai.api_server \
  --config "${PROJECT_DIR}/service/utils/vllm-config.yaml" "$@"
```

One operational note: startup takes several minutes. The model loads into VRAM and
then CUDA compiles computation graphs for each sequence length. Start vLLM in a tmux
window and let it finish before pointing clients at it.

As a rough performance reference on this hardware: 36.5 tok/s single-stream, around
338 tok/s aggregate at 64 concurrent sequences — enough headroom for several parallel
Claude Code subagent sessions running simultaneously.

---

## SSH Tunnel from the Mac

A single SSH connection forwards both inference ports. Add this to `~/.ssh/config`:

```
Host HP-ZGX
    HostName 192.168.178.103
    User ekoepplin
    IdentityFile ~/.ssh/id_ed25519
    LocalForward *:11434 localhost:11434
    LocalForward *:8000 localhost:8000
    ServerAliveInterval 60
```

The `*:` prefix on `LocalForward` binds the local port on all interfaces, not just
loopback. This matters for the devcontainer setup later.

Open the tunnel:

```bash
ssh HP-ZGX   # keep this terminal open; ports are now live locally
```

Verify it's working:

```bash
curl http://localhost:11434/api/tags    # should list Ollama models
curl http://localhost:8000/v1/models   # should list the vLLM model
```

The most common issue is a stale tunnel from a previous session holding the port:

```bash
lsof -i :11434 -i :8000   # find the stale process, kill it, reconnect
```

---

## Shell Functions for Claude Code

Claude Code checks `ANTHROPIC_BASE_URL` on startup and routes all inference calls
there. Set it to your Ollama or vLLM endpoint and the rest of Claude Code — file
reading, subagents, tool calls, memory — works exactly as normal. No code changes,
no plugins, no proxy middleware.

`ANTHROPIC_AUTH_TOKEN` (for Ollama) and `ANTHROPIC_API_KEY` (for vLLM) are set to
dummy values because both servers accept any token.

Add these wrappers to `~/.zshrc`:

```bash
OLLAMA_DEFAULT_MODEL="qwen3-coder-next"

# Claude Code via Ollama on the ZGX — no Anthropic API calls
claude-zgx() {
  local model="$OLLAMA_DEFAULT_MODEL"
  [[ -n "$1" && "$1" != -* ]] && { model="$1"; shift; }
  ANTHROPIC_AUTH_TOKEN=ollama \
  ANTHROPIC_BASE_URL=http://localhost:11434 \
    claude --model "$model" "$@"
}

# Claude Code via vLLM on the ZGX — no Anthropic API calls
claude-vllm() {
  ANTHROPIC_BASE_URL=http://localhost:8000 \
  ANTHROPIC_API_KEY=dummy \
  ANTHROPIC_DEFAULT_OPUS_MODEL=qwen \
  ANTHROPIC_DEFAULT_SONNET_MODEL=qwen \
  ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen \
    claude "$@"
}

# Real Anthropic API — unsets everything above
claude-anthropic() {
  unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
  unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
  claude "$@"
}
```

Daily workflow: `ssh HP-ZGX` in one terminal (tunnel stays open), `claude-zgx` in
another. Every prompt, subagent spawn, and tool call goes to the ZGX — zero Anthropic
API traffic. Switch to `claude-vllm` for the higher-throughput vLLM backend, or
`claude-anthropic` when you genuinely need frontier reasoning.

---

## Devcontainers

A devcontainer extends the same idea to a fully portable environment: Claude Code
running inside a container, pointed at local models via the SSH tunnel, with
`--dangerously-skip-permissions` enabled — and the whole thing checked into the repo
so anyone who opens the project gets it for free.

Both backends are reachable from inside the container. The network path is the same
in both cases — only the port differs:

```
Devcontainer (Docker on Mac)
    │  http://host.docker.internal:11434   (Ollama)
    │  http://host.docker.internal:8000    (vLLM)
    ▼
Mac host  (SSH tunnel bound on *:11434 and *:8000)
    │  SSH LocalForward
    ▼
HP ZGX  (Ollama :11434 / vLLM :8000)
```

`host.docker.internal` is Docker's name for the Mac host. The `*:` wildcard binding
in `LocalForward` is what makes both ports reachable from inside the container — a
`127.0.0.1` binding would not be.

**`.devcontainer/devcontainer.json`:**

```json
{
  "name": "Claude Code Dev",
  "build": { "dockerfile": "Dockerfile", "context": "." },
  "remoteEnv": {
    "OLLAMA_DEFAULT_MODEL": "qwen3.5:4b",
    "VLLM_DEFAULT_MODEL": "qwen"
  },
  "mounts": [
    "source=${localEnv:HOME}/.claude,target=/home/node/.claude,type=bind",
    "source=${localEnv:HOME}/.claude.json,target=/home/node/.claude.json,type=bind"
  ],
  "remoteUser": "node"
}
```

The `.claude` bind mount carries over your Claude Code config, memory, history, and
authentication — no need to re-authenticate or reconfigure inside the container.
`~/.claude.json` carries the auth token and first-run config, which skips the login
and theme prompts on startup.

`"remoteUser": "node"` matters: Claude Code refuses `--dangerously-skip-permissions`
when running as root, and the default Docker user is root.

**`Dockerfile` (abridged):**

```dockerfile
FROM node:20-slim

RUN apt-get update && apt-get install -y curl git zsh \
    && rm -rf /var/lib/apt/lists/*

USER node
ENV HOME=/home/node

RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
# zsh-autosuggestions, zsh-syntax-highlighting ...

USER root
RUN npm install -g @anthropic-ai/claude-code
COPY claude-aliases.sh /etc/claude-aliases.sh
RUN echo '. /etc/claude-aliases.sh' >> /home/node/.zshrc

USER node
WORKDIR /workspace
```

The base image is `node:20-slim` because Claude Code is distributed as an npm package.
The aliases file contains the same `claude-zgx` / `claude-vllm` / `claude-anthropic`
functions from above, with `localhost` replaced by `host.docker.internal`.

**Running Claude Code inside the container:**

The aliases bake in `--dangerously-skip-permissions` and point at the right
`host.docker.internal` port — you don't pass any flags manually:

```bash
# Via Ollama (always-on, lower throughput)
claude-zgx                          # interactive, default model
claude-zgx qwen3.5:35b              # interactive, specific model
claude-zgx -p "refactor this file"  # non-interactive, runs to completion

# Via vLLM (start-vllm must be running on ZGX first)
claude-vllm                         # interactive, default model (qwen)
claude-vllm -p "write tests"        # non-interactive, runs to completion
```

The `-p` flag (`--print`) is a non-interactive mode: Claude Code runs the prompt, completes the
task, and exits — useful for scripting or piping into CI.

`--dangerously-skip-permissions` removes all tool approval prompts — file reads, shell
commands, edits. It's appropriate here because the container is the blast radius:
mutations stay inside the container filesystem and the mounted workspace. The host is
not exposed beyond what's explicitly mounted.

If connectivity is unclear, the container includes diagnostic helpers:

```bash
check-ollama   # verifies DNS, TCP, lists models, prints env
check-vllm     # same for port 8000
```

Each runs four steps: resolves `host.docker.internal`, checks TCP reachability, lists
available models, and prints the active environment variables — with a checklist of
what to fix if any step fails.

---

## Automation with Ansible

The full ZGX setup — DNS configuration, package installation, Ollama service, HuggingFace
model downloads, vLLM virtualenv, shell configuration, tmux workspace — is automated via
an Ansible playbook. The playbook runs locally on the ZGX after first boot and is
idempotent, so re-running it is safe.

One useful outcome of the playbook is a `tmux-workspace` command that creates (or
re-attaches to) a structured tmux session:

- `monitor` — `nvidia-smi` and `htop` side by side
- `vllm` — ready to run `start-vllm`
- `ollama` — Ollama shell
- `shell` — clean working shell

The Ansible repo and the vLLM config are at
[`hp-zgx-workflow`](https://github.com/ekoepplin/hp-zgx-workflow) if you want to
adapt them to different hardware.

---

## Tradeoffs

| Concern | Reality |
|---|---|
| Network latency | LAN SSH adds ~1 ms; negligible compared to inference time |
| Security | Ollama/vLLM bind to `localhost` on the ZGX; only reachable via authenticated SSH |
| GPU contention | Ollama and vLLM both hold VRAM — run one at a time for 30B+ models |
| vLLM startup | 5–15 min for model load + CUDA graph compilation — always start it in tmux |
| Model disk space | `qwen3-coder-next` is 52 GB; the AWQ vLLM variant is 22 GB — plan accordingly |
| IPv6 on large downloads | If HuggingFace downloads reset mid-transfer, disable IPv6 temporarily: `sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1` |

---

## Summary

The core mechanic is just two environment variables: set `ANTHROPIC_BASE_URL` to your
local model server and Claude Code routes everything there. Everything else in this post
is just making that feel good — a persistent Ollama service, a fast vLLM backend for
heavier workloads, an SSH tunnel so the GPU feels local, and a devcontainer so the whole
thing is reproducible and portable.

**You can do this today, and it actually works.** The model quality is good enough for
real coding work. The throughput handles concurrent agents. Your code stays on your own
machine. And once the setup is done, the day-to-day experience is just `ssh HP-ZGX` in
one terminal and `claude-zgx` in another — nothing else to think about.

If you want to take it further, hand the devcontainer to a colleague. They open the
project, hit `code .`, and get the same setup pointed at their own hardware — no
config, no re-authentication, no surprises.

The five files that make it work:

1. `/etc/systemd/system/ollama.service.d/override.conf` — host binding + context window
2. `vllm-config.yaml` — model, quantization, tool parser, thinking mode off
3. `~/.ssh/config` — `LocalForward *:11434` and `*:8000` with wildcard binding
4. `~/.zshrc` functions — `claude-zgx` / `claude-vllm` / `claude-anthropic`
5. `.devcontainer/devcontainer.json` — mount `.claude`, non-root user, env vars pointing at `host.docker.internal`
