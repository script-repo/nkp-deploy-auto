# Repository Review and Improvement Notes

## What This Repository Does

`nkp-deploy-auto` automates the full deployment lifecycle of **Nutanix Kubernetes
Platform (NKP) 2.16** on pre-provisioned infrastructure.  It covers:

| Phase | Script(s) |
|---|---|
| Bastion host setup | `install-bastion-prereqs.sh`, `install-deps-run-ui.sh` |
| Prism Central discovery | `scripts/prism_client.py`, `ui/app.py /api/verify` |
| Pre-flight validation (parallel) | `parallel-validate.sh`, `validate-node.sh` |
| Node preparation (parallel SSH) | `parallel-prepare-nodes.sh` |
| NKP cluster deployment (9 phases) | `deploy-nkp.sh` |
| Post-deployment verification | `verify-deployment.sh` |
| Parallel orchestration | `parallel-deploy-and-verify.sh` |
| Web UI (Flask) | `ui/app.py` |

---

## Code Validation — All Bugs Found

### Critical (would crash the application)

1. **`ui/app.py` — wrong `prism_client` import path**
   Flask starts with `cwd=ui/`.  The import `from scripts.prism_client import
   gather_inventory` resolves relative to the Python path, not the file system.
   Without inserting the repo root into `sys.path` first, Python raises
   `ModuleNotFoundError` at startup, preventing Flask from running at all.

2. **`ui/app.py` — `CONFIG_FILE` undefined in `load_config()`**
   `load_config()` tests `CONFIG_FILE.exists()` but `CONFIG_FILE` was never
   defined.  Any call to `load_config()` (including the index route) raises
   `NameError`.

3. **`ui/app.py` — wrong variable name in `load_config()` body**
   The function declares `parsed: Dict[str, Any] = {}` but the loop accumulates
   into an undeclared `config` variable, and then returns `config`.  Both the
   assignment and the return raise `NameError`.

4. **`ui/app.py` — `state` dict never initialized**
   `update_state()`, `api_run()`, and `stream()` all reference `state` (e.g.
   `state["progress"]`, `state.get("running")`), but no `state` object was
   defined anywhere in the module.  Every call to those functions raises
   `NameError`.

5. **`ui/app.py` — `PHASE_KEYWORDS` dict never defined**
   `detect_phase()` iterates `PHASE_KEYWORDS.items()` but `PHASE_KEYWORDS` is
   never declared, causing `NameError` the first time output is streamed from
   a deployment subprocess.

6. **`ui/app.py` — `shlex` used but not imported**
   `format_env_lines()` calls `shlex.quote()` to safely quote env-file values,
   but `shlex` is not in the import list.  Every config-save operation raises
   `NameError`.

7. **`ui/app.py` — `List` and `Tuple` not imported**
   Type annotations (`List[str]`, `Tuple[str, List[str]]`) reference these
   names from `typing`, but only `Any` and `Dict` were imported.  Although
   `from __future__ import annotations` defers most annotation evaluation,
   runtime subscript operations on these names in non-annotation contexts
   (e.g. variable-level annotations evaluated by some tooling) will fail.

### Functional breakage (features silently broken)

8. **`ui/app.py` — `api_run()` passes no arguments to `run_deployment()`**
   `run_deployment(mode, phases, extra_env)` has two required positional
   arguments.  The old `api_run()` created a `Thread(target=run_deployment)`
   with no `args`, so the thread crashed immediately upon start with
   `TypeError`.

9. **`ui/app.py` — index route does not pass `phase_sets` to template**
   The template references `{{ phase_sets | tojson }}` in a `<script>` block,
   but the route called `render_template("index.html", config=load_config())`
   without passing `phase_sets`.  Jinja2 raises `UndefinedError` and serves a
   500 to every browser request.

10. **`ui/app.py` — `defaults` dict used inconsistent variable names**
    The `defaults` dict (merged into every config save) used `SSH_USERNAME`,
    `SSH_PRIVATE_KEY_PATH`, `OUTPUT_DIRECTORY`, and `NODE_CIDR` — names that
    do not match `DEFAULT_CONFIG`, `FIELD_METADATA`, or the shell scripts.
    Saving config via `/api/save-config` would write an env file with keys
    the scripts can never read.

11. **`environment.env.template` — variable names differ from what scripts read**
    The template exposed `SSH_USERNAME`, `SSH_PRIVATE_KEY_PATH`, and
    `OUTPUT_DIRECTORY`.  Every script (`validate-prerequisites.sh`,
    `deploy-nkp.sh`, `parallel-validate.sh`, `validate-node.sh`) reads
    `SSH_USER`, `SSH_PRIVATE_KEY_FILE`, and `OUTPUT_DIR`.  A user who filled in
    the template and sourced it would find all node connectivity and path checks
    failing with empty-variable errors.  The template was also missing many
    variables the scripts require (`CLUSTER_NAME`, `CONTROL_PLANE_*_ADDRESS`,
    `WORKER_*_ADDRESS`, `ALL_NODES`, `CONTROL_PLANE_ENDPOINT_HOST`, etc.).

### Minor / cosmetic

12. **`install-bastion-prereqs.sh` — single-quoted heredoc suppresses expansion**
    The post-checks `cat <<'SUMMARY'` block used a single-quoted delimiter,
    which prevents all command substitution.  Users always saw the literal text
    `$(docker --version 2>/dev/null || echo "not found")` instead of actual
    version strings.

---

## Improvements Implemented

### Improvement 1 — Fix all critical bugs in `ui/app.py`

**Files changed:** `ui/app.py`

**Changes:**
- Added `shlex`, `sys` to stdlib imports; added `List`, `Tuple` to `typing`
  imports.
- Added early `sys.path.insert(0, str(_REPO_ROOT))` so
  `from scripts.prism_client import gather_inventory` resolves correctly
  regardless of the Flask working directory.
- Added `CONFIG_FILE = DEPLOYMENT_FILE` constant so `load_config()` has a
  defined name to check.
- Added `state: Dict[str, Any]` dict (progress, status, step, running) at
  module level, shared between the background deployment thread and all routes.
- Added `PHASE_KEYWORDS: Dict[str, str]` dict mapping lowercase log-line
  fragments to human-readable phase names.
- Fixed `load_config()`: replaced `config[key] = …` with `parsed[key] = …`
  and changed `return config` to `return parsed`; also added `return {}` for
  the no-file case.
- Updated `update_state()` to also set `state["running"]` whenever `status`
  changes, keeping the state dict consistent.
- Fixed `api_run()`: changed `state.get("running")` guard to `deployment_active`
  (the authoritative flag), and passed `args=("automated", PHASE_SETS["automated"], None)`
  to the thread so `run_deployment` receives its required arguments.
- Fixed `stream()`: replaced `state.get("running")` with `deployment_active`.
- Fixed `index()` route: added `phase_sets=PHASE_SETS` to `render_template()`
  so the template's `{{ phase_sets | tojson }}` resolves without error.
- Fixed `defaults` dict: renamed `SSH_USERNAME` → `SSH_USER`,
  `SSH_PRIVATE_KEY_PATH` → `SSH_PRIVATE_KEY_FILE`,
  `OUTPUT_DIRECTORY` → `OUTPUT_DIR`, `NODE_CIDR` → `POD_CIDR` to match
  all other dictionaries in the file and the shell scripts.

**Why this matters:** Without these fixes the Flask application cannot start
(import error), and every core user-facing action (load config, save config,
launch deployment, stream logs) would raise an unhandled exception.

---

### Improvement 2 — Align `environment.env.template` with script variable names

**Files changed:** `environment.env.template`

**Changes:**
- Renamed `SSH_USERNAME` → `SSH_USER` (used by every script).
- Renamed `SSH_PRIVATE_KEY_PATH` → `SSH_PRIVATE_KEY_FILE`.
- Renamed `OUTPUT_DIRECTORY` → `OUTPUT_DIR`; updated `KUBECONFIG_PATH`
  reference accordingly.
- Added all missing required variables:
  `CLUSTER_NAME`, `CONTROL_PLANE_{1,2,3}_ADDRESS`, `WORKER_{1,2,3,4}_ADDRESS`,
  `CONTROL_PLANE_NODES`, `WORKER_NODES`, `ALL_NODES` (needed by the parallel
  loops in `parallel-validate.sh` and `parallel-prepare-nodes.sh`),
  `CONTROL_PLANE_ENDPOINT_HOST`, `CONTROL_PLANE_ENDPOINT_PORT`,
  `VIRTUAL_IP_INTERFACE`, `SSH_PRIVATE_KEY_SECRET_NAME`, `POD_CIDR`,
  proxy vars, storage vars, registry vars, air-gap vars, timeout vars,
  `VERBOSE`, `FIPS_MODE`.
- Kept Prism-Central and target vars from the original template (they are
  optional / UI-populated).
- Removed `NODE_CIDR` (not used by any script; `POD_CIDR` is the correct name).

**Why this matters:** A user following the README's "copy and fill in the
template" instruction would source a file with wrong variable names, causing
every prerequisite check, SSH loop, and deployment command to fail with
confusing "unbound variable" or "command not found" errors.

---

### Improvement 3 — Fix `install-bastion-prereqs.sh` post-checks heredoc

**Files changed:** `scripts/install-bastion-prereqs.sh`

**Changes:**
- Changed `cat <<'SUMMARY'` to `cat <<SUMMARY` (removed single quotes from
  the delimiter).
- Updated the SSH check from `sshd -V >/dev/null 2>&1 && echo "enabled"` to
  `command -v sshd >/dev/null 2>&1 && sshd -V 2>&1 | head -1` so the version
  string is actually captured (sshd writes version to stderr on `-V`).
- Added a fallback for `kubectl version` since `--short` is deprecated in
  recent releases.

**Why this matters:** Operators who run `install-bastion-prereqs.sh` use the
post-check summary to confirm that Docker, kubectl, and Helm were installed
correctly.  With a single-quoted heredoc every line prints literal
`$(command ...)` text, making the summary useless and potentially masking
installation failures.
