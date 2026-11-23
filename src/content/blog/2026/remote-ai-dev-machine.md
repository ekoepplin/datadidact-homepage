---
title: "Local AI for Development: You Own Everything"
pubDatetime: 2026-03-29T10:00:00+01:00
modDatetime: 2026-11-23T10:00:00+01:00
description: "How I run coding agents against my own GPU server: the model runs on the server, the Mac is only the interface. Rewritten in November 2026 as a step-by-step setup you can rebuild on your own hardware."
heroImage: /assets/img/2026/remote-ai-dev-machine/local_models.png
tags: ["llm", "vllm", "ssh", "tailscale", "claude-code", "selfhosted"]
---

**Updated November 2026.** The first version of this post (March 2026) told the story of a
weekend with Ollama, a vLLM build from source and the TurboQuant fork. None of that is part of
my setup any more. This version shows the setup as I run it today, step by step, so you can
rebuild it on your own server. Part 2,
[Claude Subscription Meets Local Server](/posts/2026/pi-virtual-models), builds on it.

In March I got an HP ZGX AI Studio and spent a weekend turning it into a model server for
coding agents. It worked, but it had a lot of moving parts: Ollama running next to vLLM, a vLLM
fork built from source, and two ports open to the whole network. Over the following eight
months I kept removing things, until only the parts were left that I can explain. That is what
this post is: the version I would have wanted to read back then.

## The picture

Before any commands, it helps to be clear about who does what. The model runs on the server,
because that is where the GPU and the memory are. The Mac runs the agent, Claude Code or Pi.
The agent is the part that reads your files, edits them and runs commands. To think, it sends
prompts to the model and gets answers back. Those prompts travel through an SSH tunnel: an
encrypted connection that makes a port on the server look like a port on your Mac. The agent
talks to `localhost:8000` and has no idea the model sits on another machine.

```
Mac (interface only)                      GPU server (HP ZGX)
──────────────────────                    ─────────────────────────────
Claude Code / Pi                          one model server, port 8000
  reads and edits local files   SSH       bound to 127.0.0.1 only
  sends prompts to              tunnel    speaks OpenAI + Anthropic API
  localhost:8000  ────────────────────►   NVIDIA GB10, 128 GB unified memory
```

So nothing on the Mac needs a GPU. Your files stay on your Mac, and the prompts, including the
code the agent shows the model, go only to hardware you own. Part 2 adds the cloud to this picture: Claude next to the local model.

## What you need

- **A Linux server with an NVIDIA GPU** and enough memory for the model you want to run.
  Mine is an HP ZGX AI Studio: NVIDIA GB10 (Grace Blackwell), 128 GB of memory shared by CPU
  and GPU, Ubuntu 24.04.
- **Docker and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)**
  on the server. The toolkit is what lets a Docker container use the GPU. After installing it,
  connect it to Docker once:
  `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`
- **A Mac or laptop** with SSH, `curl` and `jq`, plus the agent you want to use:
  [Claude Code](https://code.claude.com), [Pi](https://github.com/earendil-works/pi), or both.

Different hardware? The steps stay the same. What changes is which model fits.

## Step 1: start one model server on the server

The model needs a program that loads it into GPU memory and answers requests over HTTP. That
program is the model server. I use vLLM and SGLang, two open-source servers built for exactly
this.

My basic rule: **one model at a time, always on port 8000.** The GB10 has a single memory pool
for CPU and GPU, so two large models would not fit side by side anyway. And because every
client points at port 8000, switching models only ever happens on the server. The clients
never notice.

Whatever server software you pick, it has to do five things:

| Requirement | Why |
|---|---|
| Serve the **Anthropic Messages API** (`/v1/messages`) | Claude Code speaks this API. vLLM and SGLang both serve it |
| Serve the **OpenAI chat API** (`/v1/chat/completions`) on the same port | Pi speaks this API |
| Have **tool calling** switched on, with the right parser for your model | Agents work through tool calls. With the wrong parser, tool calls fail silently: the model "calls" a tool and nothing happens |
| Offer a **large context window** | Claude Code's first request alone is about 12,000 tokens (measured, see step 4), and every file the agent reads adds to it. I would not go below 64k. My models run 256k |
| Bind the port to **127.0.0.1** only | The API has no password. Only the SSH tunnel in step 2 should reach it |

Two of these need a word more.

**Tool calls** are how an agent gets anything done. The model does not edit files itself. It
answers with a structured request like "call the tool `edit_file` with these arguments", and
the agent carries it out. Every model family formats those requests a little differently, and
the server needs a matching parser to turn the model's text into a proper tool call. If the
parser does not match, nothing crashes. The agent just never sees a tool call, which is why
this failure is so easy to miss.

**The context window** is how much text the model can see at once: the system prompt, the tool
descriptions, your messages, and every file the agent has read so far. An agent fills it fast.

I switch between three models. The speeds are decode rates I measured on the ZGX, meaning
how many tokens per second the model writes (256 output tokens, median of 3 runs):

| Model | Server software | Tokens per second | Measured |
|---|---|---|---|
| Qwen3.8-Flash-Next 125B-A5B, INT4 | vLLM | 48–80 | 2026-09-13 |
| Qwen3.6-35B-A3B, NVFP4 | vLLM | 106–140 | 2026-09-14 |
| Qwen3.8-27B, NVFP4 | SGLang | 15.8–49.8 | 2026-09-14 |

All three use speculative decoding: a small draft model guesses the next few tokens, and the
big model only checks them. Checking is faster than writing, so when the guesses are good, the
model gets much faster. How good the guesses are depends on the task, which is why the ranges
are so wide.

One honest caveat: speed is not quality. How well each model handles tool calls over long
agent sessions, I have not measured.

### The model I use: Qwen3.8-Flash-Next

Flash-Next is the model behind all the tests in part 2. Its serving setup lives in a public
repo with tuned defaults, so you do not have to work out the vLLM flags yourself. On the
server, clone it and run the one-time setup:

```bash
git clone https://github.com/azampatti/Qwen3.8-Flash-Next-Int4-FAST.git ~/repos/Qwen3.8-Flash-Next-Int4-FAST
cd ~/repos/Qwen3.8-Flash-Next-Int4-FAST
./setup.sh      # one time: builds the Docker images, downloads the ~118 GiB model
```

**Before the first start, make one edit.** In `serve.sh`, find the `docker run` line and change
`-p "${PORT}:8000"` to `-p "127.0.0.1:${PORT}:8000"`.

Here is why that matters. `-p 8000:8000` tells Docker to publish the port on every network
interface of the server: your home network, the Wi-Fi at a conference, everything. Since the
model API has no password, anyone on that network could use your model. `127.0.0.1` is the
loopback address, the server talking to itself. Bound there, the port is reachable from the
server only, and the SSH tunnel brings it to your Mac. And no, a firewall like `ufw` does not
save you here: Docker writes its own network rules, and they bypass `ufw`. The edit is a local
change to the repo, so check it again after every `git pull`.

Now start the server:

```bash
./serve.sh -d   # starts vLLM in the background, on port 8000
```

Give it about 5 minutes. It loads 71 GiB of weights into memory and then compiles. The server
is ready when this command lists `qwen3.8-flash-next-a5b`:

```bash
curl -s localhost:8000/v1/models
```

Last, check what the server exposes to the outside. This command lists every listening port
that is not on loopback:

```bash
ss -tlnH | awk '{print $4}' | grep -v -E '^(127\.|\[::1\])'
```

You want to see only port 22 (SSH), plus two Tailscale entries on `tailscale0` if you use
Tailscale (step 2). If port 8000 shows up, the edit above is missing.

## Step 2: reach the server from the Mac

The server now answers on its own loopback. Next, the Mac needs a way in.

I use [Tailscale](https://tailscale.com) for that. Tailscale builds a private network between
your devices, called a tailnet, which works whether you are at home or on the road. You don't
need to open any port on your router. In the tailnet policy (Tailscale admin console, Access
controls) I allow exactly one thing: SSH to the server.

```json
{
  "tagOwners": { "tag:gpu": ["autogroup:admin"] },
  "grants": [
    { "src": ["autogroup:member"], "dst": ["tag:gpu"], "ip": ["tcp:22"] }
  ]
}
```

In plain words: every member of my tailnet may reach devices tagged `gpu`, on TCP port 22, and
nothing else. Even if a container on the server ever opened a port by mistake, the tailnet
would not carry traffic to it.

Save the policy first. Then, on the server:

```bash
sudo tailscale up --advertise-tags=tag:gpu
```

The order matters: without the saved policy, Tailscale refuses the tag. A nice side effect of
the tag is that key expiry is switched off by default for tagged devices, so the server does not
quietly drop out of the tailnet after a few months.

No Tailscale? On a home network everything below works the same. Just use the server's local
IP address as `HostName`.

On the Mac, one entry in `~/.ssh/config` sets up the tunnel:

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

If the second command shows the same model list as on the server, the tunnel works. Here is
what each line in the config is for:

- `LocalForward 127.0.0.1:8000 localhost:8000`: port 8000 on the Mac now leads to port 8000 on
  the server. The `127.0.0.1` in front means the port opens on the Mac's own loopback only.
  **My March post used `*:8000` here. Don't.** That made my model reachable for everyone on
  whatever Wi-Fi my Mac had joined. It is the same mistake as `-p 8000:8000` in step 1, just
  on the other end of the tunnel.
- `ControlMaster`, `ControlPath`, `ControlPersist`: the first connection stays open in the
  background, for up to 12 hours after its last use, and later `ssh` commands reuse it instead
  of connecting again. As a bonus,
  `ssh -O check gpu` tells you whether the tunnel is still alive.
- `ServerAliveInterval 30`, `ServerAliveCountMax 3`: every 30 seconds SSH checks the other
  side is still there. After three missed answers, about 90 seconds, it gives up. Without
  this, a dropped Wi-Fi can leave a dead tunnel behind that looks open but goes nowhere.
- `ExitOnForwardFailure yes`: if port 8000 is already taken on the Mac, `ssh` stops with an
  error. Otherwise it would connect without a tunnel and leave you guessing.

Use the full Tailscale name (ending in `ts.net`) as `HostName`. A short name may also resolve
through your home router to the server's local address, and then `ssh` quietly takes the home
network instead of Tailscale.

One last bit of hygiene: allow only SSH keys on the server, no passwords. Make sure your key
login works first, and keep that session open while you test a second login, so you cannot
lock yourself out:

```bash
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
  | sudo tee /etc/ssh/sshd_config.d/10-keys-only.conf
sudo sshd -t && sudo systemctl reload ssh
```

## Step 3: check that the server can drive an agent

A model list only proves the server is up. Whether an agent can actually work with it depends
on tool calls, so let's test exactly that. This request, run on the Mac, offers the model a
weather tool and asks a question it can only answer with that tool. It uses the Anthropic API,
the same way Claude Code does:

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

`stop_reason: tool_use` means the model stopped to call a tool, and `{"city": "Berlin"}` is
the argument it wants to pass. That is the whole mechanism an agent runs on. If you get plain
text back instead, check the server's tool-calling settings first.

## Step 4: Claude Code against the server

Claude Code normally talks to Anthropic. But it sends its requests to whatever address is in
the environment variable `ANTHROPIC_BASE_URL`, so you can point it at your tunnel. I wrap that
in a small shell function in `~/.zshrc` on the Mac. The variables only apply to this one
command, so plain `claude` keeps working exactly as before:

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

Each line is there for a reason:

- `ANTHROPIC_BASE_URL`: send every request to the tunnel instead of Anthropic.
- `ANTHROPIC_AUTH_TOKEN`: any value works. Your server does not check it.
- `ANTHROPIC_DEFAULT_OPUS_MODEL`, `…SONNET…`, `…HAIKU…`: this one is easy to miss. `--model`
  only sets the model for the main conversation. On the side, Claude Code sends small
  background requests (titles, summaries) to its smaller model tiers, by name. Your server has
  never heard of those names, so those requests would fail. These three lines send every tier
  to your model.
- `CLAUDE_CODE_MAX_CONTEXT_TOKENS`: your server's context window, 262,144 tokens for
  Flash-Next. Claude Code does not know your model, so without this it assumes 200k and warns
  you about it at every start. It uses this number to decide when to shorten (compact) the
  conversation
  ([Claude Code docs](https://code.claude.com/docs/en/model-config#correct-the-window-for-a-gateway-or-custom-model-id)).
- `CLAUDE_CODE_MAX_OUTPUT_TOKENS`: the maximum length of one answer, so long files don't get
  cut off halfway.
- `MAX_THINKING_TOKENS`: Qwen models think before they answer. That is useful, but without a
  limit they can deliberate for minutes over a trivial edit. 2,048 tokens keeps it short.
- `API_TIMEOUT_MS`: one hour. A long answer from a local model can take longer than Claude Code
  is willing to wait by default.

Then go into a project and start it:

```bash
cd ~/your-project
claude-local
```

From here on it feels like normal Claude Code. The difference is under the hood: every request
to the model goes to your server. The tools themselves, editing files and running commands,
still run on your Mac.

## Step 5: Pi against the server

[Pi](https://github.com/earendil-works/pi) is an open-source coding agent. Part 2 is all about
it. It speaks the OpenAI API, which your server offers on the same port. To tell Pi about the
server, register it once as a provider in `~/.pi/agent/models.json` on the Mac. If the file
already exists, add the `zgx` entry under `providers`:

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

What the fields mean:

- `baseUrl` and `api: openai-completions`: where the server is and which API to use.
- `apiKey`: any value. Same story as above, the server does not check it.
- `thinkingFormat: qwen`: how Pi switches the model's thinking on and off. `qwen` sends the
  `enable_thinking` parameter that Qwen models expect.
- `id`: must match the name the server lists in `/v1/models`, character for character.
- `reasoning: true`: the model supports thinking.
- `contextWindow` and `maxTokens`: the server's context window and the maximum length of one
  answer. Pi's defaults (128,000 and 16,384) are lower than what Flash-Next offers, so it pays
  to set them.

Then:

```bash
cd ~/your-project
pi --model zgx/qwen3.8-flash-next-a5b
```

The interesting part, one session that uses Claude and the local model together, is what part
2 is about.

**Tested:** On 2026-11-23 I ran steps 3 to 5 exactly as written against Flash-Next, through
my own SSH tunnel (same settings as step 2, different host name), with Claude Code 2.1.311 and
Pi 1.5.2. Both agents created a small Python file, ran it and reported its output. Not re-run
that day: `setup.sh` and `serve.sh`, because Flash-Next was already running.

## Give the agent a sandbox

This one is easy to forget, so it gets its own section. A coding agent runs shell commands with
your user's rights, and that is true for a local model just as much as for a cloud model. In one
of my tests, Flash-Next ran `pip install pytest` into my global Python without asking. Nothing
bad happened, but it could have been anything.

So run agents in a container, or at least in a throwaway copy of your project, and never with
credentials you would not hand to the model. My devcontainer is in
[agentic-toolbox](https://github.com/ekoepplin/agentic-toolbox). It reaches the tunnel on the
Mac through `host.docker.internal`, so agents inside the container can use your server too.

## What changed since March

If you read the first version of this post, here is what changed and why:

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

Local AI for development is real. My code and prompts stay on hardware I own, there is no
meter running, and the whole setup has few enough parts that I can explain each one, which is
more than I could say in March.

What I no longer claim is that there is no catch. For sharpening a request, writing a plan and
judging the result, I still want a frontier model. Part 2 shows how I combine both:
[Claude Subscription Meets Local Server](/posts/2026/pi-virtual-models).
