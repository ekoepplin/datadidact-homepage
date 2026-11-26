---
title: "Local AI for Development: You Own Everything"
pubDatetime: 2026-03-29T10:00:00+01:00
modDatetime: 2026-11-26T10:00:00+01:00
description: "How to run coding agents like Claude Code and Pi against your own GPU server: the model runs on the server, your laptop is only the interface. Rewritten in November 2026 as a short, general setup guide."
heroImage: /assets/img/2026/remote-ai-dev-machine/local_models.png
tags: ["llm", "vllm", "ssh", "tailscale", "claude-code", "selfhosted"]
---

**Updated November 2026.** The first version of this post (March 2026) told the story of a
weekend with Ollama, a vLLM build from source and a forked inference engine. None of that is
part of my setup any more. This version keeps only what I still run and can explain, written so
that you can rebuild it on your own hardware. Part 2,
[Claude Subscription Meets Local Server](/posts/2026/pi-virtual-models), builds on it.

The scripts used below are in
[agentic-toolbox/examples/local-hybrid](https://github.com/ekoepplin/agentic-toolbox/tree/master/examples/local-hybrid).

## The picture

The model runs on the server, because that is where the GPU and the memory are. The laptop
runs the agent, Claude Code or Pi. The agent is the part that reads your files, edits them and
runs commands. To think, it sends prompts to the model. Those prompts travel through an SSH
tunnel, which makes a port on the server look like a port on your laptop. The agent talks to
`localhost:8000` and does not care that the model sits on another machine.

```
Laptop (interface only)                   GPU server
──────────────────────                    ─────────────────────────────
Claude Code / Pi                          one model server, port 8000
  reads and edits local files   SSH       bound to 127.0.0.1 only
  sends prompts to              tunnel    speaks OpenAI + Anthropic API
  localhost:8000  ────────────────────►
```

Nothing on the laptop needs a GPU. Your files stay on your laptop, and the prompts, including
the code the agent shows the model, go only to hardware you own.

## What you need

- **A Linux server with an NVIDIA GPU** and enough memory for the model you want. Mine is an
  HP ZGX AI Studio (NVIDIA GB10, 128 GB memory shared by CPU and GPU), but nothing below
  depends on it. Your hardware decides which model fits, not how the setup works.
- **A model server** on it. I use [vLLM](https://docs.vllm.ai) and
  [SGLang](https://docs.sglang.ai) in Docker, which needs the
  [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).
- **A laptop** with SSH, `curl` and `jq`, plus [Claude Code](https://code.claude.com),
  [Pi](https://github.com/earendil-works/pi), or both.

## Step 1: run one model server, on loopback

The model server loads the model into GPU memory and answers requests over HTTP. Which one and
with which flags depends on your model and GPU. For many popular models there are repos with
ready-made Docker images and tuned defaults, and I would start there rather than building
anything from source.

My rule: **one model at a time, always on port 8000.** Every client points at port 8000, so
switching models only ever happens on the server, and the clients never notice.

Whatever you run, it has to do five things:

| Requirement | Why |
|---|---|
| Serve the **Anthropic Messages API** (`/v1/messages`) | Claude Code speaks this API. vLLM and SGLang both serve it |
| Serve the **OpenAI chat API** (`/v1/chat/completions`) on the same port | Pi speaks this API |
| Switch on **tool calling**, with the parser for your model family | Agents work through tool calls. With the wrong parser nothing crashes: the agent just never sees a tool call |
| Offer a **large context window** | Claude Code's first request alone is about 12,000 tokens, and every file the agent reads adds to it. I would not go below 64k |
| Bind the port to **127.0.0.1** only | The API has no password. Only the SSH tunnel should reach it |

The last point is the one people get wrong, so here is the detail. If the server runs in
Docker, `-p 8000:8000` publishes the port on every network interface: your home network, the
conference Wi-Fi, everything. Write `-p 127.0.0.1:8000:8000` instead. A firewall like `ufw`
does not save you here, because Docker writes its own network rules that bypass it. If a
ready-made repo starts the container for you, check its `docker run` line, and check it again
after every update.

To see what your server exposes, list every listening port that is not on loopback:

```bash
ss -tlnH | awk '{print $4}' | grep -v -E '^(127\.|\[::1\])'
```

You want to see SSH (port 22) and, if you use Tailscale, its own listeners. Port 8000 must not
appear.

## Step 2: reach the server through an SSH tunnel

On the laptop, one entry in `~/.ssh/config` sets up the tunnel:

```ssh-config
Host gpu
    HostName <your-server>
    User <your-user>
    LocalForward 127.0.0.1:8000 localhost:8000
    ExitOnForwardFailure yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 12h
```

```bash
ssh -fN gpu                        # opens the tunnel in the background
curl -s localhost:8000/v1/models   # the server's model list, now on the laptop
```

The lines that matter:

- `LocalForward 127.0.0.1:8000 localhost:8000`: port 8000 on the laptop leads to port 8000
  on the server, and opens on the laptop's loopback only. **My March post used `*:8000` here.
  Don't.** That made my model reachable for everyone on whatever Wi-Fi my laptop had joined:
  the same mistake as `-p 8000:8000`, on the other end of the tunnel.
- `ExitOnForwardFailure yes`: if port 8000 is taken on the laptop, `ssh` fails loudly instead
  of connecting without a tunnel.
- `ServerAlive*`: after about 90 seconds without an answer, SSH gives up, so a dropped Wi-Fi
  does not leave a dead tunnel behind that looks open.
- `Control*`: later `ssh` commands reuse the open connection, and `ssh -O check gpu` tells you
  whether the tunnel is still alive.

To reach the server from outside your home network, I use [Tailscale](https://tailscale.com).
It builds a private network between your devices without opening any port on your router. In
its access policy I allow exactly one thing, SSH to the server:

```json
{
  "tagOwners": { "tag:gpu": ["autogroup:admin"] },
  "grants": [
    { "src": ["autogroup:member"], "dst": ["tag:gpu"], "ip": ["tcp:22"] }
  ]
}
```

Save the policy, then tag the server with `sudo tailscale up --advertise-tags=tag:gpu`. Even if
a container ever opened a port by mistake, the tailnet would not carry traffic to it. Use the
full Tailscale name (ending in `ts.net`) as `HostName`: a short name may resolve to the
server's home-network address, and `ssh` then quietly takes that route instead.

And on the server, allow SSH keys only, no passwords.

## Step 3: check that the server can drive an agent

A model list only proves the server is up. Whether an agent can work with it depends on tool
calls. [`check.sh`](https://github.com/ekoepplin/agentic-toolbox/blob/master/examples/local-hybrid/check.sh)
tests the three things the agents need: the model list, a plain chat over the OpenAI API (what
Pi sends), and a tool call over the Anthropic API (what Claude Code sends). It offers the model
a weather tool and asks a question it can only answer with that tool:

```
$ ./check.sh
1 model list                 ok (qwen3.8-flash-next-a5b)
2 OpenAI chat                ok
3 Anthropic + tool call      ok ({"city":"Berlin"})
check: ok
```

If step 3 returns plain text instead of a tool call, check the server's tool-calling settings
first.

## Step 4: Claude Code against the server

Claude Code sends its requests to whatever `ANTHROPIC_BASE_URL` says, so you can point it at
the tunnel. A small shell function keeps the variables scoped to one command, so plain
`claude` keeps working as before. This is
[`clients.sh`](https://github.com/ekoepplin/agentic-toolbox/blob/master/examples/local-hybrid/clients.sh):

```bash
claude-local() {
  local url="${LOCAL_URL:-http://localhost:8000}" model="${LOCAL_MODEL:-qwen}"
  ANTHROPIC_BASE_URL="$url" ANTHROPIC_AUTH_TOKEN=local \
  CLAUDE_CODE_MAX_CONTEXT_TOKENS="${LOCAL_CTX:-65536}" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$model" ANTHROPIC_DEFAULT_SONNET_MODEL="$model" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$model" \
  MAX_THINKING_TOKENS=2048 API_TIMEOUT_MS=3600000 \
    claude --model "$model" "$@"
}
```

```bash
source clients.sh
LOCAL_MODEL=<id from /v1/models> LOCAL_CTX=<your context window> claude-local
```

Two of these lines are easy to miss:

- **The model tiers.** `--model` only sets the main conversation. On the side, Claude Code
  sends small background requests (titles, summaries) to its Haiku, Sonnet and Opus tiers, by
  name. Your server has never heard of those names. The three `ANTHROPIC_DEFAULT_*_MODEL`
  lines send every tier to your model.
- **The context window.** Claude Code does not know your model, so it assumes 200k tokens,
  warns about it at every start, and uses that number to decide when to compact the
  conversation. `CLAUDE_CODE_MAX_CONTEXT_TOKENS` tells it the real size
  ([Claude Code docs](https://code.claude.com/docs/en/model-config#correct-the-window-for-a-gateway-or-custom-model-id)).

The rest: the token can be any value because your server does not check it, the thinking limit
stops reasoning models from deliberating for minutes over a trivial edit, and the one-hour
timeout gives slow local decoding time to finish long answers.

From here on it feels like normal Claude Code. Every request to the model goes to your server;
the tools, editing files and running commands, still run on your laptop.

## Step 5: Pi against the server

[Pi](https://github.com/earendil-works/pi) is an open-source coding agent, and part 2 is all
about it. It speaks the OpenAI API and needs no wrapper: register the server once as a provider
in `~/.pi/agent/models.json` (add the `gpu` entry if the file already exists):

```json
{
  "providers": {
    "gpu": {
      "baseUrl": "http://localhost:8000/v1",
      "api": "openai-completions",
      "apiKey": "local",
      "compat": { "thinkingFormat": "qwen" },
      "models": [
        { "id": "<id from /v1/models>", "reasoning": true, "contextWindow": 262144, "maxTokens": 32000 }
      ]
    }
  }
}
```

```bash
pi --model gpu/<id>
```

Hints:

- `id` must match the name in `/v1/models` character for character.
- Set `contextWindow` and `maxTokens` to what your server offers. Pi's defaults are 128,000 and
  16,384.
- `thinkingFormat` tells Pi how to switch the model's thinking on and off. `qwen` sends the
  `enable_thinking` parameter that Qwen models expect. Drop `compat` and `reasoning` for models
  that do not think.

**Tested:** On 2026-11-23 and 2026-11-26 I ran steps 3 to 5 against Qwen3.8-Flash-Next on vLLM,
through my own tunnel, with Claude Code 2.1.311 and Pi 1.5.2. Both agents created a small
Python file, ran it and reported its output.

## Give the agent a sandbox

A coding agent runs shell commands with your user's rights, and that is as true for a local
model as for a cloud model. In one of my tests, the local model ran `pip install pytest` into my
global Python without asking. Nothing bad happened, but it could have been anything.

So run agents in a container, or at least in a throwaway copy of your project, and never with
credentials you would not hand to the model. My devcontainer is in
[agentic-toolbox](https://github.com/ekoepplin/agentic-toolbox). It reaches the tunnel through
`host.docker.internal`, so agents inside the container can use the server too.

## What changed since March

- **One model server at a time, one port.** In March, Ollama ran as a service next to vLLM, and
  it stayed reachable on my network, without a password, for weeks after I had stopped using it.
- **Ready-made Docker images instead of source builds.** Each build took tens of minutes.
- **Everything on loopback, the tunnel included.** `*:8000` became `127.0.0.1:8000`.
- **Tailscale with SSH only,** instead of SSH to a local IP address.
- **Thinking on, but capped,** instead of switched off.

## Tradeoffs

| Concern | Reality |
|---|---|
| Hardware | The real entry cost. Memory decides which models you can run at all |
| Startup | Minutes, not seconds. Switching models means a restart |
| Security | The model API has no password. Loopback plus SSH-only access is what protects it |
| Quality | Good enough for much of my day-to-day work. Tool-calling quality over long sessions I have not measured |
| Safety | The agent has a shell. Give it a sandbox |

## Where this leaves me

Local AI for development is real. My code and prompts stay on hardware I own, there is no
meter running, and the setup has few enough parts that I can explain each one, which is more
than I could say in March.

What I no longer claim is that there is no catch. For sharpening a request, writing a plan and
judging the result, I still want a frontier model. Part 2 shows how I combine both:
[Claude Subscription Meets Local Server](/posts/2026/pi-virtual-models).
