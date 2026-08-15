# Calibrate GitHub Action

[Calibrate](https://calibrate.artpark.ai) is a framework for evaluating AI agents which let you move from slow, manual testing to a fast, automated, and repeatable testing process for your entire agent stack.,

This action runs your [Calibrate](https://calibrate.artpark.ai) agent tests automatically as part of your CI/CD pipeline.

You give it one or more agents. It runs all the tests attached to those agents,
waits for them to finish, and reports the results. Leave the agent list out and
it runs the tests for every agent in the account linked to the API key.

You can choose what happens when a test fails:

- **gate** (default) — the check fails, so a broken agent can block a merge.
- **report** — the check always passes; it just shows the numbers.
- **gate-if-worse** — the check fails only if fewer tests pass than last time.

## Failing only when things get worse

Some agents never pass every test, so `gate` would block every merge. Use
`mode: gate-if-worse` instead. It compares this run against the agent's
previous run in Calibrate.

- Pass rate the same or higher: the check passes, even with failing tests.
- Pass rate lower: the check fails.
- An agent that cannot run, errors, or times out: the check fails.

The pass rate is one number across all your agents: tests passed divided by
tests run.

Nothing is stored anywhere. Calibrate already keeps every run, so the action
just reads the previous one.

Which previous run: the most recent one that covered the most tests. A run
someone did by hand over three tests is ignored, so it cannot become the number
to beat. An agent with no earlier run is left out, and if that is all of them,
the check passes and says there was nothing to compare with.

One thing to know: if you added tests since the previous run, you are comparing
a rate over 40 tests with a rate over 45. That is what gating on a rate means.

See [`examples/gate-if-worse.yml`](examples/gate-if-worse.yml) for the full
workflow.

If the run is on a pull request, it also adds a comment to the PR with the
results. Re-running updates that same comment instead of adding a new one.

## Setup

1. Create an API key in the Calibrate UI.
2. In your GitHub repo, save it as a secret named `CALIBRATE_API_KEY`
   (Settings → Secrets and variables → Actions).
3. Add the workflow file below to your repo.

The workflow includes a `permissions` block that lets the action post its
results as a comment on your pull requests. Keep it if you want the PR comment;
remove it if you don't.

## Usage

```yaml
# .github/workflows/calibrate.yml
name: Calibrate
on: [pull_request]

permissions:
  contents: read
  pull-requests: write # for the PR comment

jobs:
  agent-tests:
    runs-on: ubuntu-slim
    steps:
      - uses: ARTPARK-SAHAI-ORG/calibrate-github-action@v1
        with:
          api-key: ${{ secrets.CALIBRATE_API_KEY }}
          agents: checkout-bot, support-agent
```

You can also list agents one per line:

```yaml
agents: |
  checkout-bot
  support-agent
```

Or omit `agents` to run every agent in the account linked to the API key:

```yaml
- uses: ARTPARK-SAHAI-ORG/calibrate-github-action@v1
  with:
    api-key: ${{ secrets.CALIBRATE_API_KEY }}
```

## Inputs

| Input           | Required | Default                            | Description                                                                                                                                    |
| --------------- | -------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `api-key`       | yes      | —                                  | `sk_…` key. Use a secret.                                                                                                                      |
| `agents`        | no       | _all agents_                       | Agent names, separated by commas or newlines. Runs **all** tests linked to each. Omit to run every agent in the account linked to the API key. |
| `base-url`      | no       | `https://pense-backend.artpark.ai` | Backend API. Override only for self-hosted.                                                                                                    |
| `app-url`       | no       | `https://calibrate.artpark.ai`     | Web UI base for `view` links in the report.                                                                                                    |
| `mode`          | no       | `gate`                             | `gate` fails the job on any failure; `report` always succeeds; `gate-if-worse` fails only if the pass rate drops.                               |
| `poll-interval` | no       | `5`                                | Seconds between status polls.                                                                                                                  |
| `timeout`       | no       | `1800`                             | Max seconds to wait for runs to finish.                                                                                                        |

## Outputs

`total`, `passed`, `failed` — test-case counts across all agents.

`pass-rate`, `previous-pass-rate` — the two percentages compared in
`gate-if-worse` mode. Both are empty in the other modes, and when there was no
earlier run to compare against.
