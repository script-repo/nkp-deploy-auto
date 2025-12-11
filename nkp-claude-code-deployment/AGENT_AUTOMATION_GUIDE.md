# Agent Automation Guide (OpenAI GPT-5, Claude Code, and OpenAI-Compatible Models)

This guide shows how to run the NKP 2.16 deployment with three common automation choices: **OpenAI GPT-5 (ChatGPT or API)**, **Claude Code**, and **any OpenAI-compatible model** (LM Studio, LocalAI, Ollama with an OpenAI shim, etc.).

## 1) Pre-Flight: Files and Environment

1. Copy and edit your environment file:
   ```bash
   cd nkp-claude-code-deployment
   cp environment.env.template environment.env
   # Fill in node IPs, SSH settings, VIP, MetalLB pool, license, etc.
   ```
2. Share the core files with your agent session (or ensure they are on disk for script-only usage):
   - `environment.env`
   - `nkp-deployment-spec.yaml`
   - `CLAUDE_CODE_PROMPTS.md`
   - `PARALLEL_PROMPTS.md`
3. Make scripts executable for local or agent-driven runs:
   ```bash
   chmod +x scripts/*.sh
   ```

## 2) Using OpenAI GPT-5 (ChatGPT / IDE Plugin / API)

### ChatGPT / IDE Plugin workflow
1. Start a new GPT-5 chat and upload (or reference) the repository folder `nkp-claude-code-deployment/`.
2. Ask GPT-5 to read `environment.env` and `CLAUDE_CODE_PROMPTS.md` for context.
3. Kick off the deployment with the Master Deployment Prompt:
   ```
   Deploy NKP 2.16 using the settings in environment.env and nkp-deployment-spec.yaml.
   Run ./scripts/parallel-deploy-and-verify.sh for a parallelized flow with automatic verification.
   Share progress per phase and stop on critical errors.
   ```
4. To run specific phases, instruct GPT-5 to execute the helper scripts:
   ```
   ./scripts/parallel-validate.sh           # Parallel prerequisite checks
   ./scripts/parallel-prepare-nodes.sh      # Parallel node prep
   ./scripts/deploy-nkp.sh                  # Sequential deployment
   ./scripts/verify-deployment.sh           # Post-deploy verification
   ```

### OpenAI API example (any OpenAI-compatible client)
If you use the OpenAI CLI or any SDK, send a system message that references the repo and asks the model to run the parallel runner. Example with the `openai` CLI:
```bash
openai api chat.completions.create \
  -m gpt-5 \
  -g "Deploy NKP with ./scripts/parallel-deploy-and-verify.sh using environment.env and nkp-deployment-spec.yaml. Report each phase." \
  -a code_interpreter
```
*(Replace the model flag with your available GPT-5 endpoint name.)*

## 3) Using Claude Code (CLI, VS Code, or Cursor)
1. Open the `nkp-claude-code-deployment` directory in your editor or terminal.
2. Add context files to the Claude Code session: `environment.env`, `nkp-deployment-spec.yaml`, `CLAUDE_CODE_PROMPTS.md`, and `PARALLEL_PROMPTS.md`.
3. Run the parallelized flow by pasting:
   ```
   Execute ./scripts/parallel-deploy-and-verify.sh.
   If a phase fails, stop and show the failing log from the logs/ directory.
   ```
4. For granular control, use the phase-specific prompts in `PARALLEL_PROMPTS.md` (e.g., run validation and node prep in parallel, then continue sequential deployment and Kommander installation).

## 4) Using Any OpenAI-Compatible Model (LM Studio, LocalAI, Ollama + OpenAI API)
1. Point your client to the compatible API endpoint, for example:
   ```bash
   export OPENAI_API_BASE=http://localhost:8080/v1
   export OPENAI_API_KEY=sk-local
   ```
2. Send the same master request as the OpenAI example, replacing the model name with what your backend exposes:
   ```bash
   curl -s "$OPENAI_API_BASE/chat/completions" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer $OPENAI_API_KEY" \
     -d '{
       "model": "gpt-5-compatible",
       "messages": [
         {"role": "system", "content": "Deploy NKP using the repo files provided."},
         {"role": "user", "content": "Run ./scripts/parallel-deploy-and-verify.sh with environment.env and nkp-deployment-spec.yaml, then share the verification summary."}
       ]
     }'
   ```
3. If the platform supports file attachments, include `environment.env` and `nkp-deployment-spec.yaml` so the model can read the required values.

## 5) Parallel Automation with Built-In Testing

The fastest path—whether driven by an agent or manually—is the new parallel runner:
```bash
./scripts/parallel-deploy-and-verify.sh          # Parallel validation + prep, deploy, verify
./scripts/parallel-deploy-and-verify.sh --skip-prepare   # Skip node prep if already tuned
./scripts/parallel-deploy-and-verify.sh --skip-verify    # Skip post-deploy checks (not recommended)
```
What it does:
- Launches **parallel validation** (`parallel-validate.sh`) and **parallel node prep** (`parallel-prepare-nodes.sh`).
- Runs the standard **deployment** (`deploy-nkp.sh`).
- Automatically executes **verification** (`verify-deployment.sh`) to provide testing automation.
- Writes a concise summary to `logs/parallel-deploy-<timestamp>.summary` and keeps per-task logs in `logs/parallel-tasks-<timestamp>/`.

### Verification-first safety
If you only want to test an existing cluster, call the verification script directly:
```bash
./scripts/verify-deployment.sh
```

## 6) Prompts You Can Copy/Paste
- **Master prompt (any agent):** “Deploy NKP 2.16 using environment.env and nkp-deployment-spec.yaml. Start with ./scripts/parallel-deploy-and-verify.sh and stop on errors.”
- **Validation-only prompt:** “Run ./scripts/parallel-validate.sh and summarize pass/fail counts for bastion, network, and each node.”
- **Verification-only prompt:** “Run ./scripts/verify-deployment.sh and share the verification-summary.txt output.”

Use these snippets with GPT-5, Claude Code, or any OpenAI-compatible model to minimize context switching.
