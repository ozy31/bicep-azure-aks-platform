# 4. AI workloads: managed models first, GPU nodes on demand

## Status

Accepted

## Context

Teams want to run LLM features on the platform: calling hosted models from
services in the cluster, and serving a few open-weight models themselves
(embeddings, small rerankers, fine-tuned checkpoints). Both paths have the
same failure modes as any other dependency, plus two new ones: a GPU node
costs more per hour than the rest of a dev environment, and an API key for
a model endpoint is a secret that ends up in logs and laptops.

## Decision

- **Hosted models through a private Azure OpenAI account.** Public network
  access is off, the account is reached through a private endpoint in the
  spoke, and `disableLocalAuth` removes API keys entirely. Pods call it with
  workload identity; an identity only gets *Cognitive Services OpenAI User*
  when its entry in `workloadIdentities` sets `openAi: true`.
- **Model versions are pinned** (`versionUpgradeOption: NoAutoUpgrade`) and
  deployments are created one at a time, because the service rejects
  parallel changes on one account. A version change is a pull request.
- **Data zone deployments in the EU** keep prompts and completions in the
  region group, which matters more than the small price difference to
  global deployments.
- **Self-hosted models on a GPU pool that scales from zero.** The pool is
  tainted `nvidia.com/gpu=present:NoSchedule`, so only pods that ask for a
  GPU land there, and the cluster autoscaler adds a node only while such a
  pod is pending. Dev uses Spot capacity; prod uses regular capacity
  because an evicted inference node drops in-flight requests.
- **KEDA for scaling inference.** Request queues and token throughput say
  more about inference load than CPU does. The managed KEDA add-on scales
  deployments on Prometheus queries or queue length, and to zero where a
  cold start is acceptable.
- **Quota is an alert, not a retry loop.** Sustained HTTP 429s from Azure
  OpenAI page the platform action group: the fix is capacity (tokens per
  minute, or a second region), not clients retrying harder.

## Consequences

- No model API key exists to leak. Local development against the dev
  account needs `az login` and a role assignment, not a shared key.
- GPU nodes take several minutes to join (image pull, driver). Latency
  sensitive models should keep `minCount: 1` in prod; batch work can wait.
- The NVIDIA device plugin (or the GPU operator) has to run on the GPU pool
  before pods can request `nvidia.com/gpu`; it is installed by the GitOps
  layer, not by this template.
- Spot evictions in dev are expected. Workloads that cannot tolerate them
  do not belong on the dev GPU pool.
