---
title: "Local AI for Development: You Own Everything"
pubDatetime: 2026-03-29T10:00:00+01:00
modDatetime: 2026-11-23T10:00:00+01:00
description: "How I run coding agents against my own GPU server: the model runs on the server, the Mac is only the interface. Rewritten in November 2026 as a step-by-step setup you can rebuild on your own hardware."
heroImage: /assets/img/2026/remote-ai-dev-machine/local_models.png
tags: ["llm", "vllm", "ssh", "tailscale", "claude-code", "selfhosted"]
---

**Updated November 2026.** The first version of this post (March 2026) described a weekend of
Ollama, a vLLM build from source and the TurboQuant fork. None of that is in my setup any more.
This version describes the setup as I run it today, step by step, so you can rebuild it on
your own server. Part 2, [Claude Subscription Meets Local Server](/posts/2026/pi-virtual-models),
builds on it.

In March I got an HP ZGX AI Studio and spent a weekend turning it into a model server for
coding agents. It worked, but it had many moving parts: Ollama next to vLLM, a vLLM fork built
from source, two ports open to the network. Eight months later the setup is smaller. This post
is the version I would have wanted back then.

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

Part 2 adds the cloud: Claude next to the local model.

## What you need

- **A Linux server with an NVIDIA GPU** and enough memory for the model. Mine: HP ZGX AI
  Studio, NVIDIA GB10 (Grace Blackwell), 128 GB memory shared by CPU and GPU, Ubuntu 24.04.
- **Docker and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)**
  on the server. After installing the toolkit, connect it to Docker once:
  `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`
- **A Mac or laptop** with SSH, `curl`, `jq`, and the agent you want:
  [Claude Code](https://code.claude.com) and/or [Pi](https://github.com/earendil-works/pi).

If your hardware differs, the steps stay the same. Only the model you can fit changes.

## Step 1: start one model server on the server

The basic rule: **one model at a time, always on port 8000.** The GB10 has a single memory
pool, so two large models do not fit side by side anyway. And because every client points at
port 8000, switching models never means changing a client.

Whatever software you use, the server must do these five things:

| Requirement | Why |
|---|---|
| Serve the **Anthropic Messages API** (`/v1/messages`) | Claude Code speaks this API. vLLM and SGLang both serve it |
| Serve the **OpenAI chat API** (`/v1/chat/completions`) on the same port | Pi speaks this API |
| Have **tool calling** switched on, with the right parser for your model | Agents work through tool calls. With the wrong parser, tool calls fail silently: the model "calls" a tool and nothing happens |
| Offer a **large context window** | Claude Code's first request alone is about 12,000 tokens (measured, see step 4), and every file the agent reads adds to it. I would not go below 64k. My models run 256k |
| Bind the port to **127.0.0.1** only | The API has no password. Only the SSH tunnel in step 2 should reach it |

I switch between three models. The speeds are decode rates I measured on the ZGX
(256 output tokens, median of 3 runs):

| Model | Server software | Tokens per second | Measured |
|---|---|---|---|
| Qwen3.8-Flash-Next 125B-A5B, INT4 | vLLM | 48–80 | 2026-09-13 |
| Qwen3.6-35B-A3B, NVFP4 | vLLM | 106–140 | 2026-09-14 |
| Qwen3.8-27B, NVFP4 | SGLang | 15.8–49.8 | 2026-09-14 |

All three use speculative decoding: a small draft model guesses the next tokens and the big
model checks them. That is why the speed depends on the task and the ranges are wide.

Speed is not quality. How well each model handles tool calls over long agent sessions, I have
not measured.

### The model I use: Qwen3.8-Flash-Next

Flash-Next is the model behind all tests in part 2. Its serving setup is a public repo with
tuned defaults, so you do not have to work out vLLM flags yourself. On the server:

```bash
git clone https://github.com/azampatti/Qwen3.8-Flash-Next-Int4-FAST.git ~/repos/Qwen3.8-Flash-Next-Int4-FAST
cd ~/repos/Qwen3.8-Flash-Next-Int4-FAST
./setup.sh      # one time: builds the Docker images, downloads the ~118 GiB model
```

**Before the first start, make one edit.** In `serve.sh`, find the `docker run` line and change
`-p "${PORT}:8000"` to `-p "127.0.0.1:${PORT}:8000"`. Without it, Docker opens port 8000 on
every network interface of the server. A firewall like `ufw` does not help here: Docker's port
rules bypass it. The edit is a local change to the repo, so check it again after every
`git pull`.

Then start the server:

```bash
./serve.sh -d   # starts vLLM in the background, on port 8000
```

Startup takes about 5 minutes: it loads 71 GiB of weights, then compiles. The server is ready
when this command lists `qwen3.8-flash-next-a5b`:

```bash
curl -s localhost:8000/v1/models
```

Finally, check that nothing but SSH is reachable from outside the server:

```bash
ss -tlnH | awk '{print $4}' | grep -v -E '^(127\.|\[::1\])'
```

Expected: only port 22, and if you use Tailscale (step 2), two Tailscale entries on
`tailscale0`. Port 8000 must not appear.

## Step 2: reach the server from the Mac

I reach the ZGX over [Tailscale](https://tailscale.com), at home and away, without opening a
port on my router. The tailnet policy (Tailscale admin console, Access controls) allows SSH
to the server and nothing else:

```json
{
  "tagOwners": { "tag:gpu": ["autogroup:admin"] },
  "grants": [
    { "src": ["autogroup:member"], "dst": ["tag:gpu"], "ip": ["tcp:22"] }
  ]
}
```

Save the policy first. Then, on the server:

```bash
sudo tailscale up --advertise-tags=tag:gpu
```

Without the saved policy, Tailscale refuses the tag. Tagged devices have key expiry switched
off by default, so the server does not drop out of the tailnet after a few months.

No Tailscale? On a home network, everything below works the same with the server's local IP
address as `HostName`.

On the Mac, one entry in `~/.ssh/config` carries the tunnel:

```ssh-config
Host gpu
    HostName <your-server>.<your-tailnet>.ts.net
    User <your-user>
    IdentityFile ~/.ssh/id_ed25519
    LocalForward 127.0.0.1:8000 localhost:8000
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 12h
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
```

Open the tunnel and test it:

```bash
ssh -fN gpu                        # opens the tunnel in the background
curl -s localhost:8000/v1/models   # the server's model list, now on the Mac
```

What the lines do:

- `LocalForward 127.0.0.1:8000 localhost:8000`: port 8000 on the Mac leads to port 8000 on the
  server, and it opens on the Mac's own loopback only. **My March post used `*:8000`. Don't.**
  That made the model reachable for everyone on whatever Wi-Fi my Mac had joined.
- `ControlMaster`, `ControlPath`, `ControlPersist`: later `ssh` commands reuse the open
  connection. `ssh -O check gpu` tells you whether it is still alive.
- `ServerAliveInterval 30`, `ServerAliveCountMax 3`: a dropped connection is noticed after
  about 90 seconds, instead of leaving a dead tunnel behind.
- `ExitOnForwardFailure yes`: if port 8000 is already taken on the Mac, `ssh` stops with an
  error instead of connecting without a tunnel.

Use the full Tailscale name (`…ts.net`) as `HostName`. A short name can also resolve through
your home router to the local address, and then `ssh` bypasses Tailscale without telling you.

Last, allow only SSH keys on the server, no passwords. Make sure your key login works first,
and keep that session open while you test a second login:

```bash
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
  | sudo tee /etc/ssh/sshd_config.d/10-keys-only.conf
sudo sshd -t && sudo systemctl reload ssh
```

## Step 3: check that the server can drive an agent

A model list is not enough. An agent needs working tool calls. This request, run on the Mac,
offers the model a tool and asks a question it can only answer with that tool. It uses the
Anthropic API, like Claude Code:

```bash
curl -s localhost:8000/v1/messages -H 'Content-Type: application/json' -d '{
  "model": "qwen3.8-flash-next-a5b", "max_tokens": 2048,
  "tools": [{"name": "get_weather", "description": "Current weather for a city",
             "input_schema": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}],
  "messages": [{"role": "user", "content": "What is the weather in Berlin? Use the tool."}]
}' | jq '{stop_reason, call: [.content[] | select(.type == "tool_use") | .input]}'
```

Expected output:

```json
{
  "stop_reason": "tool_use",
  "call": [{ "city": "Berlin" }]
}
```

If you get text back instead of a tool call, check the server's tool-calling settings first.

## Step 4: Claude Code against the server

Claude Code sends its requests to the address in `ANTHROPIC_BASE_URL`. Put this function in
`~/.zshrc` on the Mac. The settings apply only to this one command, so plain `claude` keeps
working as before:

```bash
claude-local() {
  local model=qwen3.8-flash-next-a5b
  ANTHROPIC_BASE_URL=http://localhost:8000 \
  ANTHROPIC_AUTH_TOKEN=local \
  ANTHROPIC_DEFAULT_OPUS_MODEL=$model \
  ANTHROPIC_DEFAULT_SONNET_MODEL=$model \
  ANTHROPIC_DEFAULT_HAIKU_MODEL=$model \
  CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144 \
  CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000 \
  MAX_THINKING_TOKENS=2048 \
  API_TIMEOUT_MS=3600000 \
    claude --model $model "$@"
}
```

What each setting does:

- `ANTHROPIC_BASE_URL`: send all requests to the tunnel instead of Anthropic.
- `ANTHROPIC_AUTH_TOKEN`: any value. The server does not check it.
- `ANTHROPIC_DEFAULT_OPUS_MODEL`, `…SONNET…`, `…HAIKU…`: `--model` only sets the model for
  the main conversation. Claude Code also sends background requests (titles, summaries) to its
  smaller model tiers by name, and your server does not know those names. These three lines
  send every tier to your model.
- `CLAUDE_CODE_MAX_CONTEXT_TOKENS`: your server's context window (262,144 for Flash-Next).
  Claude Code does not know the model, would otherwise assume 200k and warn about it at every
  start. It uses this number to decide when to shorten (compact) the conversation
  ([Claude Code docs](https://code.claude.com/docs/en/model-config#correct-the-window-for-a-gateway-or-custom-model-id)).
- `CLAUDE_CODE_MAX_OUTPUT_TOKENS`: the maximum length of one answer, so long files are not
  cut off.
- `MAX_THINKING_TOKENS`: Qwen models think before they answer. Without a limit they can think
  for minutes about a trivial edit.
- `API_TIMEOUT_MS`: one hour. Long answers from a local model can take longer than Claude
  Code waits by default.

Then go into a project and start it:

```bash
cd ~/your-project
claude-local
```

## Step 5: Pi against the server

Pi speaks the OpenAI API to the same port. Register the server once in
`~/.pi/agent/models.json` on the Mac (if the file already exists, add the `zgx` entry under
`providers`):

```json
{
  "providers": {
    "zgx": {
      "baseUrl": "http://localhost:8000/v1",
      "api": "openai-completions",
      "apiKey": "local",
      "compat": { "thinkingFormat": "qwen" },
      "models": [
        { "id": "qwen3.8-flash-next-a5b", "reasoning": true, "contextWindow": 262144, "maxTokens": 32000 }
      ]
    }
  }
}
```

- `api: openai-completions`: talk to the server through the OpenAI chat API.
- `apiKey`: any value. The server does not check it.
- `thinkingFormat: qwen`: how Pi switches the model's thinking on and off. `qwen` sends the
  `enable_thinking` parameter that Qwen models expect.
- `id`: must match the name the server lists in `/v1/models`.
- `reasoning: true`: the model supports thinking. `contextWindow` and `maxTokens`: the
  server's context window and the maximum length of one answer. Pi's defaults (128,000 and
  16,384) are lower than what Flash-Next offers.

Then:

```bash
cd ~/your-project
pi --model zgx/qwen3.8-flash-next-a5b
```

Part 2 is about what Pi adds on top: one session that uses Claude and the local model together.

**Tested:** On 2026-11-23 I ran steps 3 to 5 exactly as written against Flash-Next, through
my own SSH tunnel (same settings as step 2, different host name), with Claude Code 2.1.311 and
Pi 1.5.2. Both agents created a small Python file, ran it and reported its output. Not re-run
that day: `setup.sh` and `serve.sh`, because Flash-Next was already running.

## Give the agent a sandbox

A coding agent runs shell commands with your user's rights, local model or not. In one of my
tests, Flash-Next ran `pip install pytest` into my global Python without asking. Run agents in
a container, or at least in a throwaway copy of your project, and never with credentials you
would not hand to the model. My devcontainer, which reaches port 8000 through
`host.docker.internal`, is in [agentic-toolbox](https://github.com/ekoepplin/agentic-toolbox).

## What changed since March

| March 2026 | Now | Why |
|---|---|---|
| Ollama as an always-on service, next to vLLM | Removed | One server software at a time, one port. Ollama also stayed reachable on my network, without a password, for five weeks after I stopped using it |
| vLLM built from source, plus the TurboQuant fork | Ready-made Docker images per model | Each build took tens of minutes. The images already support the GB10 |
| One model | Three models, one at a time on port 8000 | Switching is a restart on the server, no client changes |
| SSH to a local IP address | Tailscale, SSH only | Works from anywhere, nothing open on the router |
| Tunnel bound to `*` | Tunnel bound to `127.0.0.1` | `*` exposed the model to every network my Mac joined |
| Thinking switched off | Thinking on, limited to 2,048 tokens | All three models think before they answer; the limit keeps it short |

## Tradeoffs

| Concern | Reality |
|---|---|
| Hardware | The real entry cost. Flash-Next alone needs about 71 GiB for its weights plus 20 GB for its cache |
| Startup | Minutes, not seconds: about 5 minutes for Flash-Next. Switching models means a restart |
| Security | The model API has no password. Binding it to 127.0.0.1 and allowing only SSH is what protects it |
| Quality | Good enough for much of my day-to-day work. Tool-calling quality over long sessions is unmeasured |
| Safety | The agent has a shell. Give it a sandbox |

## Where this leaves me

Local AI for development is real: my code and prompts stay on hardware I own, there is no
meter running, and the setup has few enough parts that I can explain each one. What I no
longer claim is that there is no catch. For sharpening a request, writing a plan and judging
the result, I still want a frontier model. Part 2 shows how I combine both:
[Claude Subscription Meets Local Server](/posts/2026/pi-virtual-models).
