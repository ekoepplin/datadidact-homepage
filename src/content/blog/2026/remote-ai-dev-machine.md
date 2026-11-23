---
title: "Local AI for Development: You Own Everything"
pubDatetime: 2026-03-29T10:00:00+01:00
modDatetime: 2026-11-23T10:00:00+01:00
description: "How I run coding agents against my own GPU server: the model runs on the server, the Mac is only the interface. Rewritten in November 2026 as a step-by-step setup you can rebuild on your own hardware."
heroImage: /assets/img/2026/remote-ai-dev-machine/local_models.png
tags: ["llm", "vllm", "ssh", "tailscale", "claude-code", "selfhosted"]
---

> **Updated November 2026.** The first version of this post (March 2026) described a weekend
> of Ollama, a custom vLLM build and TurboQuant. All of that is gone. This version describes
> the setup as I run it today, step by step, so you can rebuild it on your own server.
> Part 2, [Claude Subscription Meets Local Server](/posts/2026/pi-virtual-models), builds on it.

In March I got an HP ZGX AI Studio and spent a weekend turning it into a model server for
coding agents. It worked, but it was a pile of moving parts: Ollama next to vLLM, a vLLM fork
built from source, two open ports. Eight months later the setup is smaller, and every piece
has a reason. This post is the version I would have wanted back then.

## The picture

The model runs on the server. The Mac only runs the agent: it reads and edits my files and
sends prompts through an SSH tunnel. Nothing on the Mac needs a GPU.

```
Mac (interface only)                      GPU server (HP ZGX)
──────────────────────                    ─────────────────────────────
Claude Code / Pi                          one model server, port 8000
  reads and edits local files   SSH       bound to 127.0.0.1 only
  sends prompts to              tunnel    speaks OpenAI + Anthropic API
  localhost:8000  ────────────────────►   NVIDIA GB10, 128 GB unified memory
```

Part 2 adds the cloud: Claude (via subscription or API) next to the local model.

## What you need

- **A Linux server with an NVIDIA GPU** and enough memory for the model. Mine: HP ZGX AI
  Studio, NVIDIA GB10 (Grace Blackwell), 128 GB unified CPU/GPU memory, Ubuntu 24.04.
- **Docker with the NVIDIA Container Toolkit** on the server
  (`sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`).
- **A laptop with SSH** and the agent: [Claude Code](https://code.claude.com) and/or
  [Pi](https://github.com/earendil-works/pi).

If your hardware differs, the steps stay the same. Only the model you can fit changes.

## Step 1: one model server on the server

Rule one: **one backend at a time, always on port 8000.** The GB10 has a single memory pool,
so two large models do not fit side by side anyway. Every client points at port 8000, so
switching models never means changing a client.

What the server must do, whatever software you use:

| Requirement | Why |
|---|---|
| Serves the **Anthropic Messages API** (`/v1/messages`) | Claude Code speaks it natively. vLLM and SGLang both do |
| Serves the **OpenAI chat API** (`/v1/chat/completions`) | Pi and most other agents use it. Same port |
| **Tool calling on**, with the parser for your model | Agents work through tool calls. The wrong parser fails silently: the model "calls" a tool and nothing happens |
| **Context window of 64k tokens or more** | The practical minimum for Claude Code. My backends run 256k |
| **Port bound to 127.0.0.1** | The API has no authentication. See step 2 |

These are the three backends I switch between. Speeds are decode rates measured on the ZGX
(256 max tokens, median of 3):

| Model | Engine | Decode tok/s | Measured |
|---|---|---|---|
| Qwen3.8-Flash-Next 125B-A5B INT4 | vLLM | 48–80 | 2026-09-13 |
| Qwen3.6-35B-A3B NVFP4 + MTP | vLLM | 106–140 | 2026-09-14 |
| Qwen3.8-27B NVFP4 + DSpark | SGLang | 15.8–49.8 | 2026-09-14 |

Speed is not quality. How well each one handles tool calls in long agent sessions, I have not
measured yet.

### The one I use: Qwen3.8-Flash-Next

Flash-Next is the model behind all tests in part 2. Its serving recipe is a public repo with
tuned defaults, so you do not have to work out vLLM flags yourself:

```bash
# on the server
git clone https://github.com/azampatti/Qwen3.8-Flash-Next-Int4-FAST.git ~/repos/Qwen3.8-Flash-Next-Int4-FAST
cd ~/repos/Qwen3.8-Flash-Next-Int4-FAST
./setup.sh      # builds the Docker image, downloads the ~118 GiB checkpoint
./serve.sh -d   # starts vLLM in the background, port 8000 by default
```

Startup takes about 5 minutes (loading 71 GiB of weights, then CUDA graph capture). It is ready
when this answers:

```bash
curl -s localhost:8000/v1/models   # lists qwen3.8-flash-next-a5b
```

**One change before you use it:** check the `docker run` line in `serve.sh` and make sure the
port is published as `-p 127.0.0.1:8000:8000`, not `-p 8000:8000`. Mine needed that edit, and a
`git pull` undoes it. Docker's port rules bypass `ufw`, so a firewall does not save you here.

Verify from the server that nothing but SSH listens beyond loopback:

```bash
ss -tlnH | awk '{print $4}' | grep -v -E '^(127\.|\[::1\])'
# expected: only :22, plus Tailscale's own listeners on tailscale0 (step 2)
```

## Step 2: reach the server from anywhere

I reach the ZGX over [Tailscale](https://tailscale.com), at home and away, with no port open on
the router. The tailnet policy allows SSH and nothing else:

```json
{
  "tagOwners": { "tag:gpu": ["autogroup:admin"] },
  "grants": [
    { "src": ["autogroup:member"], "dst": ["tag:gpu"], "ip": ["tcp:22"] }
  ]
}
```

Save the policy first, then on the server: `sudo tailscale up --advertise-tags=tag:gpu`
(without the policy the tag is refused). Tagged devices have key expiry
off, so the server does not drop out. On a home LAN without Tailscale, the rest of this post
works the same with the server's LAN address.

Then one SSH config entry on the Mac carries the tunnel:

```ssh-config
Host gpu
    HostName <your-server>.<your-tailnet>.ts.net
    User <you>
    IdentityFile ~/.ssh/id_ed25519
    LocalForward 127.0.0.1:8000 localhost:8000
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 12h
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
```

```bash
ssh -fN gpu                         # tunnel in the background
curl -s localhost:8000/v1/models    # now answers on the Mac
```

What each part is for:

- `LocalForward 127.0.0.1:8000`: the port opens on the Mac's loopback only. **My March post
  used `*:8000`. Don't.** That hands the unauthenticated model API to everyone on whatever
  Wi-Fi the Mac has joined.
- `ControlMaster` / `ControlPersist`: later `ssh` calls reuse the connection, and
  `ssh -O check gpu` tells you whether the tunnel is alive.
- `ServerAlive*`: a dropped link is noticed in about 90 seconds instead of leaving a dead
  tunnel that accepts connections and resets them.
- `ExitOnForwardFailure`: if port 8000 is already taken on the Mac, `ssh` fails loudly instead
  of connecting without a tunnel.

Use the full MagicDNS name as `HostName`. A short name may also resolve through your home
router to the LAN address, and then `ssh` silently bypasses Tailscale.

Keys only on the server, before you rely on this:
`printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/10-keys-only.conf`
and `sudo systemctl reload ssh` (test a second login before closing the first).

## Step 3: check the server is fit for an agent

A model list is not enough. An agent needs tool calls through the API it speaks. This request
asks for a tool call through the Anthropic API, the way Claude Code does:

```bash
curl -s localhost:8000/v1/messages -H 'Content-Type: application/json' -d '{
  "model": "qwen3.8-flash-next-a5b", "max_tokens": 2048,
  "tools": [{"name": "get_weather", "description": "Current weather for a city",
             "input_schema": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}],
  "messages": [{"role": "user", "content": "What is the weather in Berlin? Use the tool."}]
}' | jq '{stop_reason, call: [.content[] | select(.type == "tool_use") | .input]}'
```

Expected: `"stop_reason": "tool_use"` and `{"city": "Berlin"}`. If you get text instead, the
tool parser is wrong or off.

## Step 4: Claude Code against the server

Claude Code sends its requests to `ANTHROPIC_BASE_URL`. A shell function in `~/.zshrc` scopes
the settings to one command, so a normal `claude` stays untouched:

```bash
claude-local() {
  local model=qwen3.8-flash-next-a5b
  ANTHROPIC_BASE_URL=http://localhost:8000 \
  ANTHROPIC_AUTH_TOKEN=local \
  ANTHROPIC_DEFAULT_OPUS_MODEL=$model \
  ANTHROPIC_DEFAULT_SONNET_MODEL=$model \
  ANTHROPIC_DEFAULT_HAIKU_MODEL=$model \
  CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000 \
  MAX_THINKING_TOKENS=2048 \
  API_TIMEOUT_MS=3600000 \
    claude --model $model "$@"
}
```

Each line has a reason:

- `ANTHROPIC_AUTH_TOKEN`: any value, the server does not check it.
- `ANTHROPIC_DEFAULT_*_MODEL`: `--model` only covers the main conversation. Background work
  (titles, summaries, the auto-mode safety check) asks for the haiku tier by name, which your
  server does not serve. These three map every tier onto your model.
- `MAX_THINKING_TOKENS`: current Qwen models reason before answering. Uncapped, they
  deliberate for minutes over trivial edits.
- `API_TIMEOUT_MS`: long local generations outrun Claude Code's default stream timeout.

If your server's context window is **smaller than 200k**, also set
`CLAUDE_CODE_MAX_CONTEXT_TOKENS` to it. Claude Code does not know your model, assumes 200k,
and would otherwise compact too late
([docs](https://code.claude.com/docs/en/model-config#correct-the-window-for-a-gateway-or-custom-model-id)).

Then `cd` into a project and run `claude-local`. Every prompt, tool call and subagent goes to
your server.

## Step 5: Pi against the server

Pi talks to the same port through the OpenAI API. Register the server once as a provider, for
example with the `local-provider.ts` extension from the companion repo of part 2 (published
with part 2), which reads the model list from the server:

```bash
LOCAL_BASE_URL=http://localhost:8000/v1 pi -e ./extensions/local-provider.ts \
  --model local/qwen3.8-flash-next-a5b
```

Part 2 is about what Pi adds: one session that uses Claude and the local model together.

I ran the client-side commands of steps 2 to 5 against Flash-Next on 2026-11-23, with
Claude Code 2.1.311 and Pi 1.5.2. Both agents created and ran a small Python file.

## Give the agent a sandbox

A coding agent runs shell commands with your user's rights, local model or not. In one of my
tests Flash-Next ran `pip install pytest` into my global Python without asking. Run agents in a
container or at least a throwaway checkout, and never with credentials you would not hand to
the model. My devcontainer, which also reaches port 8000 through `host.docker.internal`, is in
[agentic-toolbox](https://github.com/ekoepplin/agentic-toolbox).

## What changed since March

| March 2026 | Now | Why |
|---|---|---|
| Ollama as an always-on service, next to vLLM | Removed | One server, one port. Ollama also kept listening openly on the server for five weeks after I stopped using it |
| vLLM built from source, TurboQuant fork | Prebuilt Docker images per model | Standard pip vLLM crashes on the GB10 (sm_121). Images built for CUDA 13 run |
| One model | Three backends, one at a time on port 8000 | Switching is a restart, not a client change |
| SSH to a LAN address | Tailscale, SSH only | Works from anywhere, nothing open on the router |
| Tunnel bound to `*` | Tunnel bound to `127.0.0.1` | `*` exposed the model to every network the Mac joined |
| `enable_thinking: false` | Thinking on, capped at 2048 tokens | All three models reason before answering; the cap keeps it short |

## Tradeoffs

| Concern | Reality |
|---|---|
| Hardware | The real entry cost. Flash-Next alone takes about 71 GiB for weights plus a 20 GB KV cache |
| Startup | Minutes, not seconds: about 5 minutes for Flash-Next. Switching models means a restart |
| Security | The model API has no authentication. Loopback binding plus SSH-only access is what protects it |
| Quality | Fine for a lot of day-to-day work in my use. Tool-calling quality across long sessions is unmeasured |
| Safety | The agent has a shell. Sandbox it |

## Where this leaves me

Local AI for development is real: my code and prompts stay on hardware I own, there is no
meter running, and the setup above has few enough parts that I can explain each one. What I
no longer claim is that there is no catch. For refining a request, writing a plan and judging
the result, I still want a frontier model. Part 2 shows how I combine both: [Claude Subscription Meets Local Server](/posts/2026/pi-virtual-models).
