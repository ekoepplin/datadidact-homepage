---
title: "Local AI for Development: You Own Everything"
pubDatetime: 2026-03-29T10:00:00+01:00
modDatetime: 2026-11-26T10:00:00+01:00
description: "Run Claude Code or Pi against a model on your own GPU. The model does the thinking on the GPU box, your laptop stays the place where you work, and an SSH tunnel connects the two."
heroImage: /assets/img/2026/remote-ai-dev-machine/cover-drawing.jpg
tags: ["llm", "vllm", "ssh", "tailscale", "claude-code", "selfhosted"]
---

**Updated November 2026.** Back in March I wrote this post after a weekend of Ollama, building
vLLM from source and a forked inference engine. It worked, kind of. Most of it is gone now.
What's left is a setup with so few moving parts that I can explain all of them, and that's the
version you're reading. [Part 2](/posts/2026/pi-virtual-models) builds on it and brings Claude
back into the picture.

## Why bother?

Coding agents are great. Claude Code, Pi and friends read your code, edit files, run your
tests. But every prompt they send includes your code, and it all goes to someone else's
servers. Every token is billed somewhere.

Open models got good enough this year that I do a lot of my day-to-day work with one running
on my own hardware. My code never leaves machines I own, and there's no meter running. And
once it's set up, it feels exactly like the cloud version.

The trick is to split the work in two:

- **The model** runs wherever the GPU is.
- **The agent** runs on your laptop, next to your code.

They talk through an SSH tunnel. As far as the agent knows, the model is at `localhost:8000`.
It has no idea the model lives on another machine.

```
 laptop                                 GPU machine
┌───────────────────────┐  SSH tunnel  ┌───────────────────────┐
│ Claude Code / Pi      │ ───────────> │ model server          │
│ your code, your edits │  port 8000   │ reachable only        │
└───────────────────────┘              │ through the tunnel    │
                                       └───────────────────────┘
```

Your laptop needs no GPU. Your files stay on your laptop. Only the prompts go to the GPU, and
that GPU is yours.

All scripts from this post are in
[agentic-toolbox/examples/local-hybrid](https://github.com/ekoepplin/agentic-toolbox/tree/master/examples/local-hybrid),
so you can copy instead of typing.

## What you need

- **A GPU with enough memory for the model you want.** Where it sits doesn't matter: under
  your desk, in the office, in a closet. Mine is a small HP box on my desk. Memory decides
  which models you can run. Nothing else in this post depends on the hardware.
- **A model server** that serves the model over HTTP. I use [vLLM](https://docs.vllm.ai) and
  [SGLang](https://docs.sglang.ai). For most popular models you'll find ready-made Docker
  images with sensible defaults. Start there. Don't build anything from source (been there, it
  ate my weekend).
- **A coding agent on your laptop:** [Claude Code](https://code.claude.com),
  [Pi](https://github.com/earendil-works/pi), or both.

## Step 1: get the model server right

I won't tell you which flags to use, because that depends on your model and your GPU. What
matters is what the server needs to do:

- **Speak both APIs.** Claude Code speaks the Anthropic API, Pi speaks the OpenAI API. Recent
  vLLM and SGLang do both on the same port, so one server works for both agents.
- **Tool calling on.** This is the big one. Agents do everything through tool calls: read a
  file, edit, run a command. With the wrong tool parser for your model, nothing crashes. The
  agent just never sees a tool call and starts chatting instead of working. That kind of bug
  can cost you an evening.
- **A big context window.** Claude Code's very first request is already about 12,000 tokens,
  and every file the agent reads adds to that. I wouldn't go below 64k.
- **Only reachable from the server itself.** More on that now.

### The one security thing you have to get right

The model API has no password. Anyone who can reach the port can use your GPU and read your
prompts. So the server should listen only on the machine itself (`127.0.0.1`), and the only
way in is the SSH tunnel.

If you run the server in Docker, this is where people get burned. `-p 8000:8000` opens the port
on *every* network: your home Wi-Fi, the café Wi-Fi, everything. And a firewall like `ufw`
won't save you, because Docker writes its own rules around it. Write this instead:

```bash
docker run -p 127.0.0.1:8000:8000 ...
```

If a ready-made repo starts the container for you, check its `docker run` line. Check it again
after every update.

Test it from another device on the same network:

```bash
curl -m 5 http://<server-address>:8000/v1/models
```

You want this to *fail*. If you get a model list back, the whole network can use your model.

I learned this the hard way. In March I had Ollama running next to vLLM "just to try it". I
stopped using it, but it kept running, without a password, reachable on my network, for weeks.

## Step 2: the SSH tunnel

One entry in `~/.ssh/config` on your laptop:

```ssh-config
Host gpu
    HostName <your-server>
    LocalForward 127.0.0.1:8000 localhost:8000
    ExitOnForwardFailure yes
    ServerAliveInterval 30
```

```bash
ssh -fN gpu                        # tunnel up, in the background
curl -s localhost:8000/v1/models   # the GPU's model list, now on your laptop
```

What's going on here: `LocalForward` takes port 8000 on your laptop and connects it to port
8000 on the server. `ExitOnForwardFailure` makes `ssh` fail loudly if the port is already taken,
instead of quietly connecting without a tunnel. `ServerAliveInterval` makes a dead tunnel die
fast after your Wi-Fi drops, instead of hanging around and looking alive.

Look at the `127.0.0.1` in the `LocalForward` line. In my March post that said `*:8000`, which
put my model on whatever Wi-Fi my laptop had joined. Same mistake as `-p 8000:8000`, just on
the other end of the tunnel. Don't do that.

### Away from home

To reach the server from anywhere, I use [Tailscale](https://tailscale.com). It's a private
network between your own devices, and you don't have to open any port on your router. In its
access policy I allow exactly one thing, SSH to the GPU box:

```json
{
  "tagOwners": { "tag:gpu": ["autogroup:admin"] },
  "grants": [
    { "src": ["autogroup:member"], "dst": ["tag:gpu"], "ip": ["tcp:22"] }
  ]
}
```

Tag the server with `sudo tailscale up --advertise-tags=tag:gpu` and use its full Tailscale
name (the one ending in `ts.net`) as `HostName`. Even if a container opens a port by mistake,
Tailscale won't let traffic through to it. And on the server: SSH keys only, no passwords.

## Step 3: can the server actually drive an agent?

A model list only tells you the server is up. Whether an agent can *work* with it comes down
to tool calls. So before you start an agent and wonder why it only chats,
[`check.sh`](https://github.com/ekoepplin/agentic-toolbox/blob/master/examples/local-hybrid/check.sh)
gives the model a fake weather tool and asks a question it can only answer by calling that tool:

```
$ ./check.sh
1 model list                 ok (qwen3.8-flash-next-a5b)
2 OpenAI chat                ok
3 Anthropic + tool call      ok ({"city":"Berlin"})
check: ok
```

Line 2 is what Pi needs, line 3 is what Claude Code needs. If line 3 comes back as plain text
instead of a tool call, look at your server's tool-calling settings first. Saves you a lot of
guessing.

## Step 4: Claude Code on your own model

Claude Code sends its requests wherever `ANTHROPIC_BASE_URL` points. Point it at the tunnel and
you're done. Almost. I wrap it in a small function so plain `claude` keeps working as before
([`clients.sh`](https://github.com/ekoepplin/agentic-toolbox/blob/master/examples/local-hybrid/clients.sh)):

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

Most of this is boring plumbing. Two lines will bite you if you leave them out:

- **The model names.** On the side, Claude Code sends small background requests, like
  titles and summaries, to "haiku", "sonnet" and "opus". Your server has never heard of
  those names. The three `ANTHROPIC_DEFAULT_*` lines send them all to your model.
- **The context window.** Claude Code doesn't know your model and assumes 200k tokens. It uses
  that number to decide when to compact the conversation, so with a smaller model it compacts
  way too late. `CLAUDE_CODE_MAX_CONTEXT_TOKENS` tells it the real size
  ([docs](https://code.claude.com/docs/en/model-config#correct-the-window-for-a-gateway-or-custom-model-id)).

The rest: your server doesn't check the token, so any value works. The thinking cap stops a
reasoning model from thinking for minutes about a one-line edit. And the long timeout gives a
slow local model time to finish.

From here on it's just Claude Code. The thinking happens on your GPU, while files and commands
stay on your laptop.

## Step 5: Pi on your own model

[Pi](https://github.com/earendil-works/pi) is an open-source coding agent, and Part 2 is all
about it. Pi doesn't need a wrapper. You register your server once as a provider in
`~/.pi/agent/models.json`:

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

The `id` has to match `/v1/models` exactly. Set `contextWindow` and `maxTokens` to what your
server actually offers. The `compat` and `reasoning` lines tell Pi how to switch thinking on and
off for Qwen models. Drop them for models that don't think.

I ran steps 3 to 5 on 2026-11-26 against Qwen3.8-Flash-Next on vLLM, with Claude Code 2.1.311
and Pi 1.5.2. Both agents wrote a small Python file, ran it and reported the output.

## Give the agent a sandbox

Easy to forget: a coding agent runs shell commands with *your* rights. A local model doesn't
change that. In one of my tests, the local model ran `pip install pytest` into my global Python
without asking. Nothing bad happened, but it could have been anything.

So put the agent in a container, or at least a throwaway copy of your project, and never give it
credentials you wouldn't hand to the model. My devcontainer is in
[agentic-toolbox](https://github.com/ekoepplin/agentic-toolbox). Agents inside it reach the
tunnel through `host.docker.internal`, so they can use the GPU too.

## The catch

It's not free, it's just paid up front. The hardware is the real entry cost, and memory decides
what you can run at all. Starting a model takes minutes, not seconds, so switching models is a
coffee break. And security is on you: the model API has no password, so the tunnel is your only
door.

Quality? Good enough for a lot of my daily work. How it holds up over long agent sessions I
haven't measured, so I won't pretend I have.

## Where this leaves me

Local AI for development is real, and the boring setup is the one that sticks: one model
server, one tunnel, your agent of choice. My code and prompts stay on my hardware, nothing is
billed per token, and I can explain every piece of it. I couldn't say that in March.

What I won't claim is that the local model does everything. For sharpening a request, writing a
plan and judging the result, I still want a frontier model. Part 2 is about combining both:
[Claude Subscription Meets Local Server](/posts/2026/pi-virtual-models).
